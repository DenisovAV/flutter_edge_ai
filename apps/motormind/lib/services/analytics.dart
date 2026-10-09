import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../firebase_options.dart';
import 'log.dart';

/// Compile-time switch (VA-7.1.3). Demo builds pass nothing and ship the
/// no-op; the store flavor passes `--dart-define=MOTORMIND_ANALYTICS=true`
/// after `flutterfire configure` has generated the platform config.
const bool kAnalyticsEnabled = bool.fromEnvironment('MOTORMIND_ANALYTICS');

/// Anonymous event counts only. Parameters are restricted to a short allow
/// list so no free text and no financial value can ever be logged. Every
/// call is fire-and-forget and never throws. Instrumentation of screens and
/// turns lands with VA-7.1.3; today only [init] runs.
abstract class Analytics {
  /// Prepares the backend; a no-op in demo builds.
  Future<void> init();

  /// Records a screen view by name.
  Future<void> screen(String name);

  /// Records an event; parameters outside the allow list are dropped.
  Future<void> event(String name, {Map<String, Object>? params});
}

class NoopAnalytics implements Analytics {
  @override
  Future<void> init() async {}

  @override
  Future<void> screen(String name) async {}

  @override
  Future<void> event(String name, {Map<String, Object>? params}) async {}
}

class FirebaseAnalyticsService implements Analytics {
  FirebaseAnalytics? _fa;

  static const Set<String> allowedParams = {
    'tool',
    'model_id',
    'component',
    'surface',
    'outcome',
    'mode',
    'from',
    'to',
  };

  @override
  Future<void> init() async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    _fa = FirebaseAnalytics.instance;
  }

  @override
  Future<void> screen(String name) async {
    await _fa?.logScreenView(screenName: name);
  }

  @override
  Future<void> event(String name, {Map<String, Object>? params}) async {
    // Numbers are refused outright: a financial value must never reach
    // analytics, and a bucketed string is the only allowed shape.
    final safe = <String, Object>{
      for (final e in (params ?? const {}).entries)
        if (allowedParams.contains(e.key) && e.value is! num) e.key: e.value,
    };
    if (params != null && safe.length != params.length) {
      logDev('analytics: dropped disallowed params from "$name"');
    }
    await _fa?.logEvent(name: name, parameters: safe);
  }
}

final analyticsProvider = Provider<Analytics>(
  (ref) => kAnalyticsEnabled ? FirebaseAnalyticsService() : NoopAnalytics(),
);
