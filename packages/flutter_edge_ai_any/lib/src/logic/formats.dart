// The synced data formats of design §2 (Formats, §2.1-§2.3), in one place:
// hashes, leaf keys, the `doc`, `vecs.<h>`, manifest and tombstone values,
// and the rev range. Pure functions over plain data, so they run on any
// isolate and are tested without the native library.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The format version this code writes and fully reads.
const int currentFmt = 1;

/// The largest rev: 2^53 − 2, so `maxSeen + 1` is always a safe JSON
/// integer (design §2 Formats).
const int maxRev = 9007199254740990;

/// A rev more than this far ahead of the local clock is counted in
/// `revsAheadOfClock` (design §7: 5 min).
const int aheadThresholdMs = 5 * 60 * 1000;

/// The two bundles (any_shim.h, rag_bundles).
const locationBundleId = 'flutter_edge_ai.rag.location/v1';
const documentBundleId = 'flutter_edge_ai.rag.document/v1';

/// The manifest object's seed (design §2.1).
String manifestSeed(String indexName) =>
    'flutter_edge_ai.rag/manifest/$indexName';

/// The reserved tombstone record id of clear revs (design §2.3): not 64
/// hex, so it never collides with `sha256(key)`.
const clearRecordId = 'clear';

/// SHA-256 over UTF-8, lowercase hex.
String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// `<h>`: a profile's leaf key, `sha256(v1RecordId ‖ "\n" ‖ dimension)`.
String profileLeafKey(String v1RecordId, int dimension) =>
    sha256Hex('$v1RecordId\n$dimension');

/// `<f>`: a filter field's leaf key, `sha256(name)-type`. Also the key of
/// the field in the local `f.*` normalisation.
String fieldLeafKey(String name, String type) => '${sha256Hex(name)}-$type';

/// Whether [rev] is a rev this format allows.
bool revInRange(Object? rev) => rev is int && rev >= 1 && rev <= maxRev;

// ------------------------------------------------------------------ doc

/// What a reader makes of a `doc` value.
enum DocKind {
  /// fmt 1, every field valid.
  ok,

  /// A higher fmt: unindexable and never overwritten, but `loc`, `key` and
  /// `rev` were readable, so it still takes part in the key map.
  newerFormat,

  /// fmt 1 with a rev out of range.
  revOutOfRange,

  /// Not JSON, or `fmt`/`loc`/`key`/`rev` unreadable.
  malformed,
}

/// A parsed `doc` value.
final class DocValue {
  DocValue({
    required this.kind,
    this.loc,
    this.key,
    this.rev,
    this.mod,
    this.content,
    this.meta,
  });

  final DocKind kind;
  final String? loc;
  final String? key;
  final int? rev;
  final String? mod;
  final String? content;
  final String? meta;

  static DocValue parse(Object? raw) {
    Object? v = raw;
    if (v is String) {
      try {
        v = jsonDecode(v);
      } on FormatException {
        return DocValue(kind: DocKind.malformed);
      }
    }
    if (v is! Map) return DocValue(kind: DocKind.malformed);
    final fmt = v['fmt'];
    final loc = v['loc'];
    final key = v['key'];
    final rev = v['rev'];
    if (fmt is! int || loc is! String || key is! String || key.isEmpty) {
      return DocValue(kind: DocKind.malformed);
    }
    if (fmt > currentFmt) {
      return DocValue(
        kind: revInRange(rev) ? DocKind.newerFormat : DocKind.revOutOfRange,
        loc: loc,
        key: key,
        rev: rev is int ? rev : null,
      );
    }
    if (rev is! int) return DocValue(kind: DocKind.malformed, loc: loc);
    if (!revInRange(rev)) {
      return DocValue(kind: DocKind.revOutOfRange, loc: loc, key: key);
    }
    final mod = v['mod'];
    final content = v['content'];
    final meta = v['meta'];
    if (fmt < 1 ||
        mod is! String ||
        content is! String ||
        (meta != null && meta is! String)) {
      return DocValue(kind: DocKind.malformed, loc: loc, key: key, rev: rev);
    }
    return DocValue(
      kind: DocKind.ok,
      loc: loc,
      key: key,
      rev: rev,
      mod: mod,
      content: content,
      meta: meta as String?,
    );
  }

