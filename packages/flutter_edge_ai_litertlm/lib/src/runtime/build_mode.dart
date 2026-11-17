// The build mode, read the way Flutter's `kReleaseMode`, `kProfileMode` and
// `kDebugMode` (package:flutter/foundation.dart) read it, without importing
// Flutter: the runtime side of this package (lib/src/ffi, lib/src/bundle, the
// EmbeddingGemma 2 pass) is meant to run from plain Dart as well. Each is a
// compile-time constant, so code behind `if (isDebugBuild)` is tree-shaken out
// of a release build exactly as it was behind `kDebugMode`. Not exported.

/// `dart.vm.product`: a release (product) build. Flutter's `kReleaseMode`.
const bool isProductBuild = bool.fromEnvironment('dart.vm.product');

/// `dart.vm.profile`: a profile build. Flutter's `kProfileMode`.
const bool isProfileBuild = bool.fromEnvironment('dart.vm.profile');

/// Neither a release nor a profile build. Flutter's `kDebugMode`, which is
/// false in a profile build too.
const bool isDebugBuild = !isProductBuild && !isProfileBuild;

/// A release build: [isProductBuild] under the name of Flutter's
/// `kReleaseMode`. A profile build is not one.
const bool isReleaseBuild = isProductBuild;
