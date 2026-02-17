package session

import (
	cfg "powergrid/internal/config"
	consoleuser "powergrid/internal/consoleuser"
)

type Profile struct {
	Limit                          int
	WantMagsafeLED                 bool
	WantDisableChargingBeforeSleep bool
}

func ProfileForNoUser(defaultLimit int) Profile {
	systemLimit := cfg.ReadSystemChargeLimit()
	return Profile{
		Limit:                          cfg.EffectiveChargeLimit(0, systemLimit, defaultLimit),
		WantMagsafeLED:                 false,
		WantDisableChargingBeforeSleep: true,
	}
}

func ProfileForUser(u *consoleuser.ConsoleUser, defaultLimit int) Profile {
	systemLimit := cfg.ReadSystemChargeLimit()
	userLimit := cfg.ReadUserChargeLimit(u.HomeDir)
	return Profile{
		Limit:                          cfg.EffectiveChargeLimit(userLimit, systemLimit, defaultLimit),
		WantMagsafeLED:                 cfg.ReadUserMagsafeLED(u.HomeDir),
		WantDisableChargingBeforeSleep: cfg.ReadUserDisableChargingBeforeSleep(u.HomeDir),
	}
}
