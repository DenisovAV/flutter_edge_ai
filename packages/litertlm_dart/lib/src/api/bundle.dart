// What a `.litertlm` file asks for, as the API's backends.

import '../bundle/litertlm_bundle_info.dart';
import '../bundle/litertlm_load_plan.dart' show encoderDefaultBackend;
import 'backend.dart';

/// The encoders' backends a bundle declares.
extension BundleInfoBackends on BundleInfo {
  /// Where the bundle's vision encoder runs when the caller does not say:
  /// its declared `backend_constraint` (the CPU when it allows the CPU), the
  /// NPU when it is compiled for one, else the CPU. Null when the bundle has
  /// no vision encoder. Pass it as `EngineConfig.visionBackend` to load the
  /// encoder where the file wants it.
  Backend? get declaredVisionBackend => switch (visionEncoder) {
    final encoder? => backendOf(encoderDefaultBackend(encoder)),
    null => null,
  };

  /// The same for the audio encoder.
  Backend? get declaredAudioBackend => switch (audioEncoder) {
    final encoder? => backendOf(encoderDefaultBackend(encoder)),
    null => null,
  };
}
