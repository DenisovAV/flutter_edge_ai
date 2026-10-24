/// The native LiteRT-LM engine reads a `.litertlm` before it loads it
/// (`planLiteRtLmLoad`) and, with `LiteRtLmEngine(backendFallback: false)`,
/// makes one attempt and reports LiteRT-LM's own reason when it fails.
///
/// What runs where:
/// - an incomplete file and a bundle compiled for an NPU this host has no
///   dispatch for are refused before any engine exists;
/// - a strict GPU load the engine refuses fails once, with the native reason;
/// - the generic Gemma 4 E2B loads on the GPU with its encoders on the CPU,
///   and says so in `activeVisionBackend` / `activeAudioBackend`.
///
/// Prerequisites, macOS (the example's container, as for the other suites):
///   gemma-4-E2B-it.litertlm in ~/Library/Containers/.../Documents/
///   For the NPU case, a bundle compiled for a Qualcomm NPU there too, named
///   by --dart-define=NPU_BUNDLE=<file name>; without it that test skips.
///
/// Run:
///   flutter test integration_test/litertlm_bundle_plan_test.dart -d macos
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'local_model_file_io.dart';

const _gemma4 = 'gemma-4-E2B-it.litertlm';
const _npuBundle = String.fromEnvironment('NPU_BUNDLE');

Future<void>? _initialized;

Future<void> _initialize() => _initialized ??= FlutterEdgeAi.initialize(
  inferenceEngines: const [LiteRtLmEngine(backendFallback: false)],
);

Future<void> _install(String path) async {
  await _initialize();
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  ).fromFile(path).install();
}

/// A file with [gemma4]'s header and [length] bytes, the rest zeros (sparse):
/// its sections are where the header says, and hold nothing a model can run.
String _hollowCopy(String gemma4, int length, String name) {
  final header = File(gemma4).openSync();
  final bytes = header.readSync(4096);
  header.closeSync();
  final path = '${Directory.systemTemp.path}/$name';
  final file = File(path)..writeAsBytesSync(bytes);
  final raf = file.openSync(mode: FileMode.append);
  raf.truncateSync(length);
  raf.closeSync();
  return path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final gemma4 = localModelFile(_gemma4);
  final npu = _npuBundle.isEmpty ? null : localModelFile(_npuBundle);

  testWidgets('an NPU-compiled bundle is refused on macOS before any engine', (
    _,
  ) async {
    await _install(npu!);
    final watch = Stopwatch()..start();
    Object? error;
    try {
      await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    } on Object catch (e) {
      error = e;
    }
    debugPrint(
      '[plan] NPU bundle on macOS: $error '
      '(${watch.elapsedMilliseconds} ms)',
    );
    expect(
      error,
      isA<LiteRtLmBundleException>().having(
        (e) => e.problem,
        'problem',
        LiteRtLmBundleProblem.unsupportedNpu,
      ),
    );
    expect(watch.elapsedMilliseconds, lessThan(2000));
  }, skip: npu == null);

  testWidgets('an incomplete download is refused before any engine', (_) async {
    final info = await readLiteRtLmBundleInfo(gemma4!);
    final path = _hollowCopy(
      gemma4,
      info.expectedLength ~/ 2,
      'plan_half.litertlm',
    );
    await _install(path);
    Object? error;
    try {
      await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    } on Object catch (e) {
      error = e;
    }
    debugPrint('[plan] half a file: $error');
    expect(
      error,
      isA<LiteRtLmBundleException>().having(
        (e) => e.problem,
        'problem',
        LiteRtLmBundleProblem.incomplete,
      ),
    );
    File(path).deleteSync();
  }, skip: gemma4 == null);

  testWidgets('strict: one GPU attempt, with the reason LiteRT-LM gives', (
    _,
  ) async {
    final info = await readLiteRtLmBundleInfo(gemma4!);
    final path = _hollowCopy(
      gemma4,
      info.expectedLength,
      'plan_hollow.litertlm',
    );
    await _install(path);
    Object? error;
    try {
      await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.gpu,
      );
    } on Object catch (e) {
      error = e;
    }
    debugPrint('[plan] hollow file on the GPU: $error');
    expect(error, isA<BackendInitException>());
    final attempts = (error! as BackendInitException).attempts;
    expect(attempts.map((a) => a.backend), [PreferredBackend.gpu]);
    final create = attempts.single.error;
    expect(create, isA<LiteRtLmEngineCreateException>());
    debugPrint(
      '[plan] native: ${(create as LiteRtLmEngineCreateException).nativeCode} '
      '${create.nativeMessage}',
    );
    expect(create.nativeMessage, isNotNull);
    File(path).deleteSync();
  }, skip: gemma4 == null);

  testWidgets('the generic Gemma 4: GPU text, encoders on the CPU, reported', (
    _,
  ) async {
    await _install(gemma4!);
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.gpu,
      supportImage: true,
      supportAudio: true,
    );
    debugPrint(
      '[plan] gemma 4: text ${model.activeBackend}, vision '
      '${model.activeVisionBackend}, audio ${model.activeAudioBackend}',
    );
    expect(model.activeBackend, PreferredBackend.gpu);
    expect(model.activeVisionBackend, PreferredBackend.cpu);
    expect(model.activeAudioBackend, PreferredBackend.cpu);
    final session = await model.createSession(maxOutputTokens: 16);
    await session.addQueryChunk(
      const Message(text: 'Say the word hello.', isUser: true),
    );
    final reply = await session.getResponse();
    debugPrint('[plan] reply: $reply');
    expect(reply.toLowerCase(), contains('hello'));
    await session.close();
    await model.close();
  }, skip: gemma4 == null || !Platform.isMacOS);
}
