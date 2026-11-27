// Loads litertlm_dart's native libraries in a plain Dart program, no model:
// what CI runs after `dart run` and after `dart build cli` of a bundle moved
// elsewhere. Prints the code assets' directory it resolved and the native
// release, and exits 0 only when LiteRtLm, LiteRt and StreamProxy loaded and
// a client got as far as the (missing) model, which LiteRT-LM refuses by its
// path, and, on Linux and Windows, when the GPU accelerator is loaded under
// the bare name LiteRT's GPU registry opens it by (and on Windows Dawn and
// the shader compiler with it), and on macOS when libLiteRtLm carries the
// statically linked Metal accelerator LiteRT registers first: the GPU's own
// load is not run, as CI has no GPU. No platform needs a hooks define (from
// litertlm_dart 0.20.0), and no Gemma constraint provider may be among the
// code assets: the tool-call constraints are LLGuidance's, inside libLiteRtLm.
//
// Internal to the repository's CI: it reads the runtime's private library
// lookup, which the published API does not expose.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'package:litertlm_dart/litert_bindings.dart' show LiteRtBindings;
// ignore: implementation_imports — the client, to check a load gets as far as the model, and its engine-create failure.
import 'package:litertlm_dart/src/ffi/litert_lm_client.dart';
// ignore: implementation_imports — the plain LiteRtLm opener under test.
import 'package:litertlm_dart/src/ffi/litert_lm_library.dart';
// ignore: implementation_imports — the code-asset directory lookup under test.
import 'package:litertlm_dart/src/ffi/native_asset_dir.dart';
// ignore: implementation_imports — prints the native release the hook bundled.
import 'package:litertlm_dart/src/runtime/native_release.dart';

Future<void> main() async {
  stdout.writeln('executable: ${Platform.resolvedExecutable}');
  stdout.writeln('native release: $liteRtLmNativeReleaseTag');
  final lookup = nativeAssetLookup;
  final dir = switch (lookup) {
    NativeAssetsFound(:final dir) => dir,
    _ => null,
  };
  stdout.writeln('code assets: $dir');
  if (dir == null) {
    stderr.writeln('FAIL: ${plainDartAssetsMessage(lookup)}');
    exit(1);
  }
  final liteRtLm = openLiteRtLmLibrary();
  stdout.writeln('opened ${nativeAssetPath(dir, liteRtLmAssetFile)}');
  LiteRtBindings.open();
  stdout.writeln('opened the LiteRT C API');
  final providers = [
    for (final entity in Directory(dir).listSync())
      if (RegExp(
        'GemmaModelConstraintProvider|LtGmcp',
      ).hasMatch(entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty)))
        entity.path,
  ];
  if (providers.isNotEmpty) {
    stderr.writeln(
      'FAIL: a Gemma constraint provider is among the code assets: '
      '${providers.join(', ')}',
    );
    exit(1);
  }
  const missing = '/no/such/model.litertlm';
  try {
    await LiteRtLmFfiClient().initialize(modelPath: missing, backend: 'cpu');
    stderr.writeln('FAIL: a client initialized without a model');
    exit(1);
  } on LiteRtLmEngineCreateException catch (e) {
    // The libraries loaded and LiteRT-LM looked for the model.
    if (!'$e'.contains(missing)) {
      stderr.writeln('FAIL: the engine refused something else: $e');
      exit(1);
    }
    stdout.writeln('client: libraries loaded, the missing model refused');
  } on Object catch (e) {
    stderr.writeln(
      'FAIL: ${e.runtimeType} before the model was looked for: $e',
    );
    exit(1);
  }
  if (Platform.isMacOS) {
    // LiteRT's gpu_registry registers this definition before it looks for any
    // accelerator library; it is set by the accelerator linked into
    // libLiteRtLm when the library loads.
    const symbol = 'LiteRtStaticLinkedAcceleratorGpuDef';
    if (!liteRtLm.providesSymbol(symbol) ||
        liteRtLm.lookup<Pointer<Void>>(symbol).value == nullptr) {
      stderr.writeln(
        'FAIL: libLiteRtLm has no statically linked GPU accelerator ($symbol '
        'missing or null)',
      );
      exit(1);
    }
    stdout.writeln(
      'GPU: Metal accelerator statically linked ($symbol set in libLiteRtLm)',
    );
  }
  final notLoaded = [
    for (final name in _gpuLibraries())
      if (!_loadedByBareName(name)) name,
  ];
  if (notLoaded.isNotEmpty) {
    stderr.writeln(
      'FAIL: not loaded under the bare names the GPU looks for: '
      '${notLoaded.join(', ')}',
    );
    exit(1);
  }
  if (_gpuLibraries().isNotEmpty) {
    stdout.writeln('GPU libraries loaded: ${_gpuLibraries().join(', ')}');
  }
  stdout.writeln('OK');
}

/// What LiteRT and Dawn open by bare name for the GPU on this OS.
List<String> _gpuLibraries() => Platform.isWindows
    ? const [
        'libLiteRtWebGpuAccelerator.dll',
        'webgpu_dawn.dll',
        'dxcompiler.dll',
        'dxil.dll',
      ]
    : Platform.isLinux
    ? const ['libLiteRtWebGpuAccelerator.so']
    : const [];

/// Whether [name] resolves to a module already in the process, as a bare-name
/// load by LiteRT would: `GetModuleHandleW` on Windows, `dlopen` with
/// `RTLD_NOLOAD` on Linux.
bool _loadedByBareName(String name) {
  if (Platform.isWindows) {
    final getModuleHandle = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('GetModuleHandleW');
    final wide = name.toNativeUtf16();
    try {
      return getModuleHandle(wide) != 0;
    } finally {
      malloc.free(wide);
    }
  }
  const rtldLazy = 0x1;
  const rtldNoload = 0x4;
  final process = DynamicLibrary.process();
  final dlopen = process
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Int32),
        Pointer<Void> Function(Pointer<Utf8>, int)
      >('dlopen');
  final dlclose = process
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('dlclose');
  final path = name.toNativeUtf8();
  try {
    final handle = dlopen(path, rtldLazy | rtldNoload);
    if (handle == nullptr) return false;
    // RTLD_NOLOAD still takes a reference: give it back.
    dlclose(handle);
    return true;
  } finally {
    malloc.free(path);
  }
}
