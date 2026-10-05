/// Web arm of the [readTextFile] seam — see the io arm for what this exists for.
///
/// Reached only when `dart:io` is absent, i.e. on web. `WordPieceEmbeddingTokenizer`
/// still has to EXIST on web (`flutter_gemma_onnx`'s web embedding arm imports
/// the tokenizer directly), so the path-based loader has to compile there; it
/// just cannot run. Throwing beats returning empty: a web caller that reaches
/// here has an on-disk path that will never resolve in a browser, and the fix is
/// to fetch the bytes itself and use `fromJsonString`.
/// `async` so the failure arrives as a rejected Future, exactly as the io arm's
/// would: a bare `=> throw` raises synchronously at the call site, which a
/// caller using `.catchError` rather than `await` would not catch.
Future<String> readTextFile(String path) async => throw UnsupportedError(
  'WordPieceEmbeddingTokenizer.fromPath reads a file from disk and is not '
  'available on web (no dart:io). Fetch the tokenizer.json yourself and use '
  'WordPieceEmbeddingTokenizer.fromJsonString instead. Path was: $path',
);
