import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gemma/core/domain/web_storage_mode.dart';
import 'package:flutter_gemma/core/services/download_service.dart';
import 'package:flutter_gemma/core/services/file_system_service.dart';
import 'package:flutter_gemma/core/services/asset_loader.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';
import 'package:flutter_gemma/core/services/protected_files_registry.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/handlers/network_source_handler.dart';
import 'package:flutter_gemma/core/handlers/web_network_source_handler_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/handlers/web_network_source_handler.dart';
import 'package:flutter_gemma/core/handlers/asset_source_handler.dart';
import 'package:flutter_gemma/core/handlers/web_asset_source_handler_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/handlers/web_asset_source_handler.dart';
import 'package:flutter_gemma/core/handlers/bundled_source_handler.dart';
import 'package:flutter_gemma/core/handlers/file_source_handler.dart';
import 'package:flutter_gemma/core/handlers/web_bundled_source_handler_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/handlers/web_bundled_source_handler.dart';
import 'package:flutter_gemma/core/handlers/web_file_source_handler_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/handlers/web_file_source_handler.dart';
import 'package:flutter_gemma/core/handlers/source_handler_registry.dart';
import 'package:flutter_gemma/core/infrastructure/platform_file_system_service.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/infrastructure/platform_file_system_service_stub.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';
import 'package:flutter_gemma/core/infrastructure/flutter_asset_loader_stub.dart'
    if (dart.library.io) 'package:flutter_gemma/core/infrastructure/flutter_asset_loader.dart';
import 'package:flutter_gemma/core/infrastructure/shared_preferences_model_repository.dart';
import 'package:flutter_gemma/core/infrastructure/in_memory_model_repository.dart';
import 'package:flutter_gemma/core/services/vector_store_repository.dart';
import 'package:flutter_gemma/core/di/download_hub/configure_download_updates_stream_mobile.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/di/download_hub/configure_download_updates_stream_stub.dart'
    as download_hub;
import 'package:flutter_gemma/core/services/vector_store_filter.dart';
import 'package:flutter_gemma/core/infrastructure/unconfigured_vector_store.dart';
import 'package:flutter_gemma/core/infrastructure/web_download_service_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/infrastructure/web_download_service.dart';
import 'package:flutter_gemma/core/infrastructure/web_js_interop_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/infrastructure/web_js_interop.dart';
import 'platform/mobile_service_factory.dart'
    if (dart.library.js_interop) 'platform/web_service_factory.dart'
    as platform;
import 'package:flutter_gemma/core/infrastructure/shared_preferences_protected_registry.dart';

/// Dependency Injection Container for managing service lifecycle
///
/// Features:
/// - Singleton pattern - one instance per application
/// - Platform-aware service selection (web vs mobile)
/// - Lazy initialization of services
/// - Constructor injection for testability
/// - Clear separation of concerns
///
/// Platform Support:
/// - Mobile: Uses dart:io-based services (PlatformFileSystemService, BackgroundDownloaderService)
/// - Web: Uses URL-based services (WebFileSystemService, WebDownloadService)
///
/// Requirements:
/// - Mobile platforms require Flutter bindings to be initialized before ServiceRegistry
///   (BackgroundDownloaderService uses path_provider which requires bindings)
/// - Call `WidgetsFlutterBinding.ensureInitialized()` in main() before using ServiceRegistry
///
/// Usage:
/// ```dart
/// void main() {
///   WidgetsFlutterBinding.ensureInitialized(); // Required for mobile
///   ServiceRegistry.initialize();
///   runApp(MyApp());
/// }
///
/// // Later in your code:
/// final registry = ServiceRegistry.instance;
/// final handlerRegistry = registry.sourceHandlerRegistry;
/// final handler = handlerRegistry.getHandler(source);
/// await handler.install(source);
/// ```
class ServiceRegistry {
  static ServiceRegistry? _instance;

