// Load-time smoke test for the Qwen3-TTS talker graph
// (`talker_int4.tflite`) — the FIRST test in this package that actually
// loads a real compiled `.tflite` graph through our own Dart LiteRT FFI
// (`LiteRtBindings.open()` + `loadLiteRtGraph`) rather than exercising pure
// Dart code, so a failure here is a genuine "our FFI can't load this graph"
// signal, not a logic bug.
//
// Verifies `TalkerLayout.assertLayout` against the REAL talker graph: the
// frozen constants pinned by the C1 spike (2026-08-03, see
// `qwen3_talker_layout.dart`'s file header) must still match reality. The
// talker (~256 MB int4) is NOT committed to the repo — it lives in the
// local HuggingFace cache (see [_defaultModelDir] below) or wherever
// `QWEN3_MODEL_DIR` points. When absent (e.g. in CI without the artifact
// fetched) the test skips gracefully so the suite stays green; when present
// (as it is for local device runs) it asserts the golden layout.
@Tags(['qwen3-artifacts'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_gemma_litertlm/litert_bindings.dart';
import 'package:flutter_gemma_speech/src/litert/litert_graph.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_talker_layout.dart';
import 'package:flutter_test/flutter_test.dart';

/// Default location of the Qwen3-TTS model snapshot dir — the local
/// HuggingFace cache path for `litert-community/Qwen3-TTS-12Hz-0.6B-Base`.
/// Override with the `QWEN3_MODEL_DIR` environment variable to run against
/// a different snapshot.
String _defaultModelDir() {
  final home = Platform.environment['HOME'] ?? '';
  return '$home/.cache/huggingface/hub/'
      'models--litert-community--Qwen3-TTS-12Hz-0.6B-Base/snapshots/'
      '66855540b3b34679f06c3ff07859603fc9514c66';
}

String _modelDir() =>
    Platform.environment['QWEN3_MODEL_DIR'] ?? _defaultModelDir();

void main() {
  test('TalkerLayout.assertLayout passes against the real talker graph '
      '(frozen C1 constants)', () {
    final talkerPath = '${_modelDir()}/talker_int4.tflite';
    if (!File(talkerPath).existsSync()) {
      markTestSkipped(
        'Qwen3-TTS talker graph not found at $talkerPath — set '
        'QWEN3_MODEL_DIR or fetch the model snapshot to run this test.',
      );
      return;
    }

    final bindings = LiteRtBindings.open();
    LiteRtEnvironment? environment;
    LoadedGraph? talker;
    try {
      final envPtr = calloc<LiteRtEnvironment>();
      bindings
          .createEnvironment(0, nullptr, envPtr)
          .check('LiteRtCreateEnvironment');
      environment = envPtr.value;
      calloc.free(envPtr);

      // CPU: this test only needs the graph to load and its declared
      // tensor layouts to be introspectable — no forward pass is run, so
      // there is no reason to pull in a GPU/NPU delegate.
      talker = loadLiteRtGraph(
        bindings,
        environment,
        talkerPath,
        kLiteRtHwAcceleratorCpu,
      );

      // The real assertion: the graph our Dart FFI just loaded matches
      // every frozen constant TalkerLayout.assertLayout knows how to
      // check (see its doc for exactly what that covers).
      expect(
        () => TalkerLayout.assertLayout(bindings, talker!.compiledModel),
        returnsNormally,
      );

      // Print the raw introspected values TalkerLayout.assertLayout just
      // confirmed, so a device run leaves a paper trail of what was
      // actually observed on the real graph (mirrors the other Qwen3/TTS
      // device-gate tests' diagnostic prints).
      final embDecode = LiteRtLayoutView.calloc();
      final embPrefill32 = LiteRtLayoutView.calloc();
      final embPrefill128 = LiteRtLayoutView.calloc();
      final maskDecode = LiteRtLayoutView.calloc();
      try {
        bindings
            .getInputTensorLayout(
              talker.compiledModel,
              TalkerLayout.decodeSig,
              0,
              embDecode.pointer,
            )
            .check('decode.embeddings (diagnostic)');
        bindings
            .getInputTensorLayout(
              talker.compiledModel,
              TalkerLayout.prefill32Sig,
              0,
              embPrefill32.pointer,
            )
            .check('prefill_32.embeddings (diagnostic)');
        bindings
            .getInputTensorLayout(
              talker.compiledModel,
              TalkerLayout.prefill128Sig,
              0,
              embPrefill128.pointer,
            )
            .check('prefill_128.embeddings (diagnostic)');
        bindings
            .getInputTensorLayout(
              talker.compiledModel,
              TalkerLayout.decodeSig,
              2,
              maskDecode.pointer,
            )
            .check('decode.mask (diagnostic)');

        List<int> dims(LiteRtLayoutView v) => [
          for (var i = 0; i < v.rank; i++) v.dimension(i),
        ];

        // ignore: avoid_print
        print(
          'TALKER-LAYOUT-TEST<<<'
          'decode.embeddings=${dims(embDecode)} '
          'prefill_32.embeddings=${dims(embPrefill32)} '
          'prefill_128.embeddings=${dims(embPrefill128)} '
          'decode.mask=${dims(maskDecode)} '
          'lastKvInputIndex=${TalkerLayout.numTalkerInputs - 1} reachable=true'
          '>>>',
        );
      } finally {
        embDecode.free();
        embPrefill32.free();
        embPrefill128.free();
        maskDecode.free();
      }
    } finally {
      if (talker != null) {
        bindings.destroyCompiledModel(talker.compiledModel);
        bindings.destroyOptions(talker.options);
        bindings.destroyModel(talker.model);
      }
      if (environment != null) bindings.destroyEnvironment(environment);
    }
  });
}
