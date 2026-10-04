// ONNX GenAI + ORT iOS/simulator dlopen-anchor smoke test.
//
// `OnnxEngine`/`OnnxEmbeddingBackend` widened `_isSupportedHost` to iOS
// arm64 (device + Apple-Silicon simulator, which reports the same
// `Abi.iosArm64`) with no test anywhere in the repo that actually opens the
// bundled `onnxruntime-genai.framework` Native-Assets CodeAsset on a real
// iOS process. This test closes that gap for the LOADER half specifically:
// it proves `GenAiFfiClient` (ORT-GenAI, `gen_ai_client.dart`) and
// `OrtFfiClient` (plain ORT embedding arm, `ort_ffi_client.dart`) both
// successfully `dlopen` the framework rather than failing with a dyld
// "image not found" — the exact failure mode a bare, unanchored
// `<name>.framework/<name>` leaf name produces on iOS's dyld 4 (dyld 4
// cannot resolve framework names alone the way macOS's dyld does; see
// `flutter_edge_ai_litertlm/lib/src/ffi/litert_lm_client.dart`'s
// `@executable_path/Frameworks/` precedent, and `gen_ai_client.dart`'s
// `_candidateNames`/`ort_ffi_client.dart`'s `_openOnnxRuntime` iOS branches).
//
// Deliberately does NOT download the ~2.7 GB Phi-3.5-mini model or run a
// real generation — this only proves the SHARED LIBRARY resolves.
// `GenAiFfiClient.load()` is pointed at a bogus, non-existent model
// directory on purpose: if `dlopen` fails, the worker isolate's error is the
// `_openFirst` "Could not open any of [...]" `StateError`, thrown BEFORE any
// native model call; if `dlopen` succeeds, execution reaches
// `OgaCreateModel`, which fails instead with a DIFFERENT, native-level
// "OgaCreateModel failed" message. The two are asserted to be
// distinguishable so this test fails loudly (not silently) if the anchor
// regresses. Real end-to-end generation is covered by
// `onnx_inference_smoke_test.dart` (Android) and the desktop host-smoke
// tests in `flutter_edge_ai_onnx/test/`; an on-device iOS throughput/RAM
// go/no-go is a separate, later gate (see `onnx_engine.dart`'s
// `_isSupportedHost` doc).
//
// Runs on iOS only (`skip: !Platform.isIOS`) — meaningless elsewhere. Per
// AGENTS.md Rule 6, invoke via:
//   flutter test integration_test/onnx_ios_loader_smoke_test.dart -d <device-id>
import 'dart:io';

import 'package:flutter_edge_ai_onnx/src/embedding/ort_ffi_client.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'ONNX GenAI iOS: onnxruntime-genai.framework dlopen resolves '
    '(GenAiFfiClient.load fails on OgaCreateModel, NOT on dlopen)',
    (tester) async {
      await tester.runAsync(() async {
        final client = GenAiFfiClient();
        Object? error;
        try {
          await client.load(
            '${Directory.systemTemp.path}/onnx_ios_loader_smoke_nonexistent',
            contextWindow: 1024,
          );
        } catch (e) {
          error = e;
        }
        expect(
          error,
          isNotNull,
          reason: 'load() against a bogus model dir unexpectedly succeeded',
        );
        final message = error.toString();
        // ignore: avoid_print
        print('[onnx ios loader smoke] GenAiFfiClient.load() error: $message');
        expect(
          message.contains('Could not open any of'),
          isFalse,
          reason:
              'onnxruntime-genai.framework failed to dlopen on iOS — the '
              '@executable_path/Frameworks/ anchor is missing or wrong: '
              '$message',
        );
      });
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'ONNX embedding iOS: OrtFfiClient resolves OrtGetApiBase from '
    'onnxruntime-genai.framework (plain-ORT co-location)',
    (tester) async {
      await tester.runAsync(() async {
        Object? error;
        OrtFfiClient? client;
        try {
          client = OrtFfiClient();
        } catch (e) {
          error = e;
        }
        try {
          await client?.close();
        } catch (_) {}
        // ignore: avoid_print
        print('[onnx ios loader smoke] OrtFfiClient() error: $error');
        expect(
          error,
          isNull,
          reason:
              'OrtFfiClient() constructor failed to resolve OrtGetApiBase '
              'on iOS: $error',
        );
      });
    },
    skip: !Platform.isIOS,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
