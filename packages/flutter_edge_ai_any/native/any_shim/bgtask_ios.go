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

#include <pthread.h>
#include <stdatomic.h>

// One task: the id is stored before the expiration handler may read it
// (the handler takes the mutex the begin call holds), and the task is
// ended exactly once, by whichever of the handler and the Go side comes
// first. The struct is never freed: after an end the handler may still
// be running; it is under 100 bytes per close.
typedef struct {
	pthread_mutex_t mu;
	unsigned long task; // UIBackgroundTaskInvalid is 0
	atomic_int ended;
} any_shim_bg;

static void any_shim_bg_finish(any_shim_bg *b) {
	if (b == NULL || atomic_exchange(&b->ended, 1) != 0) return;
	pthread_mutex_lock(&b->mu);
	unsigned long t = b->task;
	pthread_mutex_unlock(&b->mu);
	if (t == 0) return;
	@autoreleasepool {
		Class cls = NSClassFromString(@"UIApplication");
		if (cls == nil) return;
		id app = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("sharedApplication"));
		if (app == nil) return;
		((void (*)(id, SEL, unsigned long))objc_msgSend)(app, sel_registerName("endBackgroundTask:"), t);
	}
}

static any_shim_bg *any_shim_bg_begin(const char *name) {
	@autoreleasepool {
		Class cls = NSClassFromString(@"UIApplication");
		SEL shared = sel_registerName("sharedApplication");
		if (cls == nil || ![cls respondsToSelector:shared]) return NULL;
		id app = ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
		SEL begin = sel_registerName("beginBackgroundTaskWithName:expirationHandler:");
		if (app == nil || ![app respondsToSelector:begin]) return NULL;
		any_shim_bg *b = calloc(1, sizeof(any_shim_bg));
		if (b == NULL) return NULL;
		pthread_mutex_init(&b->mu, NULL);
		NSString *n = [NSString stringWithUTF8String:name];
		pthread_mutex_lock(&b->mu);
		b->task = ((unsigned long (*)(id, SEL, id, void (^)(void)))objc_msgSend)(app, begin, n, ^{
			// Out of time: the close goes on, iOS may suspend it.
			any_shim_bg_finish(b);
		});
		pthread_mutex_unlock(&b->mu);
		return b;
	}
}
*/
import "C"

import "unsafe"

// beginBackgroundTask asks iOS for time to finish name; the returned
// func ends the task. Without a UIApplication (an extension, a test
// host) both are no-ops.
func beginBackgroundTask(name string) (end func()) {
	cs := C.CString(name)
	defer C.free(unsafe.Pointer(cs))
	b := C.any_shim_bg_begin(cs)
	return func() { C.any_shim_bg_finish(b) }
}
