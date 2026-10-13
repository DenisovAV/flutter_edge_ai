// Native: the fit runs on a background isolate, off the caller's (UI) isolate.

import 'dart:isolate';

import 'decider_fit.dart';

/// Runs [fitDecider] on a new isolate. The request's typed lists are copied
/// to it once; the fit's are copied back.
Future<DeciderFit> runDeciderFit(DeciderFitRequest request) =>
    Isolate.run(() => fitDecider(request), debugName: 'decider-fit');
