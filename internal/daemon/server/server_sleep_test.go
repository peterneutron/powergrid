package server

import (
	"testing"
	"time"

	"github.com/peterneutron/powerkit-go/pkg/powerkit"
)

func testSystemInfo(charge int, smcChargingEnabled bool) *powerkit.SystemInfo {
	return &powerkit.SystemInfo{
		IOKit: &powerkit.IOKitData{
			Battery: powerkit.IOKitBattery{
				CurrentCharge: charge,
			},
		},
		SMC: &powerkit.SMCData{
			State: powerkit.SMCState{
				IsChargingEnabled: smcChargingEnabled,
			},
		},
	}
}

func resetServerTestGlobals(t *testing.T) {
	t.Helper()
	oldSetChargingStateFn := setChargingStateFn
	oldGetSystemInfoFn := getSystemInfoFn
	oldNowFn := nowFn
	t.Cleanup(func() {
		setChargingStateFn = oldSetChargingStateFn
		getSystemInfoFn = oldGetSystemInfoFn
		nowFn = oldNowFn
	})
}

func TestHandleBeforeSleepNoopWhenFeatureDisabled(t *testing.T) {
	resetServerTestGlobals(t)

	calls := 0
	setChargingStateFn = func(powerkit.ChargingAction) error {
		calls++
		return nil
	}

	d := &Daemon{currentLimit: 80}
	d.handleBeforeSleep()

	if calls != 0 {
		t.Fatalf("expected no charging writes when feature disabled, got %d", calls)
	}
	if d.sleepTransitionActive {
		t.Fatalf("expected sleep transition to remain inactive")
	}
	if !d.wakeHoldUntil.IsZero() {
		t.Fatalf("expected wake hold to remain cleared")
	}
}

func TestHandleBeforeSleepNoopWhenLimitIsHundred(t *testing.T) {
	resetServerTestGlobals(t)

	calls := 0
	setChargingStateFn = func(powerkit.ChargingAction) error {
		calls++
		return nil
	}

	d := &Daemon{
		currentLimit:                   100,
		wantDisableChargingBeforeSleep: true,
		sleepTransitionActive:          true,
		wakeHoldUntil:                  time.Now().Add(time.Minute),
	}
	d.handleBeforeSleep()

	if calls != 0 {
		t.Fatalf("expected no charging writes when limit is 100, got %d", calls)
	}
	if d.sleepTransitionActive {
		t.Fatalf("expected sleep transition to be cleared")
	}
	if !d.wakeHoldUntil.IsZero() {
		t.Fatalf("expected wake hold to be cleared")
	}
}

func TestHandleBeforeSleepSuccessSetsTransitionActive(t *testing.T) {
	resetServerTestGlobals(t)

	var setCalls int
	setChargingStateFn = func(action powerkit.ChargingAction) error {
		setCalls++
		if action != powerkit.ChargingActionOff {
			t.Fatalf("expected charging-off action, got %v", action)
		}
		return nil
	}

	var verifyCalls int
	getSystemInfoFn = func(opts ...powerkit.FetchOptions) (*powerkit.SystemInfo, error) {
		verifyCalls++
		return testSystemInfo(80, false), nil
	}

	d := &Daemon{
		currentLimit:                   80,
		wantDisableChargingBeforeSleep: true,
	}
	d.handleBeforeSleep()

	if setCalls != 1 {
		t.Fatalf("expected one charging disable attempt, got %d", setCalls)
	}
	if verifyCalls != 1 {
		t.Fatalf("expected one verification read, got %d", verifyCalls)
	}
	if !d.sleepTransitionActive {
		t.Fatalf("expected sleep transition to be active after successful verification")
	}
}

func TestHandleBeforeSleepRetriesAndClearsTransitionOnFailure(t *testing.T) {
	resetServerTestGlobals(t)

	var setCalls int
	setChargingStateFn = func(powerkit.ChargingAction) error {
		setCalls++
		return nil
	}

	var verifyCalls int
	getSystemInfoFn = func(opts ...powerkit.FetchOptions) (*powerkit.SystemInfo, error) {
		verifyCalls++
		return testSystemInfo(80, true), nil
	}

	d := &Daemon{
		currentLimit:                   80,
		wantDisableChargingBeforeSleep: true,
		sleepTransitionActive:          true,
	}
	d.handleBeforeSleep()

	if setCalls != 2 {
		t.Fatalf("expected two charging disable attempts, got %d", setCalls)
	}
	if verifyCalls != 2 {
		t.Fatalf("expected two verification reads, got %d", verifyCalls)
	}
	if d.sleepTransitionActive {
		t.Fatalf("expected sleep transition to be cleared after verification failure")
	}
}

func TestRunChargingLogicSuppressesEnableDuringSleepTransition(t *testing.T) {
	resetServerTestGlobals(t)

	var actions []powerkit.ChargingAction
	setChargingStateFn = func(action powerkit.ChargingAction) error {
		actions = append(actions, action)
		return nil
	}

	d := &Daemon{
		currentLimit:          80,
		sleepTransitionActive: true,
	}
	d.runChargingLogicLocked(testSystemInfo(79, false))

	if len(actions) != 0 {
		t.Fatalf("expected no charging writes during sleep transition, got %v", actions)
	}
}

func TestShouldSuppressChargingEnableDuringWakeHold(t *testing.T) {
	resetServerTestGlobals(t)

	now := time.Date(2026, 4, 20, 10, 0, 0, 0, time.UTC)
	d := &Daemon{
		wakeHoldUntil: now.Add(wakeHoldDuration),
	}

	if !d.shouldSuppressChargingEnableLocked(80, 80, now) {
		t.Fatalf("expected wake hold to suppress charging enable at or above limit")
	}
	if d.shouldSuppressChargingEnableLocked(79, 80, now) {
		t.Fatalf("expected wake hold to allow charging enable below limit")
	}
}

func TestRunChargingLogicAllowsImmediateEnableBelowLimitDuringWakeHold(t *testing.T) {
	resetServerTestGlobals(t)

	now := time.Date(2026, 4, 20, 10, 0, 0, 0, time.UTC)
	nowFn = func() time.Time { return now }

	var actions []powerkit.ChargingAction
	setChargingStateFn = func(action powerkit.ChargingAction) error {
		actions = append(actions, action)
		return nil
	}

	d := &Daemon{
		currentLimit:    80,
		wakeHoldUntil:   now.Add(wakeHoldDuration),
		lastSMCStatus:   nil,
		lastIOKitStatus: nil,
	}
	d.runChargingLogicLocked(testSystemInfo(79, false))

	if len(actions) != 1 || actions[0] != powerkit.ChargingActionOn {
		t.Fatalf("expected wake hold to allow immediate enable below limit, got %v", actions)
	}
}
