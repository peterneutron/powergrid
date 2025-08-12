package main

import (
	"context"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"google.golang.org/grpc"

	// Use your actual module path for powerkit-go
	"github.com/peterneutron/powerkit-go/pkg/powerkit"

	// This is the relative path to our generated gRPC code
	rpc "powergrid/generated/go"
	cfg "powergrid/internal/config"
	consoleuser "powergrid/internal/consoleuser"
	oslogger "powergrid/internal/oslogger"
)

const (
	// Using a path in /var/run is standard for system-wide daemons.
	socketPath = "/var/run/powergrid.sock"
	// For v0.x.x, the limit is hardcoded. We'll add config files later.
	defaultChargeLimit = 80
	// Logger filter Key
	logSubsystem = "com.neutronstar.powergrid.daemon"
)

// --- Use our new custom logger ---
// We create one logger for the whole application with a general category.
// Console.app lets us filter by category if we need to.
var logger = oslogger.NewLogger(logSubsystem, "Daemon")

// powerGridServer implements our gRPC service. It holds the daemon's state.
type powerGridServer struct {
	rpc.UnimplementedPowerGridServer

	mu                 sync.RWMutex
	currentLimit       int32
	isChargeLimited    bool
	lastIOKitStatus    *powerkit.IOKitData
	lastSMCStatus      *powerkit.SMCData
	lastBatteryWattage float32
	lastAdapterWattage float32
	lastSystemWattage  float32

	// console user tracking
	currentConsoleUser *consoleuser.ConsoleUser

	// assertion intent flags (UI-stable)
	wantPreventDisplaySleep bool
	wantPreventSystemSleep  bool
}

// GetStatus is the gRPC handler for providing status to the UI.
func (s *powerGridServer) GetStatus(_ context.Context, _ *rpc.Empty) (*rpc.StatusResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// If we haven't received any data yet, return a default state.
	if s.lastIOKitStatus == nil {
		return &rpc.StatusResponse{ChargeLimit: s.currentLimit, AdapterDescription: "Initializing..."}, nil
	}

	resp := &rpc.StatusResponse{
		CurrentCharge:      int32(s.lastIOKitStatus.Battery.CurrentCharge),
		IsCharging:         s.lastIOKitStatus.State.IsCharging,
		IsConnected:        s.lastIOKitStatus.State.IsConnected,
		ChargeLimit:        s.currentLimit,
		IsChargeLimited:    s.isChargeLimited,
		CycleCount:         int32(s.lastIOKitStatus.Battery.CycleCount),
		AdapterDescription: s.lastIOKitStatus.Adapter.Description,
		BatteryWattage:     s.lastBatteryWattage,
		AdapterWattage:     s.lastAdapterWattage,
		SystemWattage:      s.lastSystemWattage,
		// New fields populated from latest snapshots
		HealthByMax:               int32(s.lastIOKitStatus.Calculations.HealthByMaxCapacity),
		AdapterInputVoltage:       float32(s.lastIOKitStatus.Adapter.InputVoltage),
		AdapterInputAmperage:      float32(s.lastIOKitStatus.Adapter.InputAmperage),
		PreventDisplaySleepActive: s.wantPreventDisplaySleep,
		PreventSystemSleepActive:  s.wantPreventSystemSleep,
		ForceDischargeActive: func() bool {
			if s.lastSMCStatus != nil {
				return !s.lastSMCStatus.State.IsAdapterEnabled
			}
			// If we don't have SMC, infer as false.
			return false
		}(),
	}
	if s.lastSMCStatus != nil {
		resp.SmcChargingEnabled = s.lastSMCStatus.State.IsChargingEnabled
		resp.SmcAdapterEnabled = s.lastSMCStatus.State.IsAdapterEnabled
	}
	return resp, nil
}

// SetChargeLimit is the gRPC handler for changing the charge limit.
func (s *powerGridServer) SetChargeLimit(_ context.Context, req *rpc.SetChargeLimitRequest) (*rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	newLimit := req.GetLimit()
	if newLimit < 60 || newLimit > 100 {
		logger.Default("Ignoring invalid charge limit: %d", newLimit)
		return &rpc.Empty{}, nil
	}

	// If no console user is present, default to daemon's default and do not persist.
	if s.currentConsoleUser == nil {
		logger.Default("SetChargeLimit requested with no console user; using daemon default %d%%", defaultChargeLimit)
		s.currentLimit = defaultChargeLimit
		go s.runChargingLogic(nil)
		return &rpc.Empty{}, nil
	}

	u := s.currentConsoleUser
	// Persist to the user's preferences and update in-memory limit.
	if err := cfg.WriteUserChargeLimit(u.HomeDir, u.UID, int(newLimit)); err != nil {
		logger.Error("Failed to persist user charge limit for %s: %v", u.Username, err)
		// Still update in-memory so UX isn't blocked; it will be reconciled on next read.
	} else {
		logger.Default("Persisted user charge limit %d%% for %s", newLimit, u.Username)
	}
	// Update effective limit snapshot immediately.
	s.currentLimit = newLimit

	// Trigger an immediate logic check with the new limit (synchronous so UI sees fresh status).
	s.runChargingLogic(nil)

	return &rpc.Empty{}, nil
}

