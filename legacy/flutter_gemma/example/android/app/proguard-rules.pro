# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Google Play Core (for deferred components)
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# MediaPipe and protobuf: nothing here, on purpose. flutter_gemma_mediapipe's
# consumer rules cover them, and this app's release build is what proves those
# rules are enough — an app-side copy would hide a gap in them (#514).

# Kotlinx coroutines — no wholesale keep, on purpose. The artifact ships its own
# R8 rules (META-INF/com.android.tools/r8/coroutines.pro) and they are complete.
# A package-wide keep here pinned 874 classes by name in this app's own release
# build, measured off R8's mapping.txt; that is the same waste #486 reported
# against the plugin's consumer rules, and this file should not demonstrate the
# pattern the plugin just stopped shipping.
-dontwarn kotlinx.coroutines.**