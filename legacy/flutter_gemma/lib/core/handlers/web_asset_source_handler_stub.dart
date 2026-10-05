/// Stub implementation for non-web platforms
/// This file is used when dart:js_interop is not available
library;

import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';
import 'package:flutter_gemma/core/infrastructure/web_cache_service.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';

/// Stub class - should never be instantiated on non-web platforms
class WebAssetSourceHandler implements SourceHandler {
  WebAssetSourceHandler({
    required WebFileSystemService fileSystem,
    required ModelRepository repository,
    required WebCacheService cacheService,
  }) {
    throw UnsupportedError(
      'WebAssetSourceHandler is only available on web platform',
    );
  }

  @override
  bool supports(ModelSource source) {
    throw UnsupportedError(
      'WebAssetSourceHandler is only available on web platform',
    );
  }

  @override
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async {
    throw UnsupportedError(
      'WebAssetSourceHandler is only available on web platform',
    );
  }

  @override
  Stream<int> installWithProgress(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) {
    throw UnsupportedError(
      'WebAssetSourceHandler is only available on web platform',
    );
  }

  @override
  bool supportsResume(ModelSource source) {
    throw UnsupportedError(
      'WebAssetSourceHandler is only available on web platform',
    );
  }
}
