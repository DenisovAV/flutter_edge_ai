/// `dart:io` / `dart:ffi` helpers for engine packages.
///
/// Import only from files that never compile to web (native-only leaves, or
/// files behind `if (dart.library.ffi)`). The web-safe engine SPI is
/// `engine.dart`.
library;

export 'src/utils/host_native_library.dart'
    show
        firstExistingPath,
        hostNativeCacheBase,
        hostNativeDirName,
        hostNativeLibraryCandidates,
        hostNativeLibraryFileName;
