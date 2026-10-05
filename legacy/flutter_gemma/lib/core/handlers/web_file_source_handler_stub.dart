import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';

/// Stub implementation for non-web platforms
class WebFileSourceHandler implements SourceHandler {
  WebFileSourceHandler({
    required dynamic fileSystem,
    required dynamic repository,
  }) {
    throw UnsupportedError(
      'WebFileSourceHandler is only available on web platform',
    );
  }

  @override
  bool supports(ModelSource source) => false;

  @override
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) {
    throw UnsupportedError(
      'WebFileSourceHandler is only available on web platform',
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
      'WebFileSourceHandler is only available on web platform',
    );
  }

  @override
  bool supportsResume(ModelSource source) => false;
}
