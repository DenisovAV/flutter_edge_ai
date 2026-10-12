// Shared by the train-side harness suites. No setUp anywhere: every check runs
// inside a test body, so a failing precondition is a failing test.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:path/path.dart' as p;

/// The profile every harness store is bound to: the published side asks for
/// exactly this id and dimension, so only the document modality can make it
/// refuse.
final compatProfile = EmbeddingProfile(id: 'compat-v1', dimension: 4);

const compatDocuments = [
  ('doc-a', 'alpha', <double>[1, 0, 0, 0]),
  ('doc-b', 'beta', <double>[0, 1, 0, 0]),
];

/// One store the train writes: `(backend, name, documents, documentCount)`.
typedef CompatStore = ({
  String backend,
  String name,
  EmbeddingModality documents,
  int documentCount,
});

const List<CompatStore> compatStores = [
  (
    backend: 'sqlite',
    name: 'text',
    documents: EmbeddingModality.text,
    documentCount: 2,
  ),
  (
    backend: 'sqlite',
    name: 'image',
    documents: EmbeddingModality.image,
    documentCount: 2,
  ),
  (
    backend: 'sqlite',
    name: 'image_empty',
    documents: EmbeddingModality.image,
    documentCount: 0,
  ),
  (
    backend: 'sqlite',
    name: 'audio',
    documents: EmbeddingModality.audio,
    documentCount: 2,
  ),
  (
    backend: 'qdrant',
    name: 'text',
    documents: EmbeddingModality.text,
    documentCount: 2,
  ),
  (
    backend: 'qdrant',
    name: 'image',
    documents: EmbeddingModality.image,
    documentCount: 2,
  ),
  (
    backend: 'qdrant',
    name: 'image_empty',
    documents: EmbeddingModality.image,
    documentCount: 0,
  ),
  (
    backend: 'qdrant',
    name: 'audio',
    documents: EmbeddingModality.audio,
    documentCount: 2,
  ),
];

/// sqlite: a database file; qdrant: a directory.
String locationOf(String root, CompatStore store) => store.backend == 'sqlite'
    ? p.join(root, 'sqlite_${store.name}.db')
    : p.join(root, 'qdrant_${store.name}');

/// What the published side reads: one JSON object per store.
Map<String, Object> manifestEntry(String root, CompatStore store) => {
  'backend': store.backend,
  'name': store.name,
  'location': locationOf(root, store),
  'profileId': compatProfile.id,
  'dimension': compatProfile.dimension,
  'documents': store.documents.name,
  'documentCount': store.documentCount,
};

File manifestFile(String root) => File(p.join(root, 'manifest.json'));

void writeManifest(String root) => manifestFile(root).writeAsStringSync(
  const JsonEncoder.withIndent(
    '  ',
  ).convert([for (final store in compatStores) manifestEntry(root, store)]),
);

/// Points the train's SQLite store at the vec0 loadable the hook downloaded.
/// `$VEC0_DYLIB` wins. Same rule as core's `hostNativeLibraryCandidates`.
void useHostVec0() {
  final override = Platform.environment['VEC0_DYLIB'];
  final home = Platform.environment['HOME'] ?? '';
  final path = (override != null && override.isNotEmpty)
      ? override
      : Platform.isMacOS
      ? '$home/Library/Caches/flutter_gemma/native/sqlite_vec/macos_arm64/'
            'libvec0.dylib'
      : '$home/.cache/flutter_gemma/native/sqlite_vec/'
            '${_linuxArch()}/libvec0.so';
  if (!File(path).existsSync()) {
    throw StateError('vec0 loadable not found at $path; set VEC0_DYLIB.');
  }
  // ignore: invalid_use_of_visible_for_testing_member
  SqliteVectorStore.debugOverrideDylibPath = path;
}

String _linuxArch() {
  final arch = Process.runSync('uname', ['-m']).stdout.toString().trim();
  return arch == 'aarch64' || arch == 'arm64' ? 'linux_arm64' : 'linux_x86_64';
}

String requireEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    throw StateError('Set $name (see tool/rag_store_compat/README.md).');
  }
  return value;
}
