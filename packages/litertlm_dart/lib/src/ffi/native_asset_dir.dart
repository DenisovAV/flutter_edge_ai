// Where this package's native libraries are in a plain Dart program (`dart
// run`, `dart test`, `dart build cli`), which has no Flutter app bundle to
// look them up in.
//
// The Dart SDK copies every code asset into one directory (a temporary
// `dart_native_assets_*/lib/` for `dart run` and `dart test`, `bundle/lib/`
// for `dart build cli`), and no API before Dart 3.14 says where. So one
// symbol of the StreamProxy asset is resolved through its asset id, which
// loads the asset where the SDK put it, and the loader is asked which file
// holds that address (`dladdr`; `GetModuleHandleExW` + `GetModuleFileNameW`
// on Windows): its directory is the one every other asset is in.
//
// Used outside Flutter only ([liteRtLmOutsideFlutter]): in a Flutter app the
// libraries are looked up as they always were.
//
// Package-private.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'windows_std_handles.dart';

/// Whether this isolate runs outside Flutter: a plain Dart program, which has
/// no `dart:ui`. Constant, so a Flutter build compiles the plain-Dart paths
/// out. Read by the native files only: `dart test -p chrome` has no `dart:ui`
/// either, and nothing native runs there.
const bool liteRtLmOutsideFlutter = !bool.fromEnvironment('dart.library.ui');

/// The asset id of the library whose symbol locates the asset directory.
const streamProxyAssetId = 'package:litertlm_dart/src/native/StreamProxy';

/// The StreamProxy export the directory is located by: in every StreamProxy
/// this package has shipped, on every platform.
const streamProxyAnchorSymbol = 'stream_proxy_load_global';

@Native<Pointer<Void> Function(Pointer<Utf8>)>(
  assetId: streamProxyAssetId,
  symbol: streamProxyAnchorSymbol,
)
external Pointer<Void> _streamProxyAnchor(Pointer<Utf8> path);

/// Never called: a call of [_streamProxyAnchor] that an AOT build keeps.
///
/// `Native.addressOf(_streamProxyAnchor)` compiles to the VM's
/// `Native._addressOf(const Native(symbol: ..., assetId: ...))`, which reads
/// the constant's fields in native code. The AOT tree shaker sees no Dart
/// read of `Native.symbol` and `Native.assetId` and drops their values from
/// the constant unless some reachable call of an `@Native` function keeps
/// them; a Windows `dart build cli` of a program with no such call then
/// fails with "Couldn't resolve native function 'String: null' in 'String:
/// null'" (Dart 3.13.3 and 3.14.1; the same program built on macOS and Linux
/// loaded). An entry point is a root of the tree shaker, so this call, and
/// the fields with it, stay in every build.
@pragma('vm:entry-point')
Pointer<Void> keepStreamProxyAnchorCall() => _streamProxyAnchor(nullptr);

/// What the anchor's lookup found in a plain Dart program.
sealed class NativeAssetLookup {
  const NativeAssetLookup();
}

/// This package's code assets are in [dir].
final class NativeAssetsFound extends NativeAssetLookup {
  const NativeAssetsFound(this.dir);
  final String dir;
}

/// No code asset has the anchor's id: the program was not built with this
/// package's build hook (`dart compile exe`, a snapshot). [vmText] is the
/// VM's own words.
final class NativeAssetsAbsent extends NativeAssetLookup {
  const NativeAssetsAbsent(this.vmText);
  final String vmText;
}

/// The asset is there and did not load, or its symbol was not found in it:
/// quarantine, Defender or Smart App Control, a missing dependency, another
/// architecture, a damaged copy. [vmText] is the VM's own words.
final class NativeAssetLoadFailed extends NativeAssetLookup {
  const NativeAssetLoadFailed(this.vmText);
  final String vmText;
}

/// The anchor resolved, but not to this package's code assets: [module] is
/// the file the loader named (null when it named none, or not by an absolute
/// path), and no libLiteRtLm is beside it. When no asset has the anchor's id
/// the VM looks the symbol up in the process, and a StreamProxy some other
/// code loaded by name answers.
final class NativeAssetsNotOurs extends NativeAssetLookup {
  const NativeAssetsNotOurs(this.module);
  final String? module;
}

/// What the anchor lookup found, once per isolate (a top-level is per
/// isolate).
///
/// On Windows the standard handles are aligned first
/// ([alignWindowsStdHandlesOnce]): resolving the symbol loads StreamProxy.dll,
/// a static-CRT DLL.
NativeAssetLookup get nativeAssetLookup => _nativeAssetLookup;

