// The facts the model registry reads from a model file's own bytes: the NPU
// each compiled model targets (the compiler's stamp), and for a `.litertlm`
// the context its LlmMetadata sets, the KV-cache length its prefill/decode
// graph is built for, and its sections. It runs this package's readers, so the
// registry and the loader cannot disagree about a file.
//
// The readers touch only the container header, the LlmMetadata section and a
// few hundred bytes per compiled model, so the file is read over HTTP range
// requests: no multi-gigabyte download. A `.tflite` file is one model, and
// only its stamp is read.
//
// Skipped unless INSPECT_FILES names a JSON list of
// {"sha256", "url", "size"}; writes <INSPECT_OUT>/<sha256>.json for each
// (INSPECT_FORCE=1 rewrites existing ones). A
// gated repository needs HF_TOKEN, which is sent only to huggingface.co.
//
//   cd packages/flutter_edge_ai_litertlm
//   INSPECT_FILES=/tmp/files.json INSPECT_OUT=../../model_registry/derived \
//     flutter test test/catalog/inspect_bundle_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/bundle/litertlm_bundle_info.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_npu_target.dart';
import 'package:flutter_edge_ai_litertlm/src/litertlm_bundle_sampler.dart'
    show llmMetadataRange;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final listing = Platform.environment['INSPECT_FILES'];
  final out = Platform.environment['INSPECT_OUT'];
  // Re-read files that already have facts (after the facts grow a field).
  final force = Platform.environment['INSPECT_FORCE'] == '1';

  test(
    'inspect .litertlm bundles over HTTP',
    () async {
      final files = (jsonDecode(File(listing!).readAsStringSync()) as List)
          .cast<Map<String, Object?>>();
      final client = HttpClient()..autoUncompress = false;
      try {
        for (final f in files) {
          final sha = f['sha256']! as String;
          final target = File('$out/$sha.json');
          if (target.existsSync() && !force) continue;
          final remote = await _RemoteFile.open(
            client,
            Uri.parse(f['url']! as String),
            f['size']! as int,
          );
          Map<String, Object?> facts;
          try {
            facts = (f['url']! as String).endsWith('.tflite')
                ? await _inspectTflite(remote)
                : await _inspect(remote, f['url']! as String);
          } on LiteRtLmBundleException catch (e) {
            // A fact about the file, recorded for the registry to act on.
            final head = await remote.readAt(0, 16);
            facts = {
              'size': f['size'],
              'problem': e.problem.name,
              'message': e.message,
              'first_bytes_hex': [
                for (final b in head) b.toRadixString(16).padLeft(2, '0'),
              ].join(),
            };
          }
          target
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '${const JsonEncoder.withIndent('  ').convert(facts)}\n',
            );
          // ignore: avoid_print
          print('$sha ${remote.fetched} bytes fetched ${f['url']}');
        }
      } finally {
        client.close(force: true);
      }
    },
    skip: listing == null || out == null
        ? 'set INSPECT_FILES and INSPECT_OUT to inspect bundles'
        : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

Future<Map<String, Object?>> _inspect(_RemoteFile file, String url) async {
  final length = await file.length();
  final preamble = await file.readAt(0, 32);
  final version = litertlmContainerVersion(preamble, path: url);
  final view = ByteData.sublistView(preamble);
  final headerEnd = view.getUint32(24, Endian.little);
  final header = await file.readAt(32, headerEnd - 32);
  final sections = parseLitertlmHeader(
    header,
    version: version,
    fileLength: length,
    path: url,
  ).sections;
  final stamps = await readLiteRtLmSectionStamps(file, length, [
    for (final s in sections)
      if (s.dataType == 'TFLiteModel') (s.begin, s.end),
  ]);
  final info = parseLitertlmHeader(
    header,
    version: version,
    fileLength: length,
    npuTargets: stamps,
    path: url,
  );
  int? maxNumTokens;
  final metadata = llmMetadataRange(header);
  if (metadata != null) {
    final (begin, end) = metadata;
    maxNumTokens = _int32Field(await file.readAt(begin, end - begin), 5);
  }
  final targets = {
    for (final s in info.sections)
      if (s.npuTarget case final t?) '${t.vendor}/${t.soc}',
  };
  // The KV-cache inputs of the prefill/decode graph: an NPU build is compiled
  // for one cache length, and its shape is where that length is written.
  final signatures = <String, Object?>{};
  for (final s in info.sections) {
    if (s.dataType != 'TFLiteModel' ||
        s.modelType != 'tf_lite_prefill_decode') {
      continue;
    }
    signatures.addAll(await _cacheInputs(_Fb(file, s.begin)));
  }
  return {
    'container_version': '${version.major}.${version.minor}.${version.patch}',
    'size': length,
    'npu_target': targets.isEmpty ? null : targets.single,
    'llm_metadata_max_num_tokens': maxNumTokens,
    'kv_cache_length': ?_kvCacheLength(signatures),
    if (signatures.isNotEmpty) 'prefill_decode_signatures': signatures,
    'system_metadata': info.systemMetadata,
    'sections': [
      for (final s in info.sections)
        {
          'data_type': s.dataType,
          'model_type': ?s.modelType,
          'backend_constraint': ?s.backendConstraint,
          'length': s.length,
          'npu_target': ?(s.npuTarget == null
              ? null
              : '${s.npuTarget!.vendor}/${s.npuTarget!.soc}'),
          if (s.items.isNotEmpty) 'items': s.items,
        },
    ],
  };
}

