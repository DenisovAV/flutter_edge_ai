/// Several LiteRT-LM models open at once through FlutterEdgeAi.openModel.
///
/// Each backend in ORDER opens its own engine on Gemma 4 E2B; all stay open
/// while each generates, the first generates again, a getActiveModel model
/// runs next to them, they close in reverse order, and one is opened again.
///
/// Prerequisites: `gemma-4-E2B-it.litertlm` where litertlm_ffi_test.dart
/// looks for it (macOS: the app container's Documents, double-nested because
/// of the sandbox), else it is downloaded. For the NPU on Windows Lunar Lake,
/// pass the LNL bundle: `--dart-define=NPU_MODEL=C:\...\gemma4_2b_lnl.litertlm`
/// and add `npu` to ORDER.
///
/// Run:
///   flutter test integration_test/litertlm_open_model_test.dart -d macos
///   flutter test integration_test/litertlm_open_model_test.dart -d windows \
///     --dart-define=ORDER=cpu,npu,gpu --dart-define=NPU_MODEL=...
///
/// Everything that can fail is inside the test body (AGENTS.md Rule 6b).
/// Step 3 makes Gemma 4 E2B the example app's persisted active model.
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _gemma4File = 'gemma-4-E2B-it.litertlm';
const _gemma4Url =
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/$_gemma4File';
const _token = String.fromEnvironment('HUGGINGFACE_TOKEN');
const _order = String.fromEnvironment('ORDER', defaultValue: 'cpu,gpu');
const _npuModel = String.fromEnvironment('NPU_MODEL');
const _maxTokens = int.fromEnvironment('MAX_TOKENS', defaultValue: 2048);
const _prompt = 'In two sentences, what is a neural processing unit?';

String? _localPath(String filename) {
  final home = Platform.environment['HOME'];
  if (Platform.isMacOS) {
    return '$home/Library/Containers/dev.flutterberlin.flutterGemmaExample55/'
        'Data/Documents/$filename';
  }
  if (Platform.isAndroid) return '/data/local/tmp/flutter_gemma_test/$filename';
  if (Platform.isLinux) return '$home/models/$filename';
  if (Platform.isWindows) {
    return '${Platform.environment['USERPROFILE']}\\models\\$filename';
  }
  return null;
}

/// Registers [path] (or the download) without making it the active model.
Future<InferenceModelSpec> _register({
  String? path,
  required String url,
  bool activate = false,
}) async {
  final builder = FlutterEdgeAi.installModel(
    modelType: ModelType.gemma4,
    fileType: ModelFileType.litertlm,
  );
  final installation = path != null && File(path).existsSync()
      ? await builder.fromFile(path).install(activate: activate)
      : await builder
            .fromNetwork(url, token: _token)
            .install(activate: activate);
  return installation.spec;
}

Future<String> _generate(String label, InferenceModel model) async {
  final sw = Stopwatch()..start();
  final session = await model.createSession(
    temperature: 0.8,
    topK: 1,
    topP: 0.95,
    randomSeed: 1,
    maxOutputTokens: 64,
  );
  try {
    await session.addQueryChunk(const Message(text: _prompt, isUser: true));
    final reply = await session.getResponse();
    print(
      '[open_model] $label (${model.activeBackend?.name}) '
      '${sw.elapsedMilliseconds} ms: ${reply.replaceAll('\n', ' ')}',
    );
    expect(reply.trim(), isNotEmpty, reason: '$label replied nothing');
    return reply;
  } finally {
    await session.close();
  }
}

PreferredBackend _backend(String name) =>
    PreferredBackend.values.firstWhere((b) => b.name == name);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('several LiteRT-LM models stay open and independent', (
    tester,
  ) async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [
        LiteRtLmEngine(
          backendFallback: false,
          nativeLogLevel: LiteRtLmLogLevel.warning,
        ),
      ],
    );
    final order = _order.split(',').map((s) => s.trim()).toList();
    expect(
      !order.contains('npu') || _npuModel.isNotEmpty,
      isTrue,
      reason: 'ORDER names npu: pass --dart-define=NPU_MODEL=<NPU bundle>',
    );
    final e2b = await _register(path: _localPath(_gemma4File), url: _gemma4Url);
    final npuSpec = order.contains('npu')
        ? await _register(path: _npuModel, url: _npuModel)
        : null;
    final activeBefore = FlutterEdgeAi.activeModelSpec?.name;

    Future<InferenceModel> open(String name) => FlutterEdgeAi.openModel(
      name == 'npu' ? npuSpec! : e2b,
      maxTokens: name == 'npu' ? 4096 : _maxTokens,
      preferredBackend: _backend(name),
    );

    // Every model this test opens, closed at the end even when an expect
    // fails midway (close() is idempotent).
    final everything = <InferenceModel>[];
    try {
      // 1. Open every backend in ORDER (a backend may repeat), keeping all.
      final opened = <(String, InferenceModel)>[];
      for (final name in order) {
        final model = await open(name);
        everything.add(model);
        expect(model.activeBackend, _backend(name));
        opened.add((name, model));
      }
      expect(FlutterEdgeAi.activeModelSpec?.name, activeBefore);
      expect(FlutterEdgeAiPlugin.instance.initializedModel, isNull);

      // 2. Generate on each while all are open, then on the first again:
      //    creating the later engines must not break the earlier one.
      for (final (name, model) in opened) {
        await _generate(name, model);
      }
      await _generate('${order.first} again', opened.first.$2);

      // 3. The active model, next to the opened ones. This makes the file
      //    the example app's persisted active model.
      await _register(
        path: _localPath(_gemma4File),
        url: _gemma4Url,
        activate: true,
      );
      final active = await FlutterEdgeAi.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: PreferredBackend.cpu,
      );
      everything.add(active);
      await _generate('active', active);
      await _generate(order.last, opened.last.$2);

      // 4. Close the opened ones in reverse order; the active model stays.
      for (final (_, model) in opened.reversed) {
        await model.close();
      }
      expect(FlutterEdgeAiPlugin.instance.initializedModel, same(active));
      await _generate('active after closes', active);

      // 5. Open the first and the last backend again, at the same time.
      final again = await Future.wait([open(order.first), open(order.last)]);
      everything.addAll(again);
      await _generate('${order.first} reopened', again.first);
      await _generate('${order.last} reopened', again.last);
    } finally {
      for (final model in everything.reversed) {
        await model.close();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