  // Infrastructure services (singletons)
  late final FileSystemService _fileSystemService;
  late final AssetLoader _assetLoader;
  late final DownloadService _downloadService;
  late final ModelRepository _modelRepository;
  late final ProtectedFilesRegistry _protectedFilesRegistry;
  late final VectorStoreRepository _vectorStoreRepository;

  // Handlers (created once with dependencies)
  late final SourceHandler
  _networkHandler; // Platform-specific (NetworkSourceHandler or WebNetworkSourceHandler)
  late final SourceHandler _assetHandler;
  late final SourceHandler _bundledHandler; // Changed from BundledSourceHandler
  late final SourceHandler _fileHandler; // Changed from FileSourceHandler

  // Handler registry
  late final SourceHandlerRegistry _sourceHandlerRegistry;

  // Optional configuration
  final String? huggingFaceToken;
  final int maxDownloadRetries;
  final WebStorageMode webStorageMode;

  /// Backward compatibility getter for enableWebCache
  bool get enableWebCache => webStorageMode != WebStorageMode.none;

  /// Check if streaming storage mode is enabled (OPFS)
  bool get useStreamingStorage => webStorageMode == WebStorageMode.streaming;

  /// Creates the default FileSystemService based on platform
  ///
  /// - Web: WebFileSystemService (URL-based storage)
  /// - Mobile: PlatformFileSystemService (dart:io file system)
  static FileSystemService _createDefaultFileSystemService() {
    if (kIsWeb) {
      return WebFileSystemService();
    } else {
      return PlatformFileSystemService();
    }
  }

  /// Creates the default DownloadService based on platform
  ///
  /// - Web: WebDownloadService (URL registration + authenticated fetch)
  /// - Mobile: BackgroundDownloaderService (actual file downloads)
  ///
  /// Both factories have identical signatures for platform-independent calling.
  static DownloadService _createDefaultDownloadService(
    FileSystemService fileSystem,
    WebStorageMode webStorageMode,
    SharedPreferences prefs,
  ) {
    // Conditional import selects the right factory at compile time
    // Both factories accept same parameters via interfaces
    return platform.createDownloadService(fileSystem, webStorageMode, prefs);
  }

  /// Creates the appropriate AssetSourceHandler based on platform
  ///
  /// - Web: WebAssetSourceHandler (URL registration with caching)
  /// - Mobile: AssetSourceHandler (file copying with LargeFileHandler)
  static SourceHandler _createAssetSourceHandler(
    FileSystemService fileSystem,
    AssetLoader assetLoader,
    ModelRepository repository,
    DownloadService downloadService,
  ) {
    if (kIsWeb) {
      // Web: Use WebAssetSourceHandler with caching
      final webDownload = downloadService as WebDownloadService;
      return WebAssetSourceHandler(
        fileSystem: fileSystem as WebFileSystemService,
        repository: repository,
        cacheService: webDownload.cacheService,
      );
    } else {
      // Mobile: Use AssetSourceHandler with file copying
      return AssetSourceHandler(
        assetLoader: assetLoader,
        fileSystem: fileSystem,
        repository: repository,
      );
    }
  }

  /// Creates the appropriate BundledSourceHandler based on platform
  ///
  /// - Web: WebBundledSourceHandler (URL registration with caching)
  /// - Mobile: BundledSourceHandler (native bundle path)
  static SourceHandler _createBundledSourceHandler(
    FileSystemService fileSystem,
    ModelRepository repository,
    DownloadService downloadService,
  ) {
    if (kIsWeb) {
      // Web: Use WebBundledSourceHandler with caching
      final webDownload = downloadService as WebDownloadService;
      return WebBundledSourceHandler(
        fileSystem: fileSystem as WebFileSystemService,
        repository: repository,
        cacheService: webDownload.cacheService,
        jsInterop: WebJsInterop(),
      );
    } else {
      // Mobile: Use BundledSourceHandler
      return BundledSourceHandler(
        fileSystem: fileSystem,
        repository: repository,
      );
    }
  }

