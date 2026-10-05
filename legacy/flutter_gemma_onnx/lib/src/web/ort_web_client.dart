// `dart:js_interop` binding to `onnxruntime-web` (ONNX web PR,
// `feat/onnx-web`, Task 2.2). `dart:js_interop` only resolves on web compile
// targets — this file can never be imported into a VM (`flutter test`) run;
// it is compile-checked by `flutter build web` and exercised for real only
// in a browser. See `onnx_web_embedding_forward_pass.dart` for the pure-Dart
// half this client plugs into via the shared [OrtClient] interface.
//
// index.html contract: a `window.ortReady` Promise (resolving once the
// `onnxruntime-web` ESM module has loaded) AND `window.ort` set to the
// resolved module — same readiness-handshake shape as
// `flutter_gemma_litertlm`'s `window.litertLmReady`/`window.Engine`. See
// `example/web/index.html`.
@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../embedding/ort_client.dart';

/// `window.ortReady` — a Promise that resolves once `window.ort` is set.
@JS('ortReady')
external JSPromise<JSAny?> get _ortReady;

/// `window.ort` — the resolved `onnxruntime-web` ESM module namespace.
@JS('ort')
external _OrtNamespace get _ort;

extension type _OrtNamespace._(JSObject _) implements JSObject {
  external _InferenceSessionNamespace get InferenceSession;
}

extension type _InferenceSessionNamespace._(JSObject _) implements JSObject {
  external JSPromise<_OrtSession> create(
    JSAny modelPathOrBuffer,
    JSAny? options,
  );
}

extension type _OrtSession._(JSObject _) implements JSObject {
  external JSArray<JSString> get inputNames;
  external JSArray<JSString> get outputNames;
  external JSPromise<JSObject> run(JSObject feeds);
  external JSPromise<JSAny?> release();
}

/// `new ort.Tensor(type, data, dims)`.
@JS('ort.Tensor')
extension type _OrtJsTensor._(JSObject _) implements JSObject {
  external factory _OrtJsTensor(
    JSString type,
    JSAny data,
    JSArray<JSAny?> dims,
  );

  external JSAny get data;
  external JSArray<JSNumber> get dims;
}

/// `BigInt(value)` — converts a JS number to a JS BigInt. ORT int64 tensors
/// require `BigInt64Array` data (A1's load-bearing gotcha: Dart has no
/// native BigInt64Array support in `dart:js_interop` as of this SDK).
@JS('BigInt')
external JSBigInt _jsBigInt(JSNumber value);

/// `BigInt64Array.from(iterable)`.
@JS('BigInt64Array.from')
external JSObject _bigInt64ArrayFrom(JSArray<JSAny?> source);

JSObject _int64TensorData(List<int> values) {
  final bigInts = <JSAny?>[for (final v in values) _jsBigInt(v.toJS)];
  return _bigInt64ArrayFrom(bigInts.toJS);
}

_OrtJsTensor _int64Tensor(List<int> values, List<int> dims) {
  final dimsJs = <JSAny?>[for (final d in dims) d.toJS];
  return _OrtJsTensor('int64'.toJS, _int64TensorData(values), dimsJs.toJS);
}

/// `onnxruntime-web`-backed [OrtClient] — the web arm of the same seam the
/// native `dart:ffi` `OrtFfiClient` implements. WebGPU is requested first,
/// falling back to WASM (`ort.env.wasm` configuration — e.g. `wasmPaths` —
/// is the host page's responsibility, set once in the `window.ortReady` ESM
/// shim before `window.ort` is published; see `example/web/index.html`).
class OrtWebClient implements OrtClient {
  _OrtSession? _session;
  List<String> _inputNames = const [];
  String _outputName = '';

  @override
  Future<OrtIoSpec> load(String modelPath) async {
    await _ortReady.toDart;
    final options = <String, Object?>{
      'executionProviders': ['webgpu', 'wasm'],
    }.jsify();
    final session = await _ort.InferenceSession.create(
      modelPath.toJS,
      options,
    ).toDart;
    _session = session;

    _inputNames = [for (final n in session.inputNames.toDart) n.toDart];
    final outputNames = [for (final n in session.outputNames.toDart) n.toDart];
    final outputIndex = pickOnnxOutputIndex(outputNames);
    _outputName = outputNames[outputIndex];

    return OrtIoSpec(
      inputNames: _inputNames,
      outputName: _outputName,
      hasLastHiddenStateOutput: _outputName == 'last_hidden_state',
      // onnxruntime-web's InferenceSession does not expose static
      // input/output shape metadata the way the native ORT C API does — the
      // web forward pass always treats the graph as dynamic-shape (see
      // `onnx_web_embedding_forward_pass.dart`'s module doc) and discovers
      // the output dimension via a 1-token probe instead.
      staticSeqLen: null,
      staticDim: null,
    );
  }

  @override
  Future<OrtRunResult> run({
    required List<int> ids,
    List<int>? mask,
    List<int>? typeIds,
  }) async {
    final session = _session;
    if (session == null) {
      throw StateError('OrtWebClient.run() called before load() completed');
    }

    final feeds = JSObject();
    feeds.setProperty('input_ids'.toJS, _int64Tensor(ids, [1, ids.length]));
    if (mask != null) {
      feeds.setProperty(
        'attention_mask'.toJS,
        _int64Tensor(mask, [1, mask.length]),
      );
    }
    if (typeIds != null) {
      feeds.setProperty(
        'token_type_ids'.toJS,
        _int64Tensor(typeIds, [1, typeIds.length]),
      );
    }

    final results = await session.run(feeds).toDart;
    final outputTensor = results.getProperty<_OrtJsTensor>(_outputName.toJS);
    final data = outputTensor.data as JSFloat32Array;
    final values = data.toDart;
    final dims = [for (final d in outputTensor.dims.toDart) d.toDartInt];
    return OrtRunResult(values: values, shape: dims);
  }

  @override
  Future<void> close() async {
    final session = _session;
    _session = null;
    if (session != null) {
      await session.release().toDart;
    }
  }
}
