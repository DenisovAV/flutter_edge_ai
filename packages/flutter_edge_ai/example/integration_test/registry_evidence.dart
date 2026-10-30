// Evidence for the model registry (model_registry/README.md, "Evidence").
//
// A check that passed prints one line naming the registry build it ran, the
// host, and the backend that actually ran:
//
//   FEA_EVIDENCE v2 {"variant":"gemma-4-e2b-it/generic","host":"macos_arm64",...}
//
// The backend of a vision or audio check is its encoder's
// (`activeVisionBackend`, `activeAudioBackend`), not the text model's.
//
// `dart run bin/registry.dart evidence --device <device> <log>` in
// tool/model_registry turns a run's log into model_registry/evidence/. Call
// these only after a check's expectations have passed: a line is a pass.
//
// The build is found by the sha256 of the file the test installed, so a file
// staged under a familiar name still counts only if its bytes are the ones the
// registry pins. A file the registry does not have prints FEA_EVIDENCE_SKIP and
// counts for nothing.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

/// The registry build whose file has the bytes of [path], or null; hashed
/// once per file version (see [fileSha256]).
Future<CatalogVariant?> registryVariantOf(String path) async =>
    variantWithSha256(await fileSha256(path), FlutterEdgeAi.catalog.models);

/// The variant of [models] whose first file is pinned to [hex], compared
/// without regard to case, or null.
CatalogVariant? variantWithSha256(String hex, Iterable<CatalogModel> models) {
  final want = hex.toLowerCase();
  for (final model in models) {
    for (final variant in model.variants) {
      if (variant.files.isNotEmpty &&
          variant.files.first.sha256.toLowerCase() == want) {
        return variant;
      }
    }
  }
  return null;
}

/// Records that [check] passed on the model file at [path], run on
/// [backend] — the backend that ran (`activeBackend`), not the one asked for.
Future<void> recordEvidence({
  required String path,
  required PreferredBackend backend,
  required String check,
}) async {
  final name = path.split(Platform.pathSeparator).last;
  final CatalogVariant? variant;
  try {
    variant = await registryVariantOf(path);
  } on FileSystemException catch (e) {
    print(
      'FEA_EVIDENCE_SKIP ${jsonEncode({'file': name, 'check': check, 'reason': 'cannot read it: ${e.message}'})}',
    );
    return;
  }
  if (variant == null) {
    print(
      'FEA_EVIDENCE_SKIP ${jsonEncode({'file': name, 'check': check, 'reason': 'not a registry build'})}',
    );
    return;
  }
  _printEvidence(variant, backend: backend, check: check);
}

/// Records that [check] passed on [variant], installed from the catalog
/// (`installModelFromCatalog` or `fromCatalog`), run on [backend]. Every
/// installed file of it is hashed, off the UI isolate: a file that is not
/// there, or not the pinned bytes, prints FEA_EVIDENCE_SKIP and counts for
/// nothing.
Future<void> recordCatalogEvidence(
  CatalogVariant variant, {
  required PreferredBackend backend,
  required String check,
}) async {
  for (final (name, file) in installedNamesOf(variant)) {
    // Where core reads the file; returned even when nothing is there.
    final path = await FlutterEdgeAi.getModelPath(name);
    if (await pinnedBytesProblem(path, file, variant.id) case final reason?) {
      print(
        'FEA_EVIDENCE_SKIP ${jsonEncode({'file': name, 'check': check, 'reason': reason})}',
      );
      return;
    }
  }
  _printEvidence(variant, backend: backend, check: check);
}

/// Why the file at [path] is not [file]'s pinned bytes — not there, not
/// readable, other bytes — or null when it is. [id] names the variant.
Future<String?> pinnedBytesProblem(
  String path,
  ModelArtifact file,
  String id,
) async {
  if (!File(path).existsSync()) return 'not installed at $path';
  try {
    return await fileSha256(path) == file.sha256.toLowerCase()
        ? null
        : 'not the pinned bytes of $id';
  } on FileSystemException catch (e) {
    return 'cannot read $path: ${e.message}';
  }
}

/// Each file of [variant] with the name core installs it under: a TTS
/// bundle's under its type's namespace, an STT tokenizer under its model
/// file's (`<model name>__tokenizer.json`), the rest as the catalog names
/// them.
List<(String, ModelArtifact)> installedNamesOf(
  CatalogVariant variant,
) => switch (variant) {
  TtsVariant(:final type, :final files) => [
    for (final f in files) ('${type.name}__${f.installFilename}', f),
  ],
  SttVariant(:final model, :final tokenizer) => [
    (model.installFilename, model),
    (
      '${_coreBaseName(model.installFilename)}__${tokenizer.installFilename}',
      tokenizer,
    ),
  ],
  _ => [for (final f in variant.files) (f.installFilename, f)],
};

