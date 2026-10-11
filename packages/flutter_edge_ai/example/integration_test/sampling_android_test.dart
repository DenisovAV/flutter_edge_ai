// Android device check for #572: the sampled defaults on the two Android
// engines that had only ever decoded greedily by default.
//
// - MediaPipe `.task` (Gemma 3 1B, CPU and GPU): unset sampling sends
//   temperature 1.0, topK 40 (capped), topP 0.95; temperature 0 must decode
//   like topK 1; and what GPU does when the first session asked for topK 1
//   and a later one for the default 40.
// - LiteRT-LM `.litertlm` (Gemma 4 E2B, GPU = OpenCL): the GPU sampler with
//   k 64 / p 0.95 gives readable text, temperature 0 decodes like topK 1,
//   topP is honoured (p 0.05 stays near greedy), and the decode speed against
//   greedy.
//
// Every sampler config gets a freshly loaded model (LiteRT-LM #2080). Results
// are printed as `[SAMPLING-ANDROID]` lines; the hard expectations are only
// that every reply is non-empty, readable text.
//
// Stage in /data/local/tmp/flutter_gemma_test/:
//   gemma3-1b-it-int4.task, gemma-4-E2B-it.litertlm
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

const _task = 'gemma3-1b-it-int4.task';
const _litertlm = 'gemma-4-E2B-it.litertlm';
const _prompt = 'Write one sentence about the sea.';

void _log(String line) {
  // ignore: avoid_print
  print('[SAMPLING-ANDROID] $line');
}

String _flat(String s) => s.replaceAll('\n', ' ').trim();

/// Readable: mostly letters, spaces and punctuation, and a few words.
void _expectReadable(String reply, String label) {
  final text = reply.trim();
  expect(text, isNotEmpty, reason: '$label: empty reply');
  final readable = RegExp(r"[A-Za-z\s.,;:!?'\-]").allMatches(text).length;
  expect(
    readable / text.length,
    greaterThan(0.8),
    reason: '$label: unreadable reply "$text"',
  );
  expect(
    text.split(RegExp(r'\s+')).length,
    greaterThanOrEqualTo(3),
    reason: '$label: "$text"',
  );
}

Future<void> _install(
  String file,
  ModelType type,
  ModelFileType fileType,
) async {
  await registerTestEngines();
  final path = await stagedModelPath(file);
  expect(path, isNotNull, reason: 'stage $file first');
  await FlutterEdgeAi.installModel(
    modelType: type,
    fileType: fileType,
  ).fromFile(path!).install();
}

/// One reply on [model] from a fresh session, with the time it took.
Future<(String, int)> _reply(
  InferenceModel model, {
  double? temperature,
  int? topK,
  double? topP,
  int? seed,
  int maxOutputTokens = 64,
}) async {
  final sw = Stopwatch()..start();
  final session = await model.createSession(
    temperature: temperature,
    topK: topK,
    topP: topP,
    randomSeed: seed,
    maxOutputTokens: maxOutputTokens,
  );
  try {
    await session.addQueryChunk(const Message(text: _prompt, isUser: true));
    final reply = await session.getResponse();
    return (reply, sw.elapsedMilliseconds);
  } finally {
    await session.close();
  }
}

/// [_reply] on a freshly loaded model, closed afterwards.
Future<(String, int)> _freshReply(
  PreferredBackend backend, {
  double? temperature,
  int? topK,
  double? topP,
  int? seed,
  int maxOutputTokens = 64,
}) async {
  final model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 1024,
    preferredBackend: backend,
  );
  try {
    return await _reply(
      model,
      temperature: temperature,
      topK: topK,
      topP: topP,
      seed: seed,
      maxOutputTokens: maxOutputTokens,
    );
  } finally {
    await model.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final backend in [PreferredBackend.cpu, PreferredBackend.gpu]) {
    testWidgets('MediaPipe .task on ${backend.name}', (tester) async {
      await _install(_task, ModelType.gemmaIt, ModelFileType.task);
      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: backend,
      );
      try {
        final greedy = (await _reply(model, topK: 1)).$1;
        final temp0 = (await _reply(model, temperature: 0)).$1;
        final defaults = (await _reply(model)).$1;
        final seeded = <String>[
          for (final seed in [2, 3, 4]) (await _reply(model, seed: seed)).$1,
        ];
        _log('mediapipe ${backend.name} greedy="${_flat(greedy)}"');
        _log('mediapipe ${backend.name} temp0="${_flat(temp0)}"');
        _log('mediapipe ${backend.name} defaults="${_flat(defaults)}"');
        for (final s in seeded) {
          _log('mediapipe ${backend.name} seeded="${_flat(s)}"');
        }
        _log(
          'mediapipe ${backend.name} SUMMARY temp0==greedy ${temp0 == greedy} '
          'defaults==greedy ${defaults == greedy} '
          'distinctSeeded ${seeded.toSet().length}/3',
        );
        for (final r in [greedy, temp0, defaults, ...seeded]) {
          _expectReadable(r, 'mediapipe ${backend.name}');
        }
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  testWidgets('MediaPipe .task GPU: topK 1 first, then the default', (
    tester,
  ) async {
    await _install(_task, ModelType.gemmaIt, ModelFileType.task);
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: PreferredBackend.gpu,
    );
    try {
      await _reply(model, topK: 1);
      try {
        final r = (await _reply(model)).$1;
        _log('mediapipe gpu: default after topK 1 OK "${_flat(r)}"');
      } on Object catch (e) {
        _log('mediapipe gpu: default after topK 1 THREW $e');
      }
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('LiteRT-LM .litertlm GPU sampler', (tester) async {
    await _install(_litertlm, ModelType.gemma4, ModelFileType.litertlm);
    const gpu = PreferredBackend.gpu;
    final (greedy, greedyMs) = await _freshReply(
      gpu,
      topK: 1,
      maxOutputTokens: 128,
    );
    final (temp0, _) = await _freshReply(
      gpu,
      temperature: 0,
      maxOutputTokens: 128,
    );
    final (defaults, defaultsMs) = await _freshReply(gpu, maxOutputTokens: 128);
    final (lowP, _) = await _freshReply(
      gpu,
      topK: 64,
      temperature: 1.0,
      topP: 0.05,
      maxOutputTokens: 128,
    );
    _log('litertlm gpu greedy ${greedyMs}ms="${_flat(greedy)}"');
    _log('litertlm gpu temp0="${_flat(temp0)}"');
    _log('litertlm gpu defaults ${defaultsMs}ms="${_flat(defaults)}"');
    _log('litertlm gpu topP0.05="${_flat(lowP)}"');

    // Three chats on one engine with the defaults: the sampler's random
    // state carries on, so they should differ.
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: gpu,
    );
    final chats = <String>[];
    try {
      for (var i = 0; i < 3; i++) {
        chats.add((await _reply(model)).$1);
      }
    } finally {
      await model.close();
    }
    for (final c in chats) {
      _log('litertlm gpu chat="${_flat(c)}"');
    }
    _log(
      'litertlm gpu SUMMARY temp0==greedy ${temp0 == greedy} '
      'topP0.05==greedy ${lowP == greedy} defaults==greedy ${defaults == greedy} '
      'distinctChats ${chats.toSet().length}/3 '
      'greedyMs $greedyMs defaultsMs $defaultsMs',
    );
    for (final r in [greedy, temp0, defaults, lowP, ...chats]) {
      _expectReadable(r, 'litertlm gpu');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
