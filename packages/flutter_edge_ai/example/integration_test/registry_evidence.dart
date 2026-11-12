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
/// A null [backend] (the model does not say) prints FEA_EVIDENCE_SKIP.
///
/// [path] names the build: the variant whose first file has its bytes. A
/// variant of several files (a `.tflite` embedder and its tokenizer, a
/// speech model and its tokenizer, a TTS bundle) counts only when
/// [companions], the paths of the other files the test loaded, hold the
/// pinned bytes of every other file of it; otherwise FEA_EVIDENCE_SKIP names
/// the file that is missing or not pinned.
Future<void> recordEvidence({
  required String path,
  required PreferredBackend? backend,
  required String check,
  List<String> companions = const [],
}) async {
  final name = path.split(Platform.pathSeparator).last;
  void skip(String reason) => print(
    'FEA_EVIDENCE_SKIP ${jsonEncode({'file': name, 'check': check, 'reason': reason})}',
  );
  if (backend == null) {
    skip('the model reports no backend');
    return;
  }
  // Only the hash is caught: a file it cannot read, or the worker isolate's
  // own failure, is a skip. The catalog's own errors (not initialized, ids
  // that clash) fail the test, as they should.
  final hex = await _hashOrReason(path);
  if (hex.reason case final reason?) {
    skip(reason);
    return;
  }
  final variant = variantWithSha256(hex.sha256!, FlutterEdgeAi.catalog.models);
  if (variant == null) {
    skip('not a registry build');
    return;
  }
  if (await companionProblem(variant, companions) case final reason?) {
    skip(reason);
    return;
  }
  _printEvidence(variant, backend: backend, check: check);
}

/// Where core reads every file of [spec] (`FlutterEdgeAi.activeEmbedderSpec`,
/// `activeSttSpec`, `activeTtsSpec`): the companions of a record for a model
/// installed from several files. None for a null [spec].
Future<List<String>> installedFilePaths(ModelSpec? spec) async => [
  for (final file in spec?.files ?? const <ModelFile>[])
    await FlutterEdgeAi.getModelPath(file.filename),
];

/// Why [companions] are not the pinned bytes of every file of [variant]
/// after its first, or null when they are (always for a one-file variant).
/// The reason names the first file no companion holds. [hash] replaces
/// [fileSha256] in tests.
Future<String?> companionProblem(
  CatalogVariant variant,
  List<String> companions, {
  Future<String> Function(String path) hash = fileSha256,
}) async {
  if (variant.files.length < 2) return null;
  final held = <String>{};
  final unread = <String>[];
  for (final path in companions) {
    final hex = await _hashOrReason(path, hash: hash);
    if (hex.sha256 case final sha?) {
      held.add(sha);
    } else {
      unread.add('${path.split(Platform.pathSeparator).last}: ${hex.reason}');
    }
  }
  for (final file in variant.files.skip(1)) {
    if (!held.contains(file.sha256.toLowerCase())) {
      return 'no companion file holds the pinned bytes of ${file.path} of '
          '${variant.id}'
          '${unread.isEmpty ? '' : ' (${unread.join('; ')})'}';
    }
  }
  return null;
}

/// The lower-case sha256 of the file at [path], or why it has none: a file
/// it cannot read, or the hash's own failure.
Future<({String? sha256, String? reason})> _hashOrReason(
  String path, {
  Future<String> Function(String path) hash = fileSha256,
}) async {
  try {
    return (sha256: (await hash(path)).toLowerCase(), reason: null);
  } on FileSystemException catch (e) {
    return (sha256: null, reason: 'cannot read it: ${e.message}');
  } catch (e) {
    return (sha256: null, reason: 'cannot hash it: $e');
  }
}

/// The backend a speech suite asks for, from
/// `--dart-define=SPEECH_BACKEND=cpu|gpu` (default cpu). Speech compiles its
/// graphs for exactly that LiteRT accelerator and fails rather than fall back
/// (`acceleratorFor` in flutter_edge_ai_speech), so it is also the backend
/// that ran. Any other value throws, failing the test that reads it.
PreferredBackend speechBackendFromDefine() =>
    switch (const String.fromEnvironment(
      'SPEECH_BACKEND',
      defaultValue: 'cpu',
    )) {
      'cpu' => PreferredBackend.cpu,
      'gpu' => PreferredBackend.gpu,
      final other => throw ArgumentError.value(
        other,
        'SPEECH_BACKEND',
        'expected cpu or gpu',
      ),
    };

/// Records that [check] passed on [variant], installed from the catalog
/// (`installModelFromCatalog` or `fromCatalog`), run on [backend]. Every
/// installed file of it is hashed, off the UI isolate: a file that is not
/// there, or not the pinned bytes, prints FEA_EVIDENCE_SKIP and counts for
/// nothing, as does a null [backend].
Future<void> recordCatalogEvidence(
  CatalogVariant variant, {
  required PreferredBackend? backend,
  required String check,
}) async {
  if (backend == null) {
    print(
      'FEA_EVIDENCE_SKIP ${jsonEncode({'variant': variant.id, 'check': check, 'reason': 'the model reports no backend'})}',
    );
    return;
  }
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
///
/// Any failure to hash it (a file error, or the worker isolate's own) is a
/// reason, never an error that fails the test the evidence is for. [hash]
/// replaces [fileSha256] in tests.
Future<String?> pinnedBytesProblem(
  String path,
  ModelArtifact file,
  String id, {
  Future<String> Function(String path) hash = fileSha256,
}) async {
  if (!File(path).existsSync()) return 'not installed at $path';
  try {
    return await hash(path) == file.sha256.toLowerCase()
        ? null
        : 'not the pinned bytes of $id';
  } on FileSystemException catch (e) {
    return 'cannot read $path: ${e.message}';
  } catch (e) {
    return 'cannot hash $path: $e';
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
