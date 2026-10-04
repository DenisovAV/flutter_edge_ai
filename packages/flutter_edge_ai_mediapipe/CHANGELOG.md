## 1.0.9
- Support `flutter_edge_ai` 2.x.

## 1.0.8
- Renamed from `flutter_gemma_mediapipe`.
- Web loads the GenAI WASM from `@mediapipe/tasks-genai` 0.10.29.

## 1.0.7
- README: the Android dependency is `com.google.mediapipe:tasks-genai`.

## 1.0.6
- Fix Android release builds failing in R8 on classes MediaPipe references but does not ship (#514).

## 1.0.5
- Android plugin no longer applies KGP — Flutter's Gradle plugin does (#440).
- fix: await the session future inside its try block on web, so the catch can see its errors.

## 1.0.4
- Fix AGP 9 build on `android.builtInKotlin=false` — apply KGP unless built-in Kotlin is on, so the plugin's Kotlin compiles (#360).

## 1.0.3
- Migrate Android module to Built-in Kotlin — apply KGP only on AGP < 9, ready for AGP 9+ (#323).

## 1.0.2
- Accept `maxOutputTokens` (session + chat) for interface parity; MediaPipe has no output cap, so it's logged + ignored (#318).

## 1.0.1
- Point `homepage` to fluttergemma.dev. No code change.

## 1.0.0
- Stable 1.0.0; spec imports redirected off the `dart:io` mobile lib for a wasm-clean web graph.

## 1.0.0-rc.1
- Initial release: MediaPipe (`.task` / `.bin`) on-device inference engine for flutter_gemma.
- Provides `MediaPipeEngine` (InferenceEngineProvider); bundles Google's MediaPipe Pod/Gradle deps.
- Android, iOS, Web (`@mediapipe/tasks-genai` CDN). No desktop (use flutter_gemma_litertlm).
