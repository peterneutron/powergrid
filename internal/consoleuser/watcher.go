// powergrid/internal/consoleuser/watcher.go

package consoleuser

/*
#cgo CFLAGS: -x objective-c
#cgo LDFLAGS: -framework CoreFoundation -framework SystemConfiguration
#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CoreFoundation.h>

// Forward declaration of the Go callback function
void consoleUserChangedCallback(SCDynamicStoreRef store, CFArrayRef changedKeys, void *info);
*/
import "C"

import (
	"log"
	"unsafe"
)

// notificationChannel is the package-level channel to signal user changes.
// The C callback will send a signal here.
var notificationChannel = make(chan struct{}, 1)

//export consoleUserChangedCallback
func consoleUserChangedCallback(store C.SCDynamicStoreRef, changedKeys C.CFArrayRef, info unsafe.Pointer) {
	// Send a non-blocking signal to our Go channel.
	select {
	case notificationChannel <- struct{}{}:
	default:
	}
}

// Watch starts the system event listener for console user changes.
// It returns a read-only channel that receives a signal when a user change event occurs.
// This function should only be called once.
func Watch() <-chan struct{} {
	go func() {
		// Create a CFString for the key we want to watch.
		key := C.CFStringCreateWithCString(C.kCFAllocatorDefault, C.CString("State:/Users/ConsoleUser"), C.kCFStringEncodingUTF8)
		defer C.CFRelease(C.CFTypeRef(key))

		// Create an array containing just our key.
		keysToWatch := C.CFArrayCreate(C.kCFAllocatorDefault, (*unsafe.Pointer)(unsafe.Pointer(&key)), 1, &C.kCFTypeArrayCallBacks)
		defer C.CFRelease(C.CFTypeRef(keysToWatch))

		// --- FIX 1: Create a CFStringRef for the application ID ---
		appName := C.CFStringCreateWithCString(C.kCFAllocatorDefault, C.CString("com.neutronstar.powergrid"), C.kCFStringEncodingUTF8)
		defer C.CFRelease(C.CFTypeRef(appName))

		// The context object does not need to pass any data because we are using a package-level channel.
		// Pass the newly created appName CFStringRef here.
		store := C.SCDynamicStoreCreate(C.kCFAllocatorDefault, appName, C.SCDynamicStoreCallBack(C.consoleUserChangedCallback), nil)
		if store == 0 {
			log.Println("ERROR: Failed to create SCDynamicStore session in consoleuser watcher")
			return
		}
		defer C.CFRelease(C.CFTypeRef(store))

		// --- FIX 2: Explicitly cast nil to the correct C type ---
		// The third argument (patterns) must be a typed nil.
		C.SCDynamicStoreSetNotificationKeys(store, keysToWatch, C.CFArrayRef(unsafe.Pointer(nil)))

		// Add the store to a run loop to process events.
		runLoopSource := C.SCDynamicStoreCreateRunLoopSource(C.kCFAllocatorDefault, store, 0)
		C.CFRunLoopAddSource(C.CFRunLoopGetCurrent(), runLoopSource, C.kCFRunLoopDefaultMode)
		defer C.CFRelease(C.CFTypeRef(runLoopSource))

		// Start the run loop. This is a blocking call that will process events
		// and fire our callback indefinitely until the program exits.
		C.CFRunLoopRun()
	}()

	return notificationChannel
}
