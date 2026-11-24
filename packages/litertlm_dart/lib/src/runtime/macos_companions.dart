// How the macOS companion library reaches a plain Dart program: the one
// `hooks: user_defines: litertlm_dart:` key that chooses it, and the file
// name the build hook gives the companion when it bundles it as a code asset.
// Read by the hook (lib/src/hook/macos_companions.dart) and by the loader
// (lib/src/ffi/macos_load_error.dart). Package-private.

/// The `user_defines` key.
const macOSCompanionsDefine = 'macos_companions';

/// Its one value: bundle the companion as a code asset, for a plain Dart
/// program (`dart run`, `dart test`, `dart build cli`). Unset, the companions
/// reach a Flutter app as frameworks, as they always have.
const macOSCompanionsCodeAssets = 'code_assets';

/// The file name of `libGemmaModelConstraintProvider.dylib` among the code
/// assets. Short, because Google's prebuilt has 64 bytes of Mach-O header
/// slack and `dart run` / `dart test` write the asset's absolute path into
/// it as its install name.
const macOSConstraintProviderAssetFile = 'libLtGmcp.dylib';
