// ONNX plain-ORT embedding — device/emulator/simulator gate for ALL FIVE
// native platforms (macOS/Linux/Windows/Android/iOS arm/x64). The embedding
// analogue of the generation gates (`onnx_inference_smoke_test.dart` Android,
// `onnx_ios_generation_test.dart` iOS, the desktop gcloud scripts) — those are
// generation-only, so this file is the first on-device proof of the EMBEDDING
// arm on each platform.
//
// One body, every platform: `OrtFfiClient`'s loader resolves the right native
// ORT per host — a standalone `libonnxruntime` on macOS/Linux/Windows/Android
// (from the onnxruntime prebuilt / onnxruntime-android AAR), and the ORT
// statically linked inside `onnxruntime-genai.framework` on iOS (which is
// OLDER than 1.27, so `OrtFfiClient` probes `GetApi` down from
// ORT_API_VERSION to the version that framework accepts — see
// `ort_ffi_client.dart`). Drives `OnnxEmbeddingForwardPass` DIRECTLY (bypasses
// the registry/install plumbing — the native ORT path is the thing under test).
//
// Model: Xenova/all-MiniLM-L6-v2 (WordPiece `tokenizer.json`, single-file
// `model.onnx`, no external data — light enough for a simulator/emulator).
// Output `last_hidden_state` -> `tokenLevel` contract, masked mean-pool + L2,
// dim 384 — the Model-A case from `onnx_embedding_host_smoke_test.dart`, so the
// numbers stay comparable across platforms (all hosts produce the SAME cosines).
//
// Run (device / emulator / simulator attached):
//   cd packages/flutter_edge_ai/example
//   flutter test integration_test/onnx_embedding_device_test.dart -d <id>
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/onnx_embedding_forward_pass.dart';
import 'package:flutter_edge_ai_embeddings/src/tokenizer_router.dart';
import 'package:flutter_edge_ai_onnx/src/embedding/ort_ffi_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _repoBase = 'https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main';

// (url-suffix, local-filename). MiniLM's ONNX export is a single file.
const _modelFiles = [
  ('/onnx/model.onnx', 'model.onnx'),
  ('/tokenizer.json', 'tokenizer.json'),
];

// Every ONNX-embedding-supported host (lockstep with
// `OnnxEmbeddingBackend._isSupportedHost` + the hook's `_archivesFor`).
bool get _isOnnxEmbeddingHost =>
    Platform.isMacOS ||
    Platform.isLinux ||
    Platform.isWindows ||
    Platform.isAndroid ||
    Platform.isIOS;

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// Finalize a [ForwardResult] EXACTLY like `embedding_worker.dart`'s
/// `_finalize` — the real production dispatch, not a reimplementation.
List<double> _finalizeLikeWorker(
  EmbeddingOutputContract contract,
  ForwardResult result,
  List<int>? attentionMask,
) {
  switch (contract) {
    case EmbeddingOutputContract.pooledFinal:
      return List<double>.of(result.values);
    case EmbeddingOutputContract.tokenLevel:
      return meanPoolAndNormalize(result, attentionMask: attentionMask);
  }
}

Future<List<double>> _embed(
  OnnxEmbeddingForwardPass pass,
  EmbeddingTokenizer tokenizer,
  String text,
) async {
  final tokenized = tokenizer.encode('', text);
  final result = await pass.run(
    tokenIds: tokenized.ids,
    attentionMask: tokenized.attentionMask,
    tokenTypeIds: tokenized.tokenTypeIds,
  );
  final contract = pass.outputContract!;
  final effectiveMask = result.attentionMask ?? tokenized.attentionMask;
  return _finalizeLikeWorker(contract, result, effectiveMask);
}

