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

	"github.com/peterneutron/powerkit-go/pkg/powerkit"

	rpc "powergrid/generated/go"
	cfg "powergrid/internal/config"
	consoleuser "powergrid/internal/consoleuser"
	oslogger "powergrid/internal/oslogger"
)

const (
	socketPath         = "/var/run/powergrid.sock"
	defaultChargeLimit = 80
	logSubsystem       = "com.neutronstar.powergrid.daemon"
)

var logger = oslogger.NewLogger(logSubsystem, "Daemon")

type powerGridServer struct {
	rpc.UnimplementedPowerGridServer

	mu                      sync.RWMutex
	currentLimit            int32
	lastIOKitStatus         *powerkit.IOKitData
	lastSMCStatus           *powerkit.SMCData
	lastBatteryWattage      float32
	lastAdapterWattage      float32
	lastSystemWattage       float32
	currentConsoleUser      *consoleuser.ConsoleUser
	wantPreventDisplaySleep bool
	wantPreventSystemSleep  bool
}

func (s *powerGridServer) GetStatus(_ context.Context, _ *rpc.Empty) (*rpc.StatusResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.lastIOKitStatus == nil {
		return &rpc.StatusResponse{ChargeLimit: s.currentLimit, AdapterDescription: "Initializing..."}, nil
	}

	resp := &rpc.StatusResponse{
		CurrentCharge:             int32(s.lastIOKitStatus.Battery.CurrentCharge),
		IsCharging:                s.lastIOKitStatus.State.IsCharging,
		IsConnected:               s.lastIOKitStatus.State.IsConnected,
		ChargeLimit:               s.currentLimit,
		IsChargeLimited:           !s.lastSMCStatus.State.IsChargingEnabled,
		CycleCount:                int32(s.lastIOKitStatus.Battery.CycleCount),
		AdapterDescription:        s.lastIOKitStatus.Adapter.Description,
		AdapterMaxWatts:           int32(s.lastIOKitStatus.Adapter.MaxWatts),
		BatteryWattage:            s.lastBatteryWattage,
		AdapterWattage:            s.lastAdapterWattage,
		SystemWattage:             s.lastSystemWattage,
		HealthByMax:               int32(s.lastIOKitStatus.Calculations.HealthByMaxCapacity),
		AdapterInputVoltage:       float32(s.lastIOKitStatus.Adapter.InputVoltage),
		AdapterInputAmperage:      float32(s.lastIOKitStatus.Adapter.InputAmperage),
		TimeToFullMinutes:         int32(s.lastIOKitStatus.Battery.TimeToFull),
		TimeToEmptyMinutes:        int32(s.lastIOKitStatus.Battery.TimeToEmpty),
		PreventDisplaySleepActive: s.wantPreventDisplaySleep,
		PreventSystemSleepActive:  s.wantPreventSystemSleep,
		ForceDischargeActive: func() bool {
			if s.lastSMCStatus != nil {
				return !s.lastSMCStatus.State.IsAdapterEnabled
			}
			return false
		}(),
	}
	if s.lastSMCStatus != nil {
		resp.SmcChargingEnabled = s.lastSMCStatus.State.IsChargingEnabled
		resp.SmcAdapterEnabled = s.lastSMCStatus.State.IsAdapterEnabled
	}
	return resp, nil
}

func (s *powerGridServer) SetChargeLimit(_ context.Context, req *rpc.SetChargeLimitRequest) (*rpc.Empty, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	newLimit := req.GetLimit()
	if newLimit < 60 || newLimit > 100 {
		logger.Default("Ignoring invalid charge limit: %d", newLimit)
		return &rpc.Empty{}, nil
	}

	if s.currentConsoleUser == nil {
		logger.Default("SetChargeLimit requested with no console user; using daemon default %d%%", defaultChargeLimit)
		s.currentLimit = defaultChargeLimit
	} else {
		u := s.currentConsoleUser
		if err := cfg.WriteUserChargeLimit(u.HomeDir, u.UID, int(newLimit)); err != nil {
			logger.Error("Failed to persist user charge limit for %s: %v", u.Username, err)
		} else {
			logger.Default("Persisted user charge limit %d%% for %s", newLimit, u.Username)
		}
		s.currentLimit = newLimit
	}

	s.runChargingLogicLocked(nil)

	return &rpc.Empty{}, nil
}

