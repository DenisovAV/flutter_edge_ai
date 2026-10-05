# MediaPipe (.task) + protobuf proguard rules moved to the
# flutter_gemma_mediapipe package (android/consumer-proguard-rules.pro).

# Kotlinx coroutines — deliberately NOT kept wholesale here.
#
# A `-keep class kotlinx.coroutines.** { *; }` used to sit on this line, labelled
# "used by .litertlm FFI dispatch". That was already untrue: .litertlm runs
# through Dart FFI, and this plugin's Kotlin (FlutterGemmaPlugin.kt, the bundled
# channel) references no coroutine at all. It came across from the pre-monorepo
# monolith and never got re-examined.
#
# A consumer rule merges into EVERY app that enables R8, so it is not ours to
# spend. This one pinned 874 coroutine classes by name in this repo's own
# example (measured off R8's mapping.txt, release build; #486 reports 920 in a
# different app) — none of them shrinkable, optimizable or renameable, enough to
# drag an app's Play Console DEX quality percentages.
#
# Nothing needs it. kotlinx-coroutines ships its own rules inside the artifact
# (META-INF/com.android.tools/r8/coroutines.pro), which R8 applies on its own:
# the volatile fields updated through AtomicFieldUpdater, SafeContinuation, and
# the Job GC anchors in ReadonlySharedFlow/ReadonlyStateFlow. That is the
# complete set upstream declares necessary. flutter_gemma_mediapipe and
# flutter_gemma_builtin_ai DO use coroutines heavily and keep none of them
# either, for the same reason.
#
# The -dontwarn stays: it costs nothing at shrink time and only silences
# references, never preserves classes.
-dontwarn kotlinx.coroutines.**

# okhttp optional TLS providers — referenced reflectively, never present at
# runtime. Pre-0.15.2 these were absorbed by the wide `-dontwarn
# com.google.guava.**` rule (guava pulled okhttp transitively via
# localagents-rag); 0.15.2 dropped that dep so R8 release builds need the
# warning suppressed explicitly.
-dontwarn org.bouncycastle.jsse.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**