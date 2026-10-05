// The vision↔audio backend wiring inside LiteRtLmEngine.createModel is a pure
// map from RuntimeConfig → client.initialize() args, extracted as
// `encoderInitArgs` so it is unit-testable without path_provider or a real FFI
// dlopen. The bug this guards is a vision↔audio swap (the two lines are
// copy-paste near-twins) — invisible under the default config, where both
// resolve to 'cpu', so a device smoke test would not catch it.

import 'package:flutter_gemma/core/domain/platform_types.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma_litertlm/src/litert_lm_engine.dart';
import 'package:flutter_test/flutter_test.dart';

RuntimeConfig _config({
  bool supportImage = false,
  bool supportAudio = false,
  PreferredBackend? preferredVisionBackend,
  PreferredBackend? preferredAudioBackend,
  int? maxNumImages,
  ActivationDataType? activationDataType,
}) => RuntimeConfig(
  maxTokens: 1024,
  modelPath: '/tmp/model.litertlm',
  supportImage: supportImage,
  supportAudio: supportAudio,
  preferredVisionBackend: preferredVisionBackend,
  preferredAudioBackend: preferredAudioBackend,
  maxNumImages: maxNumImages,
  activationDataType: activationDataType,
);

void main() {
  group('encoderInitArgs', () {
    test('vision and audio backends are NOT swapped', () {
      final args = encoderInitArgs(
        _config(
          supportImage: true,
          supportAudio: true,
          preferredVisionBackend: PreferredBackend.gpu,
          preferredAudioBackend: PreferredBackend.npu,
        ),
        PreferredBackend.cpu,
      );
      expect(args.visionBackend, 'gpu');
      expect(args.audioBackend, 'npu');
    });

    test('both encoders default to cpu when unset', () {
      final args = encoderInitArgs(
        _config(supportImage: true, supportAudio: true),
        PreferredBackend.gpu,
      );
      expect(args.visionBackend, 'cpu');
      expect(args.audioBackend, 'cpu');
      // The text backend is independent and follows the active backend.
      expect(args.backend, 'gpu');
    });

    test('enableVision/enableAudio track supportImage/supportAudio', () {
      final off = encoderInitArgs(_config(), PreferredBackend.cpu);
      expect(off.enableVision, isFalse);
      expect(off.enableAudio, isFalse);
      final on = encoderInitArgs(
        _config(supportImage: true, supportAudio: true),
        PreferredBackend.cpu,
      );
      expect(on.enableVision, isTrue);
      expect(on.enableAudio, isTrue);
    });

    test('maxNumImages is 0 when vision is off, defaults to 1 when on', () {
      expect(encoderInitArgs(_config(), PreferredBackend.cpu).maxNumImages, 0);
      expect(
        encoderInitArgs(
          _config(supportImage: true),
          PreferredBackend.cpu,
        ).maxNumImages,
        1,
      );
      expect(
        encoderInitArgs(
          _config(supportImage: true, maxNumImages: 4),
          PreferredBackend.cpu,
        ).maxNumImages,
        4,
      );
    });

    test('activationDataType is null unless the caller sets one', () {
      // Null must reach the client as null, not as a default: the client then
      // skips the setter and the model file's prefer_activation_type applies.
      expect(
        encoderInitArgs(_config(), PreferredBackend.gpu).activationDataType,
        isNull,
      );
      expect(
        encoderInitArgs(
          _config(activationDataType: ActivationDataType.float32),
          PreferredBackend.gpu,
        ).activationDataType,
        0,
      );
      // Sent as asked whichever backend the attempt uses, like LiteRT-LM's
      // own EngineConfig.activationDataType.
      expect(
        encoderInitArgs(
          _config(activationDataType: ActivationDataType.float16),
          PreferredBackend.cpu,
        ).activationDataType,
        1,
      );
    });
  });
}