  /// Creates the appropriate NetworkSourceHandler based on platform
  ///
  /// - Web: WebNetworkSourceHandler (with conditional metadata saving based on cache)
  /// - Mobile: NetworkSourceHandler (always saves metadata, files persist on disk)
  static SourceHandler _createNetworkSourceHandler(
    DownloadService downloadService,
    FileSystemService fileSystem,
    ModelRepository repository,
    String? huggingFaceToken,
    int maxDownloadRetries,
  ) {
    if (kIsWeb) {
      // Web: Use WebNetworkSourceHandler with cache-aware metadata saving
      final webDownload = downloadService as WebDownloadService;
      return WebNetworkSourceHandler(
        downloadService: webDownload,
        repository: repository,
        cacheService: webDownload.cacheService,
        huggingFaceToken: huggingFaceToken,
      );
    } else {
      // Mobile: Use NetworkSourceHandler (always saves metadata)
      return NetworkSourceHandler(
        downloadService: downloadService,
        fileSystem: fileSystem,
        repository: repository,
        huggingFaceToken: huggingFaceToken,
        maxDownloadRetries: maxDownloadRetries,
      );
    }
  }

  /// Creates the appropriate FileSourceHandler based on platform
  ///
  /// - Web: WebFileSourceHandler (URL validation and registration)
  /// - Mobile: FileSourceHandler (external file registration)
  static SourceHandler _createFileSourceHandler(
    FileSystemService fileSystem,
    ProtectedFilesRegistry protectedFiles,
    ModelRepository repository,
  ) {
    if (kIsWeb) {
      // Web: Use WebFileSourceHandler
      // Type-safe cast (validated in constructor)
      final webFs = fileSystem as WebFileSystemService;
      return WebFileSourceHandler(fileSystem: webFs, repository: repository);
    } else {
      // Mobile: Use FileSourceHandler
      return FileSourceHandler(
        fileSystem: fileSystem,
        protectedFiles: protectedFiles,
        repository: repository,
      );
    }
  }

  /// Internal async factory for creating ServiceRegistry
  static Future<ServiceRegistry> _create({
    String? huggingFaceToken,
    int maxDownloadRetries = 10,
    WebStorageMode webStorageMode = WebStorageMode.cacheApi,
    FileSystemService? fileSystemService,
    AssetLoader? assetLoader,
    DownloadService? downloadService,
    ModelRepository? modelRepository,
    ProtectedFilesRegistry? protectedFilesRegistry,
    VectorStoreRepository? vectorStoreRepository,
    FilterSchema filterSchema = const FilterSchema(),
  }) async {
    // Initialize file system service first
    final fileSystem = fileSystemService ?? _createDefaultFileSystemService();

    // Validate web platform requirements early
    if (kIsWeb && fileSystem is! WebFileSystemService) {
      throw ArgumentError(
        'Web platform requires WebFileSystemService. '
        'Either provide WebFileSystemService explicitly or use platform defaults.',
      );
    }

    // Initialize SharedPreferences (needed for web caching)
    final prefs = await SharedPreferences.getInstance();

    // Create download service
    final download =
        downloadService ??
        _createDefaultDownloadService(fileSystem, webStorageMode, prefs);

    return ServiceRegistry._(
      huggingFaceToken: huggingFaceToken,
      maxDownloadRetries: maxDownloadRetries,
      webStorageMode: webStorageMode,
      fileSystemService: fileSystem,
      assetLoader: assetLoader,
      downloadService: download,
      modelRepository: modelRepository,
      protectedFilesRegistry: protectedFilesRegistry,
      vectorStoreRepository: vectorStoreRepository,
      filterSchema: filterSchema,
    );
  }