final NativeAssetLookup _nativeAssetLookup = _lookUpNativeAssets();

/// The directory this package's code assets are in, in a plain Dart program;
/// null when [nativeAssetLookup] found none.
String? get nativeAssetDir => switch (nativeAssetLookup) {
  NativeAssetsFound(:final dir) => dir,
  _ => null,
};

/// The file name of the code asset [name] (`LiteRtLm`, `StreamProxy`, ...)
/// on [os] (`Platform.operatingSystem` by default): the one table of them.
String codeAssetFileName(String name, {String? os}) =>
    switch (os ?? Platform.operatingSystem) {
      'windows' => '$name.dll',
      'macos' => 'lib$name.dylib',
      _ => 'lib$name.so',
    };

/// The file name of libLiteRtLm among the code assets on this OS.
String get liteRtLmAssetFile => codeAssetFileName('LiteRtLm');

NativeAssetLookup _lookUpNativeAssets() {
  if (Platform.isWindows) alignWindowsStdHandlesOnce();
  final Pointer<Void> address;
  try {
    address =
        Native.addressOf<NativeFunction<Pointer<Void> Function(Pointer<Utf8>)>>(
          _streamProxyAnchor,
        ).cast();
  } on ArgumentError catch (e) {
    return anchorFailure('${e.message ?? e}');
  }
  final module = Platform.isWindows
      ? _windowsModulePath(address)
      : _dladdrModulePath(address);
  final dir = checkedAssetDir(
    module == null
        ? null
        : directoryOfModule(module, windows: Platform.isWindows),
    mainLibraryFile: liteRtLmAssetFile,
    exists: (path) => File(path).existsSync(),
  );
  return dir == null ? NativeAssetsNotOurs(module) : NativeAssetsFound(dir);
}

/// What the VM's [text] says about a failed anchor lookup: no asset under
/// the id ("No asset with id", or the process lookup it fell back to), or an
/// asset that did not load. The text is kept for the message either way.
@visibleForTesting
NativeAssetLookup anchorFailure(String text) =>
    text.contains('No asset with id') ||
        text.contains('Attempted to fallback to process lookup')
    ? NativeAssetsAbsent(text)
    : NativeAssetLoadFailed(text);

/// [dir], the directory of the file the anchor symbol resolved to, when it
/// is this package's code assets: it holds libLiteRtLm under its asset file
/// name ([mainLibraryFile]). Null otherwise ([NativeAssetsNotOurs]).
@visibleForTesting
String? checkedAssetDir(
  String? dir, {
  required String mainLibraryFile,
  required bool Function(String path) exists,
}) {
  if (dir == null) return null;
  return exists(
        pathInAssetDir(dir, mainLibraryFile, windows: Platform.isWindows),
      )
      ? dir
      : null;
}

/// The message when a plain Dart program has no code assets of this package
/// to load LiteRT-LM from.
const plainDartNoAssetsMessage =
    'litertlm_dart: LiteRT-LM\'s native libraries are not among this Dart '
    "program's code assets, so it cannot load. Run it with dart run or dart "
    'test, or build it with dart build cli, which run its build hook; dart '
    'compile exe runs no build hooks and cannot bundle LiteRT-LM.';

/// What a plain Dart program is told when [lookup] found no code assets of
/// this package; null when it found them.
String? plainDartAssetsMessage(NativeAssetLookup lookup) => switch (lookup) {
  NativeAssetsFound() => null,
  NativeAssetsAbsent(:final vmText) =>
    '$plainDartNoAssetsMessage\nThe Dart VM: '
        '$vmText',
  NativeAssetLoadFailed(:final vmText) =>
    "litertlm_dart: LiteRT-LM's native libraries are among this Dart "
        "program's code assets, but StreamProxy, the first of them, did not "
        'load. A quarantined, blocked (Defender, Smart App Control) or damaged '
        'copy, a missing system library or a build for another architecture '
        'fails this way.\nThe Dart VM: $vmText',
  NativeAssetsNotOurs(:final module) =>
    "litertlm_dart: LiteRT-LM's native libraries are not among this Dart "
        "program's code assets: its StreamProxy symbol resolved to "
        '${module ?? 'a library the loader did not name'}, with no '
        '$liteRtLmAssetFile beside it (another copy, loaded by name). Run it '
        'with dart run or dart test, or build it with dart build cli; dart '
        'compile exe runs no build hooks and cannot bundle LiteRT-LM.',
};

