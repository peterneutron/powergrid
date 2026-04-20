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