// SetPowerFeature enables or disables application-local power assertions and adapter state.
func (s *powerGridServer) SetPowerFeature(_ context.Context, req *rpc.SetPowerFeatureRequest) (*rpc.Empty, error) {
	switch req.GetFeature() {
	case rpc.PowerFeature_PREVENT_DISPLAY_SLEEP:
		s.mu.Lock()
		s.wantPreventDisplaySleep = req.GetEnable()
		s.mu.Unlock()
		if req.GetEnable() {
			if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventDisplaySleep, "PowerGrid: Prevent Display Sleep"); err != nil {
				logger.Error("Failed to create display sleep assertion: %v", err)
			} else {
				logger.Default("Successfully created display sleep assertion.")
			}
		} else {
			powerkit.ReleaseAssertion(powerkit.AssertionTypePreventDisplaySleep)
			logger.Default("Successfully released display sleep assertion.")
		}
	case rpc.PowerFeature_PREVENT_SYSTEM_SLEEP:
		s.mu.Lock()
		s.wantPreventSystemSleep = req.GetEnable()
		s.mu.Unlock()
		if req.GetEnable() {
			if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventSystemSleep, "PowerGrid: Prevent System Sleep"); err != nil {
				logger.Error("Failed to create system sleep assertion: %v", err)
			} else {
				logger.Default("Successfully created system sleep assertion.")
			}
		} else {
			powerkit.ReleaseAssertion(powerkit.AssertionTypePreventSystemSleep)
			logger.Default("Successfully released system sleep assertion.")
		}
	case rpc.PowerFeature_FORCE_DISCHARGE:
		if req.GetEnable() {
			if err := powerkit.SetAdapterState(powerkit.AdapterActionOff); err != nil {
				logger.Error("Failed to force discharge (adapter off): %v", err)
			} else {
				logger.Default("Successfully disabled adapter (force discharge).")
			}
		} else {
			if err := powerkit.SetAdapterState(powerkit.AdapterActionOn); err != nil {
				logger.Error("Failed to re-enable adapter: %v", err)
			} else {
				logger.Default("Successfully re-enabled adapter.")
			}
		}
	default:
		// No-op for unspecified/unknown
	}

	// After changing a feature, update status immediately (synchronous so UI sees fresh status).
	s.runChargingLogic(nil)
	return &rpc.Empty{}, nil
}

// runChargingLogic is the core decision-making function. It should be triggered on events.
func (s *powerGridServer) runChargingLogic(info *powerkit.SystemInfo) {
	var err error
	// If no info is provided (e.g., on wake-up), fetch the latest.
	if info == nil {
		info, err = powerkit.GetSystemInfo()
		if err != nil {
			logger.Error("Failed to get system info: %v", err)
			return
		}
	}

	// Lock for state updates
	s.mu.Lock()
	defer s.mu.Unlock()

	// Preserve SMC snapshot across IOKit-only events so we don't lose adapter/charging state.
	if info.SMC == nil && s.lastSMCStatus != nil {
		info.SMC = s.lastSMCStatus
	}

	s.lastIOKitStatus = info.IOKit
	s.lastSMCStatus = info.SMC

	if info.IOKit != nil {
		s.lastBatteryWattage = float32(info.IOKit.Calculations.BatteryPower)
		s.lastAdapterWattage = float32(info.IOKit.Calculations.AdapterPower)
		s.lastSystemWattage = float32(info.IOKit.Calculations.SystemPower)
	}

	if info.IOKit == nil || info.SMC == nil {
		logger.Default("Skipping logic run due to incomplete data.")
		return
	}

	charge := info.IOKit.Battery.CurrentCharge
	limit := int(s.currentLimit)
	isChargingSMC := info.SMC.State.IsChargingEnabled

	// THE CORE LOGIC
	// if charge >= limit && isChargingSMC {
	// Only try to disable charging if we are over the limit, the SMC reports charging is enabled,
	// AND we don't already believe we are the ones who limited it.
	if charge >= limit && isChargingSMC && !s.isChargeLimited {
		logger.Default("Charge %d%% >= Limit %d%%. Disabling charging.", charge, limit)
		if err := powerkit.SetChargingState(powerkit.ChargingActionOff); err != nil {
			logger.Error("Failed to disable charging: %v", err)
		} else {
			s.isChargeLimited = true
			logger.Default("Successfully disabled charging.")
		}
	} else if charge < limit && !isChargingSMC {
		logger.Default("Charge %d%% < Limit %d%%. Re-enabling charging.", charge, limit)
		if err := powerkit.SetChargingState(powerkit.ChargingActionOn); err != nil {
			logger.Error("Failed to enable charging: %v", err)
		} else {
			s.isChargeLimited = false
			logger.Default("Successfully enabled charging.")
		}
	}
}