/// [nativeAssetDir] in a plain Dart program; an [ArgumentError] saying why
/// there is none ([plainDartAssetsMessage]), never a fall back to the lookup
/// of a Flutter app.
String requireNativeAssetDir() => requireAssetDir(nativeAssetLookup);

/// The directory [lookup] found, or the [ArgumentError] of
/// [requireNativeAssetDir].
@visibleForTesting
String requireAssetDir(NativeAssetLookup lookup) => switch (lookup) {
  NativeAssetsFound(:final dir) => dir,
  _ => throw ArgumentError(plainDartAssetsMessage(lookup)),
};

/// The directory of [modulePath], the file a loader reported: everything
/// before its last separator (`/`, and on Windows also `\`). Null when
/// [modulePath] names no directory.
@visibleForTesting
String? directoryOfModule(String modulePath, {required bool windows}) {
  final cut = windows
      ? modulePath.lastIndexOf(RegExp(r'[\\/]'))
      : modulePath.lastIndexOf('/');
  if (cut < 0) return null;
  // A file in the root: `/libX.so`, `C:\X.dll`.
  if (cut == 0) return windows ? null : '/';
  final dir = modulePath.substring(0, cut);
  return windows && dir.endsWith(':') ? '$dir\\' : dir;
}

/// [name] in [dir], with the separator of the platform ([windows]).
@visibleForTesting
String pathInAssetDir(String dir, String name, {required bool windows}) {
  final sep = windows ? r'\' : '/';
  return dir.endsWith(sep) || (windows && dir.endsWith('/'))
      ? '$dir$name'
      : '$dir$sep$name';
}

/// [name] in [dir], a code-asset directory, with this platform's separator.
String nativeAssetPath(String dir, String name) =>
    pathInAssetDir(dir, name, windows: Platform.isWindows);

// ----- dladdr ---------------------------------------------------------------

/// `Dl_info`: the same four fields on macOS and glibc.
final class _DlInfo extends Struct {
  external Pointer<Utf8> fileName;
  external Pointer<Void> fileBase;
  external Pointer<Utf8> symbolName;
  external Pointer<Void> symbolAddress;
}

typedef _DladdrNative = Int32 Function(Pointer<Void>, Pointer<_DlInfo>);
typedef _DladdrDart = int Function(Pointer<Void>, Pointer<_DlInfo>);

_DladdrDart _dladdr() {
  final process = DynamicLibrary.process();
  if (process.providesSymbol('dladdr')) {
    return process.lookupFunction<_DladdrNative, _DladdrDart>('dladdr');
  }
  // glibc before 2.34 keeps it in libdl.
  return DynamicLibrary.open(
    'libdl.so.2',
  ).lookupFunction<_DladdrNative, _DladdrDart>('dladdr');
}

String? _dladdrModulePath(Pointer<Void> address) {
  final info = calloc<_DlInfo>();
  try {
    if (_dladdr()(address, info) == 0) return null;
    final name = info.ref.fileName;
    if (name == nullptr) return null;
    final path = name.toDartString();
    // Only an absolute path says where the file is.
    return path.startsWith('/') ? path : null;
  } finally {
    calloc.free(info);
  }
}

// ----- Windows --------------------------------------------------------------

const _getModuleHandleExFlagFromAddress = 0x4;
const _getModuleHandleExFlagUnchangedRefcount = 0x2;

String? _windowsModulePath(Pointer<Void> address) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final getModuleHandleEx = kernel32
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Void>, Pointer<IntPtr>),
        int Function(int, Pointer<Void>, Pointer<IntPtr>)
      >('GetModuleHandleExW');
  final getModuleFileName = kernel32
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Utf16>, Uint32),
        int Function(int, Pointer<Utf16>, int)
      >('GetModuleFileNameW');
  final module = calloc<IntPtr>();
  try {
    if (getModuleHandleEx(
          _getModuleHandleExFlagFromAddress |
              _getModuleHandleExFlagUnchangedRefcount,
          address,
          module,
        ) ==
        0) {
      return null;
    }
    // A buffer that is filled to its end may have cut the path: grow it.
    for (var size = 260; ; size = size * 2 > 32768 ? 32768 : size * 2) {
      final buffer = calloc<Uint16>(size);
      try {
        final length = getModuleFileName(module.value, buffer.cast(), size);
        if (length == 0) return null;
        if (length < size) return buffer.cast<Utf16>().toDartString();
        // The longest path Windows has, and it was cut.
        if (size == 32768) return null;
      } finally {
        calloc.free(buffer);
      }
    }
  } finally {
    calloc.free(module);
  }
}

