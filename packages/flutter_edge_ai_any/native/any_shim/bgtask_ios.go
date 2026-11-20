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

// UIBackgroundTaskInvalid is 0.
static unsigned long any_shim_bg_begin(const char *name) {
	@autoreleasepool {
		Class cls = NSClassFromString(@"UIApplication");
		SEL shared = sel_registerName("sharedApplication");
		if (cls == nil || ![cls respondsToSelector:shared]) return 0;
		id app = ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
		SEL begin = sel_registerName("beginBackgroundTaskWithName:expirationHandler:");
		SEL end = sel_registerName("endBackgroundTask:");
		if (app == nil || ![app respondsToSelector:begin]) return 0;
		__block unsigned long task = 0;
		NSString *n = [NSString stringWithUTF8String:name];
		task = ((unsigned long (*)(id, SEL, id, void (^)(void)))objc_msgSend)(app, begin, n, ^{
			// Out of time: the close goes on, iOS may suspend it.
			unsigned long t = task;
			task = 0;
			if (t != 0) ((void (*)(id, SEL, unsigned long))objc_msgSend)(app, end, t);
		});
		return task;
	}
}

static void any_shim_bg_end(unsigned long task) {
	if (task == 0) return;
	@autoreleasepool {
		Class cls = NSClassFromString(@"UIApplication");
		if (cls == nil) return;
		id app = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("sharedApplication"));
		if (app == nil) return;
		((void (*)(id, SEL, unsigned long))objc_msgSend)(app, sel_registerName("endBackgroundTask:"), task);
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
	t := C.any_shim_bg_begin(cs)
	return func() { C.any_shim_bg_end(t) }
}