  /// The `doc` property value, as the string it is stored as.
  static String encode({
    required String loc,
    required String key,
    required int rev,
    required String mod,
    required String content,
    required String? meta,
  }) => jsonEncode({
    'fmt': currentFmt,
    'loc': loc,
    'key': key,
    'rev': rev,
    'mod': mod,
    'content': content,
    'meta': meta,
  });
}

/// The hash a document's meta is compared by (S1): absent meta and an
/// empty string are different values.
String metaHash(String? meta) => meta == null ? '-' : sha256Hex('m:$meta');

// ----------------------------------------------------------------- vecs

/// What a reader makes of a `vecs.<h>` leaf under this device's profile.
enum LeafKind { ok, missing, badVector, wrongDimension, newerFormat }

/// A parsed vector leaf.
final class LeafValue {
  LeafValue(this.kind, {this.ch, this.vector});
  final LeafKind kind;
  final String? ch;
  final Float32List? vector;

  static LeafValue parse(Object? raw, int dimension) {
    if (raw == null) return LeafValue(LeafKind.missing);
    Object? v = raw;
    if (v is String) {
      try {
        v = jsonDecode(v);
      } on FormatException {
        return LeafValue(LeafKind.badVector);
      }
    }
    if (v is! Map) return LeafValue(LeafKind.badVector);
    final fmt = v['fmt'];
    if (fmt is int && fmt > currentFmt) {
      final ch = v['ch'];
      return LeafValue(LeafKind.newerFormat, ch: ch is String ? ch : null);
    }
    final dim = v['dim'];
    final ch = v['ch'];
    final enc = v['enc'];
    final vec = v['vec'];
    if (fmt != currentFmt ||
        dim is! int ||
        ch is! String ||
        enc != 'f32le-b64' ||
        vec is! String) {
      return LeafValue(LeafKind.badVector, ch: ch is String ? ch : null);
    }
    if (dim != dimension) return LeafValue(LeafKind.wrongDimension, ch: ch);
    final decoded = decodeVector(vec, dim);
    if (decoded == null || vectorProblem(decoded) != null) {
      return LeafValue(LeafKind.badVector, ch: ch);
    }
    return LeafValue(LeafKind.ok, ch: ch, vector: decoded);
  }

  static Map<String, Object?> encode(Float32List vector, String ch) => {
    'fmt': currentFmt,
    'dim': vector.length,
    'enc': 'f32le-b64',
    'ch': ch,
    'vec': encodeVector(vector),
  };
}

/// Little-endian float32, standard base64 with padding.
String encodeVector(Float32List v) {
  final bytes = ByteData(v.length * 4);
  for (var i = 0; i < v.length; i++) {
    bytes.setFloat32(i * 4, v[i], Endian.little);
  }
  return base64.encode(bytes.buffer.asUint8List());
}

/// The vector, or null when the text is not base64 of exactly [dim] finite
/// float32 values.
Float32List? decodeVector(String b64, int dim) {
  final Uint8List bytes;
  try {
    bytes = base64.decode(b64);
  } on FormatException {
    return null;
  }
  if (bytes.length != dim * 4) return null;
  final data = ByteData.sublistView(bytes);
  final out = Float32List(dim);
  for (var i = 0; i < dim; i++) {
    final x = data.getFloat32(i * 4, Endian.little);
    if (!x.isFinite) return null;
    out[i] = x;
  }
  return out;
}

/// The largest squared L2 norm a vector may have: what the shim refuses
/// beyond (MaxFloat32 / 8), so the index never meets a vector its cosine
/// would overflow on.
const double maxSquaredNorm = 3.4028234663852886e38 / 8;

/// Why [v] cannot be stored, or null: a value that is not finite, or a
/// squared norm above [maxSquaredNorm].
String? vectorProblem(Float32List v) {
  var sq = 0.0;
  for (final x in v) {
    if (!x.isFinite) return 'not finite';
    sq += x * x;
  }
  if (!sq.isFinite || sq > maxSquaredNorm) return 'norm too large';
  return null;
}

