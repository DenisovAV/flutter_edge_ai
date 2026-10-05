/// MediaPipe (.task) on-device inference engine for flutter_gemma.
///
/// Opt-in. Add to pubspec.yaml and pass an instance to
/// `FlutterGemma.initialize(inferenceEngines: [MediaPipeEngine()])`.
///
/// ```dart
/// import 'package:flutter_gemma/flutter_gemma.dart';
/// import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';
/// await FlutterGemma.initialize(inferenceEngines: [MediaPipeEngine()]);
/// ```
library flutter_gemma_mediapipe;

export 'src/mediapipe_engine_web.dart'
    if (dart.library.io) 'src/mediapipe_engine.dart';
