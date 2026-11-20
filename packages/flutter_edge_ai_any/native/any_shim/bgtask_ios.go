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
// handler (or the refresh below) may still run; it is a few bytes per
// close.
//
// After the task has begun, its own read of backgroundTimeRemaining runs
// on the main queue (UIKit is main-thread only): the time the task buys
// is only visible from then on. "refreshed" says that read happened;
// "remaining" is its value (< 0: in the foreground, no bound).
typedef struct {
	atomic_ulong task; // UIBackgroundTaskInvalid is 0
	atomic_int expired;
	atomic_int ended;
	atomic_int refreshed;
	_Atomic double remaining; // seconds, at refreshed_at
	_Atomic double refreshed_at; // CFAbsoluteTime of the read
} any_shim_bg;

static id any_shim_app(void) {
	Class cls = NSClassFromString(@"UIApplication");
	SEL shared = sel_registerName("sharedApplication");
	if (cls == nil || ![cls respondsToSelector:shared]) return nil;
	return ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
}

// backgroundTimeRemaining on the main thread; < 0 in the foreground
// (UIKit answers DBL_MAX there) or without a UIApplication.
static double any_shim_bg_read_main(void) {
	id app = any_shim_app();
	SEL sel = sel_registerName("backgroundTimeRemaining");
	if (app == nil || ![app respondsToSelector:sel]) return -1;
	double r = ((double (*)(id, SEL))objc_msgSend)(app, sel);
	return (r >= 0 && r < 1e6) ? r : -1;
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
		atomic_store(&b->remaining, -1);
		NSString *n = [NSString stringWithUTF8String:name];
		unsigned long t = ((unsigned long (*)(id, SEL, id, void (^)(void)))objc_msgSend)(app, begin, n, ^{
			// Out of time: the close goes on, iOS may suspend it.
			atomic_store(&b->expired, 1);
			any_shim_bg_finish(b); // a no-op until the id is stored
		});
		atomic_store(&b->task, t);
		if (atomic_load(&b->expired)) any_shim_bg_finish(b);
		dispatch_async(dispatch_get_main_queue(), ^{
			double r = any_shim_bg_read_main();
			atomic_store(&b->remaining, r);
			atomic_store(&b->refreshed_at, CFAbsoluteTimeGetCurrent());
			atomic_store(&b->refreshed, 1);
		});
		return b;
	}
}

// The task's post-begin read: 1 when it has happened, with the seconds
// left now in *left (< 0: foreground, no bound).
static int any_shim_bg_refreshed(any_shim_bg *b, double *left) {
	if (b == NULL || !atomic_load(&b->refreshed)) return 0;
	double r = atomic_load(&b->remaining);
	if (r < 0) {
		*left = -1;
	} else {
		double l = r - (CFAbsoluteTimeGetCurrent() - atomic_load(&b->refreshed_at));
		*left = l < 0 ? 0 : l;
	}
	return 1;
}

// The observers' sample (DidEnterBackground, or the seed at registration
// when the process is already in the background): kept for the debug
// log only. It is read BEFORE a close's task begins, so it never sees
// the time the task buys; the bound comes from the post-begin read.
static _Atomic double any_shim_bg_deadline = -1;

static void any_shim_bg_sample(void) {
	double r = any_shim_bg_read_main();
	atomic_store(&any_shim_bg_deadline, r < 0 ? -1 : CFAbsoluteTimeGetCurrent() + r);
}

static void any_shim_bg_observe(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
		[nc addObserverForName:@"UIApplicationDidEnterBackgroundNotification" object:nil
		                 queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
			any_shim_bg_sample();
		}];
		[nc addObserverForName:@"UIApplicationWillEnterForegroundNotification" object:nil
		                 queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
			atomic_store(&any_shim_bg_deadline, -1);
		}];
		// A process whose first open happens in the background: seed from
		// applicationState (UIApplicationStateBackground is 2).
		dispatch_async(dispatch_get_main_queue(), ^{
			id app = any_shim_app();
			SEL st = sel_registerName("applicationState");
			if (app != nil && [app respondsToSelector:st] &&
			    ((long (*)(id, SEL))objc_msgSend)(app, st) == 2) {
				any_shim_bg_sample();
			}
		});
	});
}

// The observers' sample: seconds left now, or < 0 when unknown.
static double any_shim_bg_observed(void) {
	double d = atomic_load(&any_shim_bg_deadline);
	if (d < 0) return -1;
	double r = d - CFAbsoluteTimeGetCurrent();
	return r < 0 ? 0 : r;
}

static void any_shim_bg_log(const char *msg) {
	NSLog(@"%s", msg);
}
*/
import "C"

import (
	"time"
	"unsafe"
)

// bgTask is an iOS background task around a close. Without a
// UIApplication (an extension, a test host) every method is a no-op.
type bgTask struct{ b *C.any_shim_bg }

// beginBackgroundTask asks iOS for time to finish name.
func beginBackgroundTask(name string) *bgTask {
	cs := C.CString(name)
	defer C.free(unsafe.Pointer(cs))
	return &bgTask{b: C.any_shim_bg_begin(cs)}
}

func (t *bgTask) end() {
	if t != nil {
		C.any_shim_bg_finish(t.b)
	}
}

// remaining waits up to wait for the task's post-begin read of the
// background time. refreshed is false when there is no task or the read
// did not come in time (the main thread is busy): the caller then does
// not bound by iOS. ok is false in the foreground (no bound either).
func (t *bgTask) remaining(wait time.Duration) (left time.Duration, ok, refreshed bool) {
	if t == nil || t.b == nil {
		return 0, false, false
	}
	deadline := time.Now().Add(wait)
	for {
		var l C.double
		if C.any_shim_bg_refreshed(t.b, &l) != 0 {
			if l < 0 {
				return 0, false, true
			}
			return time.Duration(float64(l) * float64(time.Second)), true, true
		}
		if time.Now().After(deadline) {
			return 0, false, false
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// observedRemaining is the observers' sample (for the debug log): the
// background time left as seen at DidEnterBackground, ok false if none.
func observedRemaining() (time.Duration, bool) {
	r := float64(C.any_shim_bg_observed())
	if r < 0 {
		return 0, false
	}
	return time.Duration(r * float64(time.Second)), true
}

// observeBackground registers the background observers (once per process).
func observeBackground() { C.any_shim_bg_observe() }

// platformLog writes a debug line where an iOS developer sees it.
func platformLog(msg string) {
	cs := C.CString(msg)
	defer C.free(unsafe.Pointer(cs))
	C.any_shim_bg_log(cs)
}
