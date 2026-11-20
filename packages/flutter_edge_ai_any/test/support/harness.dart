// Helpers for the unit suites: accounts on a FakeNetwork, indexes through
// FlutterEdgeAiRag, and a deterministic embedder.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/logic/engine.dart'
    show debugEngineMutations;
import 'package:flutter_edge_ai_any/src/logic/formats.dart';
import 'package:flutter_edge_ai_any/src/native/any_native.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_any/src/native/fs.dart' show absolutePath;

import 'fake_native.dart';

export 'fake_native.dart';

const nodeConf = 'fake nodeconf';

/// A world of devices; [root] is a temp directory for their paths.
final class World {
  World() : root = Directory.systemTemp.createTempSync('any_unit').path {
    // Restarts and gc retries in milliseconds, not seconds.
    debugEventsBackoffBase = const Duration(milliseconds: 10);
  }

  final net = FakeNetwork();
  final String root;
  final _accounts = <AnySyncAccount>[];
  final mnemonic = 'world mnemonic';

  /// Opens device [name] of the world's account (another [mnemonic] makes
  /// another account).
  Future<AnySyncAccount> open(
    String name, {
    String? mnemonic,
    Duration previousInstanceWait = const Duration(milliseconds: 300),
    Duration spaceOpenWait = const Duration(milliseconds: 300),
    Uint8List? localEncryptionKey,
  }) async {
    debugAnyNativeOverride = net.native();
    final a = await AnySyncAccount.open(
      dataDirectory: '$root/$name/sdk',
      indexDirectory: '$root/$name/index',
      mnemonic: mnemonic ?? this.mnemonic,
      deviceKey: 'key-$name',
      nodeConfYaml: nodeConf,
      previousInstanceWait: previousInstanceWait,
      spaceOpenWait: spaceOpenWait,
      localEncryptionKey: localEncryptionKey,
    );
    _accounts.add(a);
    return a;
  }

  FakeDevice device(String name) => net.device('$root/$name/sdk');

  FakeRuntime runtimeOf(String name) => net.runtimes.lastWhere(
    (r) => r.sdkImpl.device?.dataDir == absolutePath('$root/$name/sdk'),
  );

  Future<void> dispose() async {
    for (final a in _accounts) {
      try {
        await a.close();
      } on Object {
        // Already closed.
      }
    }
    debugAnyNativeOverride = null;
    FakeIndex.failApply = null;
    FakeIndex.refuseVector = null;
    FakeIndex.failApplyStatus = AnyShimStatus.io;
    FakeIndexHost.bindSlices = 0;
    FakeIndexHost.bindConflictInOp = false;
    FakeIndex.gcError = null;
    FakeIndex.failClose = false;
    FakeIndex.failScanPrefix = null;
    FakeIndex.failScanWithError = false;
    readPendingMax = const Duration(seconds: 10);
    debugEngineMutations.clear();
    debugAccountClockSkewMs.clear();
    debugEventsBackoffBase = const Duration(seconds: 1);
    Directory(root).deleteSync(recursive: true);
  }
}

FlutterEdgeAiRag ragOf(AnySyncAccount a) =>
    FlutterEdgeAiRag(providers: [AnyVectorStoreProvider(a)]);

VectorStoreSpec specOf(
  AnySyncLocation loc, {
  FilterSchema? schema,
  bool text = false,
  EmbeddingModality documents = EmbeddingModality.text,
}) => VectorStoreSpec(
  providerId: AnyVectorStoreProvider.providerId,
  location: loc.value,
  filterSchema: schema ?? FilterSchema.empty,
  enableTextSearch: text,
  documents: documents,
);

final profile4 = EmbeddingProfile(id: 'test-embedder-v1', dimension: 4);

Future<RagIndex> openVectors(
  AnySyncAccount a,
  AnySyncLocation loc, {
  FilterSchema? schema,
  bool text = false,
  EmbeddingProfile? profile,
  EmbeddingModality documents = EmbeddingModality.text,
}) => ragOf(a).openVectors(
  spec: specOf(loc, schema: schema, text: text, documents: documents),
  profile: profile ?? profile4,
);

/// A deterministic embedder: the text's letters a-d counted, plus one.
final class FakeEmbedder implements RagEmbedder {
  FakeEmbedder({this.profile, this.failOn});
  final EmbeddingProfile? profile;
  final String? failOn;
  int calls = 0;