/// [values] as float32, or null when [vectorProblem] refuses them.
Float32List? finiteFloat32(List<double> values) {
  final out = Float32List.fromList(values);
  return vectorProblem(out) == null ? out : null;
}

// -------------------------------------------------------------- manifest

/// One `fields.<f>` leaf.
final class FieldLeaf {
  const FieldLeaf(this.name, this.type);
  final String name;
  final String type;

  String get key => fieldLeafKey(name, type);

  Map<String, Object?> toJson() => {
    'fmt': currentFmt,
    'name': name,
    'type': type,
  };
}

/// One `profiles.<h>` leaf.
final class ProfileLeaf {
  const ProfileLeaf(this.id, this.dimension, this.documents);
  final String id;
  final int dimension;
  final String documents;

  String get v1RecordId => documents == 'text' ? id : '$id\u001F$documents';
  String get key => profileLeafKey(v1RecordId, dimension);

  Map<String, Object?> toJson() => {
    'fmt': currentFmt,
    'id': id,
    'dimension': dimension,
    'documents': documents,
  };
}

/// The manifest as a reader sees it (design §2.1): only leaves whose value
/// hashes to their key count; the others are counted in [ignoredLeaves].
/// `core` is object-kind, one leaf per modality (`core.DOCUMENTS =
/// {"fmt":1}`): two leaves are a conflict every reader sees.
final class ManifestRead {
  ManifestRead({
    required this.coreLeaves,
    this.coreNewerFormat = false,
    this.fields = const [],
    this.profiles = const [],
    this.textSearch = false,
    this.ignoredLeaves = 0,
  });

  /// The modalities `core` names, sorted.
  final List<String> coreLeaves;
  final bool coreNewerFormat;
  final List<FieldLeaf> fields;
  final List<ProfileLeaf> profiles;
  final bool textSearch;
  final int ignoredLeaves;

  /// Whether `core` is there (the manifest was published).
  bool get present => coreLeaves.isNotEmpty;

  /// The one modality, or null when absent or when two were published.
  String? get documents => coreLeaves.length == 1 ? coreLeaves.single : null;

  static final absent = ManifestRead(coreLeaves: const []);

  static final _modalityLeaf = RegExp(r'^[a-z][a-z0-9-]{0,31}$');

  /// From the props of an object_read item (`core`, `fields`, `profiles`,
  /// `textSearch`).
  static ManifestRead fromProps(Map<String, Object?>? props) {
    if (props == null) return absent;
    var ignored = 0;
    final core = <String>[];
    var newer = false;
    final c = _jsonValue(props['core']);
    if (c is Map) {
      for (final MapEntry(:key, :value) in c.entries) {
        final v = _jsonValue(value);
        final fmt = v is Map ? v['fmt'] : null;
        if (key is! String || !_modalityLeaf.hasMatch(key) || fmt is! int) {
          ignored++;
          continue;
        }
        if (fmt > currentFmt) newer = true;
        core.add(key);
      }
    }
    final fields = <FieldLeaf>[];
    final f = _jsonValue(props['fields']);
    if (f is Map) {
      for (final MapEntry(:key, :value) in f.entries) {
        final v = _jsonValue(value);
        if (v is Map &&
            v['name'] is String &&
            v['type'] is String &&
            (v['fmt'] is int && (v['fmt'] as int) <= currentFmt) &&
            fieldLeafKey(v['name'] as String, v['type'] as String) == key) {
          fields.add(FieldLeaf(v['name'] as String, v['type'] as String));
        } else {
          ignored++;
        }
      }
    }
    final profiles = <ProfileLeaf>[];
    final p = _jsonValue(props['profiles']);
    if (p is Map) {
      for (final MapEntry(:key, :value) in p.entries) {
        final v = _jsonValue(value);
        if (v is Map &&
            v['id'] is String &&
            v['dimension'] is int &&
            v['documents'] is String &&
            (v['fmt'] is int && (v['fmt'] as int) <= currentFmt)) {
          final leaf = ProfileLeaf(
            v['id'] as String,
            v['dimension'] as int,
            v['documents'] as String,
          );
          if (leaf.key == key) {
            profiles.add(leaf);
            continue;
          }
        }
        ignored++;
      }
    }
    core.sort();
    fields.sort((a, b) => a.key.compareTo(b.key));
    profiles.sort((a, b) => a.key.compareTo(b.key));
    final t = _jsonValue(props['textSearch']);
    return ManifestRead(
      coreLeaves: core,
      coreNewerFormat: newer,
      fields: fields,
      profiles: profiles,
      textSearch: t is Map && t['on'] == true,
      ignoredLeaves: ignored,
    );
  }

