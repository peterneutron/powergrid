package main

import (
	"testing"

	rpc "powergrid/internal/rpc"
)

func TestParseLimitValue(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		input   string
		want    int32
		wantErr bool
	}{
		{name: "off", input: "off", want: 100},
		{name: "numeric", input: "80", want: 80},
		{name: "too low", input: "59", wantErr: true},
		{name: "not a number", input: "banana", wantErr: true},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got, err := parseLimitValue(tc.input)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error for %q", tc.input)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseLimitValue(%q) returned error: %v", tc.input, err)
			}
			if got != tc.want {
				t.Fatalf("parseLimitValue(%q) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestParseLimitValueForNativeAllowedValues(t *testing.T) {
	t.Parallel()

	status := &rpc.StatusResponse{
		ChargeLimitAvailable:       true,
		ChargeLimitWritable:        true,
		ChargeLimitBackend:         "native_macos",
		ChargeLimitMinPercent:      80,
		ChargeLimitMaxPercent:      100,
		ChargeLimitStepPercent:     5,
		ChargeLimitAllowedPercents: []int32{80, 85, 90, 95, 100},
	}

	if got, err := parseLimitValueForStatus("85", status); err != nil || got != 85 {
		t.Fatalf("parseLimitValueForStatus(85) = %d, %v; want 85, nil", got, err)
	}
	if _, err := parseLimitValueForStatus("60", status); err == nil {
		t.Fatal("expected native parser to reject 60")
	}
}

func TestSleepModeFromStatus(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		status *rpc.StatusResponse
		want   string
	}{
		{name: "off", status: &rpc.StatusResponse{}, want: "off"},
		{name: "system", status: &rpc.StatusResponse{PreventSystemSleepActive: true}, want: "system"},
		{
			name: "display wins",
			status: &rpc.StatusResponse{
				PreventSystemSleepActive:  true,
				PreventDisplaySleepActive: true,
			},
			want: "display",
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got := sleepModeFromStatus(tc.status)
			if got != tc.want {
				t.Fatalf("sleepModeFromStatus() = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestFormatHardwareCharge(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		status *rpc.StatusResponse
		want   string
	}{
		{name: "nil", status: nil, want: "unavailable"},
		{name: "unavailable", status: &rpc.StatusResponse{}, want: "unavailable"},
		{
			name: "available",
			status: &rpc.StatusResponse{
				BatteryHardwareChargeAvailable:      true,
				BatteryHardwareChargePercent:        65,
				BatteryHardwareChargePercentPrecise: 64.1,
			},
			want: "65% (64.1% precise)",
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got := formatHardwareCharge(tc.status)
			if got != tc.want {
				t.Fatalf("formatHardwareCharge() = %q, want %q", got, tc.want)
			}
		})
	}
}