/// The stamp of a `.tflite` file: the whole file is one TFLite model.
Future<Map<String, Object?>> _inspectTflite(_RemoteFile file) async {
  final length = await file.length();
  final stamps = await readLiteRtLmSectionStamps(file, length, [(0, length)]);
  final target = stamps.values.single;
  return {
    'size': length,
    'npu_target': target == null ? null : '${target.vendor}/${target.soc}',
  };
}

/// The cache length the `decode` signature's KV-cache inputs are built for:
/// the largest dimension of each input's shape (`[1, kv heads, length, head
/// dim]`, or with the last two swapped), when every input agrees on it.
int? _kvCacheLength(Map<String, Object?> signatures) {
  final decode = signatures['decode'];
  if (decode is! Map || decode.isEmpty) return null;
  final lengths = {
    for (final shape in decode.values)
      (shape as List).cast<int>().reduce((a, b) => a > b ? a : b),
  };
  return lengths.length == 1 ? lengths.single : null;
}

/// Per signature of a TFLite model: its first KV-cache inputs and their
/// shapes, `{signature: {input name: shape}}`.
Future<Map<String, Object?>> _cacheInputs(_Fb fb) async {
  final root = await fb.root();
  final subgraphs = await fb.vector(root, 2); // Model.subgraphs
  final signatureDefs = await fb.vector(root, 7); // Model.signature_defs
  if (subgraphs == null || signatureDefs == null) return const {};
  final result = <String, Object?>{};
  for (var i = 0; i < await fb.length(signatureDefs); i++) {
    final signature = await fb.element(signatureDefs, i);
    final key = await fb.string(signature, 2) ?? 'signature$i'; // signature_key
    final subgraphIndex = await fb.scalarU32(signature, 4); // subgraph_index
    final subgraph = await fb.element(subgraphs, subgraphIndex);
    final tensors = await fb.vector(subgraph, 0); // SubGraph.tensors
    final inputs = await fb.vector(signature, 0); // SignatureDef.inputs
    if (tensors == null || inputs == null) continue;
    final caches = <String, Object?>{};
    for (var j = 0; j < await fb.length(inputs) && caches.length < 2; j++) {
      final input = await fb.element(inputs, j);
      final name = await fb.string(input, 0) ?? ''; // TensorMap.name
      if (!name.toLowerCase().contains('cache')) continue;
      final tensor = await fb.element(tensors, await fb.scalarU32(input, 1));
      final shape = await fb.vector(tensor, 0); // Tensor.shape
      caches[name] = [
        if (shape != null)
          for (var k = 0; k < await fb.length(shape); k++)
            await fb.i32(shape + 4 + 4 * k),
      ];
    }
    result[key] = caches;
  }
  return result;
}

/// A flatbuffer read through [_RemoteFile], rooted at [base].
final class _Fb {
  _Fb(this._file, this._base);

  final _RemoteFile _file;
  final int _base;

  Future<int> _u32(int at) async => ByteData.sublistView(
    await _file.readAt(at, 4),
  ).getUint32(0, Endian.little);
  Future<int> i32(int at) async => ByteData.sublistView(
    await _file.readAt(at, 4),
  ).getInt32(0, Endian.little);
  Future<int> _u16(int at) async => ByteData.sublistView(
    await _file.readAt(at, 2),
  ).getUint16(0, Endian.little);

  Future<int> root() async => _base + await _u32(_base);

  Future<int?> _field(int table, int index) async {
    final vtable = table - await i32(table);
    final vtableSize = await _u16(vtable);
    final slot = 4 + 2 * index;
    if (slot >= vtableSize) return null;
    final offset = await _u16(vtable + slot);
    return offset == 0 ? null : table + offset;
  }

  Future<int?> vector(int table, int index) async {
    final at = await _field(table, index);
    return at == null ? null : at + await _u32(at);
  }

  Future<int> length(int vector) => _u32(vector);