func (s *powerGridServer) SetPowerFeature(_ context.Context, req *rpc.SetPowerFeatureRequest) (*rpc.Empty, error) {
	switch req.GetFeature() {
	case rpc.PowerFeature_PREVENT_DISPLAY_SLEEP:
		s.mu.Lock()
		s.wantPreventDisplaySleep = req.GetEnable()
		s.mu.Unlock()
		if req.GetEnable() {
			if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventDisplaySleep, "PowerGrid: Prevent Display Sleep"); err != nil {
				logger.Error("Failed to create display sleep assertion: %v", err)
			}
		} else {
			powerkit.ReleaseAssertion(powerkit.AssertionTypePreventDisplaySleep)
		}
	case rpc.PowerFeature_PREVENT_SYSTEM_SLEEP:
		s.mu.Lock()
		s.wantPreventSystemSleep = req.GetEnable()
		s.mu.Unlock()
		if req.GetEnable() {
			if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventSystemSleep, "PowerGrid: Prevent System Sleep"); err != nil {
				logger.Error("Failed to create system sleep assertion: %v", err)
			}
		} else {
			powerkit.ReleaseAssertion(powerkit.AssertionTypePreventSystemSleep)
		}
	case rpc.PowerFeature_FORCE_DISCHARGE:
		if req.GetEnable() {
			if err := powerkit.SetAdapterState(powerkit.AdapterActionOff); err != nil {
				logger.Error("Failed to force discharge (adapter off): %v", err)
			}
		} else {
			if err := powerkit.SetAdapterState(powerkit.AdapterActionOn); err != nil {
				logger.Error("Failed to re-enable adapter: %v", err)
			}
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.runChargingLogicLocked(nil)
	return &rpc.Empty{}, nil
}

func (s *powerGridServer) runChargingLogic(info *powerkit.SystemInfo) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.runChargingLogicLocked(info)
}

func (s *powerGridServer) runChargingLogicLocked(info *powerkit.SystemInfo) {
	var err error
	if info == nil {
		info, err = powerkit.GetSystemInfo()
		if err != nil {
			logger.Error("Failed to get system info: %v", err)
			return
		}
	}

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
	isSMCChargingEnabled := info.SMC.State.IsChargingEnabled

	if charge >= limit && isSMCChargingEnabled {
		logger.Default("Charge %d%% >= Limit %d%%. Disabling charging.", charge, limit)
		if err := powerkit.SetChargingState(powerkit.ChargingActionOff); err != nil {
			logger.Error("Failed to disable charging: %v", err)
		} else {
			logger.Default("Successfully disabled charging.")
		}
	} else if charge < limit && !isSMCChargingEnabled {
		logger.Default("Charge %d%% < Limit %d%%. Re-enabling charging.", charge, limit)
		if err := powerkit.SetChargingState(powerkit.ChargingActionOn); err != nil {
			logger.Error("Failed to enable charging: %v", err)
		} else {
			logger.Default("Successfully enabled charging.")
		}
	}
}

