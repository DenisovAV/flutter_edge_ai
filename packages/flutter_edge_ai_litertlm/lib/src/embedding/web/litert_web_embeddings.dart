/// The `dart:js_interop` side of `web/litert_embeddings.js` (bundle API v2):
/// [WindowLiteRtJsBundle], the [LiteRtJsBundle] the web backend hands the
/// LiteRT.js pass, over the bundle's window functions.
library;

import 'dart:js_interop';

import 'litert_js_embedding_pass.dart'
    show LiteRtJsBundle, LiteRtJsEmbedResult, LiteRtJsTooLong, LiteRtJsVector;

/// The bundle's load function as a plain value: undefined (null here) when
/// `litert_embeddings.js` is not on the page.
@JS('loadLiteRtEmbeddings')
external JSAny? get _loadLiteRtEmbeddingsValue;

/// Undefined (null here) on a page whose copy predates the handshake: every
/// bundle before API v2.
@JS('liteRtEmbeddingsApiVersion')
external JSAny? get _apiVersionValue;

@JS('loadLiteRtEmbeddings')
external JSPromise<_LoadResult> _loadLiteRtEmbeddingsJS(
  JSString modelPath,
  JSString tokenizerPath,
  JSString? wasmPath,
);

@JS('embedLiteRtText')
external JSPromise<_EmbedResult> _embedLiteRtTextJS(JSString prefixedText);

@JS('cleanupLiteRtEmbeddings')
external JSPromise<JSAny?> _cleanupLiteRtEmbeddingsJS();

/// `{dimension, maxInputTokens}`, read by the bundle from the model.
extension type _LoadResult._(JSObject _) implements JSObject {
  external JSNumber? get dimension;
  external JSNumber? get maxInputTokens;
}

/// `{status: 'ok', values}` or `{status: 'too_long', actualTokens,
/// maxInputTokens}`.
extension type _EmbedResult._(JSObject _) implements JSObject {
  external JSString? get status;
  external JSFloat32Array? get values;
  external JSNumber? get actualTokens;
  external JSNumber? get maxInputTokens;
}

/// The [LiteRtJsBundle] the web backend hands the pass: the window API of
/// `web/litert_embeddings.js`.
final class WindowLiteRtJsBundle implements LiteRtJsBundle {
  const WindowLiteRtJsBundle();

  @override
  bool get isPresent => _loadLiteRtEmbeddingsValue.typeofEquals('function');

  @override
  int? get apiVersion {
    final value = _apiVersionValue;
    if (value == null || !value.typeofEquals('number')) return null;
    final version = (value as JSNumber).toDartDouble;
    return version == version.truncateToDouble() ? version.toInt() : null;
  }

  @override
  Future<({int dimension, int maxInputTokens})> load(
    String modelUrl,
    String tokenizerUrl,
    String wasmPath,
  ) async {
    final result = await _loadLiteRtEmbeddingsJS(
      modelUrl.toJS,
      tokenizerUrl.toJS,
      wasmPath.toJS,
    ).toDart;
    return (
      dimension: _int(result.dimension, 'loadLiteRtEmbeddings', 'dimension'),
      maxInputTokens: _int(
        result.maxInputTokens,
        'loadLiteRtEmbeddings',
        'maxInputTokens',
      ),
    );
  }

  @override
  Future<LiteRtJsEmbedResult> embed(String prefixedText) async {
    final result = await _embedLiteRtTextJS(prefixedText.toJS).toDart;
    final status = result.status?.toDart;
    switch (status) {
      case 'ok':
        final values =
            result.values ??
            (throw StateError(
              'embedLiteRtText returned status "ok" without values',
            ));
        // A copy: on dart2js `toDart` is a view of the JS array.
        return LiteRtJsVector(List<double>.of(values.toDart, growable: false));
      case 'too_long':
        return LiteRtJsTooLong(
          actualTokens: _int(
            result.actualTokens,
            'embedLiteRtText',
            'actualTokens',
          ),
          maxInputTokens: _int(
            result.maxInputTokens,
            'embedLiteRtText',
            'maxInputTokens',
          ),
        );
      default:
        throw StateError('embedLiteRtText returned an unknown status: $status');
    }
  }

  @override
  Future<void> dispose() => _cleanupLiteRtEmbeddingsJS().toDart;

  static int _int(JSNumber? value, String function, String field) {
    if (value == null) {
      throw StateError('$function returned no $field');
    }
    final number = value.toDartDouble;
    if (number != number.truncateToDouble()) {
      throw StateError('$function returned a non-integer $field: $number');
    }
    return number.toInt();
  }
}

@JS('URL.revokeObjectURL')
external void _revokeObjectUrlJs(JSString url);

/// Releases an object URL the pass created through `resolveWebModelUrl`.
void revokeObjectUrl(String url) => _revokeObjectUrlJs(url.toJS);
