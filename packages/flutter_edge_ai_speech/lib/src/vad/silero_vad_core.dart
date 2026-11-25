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
        core.probability(Float32List(vadFrameSamples));
        core.reset();
      } catch (e) {
        throw StateError(
          'VoiceActivityDetector: $modelPath is not a Silero VAD model with '
          'inputs [1,1,512] and [1,$sileroStateWidth]: $e',
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