func (s *powerGridServer) startEventStream() {
	eventChan, err := powerkit.StreamSystemEvents()
	if err != nil {
		logger.Error("FATAL: Failed to start powerkit event stream: %v", err)
	}

	logger.Default("Daemon event stream started. Watching for all power events.")
	for event := range eventChan {
		switch event.Type {

		case powerkit.EventTypeSystemWillSleep:
			s.handleSleep()

		case powerkit.EventTypeSystemDidWake:
			logger.Default("System woke up. Re-evaluating state in 3 seconds...")

			go func() {
				time.Sleep(3 * time.Second)

				s.mu.RLock()
				shouldPreventDisplaySleep := s.wantPreventDisplaySleep
				shouldPreventSystemSleep := s.wantPreventSystemSleep
				s.mu.RUnlock()

				if shouldPreventDisplaySleep {
					logger.Default("Re-applying 'Prevent Display Sleep' assertion after wake.")
					if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventDisplaySleep, "PowerGrid: Prevent Display Sleep"); err != nil {
						logger.Error("Failed to re-create display sleep assertion after wake: %v", err)
					}
				}
				if shouldPreventSystemSleep {
					logger.Default("Re-applying 'Prevent System Sleep' assertion after wake.")
					if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventSystemSleep, "PowerGrid: Prevent System Sleep"); err != nil {
						logger.Error("Failed to re-create system sleep assertion after wake: %v", err)
					}
				}

				s.runChargingLogic(nil)
			}()

		case powerkit.EventTypeBatteryUpdate:
			logger.Info("Received a battery status update, running charging logic.")
			if event.Info != nil {
				s.runChargingLogic(event.Info)
			} else {
				s.runChargingLogic(nil)
			}
		default:
			if event.Info != nil {
				s.runChargingLogic(event.Info)
			} else {
				s.runChargingLogic(nil)
			}
		}
	}
}

func (s *powerGridServer) startConsoleUserEventHandler() {
	userEvents := consoleuser.Watch()

	s.handleConsoleUserChange(nil)

	go func() {
		for range userEvents {
			logger.Default("Received console user change event. Re-evaluating in 1 second...")
			time.Sleep(1 * time.Second)
			s.handleConsoleUserChange(nil)
		}
	}()
}

func (s *powerGridServer) startConsoleUserWatcher() {
	ticker := time.NewTicker(5 * time.Second)
	s.handleConsoleUserChange(nil)
	go func() {
		for range ticker.C {
			s.handleConsoleUserChange(&struct{}{})
		}
	}()
}

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

	systemLimit := cfg.ReadSystemChargeLimitStore()
	if systemLimit == 0 {
		systemLimit = cfg.ReadSystemChargeLimit()
	}
	effective := cfg.EffectiveChargeLimit(0, systemLimit, defaultChargeLimit)
	s.mu.Lock()
	s.currentLimit = int32(effective)
	s.mu.Unlock()
	logger.Default("Applied effective limit (no user): %d%% (system=%d, default=%d)", effective, systemLimit, defaultChargeLimit)

	go s.runChargingLogic(nil)
}

func (s *powerGridServer) enterConsoleUser(u *consoleuser.ConsoleUser) {
	s.mu.Lock()
	s.currentConsoleUser = u
	s.wantPreventDisplaySleep = false
	s.wantPreventSystemSleep = false
	s.mu.Unlock()

	logger.Default("Entering ConsoleUser state (%s): clearing assertions, enabling adapter, applying effective limit", u.Username)
	powerkit.AllowAllSleep()
	if err := powerkit.SetAdapterState(powerkit.AdapterActionOn); err != nil {
		logger.Error("Failed to ensure adapter ON on user switch: %v", err)
	}

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

	go s.runChargingLogic(nil)
}

func (s *powerGridServer) handleSleep() {
	logger.Default("System is going to sleep. Proactively disabling charging.")
	if err := powerkit.SetChargingState(powerkit.ChargingActionOff); err != nil {
		logger.Error("Failed to disable charging for sleep: %v", err)
	} else {
		logger.Default("Successfully disabled charging for sleep.")
	}
}

func main() {
	logger.Default("Starting PowerGrid Daemon...")
	if os.Geteuid() != 0 {
		logger.Fault("FATAL: PowerGrid Daemon must be run as root.")
		os.Exit(1)
	}
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

	server.startConsoleUserEventHandler()

	go server.startEventStream()

	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			server.runChargingLogic(nil)
		}
	}()

	go func() {
		if err := grpcServer.Serve(lis); err != nil {
			logger.Fault("FATAL: Failed to serve gRPC: %v", err)
		}
	}()

	logger.Default("PowerGrid Daemon is running.")

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Default("Shutting down PowerGrid Daemon...")
	grpcServer.GracefulStop()
	if err := os.RemoveAll(socketPath); err != nil {
		logger.Error("Failed to remove socket on shutdown: %v", err)

	}
}
