package config

import (
    "bytes"
    "os"
    "os/exec"
    "path/filepath"
    "strconv"
    "strings"
)

const (
    SystemPlistPath = "/Library/Preferences/com.neutronstar.powergrid.daemon.plist"
    UserDomain      = "com.neutronstar.powergrid"
    KeyChargeLimit  = "ChargeLimit"
    KeyMagsafeLED   = "ControlMagsafeLED"
    KeyDisableCBS   = "DisableChargingBeforeSleep"
)

func clampLimit(v int) int {
	if v < 60 {
		return 60
	}
	if v > 100 {
		return 100
	}
	return v
}

func ReadSystemChargeLimit() int {
	out, err := runDefaultsRead(SystemPlistPath, KeyChargeLimit, nil)
	if err != nil {
		return 0
	}
	if n, err := strconv.Atoi(strings.TrimSpace(out)); err == nil {
		return clampLimit(n)
	}
	return 0
}

func ReadUserChargeLimit(homeDir string) int {
	if homeDir == "" {
		return 0
	}
	env := append(os.Environ(), "HOME="+homeDir, "USER=")
	out, err := runDefaultsRead(UserDomain, KeyChargeLimit, env)
	if err != nil {
		plistPath := filepath.Join(homeDir, "Library", "Preferences", UserDomain+".plist")
		out, err = runDefaultsRead(plistPath, KeyChargeLimit, env)
		if err != nil {
			return 0
		}
		if n, err2 := strconv.Atoi(strings.TrimSpace(out)); err2 == nil {
			return clampLimit(n)
		}
		return 0
	}
	if n, err := strconv.Atoi(strings.TrimSpace(out)); err == nil {
		return clampLimit(n)
	}
	return 0
}

func EffectiveChargeLimit(userLimit, systemLimit, defaultLimit int) int {
    if userLimit > 0 {
        return clampLimit(userLimit)
    }
    if systemLimit > 0 {
        return clampLimit(systemLimit)
    }
    return clampLimit(defaultLimit)
}

func runDefaultsRead(domainOrPath, key string, env []string) (string, error) {
	cmd := exec.Command("/usr/bin/defaults", "read", domainOrPath, key)
	if env != nil {
		cmd.Env = env
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		return "", err
	}
	return stdout.String(), nil
}

func WriteUserChargeLimit(homeDir string, uid uint32, limit int) error {
    if homeDir == "" {
        return os.ErrInvalid
    }
    env := append(os.Environ(), "HOME="+homeDir, "USER=")
    return runDefaultsWrite(UserDomain, KeyChargeLimit, limit, env)
}

func runDefaultsWrite(domainOrPath, key string, intValue int, env []string) error {
    cmd := exec.Command("/usr/bin/defaults", "write", domainOrPath, key, "-int", strconv.Itoa(intValue))
    if env != nil {
        cmd.Env = env
    }
    var stdout, stderr bytes.Buffer
    cmd.Stdout = &stdout
    cmd.Stderr = &stderr
    return cmd.Run()
}

// MagSafe LED preference (per-user)

func ReadUserMagsafeLED(homeDir string) bool {
    if homeDir == "" {
        return false
    }
    env := append(os.Environ(), "HOME="+homeDir, "USER=")
    out, err := runDefaultsRead(UserDomain, KeyMagsafeLED, env)
    if err != nil {
        // try direct plist path fallback
        plistPath := filepath.Join(homeDir, "Library", "Preferences", UserDomain+".plist")
        out, err = runDefaultsRead(plistPath, KeyMagsafeLED, env)
        if err != nil {
            return false
        }
    }
    s := strings.TrimSpace(out)
    return s == "1" || strings.EqualFold(s, "true")
}

func WriteUserMagsafeLED(homeDir string, enabled bool) error {
    if homeDir == "" {
        return os.ErrInvalid
    }
    env := append(os.Environ(), "HOME="+homeDir, "USER=")
    val := "-bool"
    boolStr := "false"
    if enabled {
        boolStr = "true"
    }
    cmd := exec.Command("/usr/bin/defaults", "write", UserDomain, KeyMagsafeLED, val, boolStr)
    cmd.Env = env
    var stdout, stderr bytes.Buffer
    cmd.Stdout = &stdout
    cmd.Stderr = &stderr
    return cmd.Run()
}

// Disable Charging Before Sleep preference (per-user)

func ReadUserDisableChargingBeforeSleep(homeDir string) bool {
    if homeDir == "" {
        return true
    }
    env := append(os.Environ(), "HOME="+homeDir, "USER=")
    out, err := runDefaultsRead(UserDomain, KeyDisableCBS, env)
    if err != nil {
        // default to true when not set
        return true
    }
    s := strings.TrimSpace(out)
    if s == "" {
        return true
    }
    return s == "1" || strings.EqualFold(s, "true")
}

func WriteUserDisableChargingBeforeSleep(homeDir string, enabled bool) error {
    if homeDir == "" {
        return os.ErrInvalid
    }
    env := append(os.Environ(), "HOME="+homeDir, "USER=")
    val := "-bool"
    boolStr := "false"
    if enabled {
        boolStr = "true"
    }
    cmd := exec.Command("/usr/bin/defaults", "write", UserDomain, KeyDisableCBS, val, boolStr)
    cmd.Env = env
    var stdout, stderr bytes.Buffer
    cmd.Stdout = &stdout
    cmd.Stderr = &stderr
    return cmd.Run()
}

// EnsureSystemConfig makes sure a system-level ChargeLimit exists; if not, writes default.
func EnsureSystemConfig(defaultLimit int) error {
    if ReadSystemChargeLimit() == 0 {
        // write to system plist path using defaults
        return runDefaultsWrite(SystemPlistPath, KeyChargeLimit, defaultLimit, nil)
    }
    return nil
}
