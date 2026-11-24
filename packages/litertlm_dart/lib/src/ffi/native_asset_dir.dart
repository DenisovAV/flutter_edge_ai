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
/// out.
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

/// The directory this package's code assets are in, in a plain Dart program;
/// null when it cannot be told: the program was not built with this
/// package's build hook (as with `dart compile exe`), the loader does not
/// say, or the directory is not ours ([checkedAssetDir]). Resolved once per
/// isolate (a top-level is per isolate).
///
/// On Windows the standard handles are aligned first
/// ([alignWindowsStdHandlesOnce]): resolving the symbol loads StreamProxy.dll,
/// a static-CRT DLL.
String? get nativeAssetDir => _nativeAssetDir;

final String? _nativeAssetDir = _resolveNativeAssetDir();

/// The file name of libLiteRtLm among the code assets on this OS.
String get liteRtLmAssetFile => Platform.isWindows
    ? 'LiteRtLm.dll'
    : Platform.isMacOS
    ? 'libLiteRtLm.dylib'
    : 'libLiteRtLm.so';

String? _resolveNativeAssetDir() {
  if (Platform.isWindows) alignWindowsStdHandlesOnce();
  final Pointer<Void> address;
  try {
    address =
        Native.addressOf<NativeFunction<Pointer<Void> Function(Pointer<Utf8>)>>(
          _streamProxyAnchor,
        ).cast();
  } on ArgumentError {
    // The symbol resolved nowhere: neither an asset under that id nor the
    // process has it.
    return null;
  }
  final module = Platform.isWindows
      ? _windowsModulePath(address)
      : _dladdrModulePath(address);
  return checkedAssetDir(
    module == null
        ? null
        : directoryOfModule(module, windows: Platform.isWindows),
    mainLibraryFile: liteRtLmAssetFile,
    exists: (path) => File(path).existsSync(),
  );
}

/// [dir], the directory of the file the anchor symbol resolved to, when it
/// is this package's code assets: it holds libLiteRtLm under its asset file
/// name ([mainLibraryFile]). When no asset has the anchor's id, the VM looks
/// the symbol up in the process instead, and a StreamProxy some other code
/// loaded by name would answer; its directory is not ours. Null otherwise.
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

/// [nativeAssetDir] in a plain Dart program; an [ArgumentError] with
/// [plainDartNoAssetsMessage] when there is none, never a fall back to the
/// lookup of a Flutter app.
String requireNativeAssetDir() => requireAssetDir(nativeAssetDir);

/// [dir], or the [ArgumentError] of [requireNativeAssetDir] when it is null.
@visibleForTesting
String requireAssetDir(String? dir) =>
    dir ?? (throw ArgumentError(plainDartNoAssetsMessage));

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

/// [name] in [nativeAssetDir] on this platform. [nativeAssetDir] must not be
/// null.
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
    return name == nullptr ? null : name.toDartString();
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
  try {
    if (loadLibraryEx(name, 0, _loadWithAlteredSearchPath) == 0) {
      // No error code: the VM may reset GetLastError before Dart reads it.
      throw ArgumentError('LoadLibraryExW could not load $path');
    }
  } finally {
    calloc.free(name);
  }
}