// startEventStream monitors the system for changes and triggers the logic.
func (s *powerGridServer) startEventStream() {
	eventChan, err := powerkit.StreamSystemEvents()
	if err != nil {
		logger.Error("FATAL: Failed to start powerkit event stream: %v", err)
	}

	logger.Default("Daemon event stream started. Watching for all power events.")
	// This loop now handles all event types from the unified channel.
	for event := range eventChan {
		// Use a switch on the event type to determine the action.
		switch event.Type {

		case powerkit.EventTypeSystemWillSleep:
			s.handleSleep()

		case powerkit.EventTypeSystemDidWake:
			logger.Default("System woke up. Re-evaluating charging state in 5 seconds...")
			// Run the logic in a new goroutine so we don't block the event loop.
			// A short delay allows system services to settle before we check.
			go func() {
				time.Sleep(5 * time.Second)
				logger.Default("Re-evaluating charging state now.")
				// Pass nil to force runChargingLogic to fetch fresh data.
				s.runChargingLogic(nil)
			}()

		case powerkit.EventTypeBatteryUpdate:
			logger.Info("Received a battery status update, running charging logic.")
			if event.Info != nil {
				// We received a battery status update, so run our standard logic.
				// Pass the event's data to be more efficient.
				s.runChargingLogic(event.Info)
			}
		}
	}
}

// --- Console user handling ---

// startConsoleUserEventHandler listens for events from the consoleuser package
// and triggers the logic to handle user transitions.
func (s *powerGridServer) startConsoleUserEventHandler() {
	// Get the event channel from the consoleuser package.
	userEvents := consoleuser.Watch()

	// Run once immediately on start to get the initial user.
	s.handleConsoleUserChange(nil)

	// Start a goroutine to process events from the channel.
	go func() {
		for range userEvents {
			logger.Default("Received console user change event. Re-evaluating in 1 second...")
			// A short delay helps debounce rapid login/logout events.
			time.Sleep(1 * time.Second)
			s.handleConsoleUserChange(nil)
		}
	}()
}

// startConsoleUserWatcher polls /dev/console ownership periodically and applies
// safety-first transitions on user changes.
func (s *powerGridServer) startConsoleUserWatcher() {
	ticker := time.NewTicker(5 * time.Second)
	// Run once immediately
	s.handleConsoleUserChange(nil)
	go func() {
		for range ticker.C {
			s.handleConsoleUserChange(&struct{}{})
		}
	}()
}

// handleConsoleUserChange reads the current console user and applies transitions
// if it changed from the previous value.
func (s *powerGridServer) handleConsoleUserChange(_ interface{}) {
	userNow, err := consoleuser.Current()
	if err != nil {
		logger.Error("Console user check failed: %v", err)
		return
	}

	s.mu.Lock()
	prev := s.currentConsoleUser
	same := (prev == nil && userNow == nil) || (prev != nil && userNow != nil && prev.UID == userNow.UID)
	s.mu.Unlock()

	if same {
		return
	}

	if userNow == nil {
		s.enterNoUser()
	} else {
		s.enterConsoleUser(userNow)
	}
}

func (s *powerGridServer) enterNoUser() {
	s.mu.Lock()
	s.currentConsoleUser = nil
	s.wantPreventDisplaySleep = false
	s.wantPreventSystemSleep = false
	s.mu.Unlock()

	logger.Default("Entering NoUser state: clearing assertions, enabling adapter, applying system/effective limit")
	// Safety actions
	powerkit.AllowAllSleep()
	if err := powerkit.SetAdapterState(powerkit.AdapterActionOn); err != nil {
		logger.Error("Failed to ensure adapter ON in NoUser: %v", err)
	}

	// Apply effective limit using daemon store (preferred), fallback to old defaults
	systemLimit := cfg.ReadSystemChargeLimitStore()
	if systemLimit == 0 {
		systemLimit = cfg.ReadSystemChargeLimit()
	}
	effective := cfg.EffectiveChargeLimit(0, systemLimit, defaultChargeLimit)
	s.mu.Lock()
	s.currentLimit = int32(effective)
	s.mu.Unlock()
	logger.Default("Applied effective limit (no user): %d%% (system=%d, default=%d)", effective, systemLimit, defaultChargeLimit)

	// Re-evaluate logic
	go s.runChargingLogic(nil)
}