/// Temp-then-rename download; skips the network if [dest] already exists
/// non-empty (a warm app-data dir shouldn't re-pull the model on a re-run).
Future<void> _downloadFile(HttpClient client, String url, File dest) async {
  if (dest.existsSync() && dest.lengthSync() > 0) {
    // ignore: avoid_print
    print('[onnx emb] cached: ${dest.path} (${dest.lengthSync()} bytes)');
    return;
  }
  final tmp = File('${dest.path}.part');
  final request = await client.getUrl(Uri.parse(url));
  request.followRedirects = true; // HF resolve/main -> CDN redirect chain.
  final response = await request.close();
  if (response.statusCode != 200) {
    await response.drain<void>();
    throw StateError('download failed (HTTP ${response.statusCode}) for $url');
  }
  final sink = tmp.openWrite();
  try {
    await response.pipe(sink);
  } finally {
    await sink.close();
  }
  await tmp.rename(dest.path);
  // ignore: avoid_print
  print('[onnx emb] downloaded: ${dest.path} (${dest.lengthSync()} bytes)');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ONNX embedding native gate: all-MiniLM-L6-v2 via the bundled ORT '
    '(dim=384 + cosine(similar) > cosine(different))',
    (tester) async {
      await tester.runAsync(() async {
        final docsDir = await getApplicationDocumentsDirectory();
        final modelDir = Directory('${docsDir.path}/onnx_emb_model');
        if (!modelDir.existsSync()) modelDir.createSync(recursive: true);

        final downloadClient = HttpClient();
        try {
          for (final (suffix, name) in _modelFiles) {
            await _downloadFile(
              downloadClient,
              '$_repoBase$suffix',
              File('${modelDir.path}/$name'),
            );
          }
        } finally {
          downloadClient.close(force: true);
        }

        final modelPath = '${modelDir.path}/model.onnx';
        final tokenizerPath = '${modelDir.path}/tokenizer.json';
        expect(
          File(modelPath).existsSync() && File(tokenizerPath).existsSync(),
          isTrue,
          reason: 'download did not produce model.onnx + tokenizer.json',
        );

        final tokenizer = await resolveEmbeddingTokenizer(tokenizerPath);
        final pass = OnnxEmbeddingForwardPass(
          modelPath,
          clientFactory: OrtFfiClient.new,
        );
        final loadSw = Stopwatch()..start();
        await pass.load();
        loadSw.stop();
        // ignore: avoid_print
        print(
          '[onnx emb] load took ${loadSw.elapsedMilliseconds} ms on '
          '${Platform.operatingSystem} (dlopen ORT + OrtCreateSession)',
        );

        try {
          expect(
            pass.outputDimension,
            384,
            reason: 'all-MiniLM-L6-v2 embeds to 384 dims',
          );
          expect(pass.outputContract, EmbeddingOutputContract.tokenLevel);

          final a = await _embed(pass, tokenizer, 'The cat sat on the mat.');
          final b = await _embed(
            pass,
            tokenizer,
            'A feline rested on the rug.',
          );
          final c = await _embed(
            pass,
            tokenizer,
            'Quantum entanglement baffles physicists.',
          );

          expect(a.length, 384);
          expect(a.any((v) => v != 0), isTrue);

          // Repeatability — identical text, identical vector.
          final a2 = await _embed(pass, tokenizer, 'The cat sat on the mat.');
          for (var i = 0; i < a.length; i++) {
            expect(a[i], closeTo(a2[i], 1e-5));
          }

          final simSimilar = _cosine(a, b);
          final simDifferent = _cosine(a, c);
          // ignore: avoid_print
          print(
            '[onnx emb] ${Platform.operatingSystem}: cosine(similar)='
            '$simSimilar cosine(different)=$simDifferent '
            'dim=${pass.outputDimension}',
          );
          expect(
            simSimilar,
            greaterThan(simDifferent + 0.1),
            reason:
                'similar-meaning sentences must score meaningfully higher '
                'than an unrelated one',
          );
        } finally {
          await pass.close();
        }
      });
    },
    skip: !_isOnnxEmbeddingHost,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
