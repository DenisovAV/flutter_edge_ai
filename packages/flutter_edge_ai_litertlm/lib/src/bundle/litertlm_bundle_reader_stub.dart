// The web arm of `readLiteRtLmBundleInfo`: a page has no file system to read
// a model from, and the web engine reads no bundle before loading it.

import 'litertlm_bundle_info.dart';

/// Not available on the web; see the native `readLiteRtLmBundleInfo`. The
/// returned future fails with an [UnsupportedError]; the call itself does not
/// throw, so `catchError` sees it.
Future<LiteRtLmBundleInfo> readLiteRtLmBundleInfo(String path) async =>
    throw UnsupportedError(
      'readLiteRtLmBundleInfo reads a file from disk and is not available on '
      'the web.',
    );