func (s *powerGridServer) enterConsoleUser(u *consoleuser.ConsoleUser) {
	s.mu.Lock()
	s.currentConsoleUser = u
	s.wantPreventDisplaySleep = false
	s.wantPreventSystemSleep = false
	s.mu.Unlock()

	logger.Default("Entering ConsoleUser state (%s): clearing assertions, enabling adapter, applying effective limit", u.Username)
	// Safety actions on user switch
	powerkit.AllowAllSleep()
	if err := powerkit.SetAdapterState(powerkit.AdapterActionOn); err != nil {
		logger.Error("Failed to ensure adapter ON on user switch: %v", err)
	}

	// Load read-only preferences: prefer daemon store, fallback to defaults.
	systemLimit := cfg.ReadSystemChargeLimitStore()
	if systemLimit == 0 {
		systemLimit = cfg.ReadSystemChargeLimit()
	}
	userLimit := cfg.ReadUserChargeLimitStore(u.UID)
	if userLimit == 0 {
		userLimit = cfg.ReadUserChargeLimit(u.HomeDir)
	}
	effective := cfg.EffectiveChargeLimit(userLimit, systemLimit, defaultChargeLimit)
	s.mu.Lock()
	s.currentLimit = int32(effective)
	s.mu.Unlock()
	logger.Default("Applied effective limit for %s: %d%% (user=%d, system=%d, default=%d)", u.Username, effective, userLimit, systemLimit, defaultChargeLimit)

	// Re-evaluate logic
	go s.runChargingLogic(nil)
}

// handleSleep is called just before the system sleeps. It unconditionally
// disables charging to prevent overcharging while asleep.
func (s *powerGridServer) handleSleep() {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Only act if charging is not already limited by us.
	if !s.isChargeLimited {
		logger.Default("System is going to sleep. Proactively disabling charging.")
		// Set our internal state to true FIRST. This is our intent.
		// This ensures that even if the command below fails, the daemon will wake up
		// in a safe, non-charging state and re-evaluate correctly.
		s.isChargeLimited = true

		if err := powerkit.SetChargingState(powerkit.ChargingActionOff); err != nil {
			logger.Error("Failed to disable charging for sleep: %v", err)
		} else {
			//s.isChargeLimited = true
			logger.Default("Successfully disabled charging for sleep.")
		}
	}
}

func main() {
	logger.Default("Starting PowerGrid Daemon...")
	if os.Geteuid() != 0 {
		logger.Fault("FATAL: PowerGrid Daemon must be run as root.")
		os.Exit(1)
	}
	// Ensure daemon-owned system config exists with default limit if missing.
	if err := cfg.EnsureSystemConfig(defaultChargeLimit); err != nil {
		logger.Error("Failed to ensure system config: %v", err)
	}

	if err := os.RemoveAll(socketPath); err != nil {
		logger.Fault("FATAL: Failed to remove old socket: %v", err)
		os.Exit(1)
	}

	lis, err := net.Listen("unix", socketPath)
	if err != nil {
		logger.Fault("FATAL: Failed to listen on socket: %v", err)
		os.Exit(1)
	}
	if err := os.Chmod(socketPath, 0777); err != nil {
		logger.Fault("FATAL: Failed to set socket permissions:  %v", err)
		os.Exit(1)
	}

	grpcServer := grpc.NewServer()
	server := &powerGridServer{currentLimit: defaultChargeLimit}
	rpc.RegisterPowerGridServer(grpcServer, server)

	// Run the first logic check immediately on start and start console user watcher.
	go server.runChargingLogic(nil)
	server.startConsoleUserEventHandler()

	// Apply initial NoUser safety defaults at boot until a user is detected.
	// server.enterNoUser()

	// Start the event listener in the background.
	go server.startEventStream()

	// Start the gRPC server to handle requests from the UI.
	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			logger.Fault("FATAL: Failed to serve gRPC: %v", err)
		}
	}()

	logger.Default("PowerGrid Daemon is running.")

	// Graceful shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Default("Shutting down PowerGrid Daemon...")
	grpcServer.GracefulStop()
	if err := os.RemoveAll(socketPath); err != nil {
		logger.Error("Failed to remove socket on shutdown: %v", err)

	}
}
