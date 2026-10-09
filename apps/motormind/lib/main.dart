import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/prefs.dart';
import 'services/analytics.dart';

/// Bootstraps preferences and analytics before the first frame. Analytics is
/// a no-op in demo builds, so the await costs nothing there; in the store
/// flavor Firebase must be ready before any event is sent.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  await container.read(analyticsProvider).init();
  runApp(UncontrolledProviderScope(container: container, child: const MotormindApp()));
}
