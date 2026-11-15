// ONNX on iOS: the two ONNX Runtimes in one process.
//
// On iOS the hook bundles two frameworks: `onnxruntime-genai.framework`
// (Microsoft's, with its own ORT linked in statically and kept private since
// ORT-GenAI 0.18.0) for generation, and `onnxruntime.framework` (Microsoft's
// static ORT linked by `native/build_ort_ios.sh`, exporting only `_Ort*`) for
// the plain-ORT embedding arm. This test runs both in one process — a
// generation turn, MiniLM embeddings while the generator is still loaded,
// then another turn — and checks with dyld that the `OrtGetApiBase` the
// embedding arm calls is defined in `onnxruntime.framework` and that genai
// does not export one.
//
// Downloads Phi-3.5-mini (~2.7 GB) and all-MiniLM-L6-v2 (~90 MB) into the
// app's Documents directory on the first run.
//
// Runs on iOS only. Per AGENTS.md Rule 6, invoke via:
//   flutter test integration_test/onnx_ios_ort_coexist_test.dart -d <device-id>
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — tokenizer for the embedding pass
import 'package:flutter_edge_ai_embeddings/src/tokenizer_router.dart';
// ignore: implementation_imports — drives the plain-ORT embedding arm directly
import 'package:flutter_edge_ai_onnx/src/embedding/onnx_embedding_pass.dart';
// ignore: implementation_imports — drives the plain-ORT embedding arm directly
import 'package:flutter_edge_ai_onnx/src/embedding/ort_ffi_client.dart';
// ignore: implementation_imports — drives ORT-GenAI's FFI client directly
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _phiBase =
    'https://huggingface.co/microsoft/Phi-3.5-mini-instruct-onnx/resolve/'
    'main/cpu_and_mobile/cpu-int4-awq-block-128-acc-level-4';
const _phiFiles = [
  'genai_config.json',
  'config.json',
  'configuration_phi3.py',
  'phi-3.5-mini-instruct-cpu-int4-awq-block-128-acc-level-4.onnx',
  'phi-3.5-mini-instruct-cpu-int4-awq-block-128-acc-level-4.onnx.data',
  'tokenizer.json',
  'tokenizer_config.json',
  'special_tokens_map.json',
];
const _miniLmBase =
    'https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main';

const _frameworks = '@executable_path/Frameworks';

/// Temp-then-rename download; skips the network when [dest] is already there.
Future<void> _download(HttpClient client, String url, File dest) async {
  if (dest.existsSync() && dest.lengthSync() > 0) return;
  final tmp = File('${dest.path}.part');
  final request = await client.getUrl(Uri.parse(url));
  request.followRedirects = true;
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
}

final class _DlInfo extends ffi.Struct {
  external ffi.Pointer<pkg_ffi.Utf8> fname;
  external ffi.Pointer<ffi.Void> fbase;
  external ffi.Pointer<pkg_ffi.Utf8> sname;
  external ffi.Pointer<ffi.Void> saddr;
}

/// The path of the image that defines [address], from dyld's `dladdr`.
String _imageOf(ffi.Pointer<ffi.Void> address) {
  final dladdr = ffi.DynamicLibrary.process()
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_DlInfo>),
        int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_DlInfo>)
      >('dladdr');
  final info = pkg_ffi.calloc<_DlInfo>();
  try {
    if (dladdr(address, info) == 0) return '<dladdr failed>';
    return info.ref.fname.toDartString();
  } finally {
    pkg_ffi.calloc.free(info);
  }
}

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

Future<String> _turn(GenAiFfiClient client, String text, bool first) async {
  final out = StringBuffer();
  await for (final chunk in client.generate(
    GenAiTurn(userContent: text, isFirstTurn: first, maxOutputTokens: 16),
  )) {
    out.write(chunk);
  }
  return '$out';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ONNX iOS: generation and embeddings in one process, each on its own ORT',
    (tester) async {
      await tester.runAsync(() async {
        final docs = await getApplicationDocumentsDirectory();
        final phiDir = Directory('${docs.path}/onnx_ios_gate_model')
          ..createSync(recursive: true);
        final embDir = Directory('${docs.path}/onnx_emb_model')
          ..createSync(recursive: true);
        final http = HttpClient();
        try {
          for (final name in _phiFiles) {
            await _download(
              http,
              '$_phiBase/$name',
              File('${phiDir.path}/$name'),
            );
          }
          await _download(
            http,
            '$_miniLmBase/onnx/model.onnx',
            File('${embDir.path}/model.onnx'),
          );
          await _download(
            http,
            '$_miniLmBase/tokenizer.json',
            File('${embDir.path}/tokenizer.json'),
          );
        } finally {
          http.close(force: true);
        }

        final client = GenAiFfiClient();
        await client.load(phiDir.path, contextWindow: 1024);
        try {
          final before = await _turn(
            client,
            'Say hello in one sentence.',
            true,
          );
          // ignore: avoid_print
          print('[onnx coexist] generation: "$before"');
          expect(before.trim(), isNotEmpty);

          final pass = OnnxEmbeddingPass(
            OnnxEmbeddingConfig(
              modelPath: '${embDir.path}/model.onnx',
              tokenizerPath: '${embDir.path}/tokenizer.json',
              tokenizerFactory: resolveEmbeddingTokenizer,
            ),
            clientFactory: OrtFfiClient.new,
          );
          try {
            final info = await pass.load();
            expect(info.dimension, 384);
            Future<List<double>> embed(String text) =>
                pass.embed(EmbeddingInput.text(text), TaskType.none);
            final a = await embed('The cat sat on the mat.');
            final b = await embed('A feline rested on the rug.');
            final c = await embed('Quantum entanglement baffles physicists.');
            // ignore: avoid_print
            print(
              '[onnx coexist] embeddings: cos(similar)=${_cosine(a, b)} '
              'cos(different)=${_cosine(a, c)}',
            );
            expect(_cosine(a, b), greaterThan(_cosine(a, c)));
          } finally {
            await pass.close();
          }

          final ort = ffi.DynamicLibrary.open(
            '$_frameworks/onnxruntime.framework/onnxruntime',
          );
          final genai = ffi.DynamicLibrary.open(
            '$_frameworks/onnxruntime-genai.framework/onnxruntime-genai',
          );
          final getApiBase = ort.lookup<ffi.Void>('OrtGetApiBase');
          final image = _imageOf(getApiBase);
          // ignore: avoid_print
          print('[onnx coexist] OrtGetApiBase is defined in $image');
          expect(image, endsWith('/onnxruntime.framework/onnxruntime'));
          expect(genai.providesSymbol('OrtGetApiBase'), isFalse);

          final after = await _turn(client, 'Name one planet.', false);
          // ignore: avoid_print
          print('[onnx coexist] generation after the embeddings: "$after"');
          expect(after.trim(), isNotEmpty);
        } finally {
          await client.shutdown().timeout(const Duration(seconds: 15));
        }
      });
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
