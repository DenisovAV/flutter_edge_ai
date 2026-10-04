import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Provided at startup from `main`; overriding it in tests avoids platform
/// channels entirely.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('override sharedPreferencesProvider in main or tests'),
);
