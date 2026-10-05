# Flutter Gemma Core - Modern Architecture

This directory contains the refactored core architecture following SOLID principles and dependency injection patterns.

## Architecture Overview

```
lib/core/
├── domain/           # Domain models (ModelSource sealed classes)
├── services/         # Service abstractions (interfaces)
├── infrastructure/   # Service implementations
├── handlers/         # Source-specific model installation handlers
├── di/              # Dependency injection container
├── api/             # Modern API facade (FlutterGemma)
└── legacy/          # Legacy adapter (backward compatibility)
```

## Modern API Usage

### Initialization

Initialize once at app startup:

```dart
import 'package:flutter_gemma/core/api/flutter_gemma.dart';

void main() {
  FlutterGemma.initialize(
    huggingFaceToken: 'hf_...', // Optional for HuggingFace models
  );
  runApp(MyApp());
}
```

### Install Models

#### From Network (HTTP/HTTPS)

```dart
final installation = await FlutterGemma.installModel()
  .fromNetwork('https://huggingface.co/.../model.bin')
  .withProgress((progress) => print('Progress: $progress%'))
  .install();
```

#### From Flutter Asset

```dart
await FlutterGemma.installModel()
  .fromAsset('models/gemma-2b-it.bin')
  .install();
```

#### From Bundled Native Resource

```dart
await FlutterGemma.installModel()
  .fromBundled('gemma.bin')
  .install();
```

#### From External File

```dart
// User-provided file via file picker
await FlutterGemma.installModel()
  .fromFile('/path/to/model.bin')
  .install();
```

### Model Management

```dart
// Check if installed
final isInstalled = await FlutterGemma.isModelInstalled('gemma-2b-it.bin');

// List all installed models
final models = await FlutterGemma.listInstalledModels();
print('Installed: $models');

// Uninstall model
await FlutterGemma.uninstallModel('gemma-2b-it.bin');
```

## Architecture Patterns

### 1. Sealed Classes (Type Safety)

```dart
sealed class ModelSource {
  factory ModelSource.network(String url) = NetworkSource;
  factory ModelSource.asset(String path) = AssetSource;
  factory ModelSource.bundled(String resourceName) = BundledSource;
  factory ModelSource.file(String path) = FileSource;
}
```

**Benefits:**
- Exhaustive pattern matching
- Compile-time type safety
- No invalid states

### 2. Strategy Pattern (Source Handlers)

Each source type has its own handler:
- `NetworkSourceHandler` - HTTP/HTTPS downloads
- `AssetSourceHandler` - Flutter assets
- `BundledSourceHandler` - Native resources
- `FileSourceHandler` - External files

```dart
final handler = handlerRegistry.getHandler(source);
await handler.install(source);
```

### 3. Dependency Injection (ServiceRegistry)

```dart
class ServiceRegistry {
  // Singleton with lazy initialization
  static ServiceRegistry get instance;

  // Services
  SourceHandlerRegistry get sourceHandlerRegistry;
  FileSystemService get fileSystemService;
  ModelRepository get modelRepository;
  // ... etc
}
```

**Benefits:**
- Easy testing with mocks
- Clear dependencies
- Swappable implementations

### 4. Repository Pattern (Persistence)

```dart
abstract interface class ModelRepository {
  Future<void> saveModel(ModelInfo info);
  Future<ModelInfo?> loadModel(String id);
  Future<void> deleteModel(String id);
  Future<List<ModelInfo>> listInstalled();
}
```

Implementation: `SharedPreferencesModelRepository`

## SOLID Principles

### Single Responsibility Principle (SRP)
Each handler handles ONE source type:
- `NetworkSourceHandler` - only network downloads
- `AssetSourceHandler` - only asset loading

### Open/Closed Principle (OCP)
Add new source types without modifying existing code:
```dart
class CustomSourceHandler implements SourceHandler {
  // New handler for custom source
}
```

### Liskov Substitution Principle (LSP)
All handlers implement the same interface:
```dart
abstract interface class SourceHandler {
  bool supports(ModelSource source);
  Future<void> install(ModelSource source);
  Stream<int> installWithProgress(ModelSource source);
}
```

### Interface Segregation Principle (ISP)
Small, focused interfaces:
- `AssetLoader` - only asset loading
- `DownloadService` - only downloads
- `FileSystemService` - only file operations

### Dependency Inversion Principle (DIP)
Depend on abstractions, not implementations:
```dart
class NetworkSourceHandler {
  final DownloadService downloadService;  // Abstract!
  final FileSystemService fileSystem;     // Abstract!
}
```

## Testing

### With Mocks (using mocktail)

```dart
class MockDownloadService extends Mock implements DownloadService {}

test('NetworkSourceHandler downloads file', () async {
  final mockDownload = MockDownloadService();
  final handler = NetworkSourceHandler(
    downloadService: mockDownload,
    fileSystem: mockFileSystem,
    repository: mockRepository,
  );

  when(() => mockDownload.download(any(), any())).thenAnswer((_) async {});

  await handler.install(NetworkSource('https://example.com/model.bin'));

  verify(() => mockDownload.download(any(), any())).called(1);
});
```

### Integration Tests

```dart
test('Full installation flow', () async {
  FlutterGemma.initialize();

  final installation = await FlutterGemma.installModel()
    .fromNetwork('https://example.com/test.bin')
    .install();

  expect(installation.modelId, 'test.bin');
  expect(await FlutterGemma.isModelInstalled('test.bin'), isTrue);
});
```

## Migration from Legacy API

### Legacy (Deprecated)

```dart
import 'package:flutter_gemma/core/legacy/legacy_model_manager.dart';

final spec = InferenceModelSpec(
  name: 'gemma-2b',
  files: [ModelFile(filename: 'model.bin', url: 'https://...')],
);

await LegacyModelManager.downloadModel(spec);  // DEPRECATED
```

### Modern (Recommended)

```dart
import 'package:flutter_gemma/core/api/flutter_gemma.dart';

await FlutterGemma.installModel()
  .fromNetwork('https://...')
  .withProgress((p) => print(p))
  .install();
```

## Performance Considerations

### Background Downloads
Uses `background_downloader` package for:
- Resume on interruption
- Background execution
- Network change handling

### Progress Tracking
- Network: Real-time progress (0-100%)
- Asset/Bundled/File: Single 100% event (no chunking)

### Memory Management
- Streaming downloads (no full file in memory)
- Lazy service initialization
- Protected file registry (prevent cleanup of external files)

## Future Enhancements

### Phase 5 (Next)
- Integration with existing `InferenceModel`
- `ModelInstallation.loadForInference()` implementation
- `ModelInstallation.loadForEmbedding()` implementation

### Roadmap
- Multi-model loading
- Model quantization support
- Automatic model updates
- Model verification (checksums)
- Differential updates

## Contributing

When adding new features:
1. Follow SOLID principles
2. Write tests first (TDD)
3. Use dependency injection
4. Document public APIs
5. Update this README

## References

- [SOLID Analysis](../../docs/SOLID_ANALYSIS.md)
- [Modern API Design](../../docs/MODERN_API_DESIGN.md)
- [DI Architecture](../../docs/DEPENDENCY_INJECTION_ARCHITECTURE.md)
- [Implementation Plan](../../docs/IMPLEMENTATION_ORCHESTRATOR.md)
