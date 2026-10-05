import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/services/file_system_service.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';

/// Handles installation of models from native bundled resources
///
/// Features:
/// - Uses platform-specific native resource paths
/// - Android: assets/models/{resourceName}
/// - iOS: Bundle.main.path(forResource:)
/// - Web: /assets/{resourceName}
/// - No copying required (uses native path directly)
/// - Single-step progress (resources already available)
///
/// NOTE on [targetFilename]: a bundled resource is compiled into the app at
/// a fixed [BundledSource.resourceName] — this handler cannot rename the
/// physical asset at runtime. `targetFilename` only namespaces the
/// repository identity key (`ModelInfo.id`); it does not affect
/// `getBundledResourcePath`. Bundled companions are not among today's
/// exposed collisions (network installs are); this closes the repository-key
/// ambiguity for future bundled companions without claiming to fix an
/// on-disk collision this handler structurally cannot fix.
class BundledSourceHandler implements SourceHandler {
  final FileSystemService fileSystem;
  final ModelRepository repository;

  BundledSourceHandler({required this.fileSystem, required this.repository});

  @override
  bool supports(ModelSource source) => source is BundledSource;

  @override
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async {
    // Bundled resources are instant, no cancellation needed
    if (source is! BundledSource) {
      throw ArgumentError('BundledSourceHandler only supports BundledSource');
    }

    // Get platform-specific bundled resource path
    // This path is used directly by the native layer (no copying needed)
    final bundledPath = await fileSystem.getBundledResourcePath(
      source.resourceName,
    );

    // Get file size for metadata
    final sizeBytes = await fileSystem.getFileSize(bundledPath);

    // Save metadata to repository
    final modelInfo = ModelInfo(
      id: targetFilename ?? source.resourceName,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: sizeBytes,
      type: modelType,
      hasLoraWeights: false,
    );

    await repository.saveModel(modelInfo);
  }

  @override
  Stream<int> installWithProgress(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async* {
    // Same as above - bundled resources are instant
    if (source is! BundledSource) {
      throw ArgumentError('BundledSourceHandler only supports BundledSource');
    }

    // Get platform-specific bundled resource path
    final bundledPath = await fileSystem.getBundledResourcePath(
      source.resourceName,
    );

    // Bundled resources are immediately available, report 100% after verification
    yield 100;

    // Get file size for metadata
    final sizeBytes = await fileSystem.getFileSize(bundledPath);

    // Save metadata to repository
    final modelInfo = ModelInfo(
      id: targetFilename ?? source.resourceName,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: sizeBytes,
      type: modelType,
      hasLoraWeights: false,
    );

    await repository.saveModel(modelInfo);
  }

  @override
  bool supportsResume(ModelSource source) {
    // Bundled resources are always available, no resume needed
    return false;
  }
}