  @override
  Set<EmbeddingModality> get modalities => {
    EmbeddingModality.text,
    EmbeddingModality.image,
  };

  @override
  Future<EmbeddingProfile> resolveProfile() async => profile ?? profile4;

  static List<double> vec(String t) => [
    for (final c in 'abcd'.split('')) 1.0 + c.allMatches(t).length,
  ];

  @override
  Future<List<double>> embedDocument(EmbeddingInput document) async {
    calls++;
    final t = document.text ?? '';
    if (failOn != null && t.contains(failOn!)) throw StateError('embed failed');
    return vec(t);
  }

  @override
  Future<List<double>> embedQuery(
    EmbeddingInput query, {
    required EmbeddingModality documentModality,
  }) async => vec(query.text ?? '');
}

/// Two devices of one account, linked, with the location bound on both.
final class Pair {
  Pair(this.w, this.a, this.b, this.loc, this.ia, this.ib);
  final World w;
  final AnySyncAccount a;
  final AnySyncAccount b;
  final AnySyncLocation loc;
  final RagIndex ia;
  final RagIndex ib;

  FakeDevice get da => w.device('a');
  FakeDevice get db => w.device('b');
  FakeSpace get sa => da.space(loc.spaceId);
  FakeSpace get sb => db.space(loc.spaceId);

  /// Delivers between the devices and lets both pull.
  Future<void> sync() async {
    w.net.sync(da, db);
    await a.pull(loc);
    await b.pull(loc);
  }
}

Future<Pair> pair(
  World w, {
  FilterSchema? schemaA,
  FilterSchema? schemaB,
  EmbeddingProfile? profileB,
  bool text = false,
}) async {
  final a = await w.open('a');
  final space = await a.createSpace('shared');
  final loc = AnySyncLocation(spaceId: space.id, indexName: 'notes');
  final ia = await openVectors(a, loc, schema: schemaA, text: text);
  final b = await w.open('b');
  w.net.link(w.device('a'), w.device('b'));
  await b.spaces(sync: true);
  final ib = await openVectors(
    b,
    loc,
    schema: schemaB ?? schemaA,
    text: text,
    profile: profileB,
  );
  return Pair(w, a, b, loc, ia, ib);
}

/// Live document objects of [s].
List<FakeObject> docObjects(FakeSpace s) => [
  for (final o in s.objects.values)
    if (o.typeId == docRoot && !o.deleted) o,
];

/// Writes a document object into [s] as a peer would have, bypassing the
/// provider: for formats the provider never writes itself.
FakeObject craftDoc(
  FakeSpace s, {
  required String indexName,
  required String key,
  required int rev,
  String content = 'crafted',
  String? meta,
  String mod = 'text',
  int fmt = 1,
  Object? docOverride,
  Map<String, Object?>? vecs,
  String? id,
}) {
  final o = FakeObject(id ?? s.device.network.newObjectId(), docRoot);
  o.scalars['doc'] = FakeVal(
    docOverride ??
        jsonEncode({
          'fmt': fmt,
          'loc': indexName,
          'key': key,
          'rev': rev,
          'mod': mod,
          'content': content,
          'meta': meta,
        }),
  );
  if (vecs != null) {
    o.leaves['vecs'] = {for (final e in vecs.entries) e.key: FakeVal(e.value)};
  }
  s.objects[o.id] = o;
  s.change(o.id);
  return o;
}

/// The vecs leaf of [profile] for a text location.
String leafKeyOf(EmbeddingProfile profile) =>
    profileLeafKey(profile.id, profile.dimension);

Map<String, Object?> leafValue(List<double> v, String content) =>
    LeafValue.encode(Float32List.fromList(v), sha256Hex(content));

/// The rev written into an object's doc.
int revOf(FakeObject o) =>
    (jsonDecode(o.scalars['doc']!.value! as String) as Map)['rev'] as int;

String contentOf(FakeObject o) =>
    (jsonDecode(o.scalars['doc']!.value! as String) as Map)['content']
        as String;

Future<List<String>> idsOf(RagIndex i, List<double> q, {int topK = 10}) async =>
    [for (final h in await i.searchVector(embedding: q, topK: topK)) h.id];
