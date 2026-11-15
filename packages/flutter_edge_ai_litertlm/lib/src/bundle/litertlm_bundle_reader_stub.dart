// The web arm of `readBundleInfo`: a page has no file system to read
// a model from, and the web engine reads no bundle before loading it.

import 'litertlm_bundle_info.dart';

/// Not available on the web; see the native `readBundleInfo`. The
/// returned future fails with an [UnsupportedError]; the call itself does not
/// throw, so `catchError` sees it.
Future<BundleInfo> readBundleInfo(String path) async => throw UnsupportedError(
  'readBundleInfo reads a file from disk and is not available on '
  'the web.',
);
