package config

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation

#import <Foundation/Foundation.h>
#include <stdlib.h>

static int pg_read_int(const char *plistPath, const char *key, int *outValue, int *found) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:plistPath];
        NSString *k = [NSString stringWithUTF8String:key];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict == nil) {
            *found = 0;
            return 0;
        }

        id value = [dict objectForKey:k];
        if (value == nil) {
            *found = 0;
            return 0;
        }

        if (![value respondsToSelector:@selector(intValue)]) {
            *found = 0;
            return 0;
        }

        *outValue = (int)[value intValue];
        *found = 1;
        return 0;
    }
}

static int pg_read_bool(const char *plistPath, const char *key, int *outValue, int *found) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:plistPath];
        NSString *k = [NSString stringWithUTF8String:key];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict == nil) {
            *found = 0;
            return 0;
        }

        id value = [dict objectForKey:k];
        if (value == nil) {
            *found = 0;
            return 0;
        }

        if (![value respondsToSelector:@selector(boolValue)]) {
            *found = 0;
            return 0;
        }

        *outValue = [value boolValue] ? 1 : 0;
        *found = 1;
        return 0;
    }
}

static int pg_write_int(const char *plistPath, const char *key, int value) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:plistPath];
        NSString *k = [NSString stringWithUTF8String:key];

        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (dict == nil) {
            dict = [NSMutableDictionary dictionary];
        }

        [dict setObject:@(value) forKey:k];
        BOOL ok = [dict writeToFile:path atomically:YES];
        return ok ? 0 : -1;
    }
}

static int pg_write_bool(const char *plistPath, const char *key, int value) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:plistPath];
        NSString *k = [NSString stringWithUTF8String:key];

        NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (dict == nil) {
            dict = [NSMutableDictionary dictionary];
        }

        [dict setObject:@(value ? YES : NO) forKey:k];
        BOOL ok = [dict writeToFile:path atomically:YES];
        return ok ? 0 : -1;
    }
}
*/
import "C"

import (
	"fmt"
	"os"
	"path/filepath"
	"unsafe"
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

func userPlistPath(homeDir string) string {
	return filepath.Join(homeDir, "Library", "Preferences", UserDomain+".plist")
}

func readInt(path, key string) (int, bool, error) {
	cPath := C.CString(path)
	cKey := C.CString(key)
	defer C.free(unsafe.Pointer(cPath))
	defer C.free(unsafe.Pointer(cKey))

	var out C.int
	var found C.int
	if rc := C.pg_read_int(cPath, cKey, &out, &found); rc != 0 {
		return 0, false, fmt.Errorf("failed to read int key %q from %q", key, path)
	}
	return int(out), found == 1, nil
}

func readBool(path, key string) (bool, bool, error) {
	cPath := C.CString(path)
	cKey := C.CString(key)
	defer C.free(unsafe.Pointer(cPath))
	defer C.free(unsafe.Pointer(cKey))

	var out C.int
	var found C.int
	if rc := C.pg_read_bool(cPath, cKey, &out, &found); rc != 0 {
		return false, false, fmt.Errorf("failed to read bool key %q from %q", key, path)
	}
	return out == 1, found == 1, nil
}

func writeInt(path, key string, value int) error {
	cPath := C.CString(path)
	cKey := C.CString(key)
	defer C.free(unsafe.Pointer(cPath))
	defer C.free(unsafe.Pointer(cKey))

	if rc := C.pg_write_int(cPath, cKey, C.int(value)); rc != 0 {
		return fmt.Errorf("failed to write int key %q to %q", key, path)
	}
	return nil
}

func writeBool(path, key string, value bool) error {
	cPath := C.CString(path)
	cKey := C.CString(key)
	defer C.free(unsafe.Pointer(cPath))
	defer C.free(unsafe.Pointer(cKey))

	intVal := 0
	if value {
		intVal = 1
	}
	if rc := C.pg_write_bool(cPath, cKey, C.int(intVal)); rc != 0 {
		return fmt.Errorf("failed to write bool key %q to %q", key, path)
	}
	return nil
}

func ReadSystemChargeLimit() int {
	n, found, err := readInt(SystemPlistPath, KeyChargeLimit)
	if err != nil || !found {
		return 0
	}
	return clampLimit(n)
}

func ReadUserChargeLimit(homeDir string) int {
	if homeDir == "" {
		return 0
	}
	n, found, err := readInt(userPlistPath(homeDir), KeyChargeLimit)
	if err != nil || !found {
		return 0
	}
	return clampLimit(n)
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

func WriteUserChargeLimit(homeDir string, uid uint32, limit int) error {
	_ = uid
	if homeDir == "" {
		return os.ErrInvalid
	}
	return writeInt(userPlistPath(homeDir), KeyChargeLimit, clampLimit(limit))
}

func ReadUserMagsafeLED(homeDir string) bool {
	if homeDir == "" {
		return false
	}
	val, found, err := readBool(userPlistPath(homeDir), KeyMagsafeLED)
	if err != nil || !found {
		return false
	}
	return val
}

func WriteUserMagsafeLED(homeDir string, enabled bool) error {
	if homeDir == "" {
		return os.ErrInvalid
	}
	return writeBool(userPlistPath(homeDir), KeyMagsafeLED, enabled)
}

func ReadUserDisableChargingBeforeSleep(homeDir string) bool {
	if homeDir == "" {
		return true
	}
	val, found, err := readBool(userPlistPath(homeDir), KeyDisableCBS)
	if err != nil || !found {
		return true
	}
	return val
}

func WriteUserDisableChargingBeforeSleep(homeDir string, enabled bool) error {
	if homeDir == "" {
		return os.ErrInvalid
	}
	return writeBool(userPlistPath(homeDir), KeyDisableCBS, enabled)
}

func EnsureSystemConfig(defaultLimit int) error {
	if ReadSystemChargeLimit() == 0 {
		return writeInt(SystemPlistPath, KeyChargeLimit, clampLimit(defaultLimit))
	}
	return nil
}
