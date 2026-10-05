import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Compile-time switch (VA-7.1.3). Demo builds pass nothing and ship the
/// no-op; the store flavor passes `--dart-define=MOTORMIND_ANALYTICS=true`
/// after `flutterfire configure` has generated the platform config.
const bool kAnalyticsEnabled = bool.fromEnvironment('MOTORMIND_ANALYTICS');

/// Anonymous event counts only. Parameters are restricted to a short allow
/// list so no free text and no financial value can ever be logged.
abstract class Analytics {
  Future<void> init();
  Future<void> screen(String name);
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
    await Firebase.initializeApp();
    _fa = FirebaseAnalytics.instance;
  }

  @override
  Future<void> screen(String name) async => _fa?.logScreenView(screenName: name);

  @override
  Future<void> event(String name, {Map<String, Object>? params}) async {
    final safe = <String, Object>{
      for (final e in (params ?? const {}).entries)
        if (allowedParams.contains(e.key) && e.value is! num) e.key: e.value,
    };
    if (kDebugMode && params != null && safe.length != params.length) {
      debugPrint('analytics: dropped disallowed params from "$name"');
    }
    await _fa?.logEvent(name: name, parameters: safe);
  }
}

final analyticsProvider = Provider<Analytics>(
  (ref) => kAnalyticsEnabled ? FirebaseAnalyticsService() : NoopAnalytics(),
);
