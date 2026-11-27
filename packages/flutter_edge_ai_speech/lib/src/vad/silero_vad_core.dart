// Silero VAD over the LiteRT C API. Runs inside the VAD worker isolate; its
// forward pass is a blocking FFI call (well under a millisecond per frame on a
// desktop CPU), so it never runs on the UI isolate.
//
// The model is the 16 kHz Silero VAD exported to LiteRT with its state as an
// explicit tensor (silero-vad v6.3, exported with anira-project's scripts,
// see assets/vad/README.md): one signature, inputs `audio [1,1,512]` and `state [1,320]`,
// outputs `probability [1,1,1]` and `state [1,320]`, in that order. The state
// is the LSTM's h and c (128 each) plus the last 64 samples of the previous
// frame, which upstream's wrapper keeps outside the model; a stream starts
// from zeros. On the CPU, always: the graph is tiny, and a GPU round trip per
// 32 ms frame would cost more than the frame.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart' show edgeAiLog;
import 'package:litertlm_dart/litert_bindings.dart';

import '../litert/litert_graph.dart';
import 'vad_endpointer.dart' show vadFrameSamples;

/// Width of the model's state tensor.
const int sileroStateWidth = 320;

/// The native half of the detector: one compiled Silero graph and the
/// stream's state.
final class SileroVadCore {
  SileroVadCore._(this._bindings, this._environment, this._graph);

  final LiteRtBindings _bindings;
  final LiteRtEnvironment _environment;
  final LoadedGraph _graph;
  final Float32List _state = Float32List(sileroStateWidth);
  bool _disposed = false;

  /// Loads and compiles the model at [modelPath] on the CPU, then runs one
  /// frame of silence to check that the graph has the expected tensors and
  /// gives a probability; on any failure everything built so far is freed.
  static SileroVadCore load(String modelPath) {
    final bindings = LiteRtBindings.open();
    LiteRtEnvironment? environment;
    LoadedGraph? graph;
    try {
      final envPtr = calloc<LiteRtEnvironment>();
      try {
        bindings
            .createEnvironment(0, nullptr, envPtr)
            .check('LiteRtCreateEnvironment');
        environment = envPtr.value;
      } finally {
        calloc.free(envPtr);
      }
      graph = loadLiteRtGraph(
        bindings,
        environment,
        modelPath,
        kLiteRtHwAcceleratorCpu,
      );
      final core = SileroVadCore._(bindings, environment, graph);
      try {
        checkSileroVadLayout(
          inputCount: _inputCount(bindings, graph.model),
          inputShapes: [
            for (var i = 0; i < 2; i++)
              _inputShape(bindings, graph.compiledModel, i),
          ],
          outputShapes: _outputShapes(bindings, graph.compiledModel, 2),
        );
      } on FormatException catch (e) {
        throw StateError(
          'VoiceActivityDetector: $modelPath is not a Silero VAD model with '
          'inputs [1,1,512] and [1,$sileroStateWidth] and outputs [1,1,1] '
          'and [1,$sileroStateWidth]: ${e.message}',
        );
      }
      // The layout is right: a failure here is the runtime's or a graph
      // that does not compute a probability, and says which.
      try {
        core.probability(Float32List(vadFrameSamples));
        core.reset();
      } catch (e) {
        throw StateError(
          'VoiceActivityDetector: $modelPath failed its first frame: $e',
        );
      }
      edgeAiLog('[SileroVadCore] loaded $modelPath');
      return core;
    } catch (_) {
      if (graph != null) destroyGraphs(bindings, [graph]);
      if (environment != null) bindings.destroyEnvironment(environment);
      rethrow;
    }
  }

