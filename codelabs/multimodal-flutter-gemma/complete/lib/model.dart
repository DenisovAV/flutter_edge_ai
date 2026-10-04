import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// One model this app knows how to install.
///
/// [fileName] doubles as the model's id: `FlutterEdgeAi.isModelInstalled` takes
/// the file name the model was installed under, not a display name.
class ModelChoice {
  const ModelChoice({
    required this.label,
    required this.nativeUrl,
    required this.nativeFileName,
    required this.nativeSize,
    required this.webUrl,
    required this.webFileName,
    required this.webSize,
    required this.modelType,
    required this.supportsImage,
    required this.supportsAudio,
  });

  final String label;
  final String nativeUrl;
  final String nativeFileName;
  final String nativeSize;
  final String webUrl;
  final String webFileName;
  final String webSize;
  final ModelType modelType;

  /// `flutter_edge_ai_litertlm`'s web arm is a separate build of the same
  /// checkpoint — the native file is not the one to hand it.
  String get url => kIsWeb ? webUrl : nativeUrl;

  /// The install id. `isModelInstalled` is keyed by it, so it has to be the
  /// file the URL downloads — a test holds the two together.
  String get fileName => kIsWeb ? webFileName : nativeFileName;

  String get sizeLabel => kIsWeb ? webSize : nativeSize;

  /// What the WEIGHTS accept. Properties of the checkpoint, not of the
  /// device: the same answer on a Pixel, on a Mac and in Chrome. They are
  /// only half of "can this app send one" — the other half is in
  /// `capabilities.dart`. Both halves really do refuse things, and they refuse
  /// different ones: Step 2's SmolVLM2 answers no to audio on a device holding
  /// a microphone, while this model answers yes to both on a platform that
  /// will carry neither.
  final bool supportsImage;
  final bool supportsAudio;
}

/// The one model this app ships. Two modalities, one checkpoint.
///
/// The repository is ungated, so nothing here needs a Hugging Face token and
/// no run needs `--dart-define`.
abstract final class Models {
  /// Gemma 4 E2B reads pictures and listens to audio with the same weights —
  /// the reason Step 3 paid 2.59 GB for it, and the reason that is the last
  /// download in the codelab. An app that took a model per modality would be
  /// holding two of them open by now; this one holds one.
  ///
  /// The web build is a separate file from the same repository, built for
  /// `@litert-lm/core` rather than the native FFI engine — 2.0 GB against
  /// 2.59 GB, and text-only either way (see `capabilities.dart`).
  static const gemma4 = ModelChoice(
    label: 'Gemma 4 E2B',
    nativeUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it.litertlm',
    nativeFileName: 'gemma-4-E2B-it.litertlm',
    nativeSize: '2.59 GB',
    webUrl:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
        'resolve/main/gemma-4-E2B-it-web.litertlm',
    webFileName: 'gemma-4-E2B-it-web.litertlm',
    webSize: '2.0 GB',
    modelType: ModelType.gemma4,
    supportsImage: true,
    supportsAudio: true,
  );
}
