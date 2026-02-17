package engine

import "github.com/peterneutron/powerkit-go/pkg/powerkit"

type ChargingDecision int

const (
	ChargingNoop ChargingDecision = iota
	ChargingEnable
	ChargingDisable
)

func DecideCharging(charge, limit int, smcChargingEnabled bool) ChargingDecision {
	if charge >= limit && smcChargingEnabled {
		return ChargingDisable
	}
	if charge < limit && !smcChargingEnabled {
		return ChargingEnable
	}
	return ChargingNoop
}

type LEDInput struct {
	AdapterPresent     bool
	Charge             int
	Limit              int
	IsCharging         bool
	IsConnected        bool
	SMCChargingEnabled bool
	ForceDischarge     bool
}

func DecideMagsafeLED(in LEDInput) (powerkit.MagsafeLEDState, bool) {
	if !in.AdapterPresent {
		return powerkit.LEDSystem, false
	}

	switch {
	case in.Charge <= 10:
		return powerkit.LEDErrorPermSlow, true
	case in.ForceDischarge:
		return powerkit.LEDOff, true
	case in.Limit >= 100:
		switch {
		case in.IsConnected && in.Charge >= 99:
			return powerkit.LEDGreen, true
		case in.IsCharging:
			return powerkit.LEDAmber, true
		default:
			return powerkit.LEDOff, true
		}
	default:
		if in.IsCharging && in.SMCChargingEnabled && in.Charge < in.Limit {
			return powerkit.LEDAmber, true
		}
		return powerkit.LEDGreen, true
	}
}
