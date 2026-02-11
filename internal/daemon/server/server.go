package server

import (
	"context"
	"fmt"
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
	"powergrid/internal/daemon/engine"
	"powergrid/internal/daemon/ipc"
	"powergrid/internal/daemon/session"
	oslogger "powergrid/internal/oslogger"
)

const (
	socketPath         = "/var/run/powergrid.sock"
	defaultChargeLimit = 80
	logSubsystem       = "com.neutronstar.powergrid.daemon"
)

var logger = oslogger.NewLogger(logSubsystem, "Daemon")

type Daemon struct {
	rpc.UnimplementedPowerGridServer

	mu                             sync.RWMutex
	currentLimit                   int32
	lastIOKitStatus                *powerkit.IOKitData
	lastSMCStatus                  *powerkit.SMCData
	lastBatteryWattage             float32
	lastAdapterWattage             float32
	lastSystemWattage              float32
	currentConsoleUser             *consoleuser.ConsoleUser
	wantPreventDisplaySleep        bool
	wantPreventSystemSleep         bool
	wantMagsafeLED                 bool
	wantDisableChargingBeforeSleep bool
	ledSupported                   bool
	lastLEDState                   powerkit.MagsafeLEDState
	buildID                        string
}

// Low Power Mode is read via powerkit-go's cached helper; no extra cache needed here.

func (s *Daemon) GetStatus(_ context.Context, _ *rpc.Empty) (*rpc.StatusResponse, error) {
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
	resp.MagsafeLedControlActive = s.wantMagsafeLED
	resp.MagsafeLedSupported = s.ledSupported
	// Low Power Mode via powerkit-go (cached internally by the library)
	if enabled, available, err := powerkit.GetLowPowerModeEnabled(); err == nil && available {
		resp.LowPowerModeEnabled = enabled
	}
	resp.DisableChargingBeforeSleepActive = s.wantDisableChargingBeforeSleep
	// Battery details (best-effort; fields may not be available on all hardware)
	if s.lastIOKitStatus != nil {
		b := s.lastIOKitStatus.Battery
		resp.BatterySerialNumber = b.SerialNumber
		resp.BatteryDesignCapacity = int32(b.DesignCapacity)
		resp.BatteryMaxCapacity = int32(b.MaxCapacity)
		resp.BatteryNominalCapacity = int32(b.NominalCapacity)
		resp.BatteryVoltage = float32(b.Voltage)
		resp.BatteryAmperage = float32(b.Amperage)
		// Temperature (°C) if available
		resp.BatteryTemperatureC = float32(b.Temperature)
		if len(b.IndividualCellVoltages) > 0 {
			cells := make([]int32, len(b.IndividualCellVoltages))
			for i, mv := range b.IndividualCellVoltages {
				cells[i] = int32(mv)
			}
			resp.BatteryIndividualCellMillivolts = cells
		}
	}
	return resp, nil
}

func (s *Daemon) GetVersion(_ context.Context, _ *rpc.Empty) (*rpc.VersionResponse, error) {
	return &rpc.VersionResponse{BuildId: s.buildID}, nil
}

func (s *Daemon) GetDaemonInfo(_ context.Context, _ *rpc.Empty) (*rpc.DaemonInfoResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return &rpc.DaemonInfoResponse{
		BuildId:             s.buildID,
		AuthMode:            ipc.AuthMode,
		MagsafeLedSupported: s.ledSupported,
	}, nil
}

func (s *Daemon) applySetChargeLimit(newLimit int32) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if newLimit < 60 || newLimit > 100 {
		logger.Default("Ignoring invalid charge limit: %d", newLimit)
		return
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
}

