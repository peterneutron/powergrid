package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	SystemPlistPath  = "/Library/Preferences/com.neutronstar.powergrid.daemon.plist"
	UserDomain       = "com.neutronstar.powergrid"
	KeyChargeLimit   = "ChargeLimit"
	DaemonConfigDir  = "/Library/Application Support/com.neutronstar.powergrid"
	UsersConfigDir   = DaemonConfigDir + "/users"
	SystemConfigPath = DaemonConfigDir + "/system.json"
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

type jsonConfig struct {
	ChargeLimit int `json:"charge_limit"`
}

func ensureDir(dir string) error {
	return os.MkdirAll(dir, 0755)
}

func readJSONLimit(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	var cfg jsonConfig
	if err := json.Unmarshal(b, &cfg); err != nil {
		return 0
	}
	return clampLimit(cfg.ChargeLimit)
}

func writeJSONLimit(path string, limit int) error {
	if err := ensureDir(filepath.Dir(path)); err != nil {
		return err
	}
	tmp := path + ".tmp"
	b, err := json.MarshalIndent(jsonConfig{ChargeLimit: clampLimit(limit)}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func EnsureSystemConfig(defaultLimit int) error {
	if fi, err := os.Stat(SystemConfigPath); err == nil && !fi.IsDir() {
		return nil
	}
	return writeJSONLimit(SystemConfigPath, defaultLimit)
}

func ReadSystemChargeLimitStore() int {
	return readJSONLimit(SystemConfigPath)
}

func ReadUserChargeLimitStore(uid uint32) int {
	if uid == 0 {
		return 0
	}
	path := filepath.Join(UsersConfigDir, fmt.Sprintf("%d.json", uid))
	return readJSONLimit(path)
}

func WriteUserChargeLimitStore(uid uint32, limit int) error {
	if uid == 0 {
		return os.ErrInvalid
	}
	path := filepath.Join(UsersConfigDir, fmt.Sprintf("%d.json", uid))
	return writeJSONLimit(path, limit)
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
	return WriteUserChargeLimitStore(uid, limit)
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