void _printEvidence(
  CatalogVariant variant, {
  required PreferredBackend backend,
  required String check,
}) {
  final simulator = _isSimulator;
  if (simulator == null) {
    // Neither a device nor an emulator for sure: a run that cannot say
    // which counts for nothing, rather than as a device.
    print(
      'FEA_EVIDENCE_SKIP ${jsonEncode({'variant': variant.id, 'check': check, 'reason': 'cannot tell an emulator from a device here (getprop unreadable)'})}',
    );
    return;
  }
  print(
    'FEA_EVIDENCE v2 ${jsonEncode({
      'variant': variant.id,
      'host': '${Abi.current()}',
      'backend': backend.name,
      'check': check,
      // A simulator or emulator reports the device's host but is not one.
      if (simulator) 'simulator': true,
    })}',
  );
}

/// The iOS simulator, or an Android emulator (an arm64 one on an Apple
/// Silicon Mac reports `android_arm64`, with the host's or a software GPU);
/// null on Android when the system properties cannot be read.
final bool? _isSimulator = () {
  if (Platform.isIOS) {
    return Platform.environment.containsKey('SIMULATOR_DEVICE_NAME');
  }
  if (!Platform.isAndroid) return false;
  return looksLikeAndroidEmulator(
    property: (name) {
      try {
        final result = Process.runSync('getprop', [name]);
        return result.exitCode == 0 ? '${result.stdout}'.trim() : null;
      } on ProcessException {
        return null;
      }
    },
    exists: (path) => File(path).existsSync(),
  );
}();

/// Whether an Android process runs on an emulator, from its system
/// properties ([property]: null when it cannot be read) and device nodes
/// ([exists]). Null when it cannot tell: no emulator sign, and not even the
/// build fingerprint (which every Android build sets) could be read.
bool? looksLikeAndroidEmulator({
  required String? Function(String name) property,
  required bool Function(String path) exists,
}) {
  final fingerprint = property('ro.build.fingerprint') ?? '';
  final hardware = property('ro.hardware') ?? '';
  final model = property('ro.product.model') ?? '';
  final emulator =
      property('ro.kernel.qemu') == '1' ||
      property('ro.boot.qemu') == '1' ||
      hardware == 'ranchu' ||
      hardware == 'goldfish' ||
      model.startsWith('sdk_gphone') ||
      // Cuttlefish (cutf_cvm, vsoc_*) and Genymotion (vbox86).
      hardware.startsWith('cutf') ||
      hardware.startsWith('vsoc') ||
      hardware.startsWith('vbox86') ||
      fingerprint.contains('/vsoc_') ||
      fingerprint.contains('generic') ||
      fingerprint.contains('/sdk_gphone') ||
      exists('/dev/qemu_pipe') ||
      exists('/dev/goldfish_pipe');
  if (emulator) return true;
  return fingerprint.isEmpty ? null : false;
}

final _hashes = <(String, int, DateTime), Future<String>>{};

/// How many files [fileSha256] has hashed in this run.
int get fileHashCount => _hashCount;
var _hashCount = 0;

/// The lower-case hex sha256 of the file at [path], hashed on a worker
/// isolate once per version of the file (its path, size and modification
/// time): a suite records several checks on one multi-GB model, and each
/// would hash it again. A failed hash is not kept.
Future<String> fileSha256(String path) {
  final stat = File(path).statSync();
  if (stat.type == FileSystemEntityType.notFound) {
    throw PathNotFoundException(path, const OSError('not found', 2));
  }
  final key = (path, stat.size, stat.modified);
  return _hashes.putIfAbsent(key, () {
    _hashCount++;
    final hashing = Isolate.run(
      () async => '${await sha256.bind(File(path).openRead()).first}',
    );
    hashing.ignore();
    return hashing.catchError((Object e, StackTrace stack) {
      _hashes.remove(key);
      Error.throwWithStackTrace(e, stack);
    });
  });
}

/// [name] with every model extension core knows taken out, as core's
/// `FileNameUtils.getBaseName` names an STT model's tokenizer namespace.
String _coreBaseName(String name) {
  var result = name;
  for (final ext in const [
    '.task',
    '.bin',
    '.tflite',
    '.json',
    '.model',
    '.litertlm',
    '.gguf',
  ]) {
    result = result.replaceAll(ext, '');
  }
  return result;
}
