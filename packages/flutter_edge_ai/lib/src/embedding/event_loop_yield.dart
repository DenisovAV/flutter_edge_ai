// The inline host's per-request yield off the web (the VM tests run the
// inline host too): a zero-duration timer, the same turn the isolate host
// takes. The web arm is `event_loop_yield_web.dart`.

/// Completes after the events queued before the call have been handled.
Future<void> yieldToEventLoop() => Future<void>.delayed(Duration.zero);