  ServiceRegistry._({
    this.huggingFaceToken,
    this.maxDownloadRetries = 10,
    this.webStorageMode = WebStorageMode.cacheApi,
    required FileSystemService fileSystemService,
    AssetLoader? assetLoader,
    required DownloadService downloadService,
    ModelRepository? modelRepository,
    ProtectedFilesRegistry? protectedFilesRegistry,
    VectorStoreRepository? vectorStoreRepository,
    FilterSchema filterSchema = const FilterSchema(),
  }) {
    // Initialize infrastructure services
    _fileSystemService = fileSystemService;
    _assetLoader = assetLoader ?? FlutterAssetLoader();
    _downloadService = downloadService;

    // Web with cache disabled (none mode): use in-memory repository (ephemeral metadata)
    // Web with cache enabled (cacheApi/streaming): use SharedPreferences (persistent metadata)
    // Mobile: always use SharedPreferences (files persist on disk)
    _modelRepository =
        modelRepository ??
        (kIsWeb && webStorageMode == WebStorageMode.none
            ? InMemoryModelRepository()
            : SharedPreferencesModelRepository());

    _protectedFilesRegistry =
        protectedFilesRegistry ?? SharedPreferencesProtectedRegistry();

    // RAG is opt-in as of 1.0. Core ships no built-in vector store on any
    // platform. Pass vectorStore: to initialize() from a RAG package
    // (flutter_gemma_rag_sqlite / flutter_gemma_rag_qdrant). When omitted,
    // UnconfiguredVectorStore throws a clear "add a RAG package" error on first
    // Core ships no vector-store impl — sqlite and qdrant are opt-in packages
    // (flutter_gemma_rag_sqlite / flutter_gemma_rag_qdrant).
    _vectorStoreRepository = vectorStoreRepository ?? UnconfiguredVectorStore();

    // Declare the filterable-metadata schema at registration, BEFORE the store
    // is initialized, so it can promote the declared fields to typed storage
    // columns (sqlite/vec0) or top-level payload keys (qdrant). Default empty
    // schema is a no-op (filters stay a safe no-op; never throws).
    _vectorStoreRepository.configure(filterSchema);

    // Initialize handlers with dependencies
    _networkHandler = _createNetworkSourceHandler(
      _downloadService,
      _fileSystemService,
      _modelRepository,
      huggingFaceToken,
      maxDownloadRetries,
    );

    _assetHandler = _createAssetSourceHandler(
      _fileSystemService,
      _assetLoader,
      _modelRepository,
      _downloadService,
    );

    _bundledHandler = _createBundledSourceHandler(
      _fileSystemService,
      _modelRepository,
      _downloadService,
    );

    _fileHandler = _createFileSourceHandler(
      _fileSystemService,
      _protectedFilesRegistry,
      _modelRepository,
    );

    // Initialize handler registry
    _sourceHandlerRegistry = SourceHandlerRegistry(
      handlers: [_networkHandler, _assetHandler, _bundledHandler, _fileHandler],
    );
  }

  /// Gets the singleton instance
  ///
  /// Throws [StateError] if not initialized.
  ///
  /// Must call [FlutterGemma.initialize()] first in main():
  /// ```dart
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await FlutterGemma.initialize();
  ///   runApp(MyApp());
  /// }
  /// ```
  static ServiceRegistry get instance {
    if (_instance == null) {
      throw StateError(
        'FlutterGemma not initialized!\n\n'
        'You must call FlutterGemma.initialize() in main() before using the plugin.\n\n'
        'Example:\n'
        '  void main() async {\n'
        '    WidgetsFlutterBinding.ensureInitialized();\n'
        '    await FlutterGemma.initialize();\n'
        '    runApp(MyApp());\n'
        '  }\n\n'
        'For more information, see: https://pub.dev/packages/flutter_gemma#initialization',
      );
    }
    return _instance!;
  }

