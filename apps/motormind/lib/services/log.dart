import 'package:flutter/foundation.dart';

/// The one place developer log lines are written. Lines carry a common prefix
/// so `adb logcat | grep motormind` shows the app's own story, and nothing is
/// printed in release builds. Page content and the person's numbers never go
/// through here: log lengths and ids, not text.
void logDev(String message) {
  if (kDebugMode) debugPrint('[motormind] $message');
}
