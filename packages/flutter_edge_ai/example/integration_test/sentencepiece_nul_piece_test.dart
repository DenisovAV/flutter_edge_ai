/// `.litertlm` bundles whose SP_Tokenizer carries a NUL-byte piece
/// (`patch_c_api.sh` section 17): FastVLM-0.5B and the Qwen3-0.6B file
/// litert-community replaced on 2026-10-13 both have piece 188 = '\x00', which
/// stock SentencePiece 0.2.2 refuses at `engine_create`. Also runs the current
/// Qwen3-0.6B (HF_Tokenizer) as the control.
///
/// Greedy, one backend per run:
///
///     flutter test integration_test/sentencepiece_nul_piece_test.dart \
///       -d macos --dart-define=BACKEND=gpu
///
/// `MODEL_BASE_URL` points the downloads at a local mirror (the three files
/// under their HF names, the old Qwen3 as `Qwen3-0.6B-a6e678a1.litertlm`), so
/// a rerun does not fetch 1.8 GB again.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _backendName = String.fromEnvironment('BACKEND', defaultValue: 'cpu');
const _baseUrl = String.fromEnvironment('MODEL_BASE_URL');

PreferredBackend get _backend => switch (_backendName) {
  'cpu' => PreferredBackend.cpu,
  'gpu' => PreferredBackend.gpu,
  _ => throw ArgumentError('BACKEND must be cpu or gpu, not $_backendName'),
};

// FastVLM-0.5B at HF commit 46001324 (sha256 ccba1e8b…), the file whose
// SP_Tokenizer has the NUL piece.
const _fastVlmUrl =
    'https://huggingface.co/litert-community/FastVLM-0.5B/resolve/'
    '460013246392191f8532e45e518576bb6513eace/FastVLM-0.5B.litertlm';
// Qwen3-0.6B.litertlm before HF e6687177 replaced its tokenizer
// (sha256 346f9b2e…). Same file name as the current one, hence the uninstall.
const _qwen3OldUrl =
    'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/'
    'a6e678a1d43b3d67452aca8b3f4f9aa96e6c750b/Qwen3-0.6B.litertlm';
const _qwen3NewUrl =
    'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/'
    'Qwen3-0.6B.litertlm';

String _url(String hfUrl, String localName) =>
    _baseUrl.isEmpty ? hfUrl : '$_baseUrl/$localName';

Future<InferenceModel> _load(
  String url, {
  int maxTokens = 2048,
  bool image = false,
}) async {
  final fileName = Uri.parse(url).pathSegments.last;
  // Two files share a name here; an installed one would be reused as is.
  if (await FlutterEdgeAi.isModelInstalled(fileName)) {
    await FlutterEdgeAi.uninstallModel(fileName);
  }
  await FlutterEdgeAi.installModel(
    modelType: ModelType.general,
    fileType: ModelFileType.litertlm,
  ).fromNetwork(url).install();
  return FlutterEdgeAi.getActiveModel(
    maxTokens: maxTokens,
    preferredBackend: _backend,
    supportImage: image,
    maxNumImages: image ? 1 : null,
    // As the wheel runs it: the encoder on the same backend as the LLM.
    preferredVisionBackend: image ? _backend : null,
  );
}

Future<String> _ask(
  InferenceModel model,
  String prompt, {
  Uint8List? image,
}) async {
  final session = await model.createSession(
    topK: 1,
    enableVisionModality: image != null,
  );
  try {
    await session.addQueryChunk(
      Message(text: prompt, isUser: true, imageBytes: image),
    );
    final chunks = <String>[];
    await for (final c in session.getResponseAsync()) {
      chunks.add(c);
    }
    return chunks.join();
  } finally {
    await session.close();
  }
}

Future<Uint8List> _asset(String path) async =>
    (await rootBundle.load('assets/$path')).buffer.asUint8List();

void _report(String tag, String prompt, String? image, String answer) {
  print('### [$_backendName] $tag ${image ?? '(text only)'} :: $prompt');
  print(answer);
  print('### end');
}

void _expectClean(String answer) {
  expect(answer.trim(), isNotEmpty);
  // The #1829 failure mode: the model echoing turn markers.
  expect(answer, isNot(contains('<start_of_turn>')));
  expect(answer, isNot(contains('<|im_start|>')));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FastVLM-0.5B (NUL piece): text and images', (t) async {
    await registerTestEngines();
    final model = await _load(
      _url(_fastVlmUrl, 'FastVLM-0.5B.litertlm'),
      image: true,
    );
    try {
      // The cases the LiteRT-LM 0.18.1 wheel answered on 2026-10-28.
      const cases = <(String, String?, String)>[
        ('Say hello', null, 'hello'),
        ('Describe this image briefly', 'test/test_image.jpg', 'dog'),
        ('Describe what is in this image', 'test/test_image.jpg', 'dog'),
        (
          'Describe what is in this image',
          'eg2_vision/house_scene.png',
          'house',
        ),
        (
          'List the fields from the document in the image',
          'eg2_vision/grocery_receipt.png',
          'grocery',
        ),
      ];
      for (final (prompt, image, keyword) in cases) {
        final answer = await _ask(
          model,
          prompt,
          image: image == null ? null : await _asset(image),
        );
        _report('FastVLM', prompt, image, answer);
        _expectClean(answer);
        expect(answer.toLowerCase(), contains(keyword));
      }
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));

  for (final (name, url, local) in <(String, String, String)>[
    (
      'Qwen3-0.6B before e6687177 (NUL piece)',
      _qwen3OldUrl,
      'Qwen3-0.6B-a6e678a1.litertlm',
    ),
    ('Qwen3-0.6B current (HF_Tokenizer)', _qwen3NewUrl, 'Qwen3-0.6B.litertlm'),
  ]) {
    testWidgets(name, (t) async {
      await registerTestEngines();
      final resolved = _url(url, local);
      final model = await _load(resolved, maxTokens: 1024);
      try {
        const prompt = 'What is 2 + 3? Answer with the number only. /no_think';
        final answer = await _ask(model, prompt);
        _report(name, prompt, null, answer);
        _expectClean(answer);
        expect(answer, contains('5'));
      } finally {
        await model.close();
        await FlutterEdgeAi.uninstallModel(
          Uri.parse(resolved).pathSegments.last,
        );
      }
    }, timeout: const Timeout(Duration(minutes: 30)));
  }
}
