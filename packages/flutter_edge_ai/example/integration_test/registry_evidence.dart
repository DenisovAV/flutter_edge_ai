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

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

final _byPath = <String, Future<CatalogVariant?>>{};

/// The registry build whose file has the bytes of [path], or null. Hashed
/// once per path per run.
Future<CatalogVariant?> registryVariantOf(String path) =>
    _byPath.putIfAbsent(path, () async {
      final digest = await sha256.bind(File(path).openRead()).first;
      final hex = '$digest';
      for (final model in FlutterEdgeAi.catalog.models) {
        for (final variant in model.variants) {
          if (variant.files.isNotEmpty && variant.files.first.sha256 == hex) {
            return variant;
          }
        }
      }
      return null;
    });

/// Records that [check] passed on the model file at [path], run on
/// [backend] — the backend that ran (`activeBackend`), not the one asked for.
Future<void> recordEvidence({
  required String path,
  required PreferredBackend backend,
  required String check,
}) async {
  final variant = await registryVariantOf(path);
  if (variant == null) {
    print(
      'FEA_EVIDENCE_SKIP ${jsonEncode({'file': path.split(Platform.pathSeparator).last, 'check': check, 'reason': 'not a registry build'})}',
    );
    return;
  }
  recordCatalogEvidence(variant, backend: backend, check: check);
}

/// Records that [check] passed on [variant], installed from the catalog
/// (`FlutterEdgeAi.installFromCatalog`), run on [backend].
void recordCatalogEvidence(
  CatalogVariant variant, {
  required PreferredBackend backend,
  required String check,
}) {
  print(
    'FEA_EVIDENCE v2 ${jsonEncode({
      'variant': variant.id,
      'host': '${Abi.current()}',
      'backend': backend.name,
      'check': check,
      // The simulator reports the device's host but is not one.
      if (Platform.isIOS && Platform.environment.containsKey('SIMULATOR_DEVICE_NAME')) 'simulator': true,
    })}',
  );
}