  Future<int> element(int vector, int i) async {
    final at = vector + 4 + 4 * i;
    return at + await _u32(at);
  }

  Future<String?> string(int table, int index) async {
    final at = await vector(table, index);
    if (at == null) return null;
    return utf8.decode(await _file.readAt(at + 4, await _u32(at)));
  }

  Future<int> scalarU32(int table, int index) async {
    final at = await _field(table, index);
    return at == null ? 0 : _u32(at);
  }
}

/// Field [number] of a serialized proto message as a varint, or null when the
/// message does not set it (proto3 omits a zero).
int? _int32Field(Uint8List message, int number) {
  var i = 0;
  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = message[i++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) return result;
      shift += 7;
    }
  }

  while (i < message.length) {
    final key = varint();
    final field = key >> 3;
    switch (key & 7) {
      case 0:
        final value = varint();
        if (field == number) return value;
      case 1:
        i += 8;
      case 2:
        // Not `i += varint()`: that reads `i` before varint() advances it.
        final length = varint();
        i += length;
      case 5:
        i += 4;
      default:
        throw FormatException('wire type ${key & 7} in LlmMetadata');
    }
  }
  return null;
}

/// A remote file read by HTTP range requests, cached in 64 KB blocks. Only the
/// methods the readers call are implemented.
final class _RemoteFile implements RandomAccessFile {
  _RemoteFile._(this._client, this._url, this._length);

  static Future<_RemoteFile> open(HttpClient client, Uri url, int size) async {
    // Resolve the Hugging Face redirects with the token, if any. The first URL
    // off huggingface.co is a signed CDN URL: it is used as it is, with no
    // token and no HEAD of its own.
    var current = url;
    for (var hops = 0; hops < 5; hops++) {
      if (current.host != 'huggingface.co') {
        return _RemoteFile._(client, current, size);
      }
      final request = await client.headUrl(current);
      request.followRedirects = false;
      final token = Platform.environment['HF_TOKEN'];
      if (token != null) request.headers.set('Authorization', 'Bearer $token');
      final response = await request.close();
      await response.drain<void>();
      if (response.isRedirect) {
        current = current.resolve(response.headers.value('location')!);
        continue;
      }
      if (response.statusCode != 200) {
        throw HttpException('HEAD ${response.statusCode}', uri: current);
      }
      return _RemoteFile._(client, current, size);
    }
    throw HttpException('too many redirects', uri: url);
  }

  static const _block = 64 * 1024;

  final HttpClient _client;
  final Uri _url;
  final int _length;
  final _blocks = <int, Uint8List>{};
  int _position = 0;
  int fetched = 0;

  Future<Uint8List> _blockAt(int index) async {
    final cached = _blocks[index];
    if (cached != null) return cached;
    final start = index * _block;
    final end = (start + _block < _length ? start + _block : _length) - 1;
    final request = await _client.getUrl(_url);
    if (_url.host == 'huggingface.co') {
      final token = Platform.environment['HF_TOKEN'];
      if (token != null) request.headers.set('Authorization', 'Bearer $token');
    }
    request.headers.set('Range', 'bytes=$start-$end');
    final response = await request.close();
    if (response.statusCode != 206) {
      await response.drain<void>();
      throw HttpException(
        'range $start-$end: ${response.statusCode}',
        uri: _url,
      );
    }
    final builder = BytesBuilder(copy: false);
    await response.forEach(builder.add);
    final bytes = builder.takeBytes();
    if (bytes.length != end - start + 1) {
      throw HttpException(
        'range $start-$end: ${bytes.length} bytes',
        uri: _url,
      );
    }
    fetched += bytes.length;
    return _blocks[index] = bytes;
  }

  Future<Uint8List> readAt(int position, int count) async {
    final end = position + count > _length ? _length : position + count;
    final out = BytesBuilder(copy: false);
    for (var at = position; at < end;) {
      final index = at ~/ _block;
      final block = await _blockAt(index);
      final offset = at - index * _block;
      final take = (end - at) < (block.length - offset)
          ? end - at
          : block.length - offset;
      out.add(Uint8List.sublistView(block, offset, offset + take));
      at += take;
    }
    return out.takeBytes();
  }

  @override
  Future<int> length() async => _length;

  @override
  Future<int> position() async => _position;

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    _position = position;
    return this;
  }

  @override
  Future<Uint8List> read(int count) async {
    final bytes = await readAt(_position, count);
    _position += bytes.length;
    return bytes;
  }

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async {
    final bytes = await read((end ?? buffer.length) - start);
    buffer.setRange(start, start + bytes.length, bytes);
    return bytes.length;
  }

  @override
  Future<void> close() async {}

  @override
  String get path => _url.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'RemoteFile does not implement ${invocation.memberName}',
  );
}
