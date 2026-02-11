package engine

import (
	"testing"

	"github.com/peterneutron/powerkit-go/pkg/powerkit"
)

func TestDecideCharging(t *testing.T) {
	tests := []struct {
		name               string
		charge             int
		limit              int
		smcChargingEnabled bool
		want               ChargingDecision
	}{
		{name: "disable at or above limit when charging enabled", charge: 80, limit: 80, smcChargingEnabled: true, want: ChargingDisable},
		{name: "enable below limit when charging disabled", charge: 79, limit: 80, smcChargingEnabled: false, want: ChargingEnable},
		{name: "noop below limit when charging enabled", charge: 79, limit: 80, smcChargingEnabled: true, want: ChargingNoop},
		{name: "noop above limit when charging disabled", charge: 90, limit: 80, smcChargingEnabled: false, want: ChargingNoop},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := DecideCharging(tc.charge, tc.limit, tc.smcChargingEnabled)
			if got != tc.want {
				t.Fatalf("unexpected decision: got=%v want=%v", got, tc.want)
			}
		})
	}
}

func TestDecideMagsafeLED(t *testing.T) {
	tests := []struct {
		name string
		in   LEDInput
		want powerkit.MagsafeLEDState
		ok   bool
	}{
		{
			name: "no adapter means no decision",
			in:   LEDInput{AdapterPresent: false},
			want: powerkit.LEDSystem,
			ok:   false,
		},
		{
			name: "low battery alarm",
			in:   LEDInput{AdapterPresent: true, Charge: 10},
			want: powerkit.LEDErrorPermSlow,
			ok:   true,
		},
		{
			name: "force discharge",
			in:   LEDInput{AdapterPresent: true, Charge: 50, ForceDischarge: true},
			want: powerkit.LEDOff,
			ok:   true,
		},
		{
			name: "full connected unlimited",
			in:   LEDInput{AdapterPresent: true, Charge: 99, Limit: 100, IsConnected: true},
			want: powerkit.LEDGreen,
			ok:   true,
		},
		{
			name: "charging unlimited",
			in:   LEDInput{AdapterPresent: true, Charge: 80, Limit: 100, IsCharging: true},
			want: powerkit.LEDAmber,
			ok:   true,
		},
		{
			name: "paused at limit",
			in:   LEDInput{AdapterPresent: true, Charge: 80, Limit: 80, IsCharging: false, SMCChargingEnabled: false},
			want: powerkit.LEDGreen,
			ok:   true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := DecideMagsafeLED(tc.in)
			if ok != tc.ok {
				t.Fatalf("unexpected ok: got=%v want=%v", ok, tc.ok)
			}
			if got != tc.want {
				t.Fatalf("unexpected LED: got=%v want=%v", got, tc.want)
			}
		})
	}
}
