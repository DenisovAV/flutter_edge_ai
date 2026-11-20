package main

// The iOS background task around a suspend or close (cancel + SDK close):
// without one, iOS may freeze the process right after it leaves the
// foreground, with the SDK's stores half closed. UIApplication is found
// at run time (NSClassFromString) so the library links no UIKit and
// stays usable from an app extension, where sharedApplication is
// unavailable: there the task is simply not taken.

/*
#cgo CFLAGS: -x objective-c -fblocks
#cgo LDFLAGS: -framework Foundation -lobjc
#include <stdlib.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <stdatomic.h>

// One task, lock-free. The expiration handler may run before begin has
// returned the id: it then only marks the task expired, and the begin
// side ends it once the id is stored. "ended" makes the end happen once,
// whichever side gets there. The struct is never freed: after an end the
// handler may still be running; it is a few bytes per close.
typedef struct {
	atomic_ulong task; // UIBackgroundTaskInvalid is 0
	atomic_int expired;
	atomic_int ended;
} any_shim_bg;

static id any_shim_app(void) {
	Class cls = NSClassFromString(@"UIApplication");
	SEL shared = sel_registerName("sharedApplication");
	if (cls == nil || ![cls respondsToSelector:shared]) return nil;
	return ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
}

static void any_shim_bg_finish(any_shim_bg *b) {
	if (b == NULL) return;
	unsigned long t = atomic_load(&b->task);
	if (t == 0 || atomic_exchange(&b->ended, 1) != 0) return;
	@autoreleasepool {
		id app = any_shim_app();
		if (app == nil) return;
		((void (*)(id, SEL, unsigned long))objc_msgSend)(app, sel_registerName("endBackgroundTask:"), t);
	}
}

static any_shim_bg *any_shim_bg_begin(const char *name) {
	@autoreleasepool {
		id app = any_shim_app();
		SEL begin = sel_registerName("beginBackgroundTaskWithName:expirationHandler:");
		if (app == nil || ![app respondsToSelector:begin]) return NULL;
		any_shim_bg *b = calloc(1, sizeof(any_shim_bg));
		if (b == NULL) return NULL;
		NSString *n = [NSString stringWithUTF8String:name];
		unsigned long t = ((unsigned long (*)(id, SEL, id, void (^)(void)))objc_msgSend)(app, begin, n, ^{
			// Out of time: the close goes on, iOS may suspend it.
			atomic_store(&b->expired, 1);
			any_shim_bg_finish(b); // a no-op until the id is stored
		});
		atomic_store(&b->task, t);
		if (atomic_load(&b->expired)) any_shim_bg_finish(b);
		return b;
	}
}

// Seconds of background time left, or < 0 when unknown (no
// UIApplication). In the foreground UIKit answers DBL_MAX.
static double any_shim_bg_remaining(void) {
	@autoreleasepool {
		id app = any_shim_app();
		SEL sel = sel_registerName("backgroundTimeRemaining");
		if (app == nil || ![app respondsToSelector:sel]) return -1;
		return ((double (*)(id, SEL))objc_msgSend)(app, sel);
	}
}
*/
import "C"

import (
	"time"
	"unsafe"
)

// beginBackgroundTask asks iOS for time to finish name; the returned
// func ends the task. Without a UIApplication (an extension, a test
// host) both are no-ops.
func beginBackgroundTask(name string) (end func()) {
	cs := C.CString(name)
	defer C.free(unsafe.Pointer(cs))
	b := C.any_shim_bg_begin(cs)
	return func() { C.any_shim_bg_finish(b) }
}

// backgroundTimeRemaining is UIApplication.backgroundTimeRemaining; ok is
// false without a UIApplication or in the foreground (unbounded).
func backgroundTimeRemaining() (time.Duration, bool) {
	r := float64(C.any_shim_bg_remaining())
	if r < 0 || r > 1e6 {
		return 0, false
	}
	return time.Duration(r * float64(time.Second)), true
}
