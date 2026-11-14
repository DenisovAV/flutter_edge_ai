// Where `LiteRtEmbeddingBackend.describe()` (native) finds the platform cache
// directory the EmbeddingGemma 2 pass keeps its weight caches under: through
// path_provider, behind one injectable function, so the pass and its config
// take a plain path. Not exported.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// The platform cache directory (path_provider's
/// `getApplicationCacheDirectory`).
Future<String> applicationCacheDirectoryPath() async =>
    (await getApplicationCacheDirectory()).path;

/// What `LiteRtEmbeddingBackend.describe()` asks for the cache directory:
/// [applicationCacheDirectoryPath]. Replaced only by tests.
@visibleForTesting
Future<String> Function() liteRtEmbeddingCacheDirectory =
    applicationCacheDirectoryPath;