func (s *Daemon) applyPowerFeature(feature rpc.PowerFeature, enable bool) {
	switch feature {
	case rpc.PowerFeature_PREVENT_DISPLAY_SLEEP:
		s.mu.Lock()
		s.wantPreventDisplaySleep = enable
		s.mu.Unlock()
		if enable {
			if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventDisplaySleep, "PowerGrid: Prevent Display Sleep"); err != nil {
				logger.Error("Failed to create display sleep assertion: %v", err)
			}
		} else {
			powerkit.ReleaseAssertion(powerkit.AssertionTypePreventDisplaySleep)
		}
	case rpc.PowerFeature_PREVENT_SYSTEM_SLEEP:
		s.mu.Lock()
		s.wantPreventSystemSleep = enable
		s.mu.Unlock()
		if enable {
			if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventSystemSleep, "PowerGrid: Prevent System Sleep"); err != nil {
				logger.Error("Failed to create system sleep assertion: %v", err)
			}
		} else {
			powerkit.ReleaseAssertion(powerkit.AssertionTypePreventSystemSleep)
		}
	case rpc.PowerFeature_FORCE_DISCHARGE:
		if enable {
			if err := powerkit.SetAdapterState(powerkit.AdapterActionOff); err != nil {
				logger.Error("Failed to force discharge (adapter off): %v", err)
			}
		} else {
			if err := powerkit.SetAdapterState(powerkit.AdapterActionOn); err != nil {
				logger.Error("Failed to re-enable adapter: %v", err)
			}
		}
	case rpc.PowerFeature_CONTROL_MAGSAFE_LED:
		s.mu.Lock()
		if !s.ledSupported && enable {
			logger.Default("MagSafe LED control not supported on this hardware.")
		} else {
			s.wantMagsafeLED = enable
			if s.currentConsoleUser != nil {
				_ = cfg.WriteUserMagsafeLED(s.currentConsoleUser.HomeDir, enable)
			}
		}
		s.mu.Unlock()
		// On disable, hand control back to system immediately
		if !enable && s.ledSupported {
			if err := powerkit.SetMagsafeLEDState(powerkit.LEDSystem); err != nil {
				logger.Error("Failed to return MagSafe LED to system control: %v", err)
			} else {
				s.lastLEDState = powerkit.LEDSystem
			}
		}
	case rpc.PowerFeature_DISABLE_CHARGING_BEFORE_SLEEP:
		s.mu.Lock()
		s.wantDisableChargingBeforeSleep = enable
		if s.currentConsoleUser != nil {
			_ = cfg.WriteUserDisableChargingBeforeSleep(s.currentConsoleUser.HomeDir, enable)
		}
		s.mu.Unlock()
	case rpc.PowerFeature_LOW_POWER_MODE:
		// Use powerkit-go to set Low Power Mode (requires root; daemon runs as root)
		if err := powerkit.SetLowPowerMode(enable); err != nil {
			logger.Error("Failed to set Low Power Mode: %v", err)
		} else {
			logger.Default("Set Low Power Mode to %v", enable)
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.runChargingLogicLocked(nil)
}

func (s *Daemon) ApplyMutation(_ context.Context, req *rpc.MutationRequest) (*rpc.Empty, error) {
	switch req.GetOperation() {
	case rpc.MutationOperation_SET_CHARGE_LIMIT:
		s.applySetChargeLimit(req.GetLimit())
	case rpc.MutationOperation_SET_POWER_FEATURE:
		s.applyPowerFeature(req.GetFeature(), req.GetEnable())
	default:
		logger.Default("Ignoring unsupported mutation operation: %v", req.GetOperation())
	}
	return &rpc.Empty{}, nil
}

// Low Power Mode status helper removed; use powerkit.GetLowPowerModeEnabled()

func (s *Daemon) runChargingLogic(info *powerkit.SystemInfo) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.runChargingLogicLocked(info)
}

func (s *Daemon) runChargingLogicLocked(info *powerkit.SystemInfo) {
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

	switch engine.DecideCharging(charge, limit, isSMCChargingEnabled) {
	case engine.ChargingDisable:
		logger.Default("Charge %d%% >= Limit %d%%. Disabling charging.", charge, limit)
		if err := powerkit.SetChargingState(powerkit.ChargingActionOff); err != nil {
			logger.Error("Failed to disable charging: %v", err)
		} else {
			logger.Default("Successfully disabled charging.")
		}
	case engine.ChargingEnable:
		logger.Default("Charge %d%% < Limit %d%%. Re-enabling charging.", charge, limit)
		if err := powerkit.SetChargingState(powerkit.ChargingActionOn); err != nil {
			logger.Error("Failed to enable charging: %v", err)
		} else {
			logger.Default("Successfully enabled charging.")
		}
	}

	// Apply MagSafe LED if requested and supported
	s.applyMagsafeLED(info)
}