const _loadWithAlteredSearchPath = 0x8;

/// Loads the DLL at [path], an absolute path into [nativeAssetDir], so that
/// the DLLs it imports resolve from its own directory
/// (`LOAD_WITH_ALTERED_SEARCH_PATH`, as the Dart VM loads a code asset and
/// `stream_proxy_load_global` a preload), and leaves it loaded. Unicode-safe,
/// unlike the ANSI `stream_proxy_load_global`: the asset directory of `dart
/// run` is under the user's profile. Throws an [ArgumentError] naming the
/// path when it does not load.
void loadWindowsAssetWithItsDirectory(String path) {
  alignWindowsStdHandlesOnce();
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final loadLibraryEx = kernel32
      .lookupFunction<
        IntPtr Function(Pointer<Utf16>, IntPtr, Uint32),
        int Function(Pointer<Utf16>, int, int)
      >('LoadLibraryExW');
  final name = path.toNativeUtf16();
  final int handle;
  try {
    handle = loadLibraryEx(name, 0, _loadWithAlteredSearchPath);
  } finally {
    malloc.free(name);
  }
  if (handle != 0) return;
  // The VM may reset GetLastError before Dart reads it, so the reason comes
  // from DynamicLibrary.open, which formats the Windows error itself. Its
  // search resolves the DLL's imports from the executable's directory, the
  // current one and PATH instead of [path]'s, so a success is no success: it
  // found an import elsewhere, and that copy is let go again.
  final DynamicLibrary loaded;
  try {
    loaded = DynamicLibrary.open(path);
  } on ArgumentError catch (e, stack) {
    Error.throwWithStackTrace(
      ArgumentError(
        'LoadLibraryExW could not load $path; with the default DLL search: '
        '${e.message ?? e}',
      ),
      stack,
    );
  }
  kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'FreeLibrary',
  )(loaded.handle.address);
  throw ArgumentError(
    '$path loads only with the default DLL search: one of the DLLs it '
    'imports is not loadable from ${File(path).parent.path}.',
  );
}

/// What a plain Dart program loads on Windows before LiteRT can reach the
/// GPU, in order, each from the code assets' directory: LiteRT's GPU
/// registry opens the WebGPU accelerator by its bare name, and Dawn may open
/// the DirectX shader compiler (which opens dxil.dll) the same way. A bare
/// name resolves to a module already loaded under it, but not to the code
/// assets' directory, which is not the executable's; a Flutter app has them
/// beside its executable. Every one is a file of the Windows native archive
/// (test/windows_preload_test.dart).
const windowsGpuAssetLibraries = [
  'LiteRt.dll',
  'dxil.dll',
  'dxcompiler.dll',
  'webgpu_dawn.dll',
  'libLiteRtWebGpuAccelerator.dll',
];

/// The code assets' directory [preloadWindowsGpuAssets] has loaded
/// [windowsGpuAssetLibraries] from in this isolate (a top-level is per
/// isolate); null before its first success.
String? _windowsGpuAssetsLoadedFrom;

/// Forgets that [preloadWindowsGpuAssets] has run, so a test can run it again.
@visibleForTesting
void resetWindowsGpuAssetsPreload() => _windowsGpuAssetsLoadedFrom = null;

/// Loads [windowsGpuAssetLibraries] from [assetDir], in order
/// ([loadWindowsAssetWithItsDirectory]), before a plain Dart program opens
/// LiteRtLm.dll or LiteRt.dll on Windows; once per isolate, since the opener
/// of the EmbeddingGemma 2 pass and option scoring runs per operation, and a
/// loaded DLL stays loaded. A failed run is tried again by the next call.
/// Throws an [Exception] naming the file that did not load: each is in every
/// Windows build, so a missing one is a broken bundle.
void preloadWindowsGpuAssets(
  String assetDir, {
  void Function(String path) load = loadWindowsAssetWithItsDirectory,
}) {
  if (_windowsGpuAssetsLoadedFrom == assetDir) return;
  for (final name in windowsGpuAssetLibraries) {
    final path = pathInAssetDir(assetDir, name, windows: true);
    try {
      load(path);
    } on ArgumentError catch (e, stack) {
      Error.throwWithStackTrace(
        Exception('Failed to preload $path: ${e.message}'),
        stack,
      );
    }
  }
  _windowsGpuAssetsLoadedFrom = assetDir;
}