  Map<String, Object?> toJson() => {
    'present': present,
    'documents': documents,
    'core': coreLeaves,
    'coreNewerFormat': coreNewerFormat,
    'fields': [
      for (final f in fields) {'name': f.name, 'type': f.type},
    ],
    'profiles': [
      for (final p in profiles)
        {'id': p.id, 'dimension': p.dimension, 'documents': p.documents},
    ],
    'textSearch': textSearch,
    'ignoredLeaves': ignoredLeaves,
  };

  static ManifestRead fromJson(Map<String, Object?> j) => ManifestRead(
    coreLeaves: [for (final c in (j['core'] as List? ?? const [])) c as String],
    coreNewerFormat: j['coreNewerFormat'] == true,
    fields: [
      for (final f in (j['fields'] as List? ?? const []))
        FieldLeaf((f as Map)['name'] as String, f['type'] as String),
    ],
    profiles: [
      for (final p in (j['profiles'] as List? ?? const []))
        ProfileLeaf(
          (p as Map)['id'] as String,
          p['dimension'] as int,
          p['documents'] as String,
        ),
    ],
    textSearch: j['textSearch'] == true,
    ignoredLeaves: j['ignoredLeaves'] as int? ?? 0,
  );
}

/// A property value that may arrive as JSON text or already decoded.
Object? _jsonValue(Object? v) {
  if (v is String) {
    try {
      return jsonDecode(v);
    } on FormatException {
      return v;
    }
  }
  return v;
}

/// The `core` leaf op of [documents].
Map<String, Object?> coreOp(String documents) => {
  'xkey': 'core',
  'leaf': documents,
  'value': {'fmt': currentFmt},
};

/// The `textSearch.on` op (only ever true).
const Map<String, Object?> textSearchOp = {
  'xkey': 'textSearch',
  'leaf': 'on',
  'value': true,
};

// ------------------------------------------------------------ tombstones

/// One tombstone record as read: the key's revs (only in-range ones), or a
/// record that failed its check (`sha256(key) != id`).
final class TombRecord {
  TombRecord({
    required this.id,
    required this.key,
    required this.maxRev,
    required this.valid,
    required this.revs,
    this.badRevs = 0,
  });

  final String id;
  final String? key;
  final int maxRev;
  final bool valid;
  final List<int> revs;

  /// Revs out of range (or not integers): ignored, counted.
  final int badRevs;

  bool get isClear => id == clearRecordId;

  static TombRecord parse(Map<String, Object?> r) {
    final id = (r['id'] ?? r['_id']) as String? ?? '';
    final key = r['key'];
    final raw = r['revs'] is List ? r['revs'] as List : const [];
    final revs = <int>[
      for (final x in raw)
        if (revInRange(x)) x as int,
    ];
    final bad = raw.length - revs.length;
    final max = revs.isEmpty ? 0 : revs.reduce((a, b) => a > b ? a : b);
    if (id == clearRecordId) {
      return TombRecord(
        id: id,
        key: null,
        maxRev: max,
        valid: true,
        revs: revs,
        badRevs: bad,
      );
    }
    final valid = key is String && sha256Hex(key) == id;
    return TombRecord(
      id: id,
      key: key is String ? key : null,
      maxRev: max,
      valid: valid,
      revs: revs,
      badRevs: bad,
    );
  }
}
