// powergrid/internal/consoleuser/watcher.go

package consoleuser

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework CoreFoundation -framework SystemConfiguration
#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CoreFoundation.h>

void consoleUserChangedCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info);
*/
import "C"

import (
	"log"
	"unsafe"
)

var notificationChannel = make(chan struct{}, 1)

//export consoleUserChangedCallback
func consoleUserChangedCallback(store C.SCDynamicStoreRef, changedKeys C.CFArrayRef, info unsafe.Pointer) {
	select {
	case notificationChannel <- struct{}{}:
	default:
	}
}

func Watch() <-chan struct{} {
	go func() {
		key := C.CFStringCreateWithCString(C.kCFAllocatorDefault, C.CString("State:/Users/ConsoleUser"), C.kCFStringEncodingUTF8)
		defer C.CFRelease(C.CFTypeRef(key))

		keysToWatch := C.CFArrayCreate(C.kCFAllocatorDefault, (*unsafe.Pointer)(unsafe.Pointer(&key)), 1, &C.kCFTypeArrayCallBacks)
		defer C.CFRelease(C.CFTypeRef(keysToWatch))

		appName := C.CFStringCreateWithCString(C.kCFAllocatorDefault, C.CString("com.neutronstar.powergrid"), C.kCFStringEncodingUTF8)
		defer C.CFRelease(C.CFTypeRef(appName))

		store := C.SCDynamicStoreCreate(C.kCFAllocatorDefault, appName, C.SCDynamicStoreCallBack(C.consoleUserChangedCallback), nil)
		if store == 0 {
			log.Println("ERROR: Failed to create SCDynamicStore session in consoleuser watcher")
			return
		}
		defer C.CFRelease(C.CFTypeRef(store))

		C.SCDynamicStoreSetNotificationKeys(store, keysToWatch, C.CFArrayRef(unsafe.Pointer(nil)))

		runLoopSource := C.SCDynamicStoreCreateRunLoopSource(C.kCFAllocatorDefault, store, 0)
		C.CFRunLoopAddSource(C.CFRunLoopGetCurrent(), runLoopSource, C.kCFRunLoopDefaultMode)
		defer C.CFRelease(C.CFTypeRef(runLoopSource))

		C.CFRunLoopRun()
	}()

	return notificationChannel
}