  /// Initializes the singleton instance
  ///
  /// Call this once at app startup, before using [instance].
  /// Multiple calls to initialize() are safe - subsequent calls are ignored.
  ///
  /// Parameters:
  /// - [huggingFaceToken]: Optional HuggingFace API token for authenticated downloads
  /// - [maxDownloadRetries]: Maximum retry attempts for transient errors (default: 10)
  ///   Note: Auth errors (401/403/404) fail after 1 attempt regardless
  /// - [webStorageMode]: Storage mode for web platform (default: WebStorageMode.cacheApi)
  ///   Note: This parameter only affects web platform, ignored on mobile
  /// - [vectorStoreRepository]: Optional custom repository (for testing)
  /// - [filterSchema]: Declared filterable-metadata fields; applied to the
  ///   vector store via `configure()` before its `initialize()` (default empty)
  /// - [downloadUpdatesStream]: Optional host download hub (mobile only).
  ///   Events must be `background_downloader` [TaskUpdate] values. Ignored on
  ///   web. Non-broadcast streams are wrapped internally.
  /// - Services can be overridden for testing (dependency injection)
  ///
  /// Note: This is async because web platform requires SharedPreferences initialization.
  static Future<void> initialize({
    String? huggingFaceToken,
    int maxDownloadRetries = 10,
    WebStorageMode webStorageMode = WebStorageMode.cacheApi,
    FileSystemService? fileSystemService,
    AssetLoader? assetLoader,
    DownloadService? downloadService,
    ModelRepository? modelRepository,
    ProtectedFilesRegistry? protectedFilesRegistry,
    VectorStoreRepository? vectorStoreRepository,
    FilterSchema filterSchema = const FilterSchema(),
    Stream<Object>? downloadUpdatesStream,
  }) async {
    // Make idempotent - skip if already initialized
    if (_instance != null) {
      // Warn if critical parameters changed
      if (_instance!.webStorageMode != webStorageMode) {
        gemmaLog(
          'WARNING: webStorageMode cannot be changed after initialization.\n'
          'Current: ${_instance!.webStorageMode}, Requested: $webStorageMode\n'
          'Restart the application to change this setting.',
        );
      }
      gemmaLog(
        'ServiceRegistry: Already initialized, skipping re-initialization',
      );
      return;
    }

    download_hub.configureDownloadUpdatesStream(downloadUpdatesStream);

    _instance = await _create(
      huggingFaceToken: huggingFaceToken,
      maxDownloadRetries: maxDownloadRetries,
      webStorageMode: webStorageMode,
      fileSystemService: fileSystemService,
      assetLoader: assetLoader,
      downloadService: downloadService,
      modelRepository: modelRepository,
      protectedFilesRegistry: protectedFilesRegistry,
      vectorStoreRepository: vectorStoreRepository,
      filterSchema: filterSchema,
    );
  }

  /// Resets the singleton (primarily for testing)
  static void reset() {
    download_hub.clearDownloadUpdatesStream();
    _instance = null;
  }

  /// Disposes all services and releases resources
  ///
  /// Should be called when shutting down the application.
  /// After calling dispose(), you must call initialize() again to use the registry.
  Future<void> dispose() async {
    download_hub.clearDownloadUpdatesStream();
    // Close VectorStore database connection
    try {
      await _vectorStoreRepository.close();
    } catch (e) {
      gemmaLog('Warning: Failed to close VectorStore: $e');
    }
  }

  // Public getters for services

  SourceHandlerRegistry get sourceHandlerRegistry => _sourceHandlerRegistry;

  FileSystemService get fileSystemService => _fileSystemService;

  AssetLoader get assetLoader => _assetLoader;

  DownloadService get downloadService => _downloadService;

  ModelRepository get modelRepository => _modelRepository;

  ProtectedFilesRegistry get protectedFilesRegistry => _protectedFilesRegistry;

  /// Access VectorStoreRepository for document embedding storage
  VectorStoreRepository get vectorStoreRepository => _vectorStoreRepository;

  // Handlers (if needed directly)

  SourceHandler get networkHandler => _networkHandler;

  SourceHandler get assetHandler => _assetHandler;

  SourceHandler get bundledHandler => _bundledHandler;

  SourceHandler get fileHandler => _fileHandler;
}