  /// The speech probability of one 512-sample frame of 16 kHz audio in
  /// [-1, 1], carrying the state on to the next frame.
  double probability(Float32List frame) {
    if (_disposed) throw StateError('SileroVadCore is disposed');
    if (frame.length != vadFrameSamples) {
      throw ArgumentError.value(
        frame.length,
        'frame.length',
        'a Silero VAD frame is $vadFrameSamples samples',
      );
    }
    final out = runLiteRtGraph(
      _bindings,
      _graph.compiledModel,
      0,
      [
        F32Input(const [1, 1, vadFrameSamples], frame),
        F32Input(const [1, sileroStateWidth], _state),
      ],
      const [
        [1, 1, 1],
        [1, sileroStateWidth],
      ],
    );
    final p = out[0][0];
    if (p.isNaN || p < 0 || p > 1) {
      throw StateError('Silero VAD returned $p, not a probability');
    }
    _state.setAll(0, out[1]);
    return p;
  }

  /// Starts a new stream: the state goes back to zeros.
  void reset() => _state.fillRange(0, sileroStateWidth, 0);

  /// Frees the graph and the environment. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    destroyGraphs(_bindings, [_graph]);
    _bindings.destroyEnvironment(_environment);
  }
}

/// Throws [FormatException] unless the graph's first signature has the
/// bundled model's layout: two inputs, audio `[1,1,512]` and state
/// `[1,320]`, and outputs probability `[1,1,1]` and state `[1,320]`, in that
/// order. Tensor element types are not read (the LiteRT C API bound here has
/// no accessor for them); the probe frame [SileroVadCore.load] runs next
/// catches a graph that does not compute a probability.
void checkSileroVadLayout({
  required int inputCount,
  required List<List<int>> inputShapes,
  required List<List<int>> outputShapes,
}) {
  const inputs = [
    [1, 1, vadFrameSamples],
    [1, sileroStateWidth],
  ];
  const outputs = [
    [1, 1, 1],
    [1, sileroStateWidth],
  ];
  if (inputCount != inputs.length) {
    throw FormatException('the graph has $inputCount inputs, not 2');
  }
  bool same(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
  for (var i = 0; i < inputs.length; i++) {
    if (!same(inputShapes[i], inputs[i])) {
      throw FormatException('input $i is ${inputShapes[i]}, not ${inputs[i]}');
    }
  }
  for (var i = 0; i < outputs.length; i++) {
    if (i >= outputShapes.length || !same(outputShapes[i], outputs[i])) {
      throw FormatException(
        'output $i is ${i < outputShapes.length ? outputShapes[i] : 'missing'}'
        ', not ${outputs[i]}',
      );
    }
  }
}

int _inputCount(LiteRtBindings bindings, LiteRtModel model) {
  final sig = calloc<LiteRtSignature>();
  final count = calloc<Size>();
  try {
    bindings.getModelSignature(model, 0, sig).check('LiteRtGetModelSignature');
    bindings
        .getNumSignatureInputs(sig.value, count)
        .check('LiteRtGetNumSignatureInputs');
    return count.value;
  } finally {
    calloc
      ..free(sig)
      ..free(count);
  }
}

List<int> _inputShape(
  LiteRtBindings bindings,
  LiteRtCompiledModel graph,
  int index,
) {
  final layout = LiteRtLayoutView.calloc();
  try {
    bindings
        .getInputTensorLayout(graph, 0, index, layout.pointer)
        .check('LiteRtGetCompiledModelInputTensorLayout($index)');
    return [for (var i = 0; i < layout.rank; i++) layout.dimension(i)];
  } finally {
    layout.free();
  }
}

/// The first [count] output shapes: the C API fills layouts from output 0.
List<List<int>> _outputShapes(
  LiteRtBindings bindings,
  LiteRtCompiledModel graph,
  int count,
) {
  final layouts = calloc<LiteRtLayoutPosix>(count);
  try {
    bindings
        .getOutputTensorLayouts(graph, 0, count, layouts.cast(), false)
        .check('LiteRtGetCompiledModelOutputTensorLayouts');
    return [
      for (var o = 0; o < count; o++)
        [
          for (var i = 0; i < ((layouts + o).ref.rankAndHasStrides & 0x7f); i++)
            (layouts + o).ref.dimensions[i],
        ],
    ];
  } finally {
    calloc.free(layouts);
  }
}
