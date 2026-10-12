// Driver for the web embedding drive suites
// (integration_test/web_embeddings_test.dart, web_embeddings_streaming_test.dart,
// web_eg2_test.dart, web_eg2_llm_test.dart).
//
// Each suite names its own response file in the data it reports
// (`reportTo` in integration_test/web_embeddings_support.dart), and this
// driver writes the data there: build/web_embeddings_response.json for
// web_embeddings_test.dart, build/web_embeddings_streaming_response.json for
// the streaming suite, build/web_eg2_response.json for EmbeddingGemma 2,
// build/web_eg2_llm_response.json for the LLM + EmbeddingGemma 2 page.
// Running one never overwrites another's record.
//
// Differs from test_driver/integration_test.dart in two more ways: the
// response data is written EVEN WHEN A TEST FAILS — a failing W1 is exactly
// when its comparison is needed — and the run may take 90 minutes: the first
// run downloads EmbeddingGemma 1 (179 MB), MiniLM (90 MB) or the two
// EmbeddingGemma 2 bundles (165 + 388 MB), and the LLM suite generates
// replies next to EmbeddingGemma 2.
import 'package:integration_test/integration_test_driver.dart';

/// `responseFileKey` in integration_test/web_embeddings_support.dart. The
/// driver runs outside the app and cannot import that file; keep them equal.
const _responseFileKey = 'responseFile';

/// Where the data of a suite that named no file goes, so it overwrites no
/// suite's record. The run then fails.
const _unnamed = 'web_embeddings_unnamed_response';

Future<void> main() => integrationDriver(
  timeout: const Duration(minutes: 90),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final name = data?[_responseFileKey];
    if (name is String && name.isNotEmpty) {
      await writeResponseData(data, testOutputFilename: name);
      return;
    }
    await writeResponseData(data, testOutputFilename: _unnamed);
    throw StateError(
      'The suite named no response file ("$_responseFileKey" in its '
      'reported data; call reportTo first thing in main). Its data is in '
      'build/$_unnamed.json.',
    );
  },
);
