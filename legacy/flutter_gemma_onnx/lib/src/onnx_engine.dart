import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show InferenceModelSpec;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver;
import 'package:flutter_gemma/core/registry/hugging_face_resolver_source.dart'
    show HuggingFaceResolverSource;
import 'package:flutter_gemma/core/registry/inference_engine_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart' show gemmaLog;
import 'package:flutter_gemma/flutter_gemma_interface.dart' show InferenceModel;

import 'ffi/gen_ai_client.dart';
import 'onnx_hugging_face_resolver.dart' show OnnxHuggingFaceResolver;
import 'onnx_inference_model.dart';

/// ONNX Runtime GenAI on-device inference engine.
///
/// **macOS/Linux/Windows/Android arm + iOS arm64 (hardened plan Phase 3,
/// design §11 D2).** [createModel] productionizes the ORT-GenAI FFI path
/// (`GenAiFfiClient` → `OnnxInferenceModel`/`OnnxSession`) — text-only,
/// greedy decoding, one session at a time. macOS/Linux/Windows/Android arm64
/// are device-verified — Android on FTL (Pixel 8 Pro, 2026-08-19: ~10.4
/// tok/s, ~3.74 GB peak RSS, flat-APK co-location with no ORT_LIB_PATH fix
/// needed, via `onnx_inference_smoke_test.dart`), the D2 throughput/RAM
/// go/no-go the gate waited on. iOS arm64 (device + Apple-Silicon simulator,
/// same `Abi.iosArm64`) is wired and verified: the app builds, signs,
/// installs and launches on a real iPhone, and generation runs — the
/// `@executable_path`-anchored dlopen resolves both `Oga*` and `OrtGetApiBase`
/// from the single self-contained genai xcframework, `OgaCreateModel` +
/// streamed generation succeed. See `hook/build.dart`'s platform table.
///
/// Mirrors [LiteRtLmEngine] from `flutter_gemma_litertlm`: a pure factory
/// that core probes via [canHandle] and calls to build a bare
/// [InferenceModel]; core owns the singleton lifecycle.
class OnnxEngine implements InferenceEngineProvider, HuggingFaceResolverSource {
  /// [clientFactory] is the injection seam for tests — defaults to the real
  /// `dart:ffi` worker-isolate client. Never override it in production code;
  /// it exists so `test/onnx_engine_test.dart` can inject a fake with zero
  /// dlopen (hardened plan Task 6).
  const OnnxEngine({GenAiClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? _defaultClientFactory;

  final GenAiClient Function() _clientFactory;

  static GenAiClient _defaultClientFactory() => GenAiFfiClient();

  @override
  String get name => 'ONNX';

  @override
  int get priority => 0;

  /// The engine's own Hugging Face resolver ([OnnxHuggingFaceResolver]).
  /// Auto-registered by `FlutterGemma.initialize(inferenceEngines: …)` so it
  /// owns the `.onnx` slot: `resolveHuggingFace(fileType: onnx)` and the
  /// one-call `fromHuggingFace(repo)` list the repo's file tree, pick an
  /// execution-provider folder, and install the whole ORT-GenAI directory
  /// (`genai_config.json` + `.onnx`[+`.onnx_data`] + tokenizer). On web the
  /// resolver returns a fileless repo-id model (Transformers.js).
  @override
  HuggingFaceResolver get huggingFaceResolver =>
      const OnnxHuggingFaceResolver();

  /// In lockstep with `hook/build.dart`'s `_archivesFor`: every host whose
  /// archive the hook bundles AND whose engine path is verified on a real
  /// device (macOS/Linux/Windows/Android/iOS arm64). The gate exists so that
  /// on a host with no archive — or an
  /// archive not yet device-validated — `GenAiFfiClient`'s worker-side dlopen
  /// doesn't fail at first use with a confusing native error; instead this
  /// engine declines cleanly (there is no other `.onnx` engine to route to
  /// yet). Widen deliberately only once the hook's archive lands for a given
  /// platform — never let it drift ahead of what `hook/build.dart` actually
  /// ships.
  static bool get _isSupportedHost {
    if (debugForceUnsupportedHost == true) return false;
    final abi = Abi.current();
    // Keep in lockstep with hook/build.dart's `_archivesFor` table.
    // macOS/Linux/Windows/Android arm64 are device-verified (Android on FTL
    // Pixel 8 Pro 2026-08-19: ~10.4 tok/s, ~3.74 GB peak RSS, flat-APK
    // co-location with no ORT_LIB_PATH fix needed). `dart:ffi`'s `Abi` has no
    // separate simulator ABI: an arm64 iOS Simulator on Apple Silicon
    // reports the SAME `Abi.iosArm64` as a real device (verified — the
    // sim-smoke test asserts this), so this one clause covers device +
    // Apple-Silicon-sim together; `Abi.iosX64` (Intel-Mac simulator) stays
    // ungated, matching `hook/build.dart` shipping no archive for it either.
    return (Platform.isMacOS && abi == Abi.macosArm64) ||
        (Platform.isLinux && abi == Abi.linuxX64) ||
        (Platform.isWindows && abi == Abi.windowsX64) ||
        (Platform.isAndroid && abi == Abi.androidArm64) ||
        (Platform.isIOS && abi == Abi.iosArm64);
  }

  /// Test-only override: when `true`, [_isSupportedHost] reports false
  /// regardless of the real host — the cheapest seam to exercise the
  /// unsupported-host branches of [canHandle]/[createModel] on a macOS-arm64
  /// CI/dev host without an actual non-macOS-arm64 machine. Never read or
  /// set outside `test/`. Reset to `null` in `tearDown`.
  @visibleForTesting
  static bool? debugForceUnsupportedHost;

  @override
  bool canHandle(InferenceModelSpec spec) {
    if (spec.fileType != ModelFileType.onnx) return false;
    if (!_isSupportedHost) {
      gemmaLog(
        'OnnxEngine declined ${Platform.operatingSystem}/${Abi.current()}: '
        'native ORT archives are macOS-arm64/linux-x64/windows-x64/'
        'android-arm64/ios-arm64-only in v1 (see hook/build.dart '
        '`_archivesFor`).',
      );
      return false;
    }
    return true;
  }

  @override
  Future<InferenceModel> createModel(
    InferenceModelSpec spec,
    RuntimeConfig config,
  ) async {
    // Belt-and-suspenders: canHandle already gates this in the normal
    // registry-dispatch path, but createModel is reachable directly (manual
    // construction / a registry bypass) — fail loud instead of dlopen-ing a
    // native archive that was never shipped for this host.
    if (!_isSupportedHost) {
      throw StateError(
        'OnnxEngine.createModel called on unsupported host '
        '${Platform.operatingSystem}/${Abi.current()} — ONNX native archives '
        'are macOS-arm64/linux-x64/windows-x64/android-arm64/ios-arm64-only '
        'in v1 (see hook/build.dart `_archivesFor`).',
      );
    }

    // The install layer hands inference engines a single resolved FILE path per
    // `InferenceModelSpec` (`RuntimeConfig.modelPath` =
    // `manager.getModelFilePaths(...).values.first`, see
    // `flutter_gemma_mobile.dart`'s createModel preamble). ORT-GenAI models are
    // whole DIRECTORIES (`genai_config.json` + `.onnx`[+`.onnx_data`] +
    // tokenizer files). The directory install
    // (`installModel(fileType: onnx).fromHuggingFace(repo)`, wired via
    // `OnnxHuggingFaceResolver` + core's directory-install path) downloads every
    // file into a per-model subdirectory and makes the primary
    // `genai_config.json` the spec's FIRST file — so `modelPath` resolves to
    // `<dir>/genai_config.json` and its PARENT is exactly the model directory
    // ORT-GenAI needs. The precheck below stays as a loud guard for a modelPath
    // whose parent is not a complete ORT-GenAI directory (a directory pointed at
    // directly, or a partial/incomplete install).
    final modelDir = File(config.modelPath).parent.path;
    final configFile = File('$modelDir/genai_config.json');
    if (!configFile.existsSync()) {
      throw StateError(
        'ONNX GenAI model directory "$modelDir" has no genai_config.json — '
        'expected an ORT-GenAI model directory '
        '(genai_config.json + .onnx[+.onnx_data] + tokenizer files). Install '
        'one with installModel(fileType: ModelFileType.onnx).fromHuggingFace('
        'repo), or point modelPath at a pre-populated ORT-GenAI directory.',
      );
    }

    final client = _clientFactory();
    await client.load(modelDir, contextWindow: config.maxTokens);

    return OnnxInferenceModel(
      client: client,
      maxTokens: config.maxTokens,
      modelType: spec.modelType,
      // NOT `config.preferredBackend`. Echoing the request is the one thing
      // this getter must never do: `InferenceModel.activeBackend` promises to
      // "reflect any fallback the plugin performed internally", and asking for
      // GPU here used to come back as GPU while the session ran on ORT's
      // default CPU provider — neither client calls
      // SessionOptionsAppendExecutionProvider at all.
      //
      // Null rather than CPU, because CPU would be its own guess: ORT-GenAI
      // selects the provider from the model directory's own genai_config.json,
      // which we never read. Null is what the contract defines for exactly
      // this — "the platform runtime does not expose a final backend".
      activeBackend: null,
      fileType: spec.fileType,
      onClose: () {},
    );
  }
}