func (s *Daemon) startEventStream() {
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
			logger.Default("System woke up. Re-evaluating state with backoff...")

			go func() {
				// Retry a few times with backoff to allow subsystems to stabilize
				delays := []time.Duration{1 * time.Second, 2 * time.Second, 4 * time.Second}
				for i, d := range delays {
					time.Sleep(d)

					s.mu.RLock()
					shouldPreventDisplaySleep := s.wantPreventDisplaySleep
					shouldPreventSystemSleep := s.wantPreventSystemSleep
					s.mu.RUnlock()

					if shouldPreventDisplaySleep {
						logger.Default("Re-applying 'Prevent Display Sleep' after wake (attempt %d).", i+1)
						if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventDisplaySleep, "PowerGrid: Prevent Display Sleep"); err != nil {
							logger.Error("Failed to re-create display sleep assertion after wake: %v", err)
						}
					}
					if shouldPreventSystemSleep {
						logger.Default("Re-applying 'Prevent System Sleep' after wake (attempt %d).", i+1)
						if _, err := powerkit.CreateAssertion(powerkit.AssertionTypePreventSystemSleep, "PowerGrid: Prevent System Sleep"); err != nil {
							logger.Error("Failed to re-create system sleep assertion after wake: %v", err)
						}
					}

					s.runChargingLogic(nil)
				}
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

func (s *Daemon) startConsoleUserEventHandler() {
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

// startConsoleUserWatcher removed (unused). Event-based handler is used instead.

func (s *Daemon) handleConsoleUserChange(_ interface{}) {
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

func (s *Daemon) enterNoUser() {
	profile := session.ProfileForNoUser(defaultChargeLimit)

	s.mu.Lock()
	s.currentConsoleUser = nil
	s.wantPreventDisplaySleep = false
	s.wantPreventSystemSleep = false
	s.wantMagsafeLED = profile.WantMagsafeLED
	s.wantDisableChargingBeforeSleep = profile.WantDisableChargingBeforeSleep
	s.currentLimit = int32(profile.Limit)
	s.mu.Unlock()

	logger.Default("Entering NoUser state: clearing assertions, enabling adapter, applying system/effective limit")
	// Safety actions
	powerkit.AllowAllSleep()
	if err := powerkit.SetAdapterState(powerkit.AdapterActionOn); err != nil {
		logger.Error("Failed to ensure adapter ON in NoUser: %v", err)
	}
	if s.ledSupported {
		if err := powerkit.SetMagsafeLEDState(powerkit.LEDSystem); err != nil {
			logger.Info("Could not set MagSafe LED to system in NoUser: %v", err)
		} else {
			s.lastLEDState = powerkit.LEDSystem
		}
	}

	logger.Default("Applied effective limit (no user): %d%%", profile.Limit)

	go s.runChargingLogic(nil)
}

func (s *Daemon) enterConsoleUser(u *consoleuser.ConsoleUser) {
	profile := session.ProfileForUser(u, defaultChargeLimit)

	s.mu.Lock()
	s.currentConsoleUser = u
	s.wantPreventDisplaySleep = false
	s.wantPreventSystemSleep = false
	s.wantMagsafeLED = profile.WantMagsafeLED
	s.wantDisableChargingBeforeSleep = profile.WantDisableChargingBeforeSleep
	s.currentLimit = int32(profile.Limit)
	s.mu.Unlock()

	logger.Default("Entering ConsoleUser state (%s): clearing assertions, enabling adapter, applying effective limit", u.Username)
	powerkit.AllowAllSleep()
	if err := powerkit.SetAdapterState(powerkit.AdapterActionOn); err != nil {
		logger.Error("Failed to ensure adapter ON on user switch: %v", err)
	}

	logger.Default("Applied effective limit for %s: %d%%", u.Username, profile.Limit)

	go s.runChargingLogic(nil)
}

func (s *Daemon) handleSleep() {
	s.mu.RLock()
	shouldDisable := s.wantDisableChargingBeforeSleep
	s.mu.RUnlock()
	if !shouldDisable {
		logger.Default("System is going to sleep. Skipping charging disable (user setting).")
		return
	}
	logger.Default("System is going to sleep. Proactively disabling charging.")
	if err := powerkit.SetChargingState(powerkit.ChargingActionOff); err != nil {
		logger.Error("Failed to disable charging for sleep: %v", err)
	} else {
		logger.Default("Successfully disabled charging for sleep.")
	}
}

func Run(buildID string) error {
	logger.Default("Starting PowerGrid Daemon...")
	if os.Geteuid() != 0 {
		return fmt.Errorf("powergrid daemon must be run as root")
	}
	if err := cfg.EnsureSystemConfig(defaultChargeLimit); err != nil {
		logger.Error("Failed to ensure system config: %v", err)
	}

	lis, err := ipc.Listen(socketPath)
	if err != nil {
		return fmt.Errorf("failed to listen on socket: %w", err)
	}

	server := &Daemon{currentLimit: defaultChargeLimit, buildID: buildID}
	grpcServer := grpc.NewServer(
		grpc.UnaryInterceptor(ipc.AuthUnaryInterceptor(func() (uint32, bool) {
			server.mu.RLock()
			defer server.mu.RUnlock()
			if server.currentConsoleUser == nil {
				return 0, false
			}
			return server.currentConsoleUser.UID, true
		})),
	)
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

	// Probe MagSafe LED capability once after start
	go func() {
		if powerkit.IsMagsafeAvailable() {
			server.mu.Lock()
			server.ledSupported = true
			server.mu.Unlock()
			logger.Default("MagSafe LED control supported on this hardware.")
			// Ensure safe default on boot
			if err := powerkit.SetMagsafeLEDState(powerkit.LEDSystem); err != nil {
				logger.Info("Could not set MagSafe LED to system on startup: %v", err)
			} else {
				server.lastLEDState = powerkit.LEDSystem
			}
		} else {
			logger.Default("MagSafe LED not supported or not present.")
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Default("Shutting down PowerGrid Daemon...")
	grpcServer.GracefulStop()
	if err := os.Remove(socketPath); err != nil && !os.IsNotExist(err) {
		logger.Error("Failed to remove socket on shutdown: %v", err)
	}
	return nil
}

func (s *Daemon) applyMagsafeLED(info *powerkit.SystemInfo) {
	if !s.wantMagsafeLED || !s.ledSupported {
		return
	}
	target, ok := engine.DecideMagsafeLED(engine.LEDInput{
		AdapterPresent:     info.IOKit != nil && info.IOKit.Adapter.MaxWatts > 0,
		Charge:             info.IOKit.Battery.CurrentCharge,
		Limit:              int(s.currentLimit),
		IsCharging:         info.IOKit.State.IsCharging,
		IsConnected:        info.IOKit.State.IsConnected,
		SMCChargingEnabled: info.SMC.State.IsChargingEnabled,
		ForceDischarge:     !info.SMC.State.IsAdapterEnabled,
	})
	if !ok {
		return
	}

	if target == s.lastLEDState {
		return
	}
	if err := powerkit.SetMagsafeLEDState(target); err != nil {
		logger.Error("Failed to set MagSafe LED: %v", err)
		return
	}
	s.lastLEDState = target
	switch target {
	case powerkit.LEDAmber:
		logger.Info("MagSafe LED -> Amber")
	case powerkit.LEDGreen:
		logger.Info("MagSafe LED -> Green")
	case powerkit.LEDOff:
		logger.Info("MagSafe LED -> Off")
	case powerkit.LEDErrorPermSlow:
		logger.Info("MagSafe LED -> Error (Perm Slow)")
	case powerkit.LEDSystem:
		logger.Info("MagSafe LED -> System")
	}
}
