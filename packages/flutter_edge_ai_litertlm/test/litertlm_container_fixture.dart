// Builds small `.litertlm` containers for tests: the 32-byte preamble, a
// header flatbuffer listing the sections, and TFLite-model sections that carry
// only what `readLiteRtLmNpuTarget` reads (`Model.metadata`, `Model.buffers`).
// Real EmbeddingGemma 2 bundles are 165-900 MB; the layouts here follow
// LiteRT-LM's `litertlm_header_schema.fbs` (pin b2f686e2) and TFLite's
// `schema.fbs`, and the reader is also run on the real bundles
// (litertlm_npu_target_test.dart, opt-in).

import 'dart:convert';
import 'dart:typed_data';

/// A flatbuffer value: a table, a vector of tables, a string, a byte vector,
/// or an inline scalar.
sealed class Fb {}

final class FbTable extends Fb {
  FbTable(this.fields);

  /// Field index → value. Scalars are inline; the others are references.
  final Map<int, Fb> fields;
}

final class FbTables extends Fb {
  FbTables(this.items);
  final List<FbTable> items;
}

final class FbString extends Fb {
  FbString(this.value);
  final String value;
}

final class FbBytes extends Fb {
  FbBytes(this.value);
  final List<int> value;
}

final class FbU8 extends Fb {
  FbU8(this.value);
  final int value;
}

final class FbU32 extends Fb {
  FbU32(this.value);
  final int value;
}

final class FbU64 extends Fb {
  FbU64(this.value);
  final int value;
}

/// Serializes [root] front to back: the root offset at 0, then every object
/// before the objects it references, so every reference points forward (as
/// flatbuffers' unsigned offsets require).
Uint8List buildFlatBuffer(FbTable root) {
  final out = BytesBuilder();
  final patches = <(int, Fb)>[]; // (position of a uoffset, its target)
  final placed = <Fb, int>{};

  void pad() {
    while (out.length % 4 != 0) {
      out.addByte(0);
    }
  }

  void u16(int v) => out.add(
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List(),
  );
  void u32(int v) => out.add(
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
  );
  void i32(int v) => out.add(
    (ByteData(4)..setInt32(0, v, Endian.little)).buffer.asUint8List(),
  );
  void u64(int v) => out.add(
    (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List(),
  );

  int place(Fb object) {
    pad();
    switch (object) {
      case FbTable(:final fields):
        final indices = fields.keys.toList()..sort();
        final count = indices.isEmpty ? 0 : indices.last + 1;
        final offsets = List<int>.filled(count, 0);
        var inline = 4;
        for (final i in indices) {
          offsets[i] = inline;
          inline += switch (fields[i]!) {
            FbU8() => 1,
            FbU64() => 8,
            _ => 4,
          };
        }
        final vtable = out.length;
        u16(4 + 2 * count);
        u16(inline);
        offsets.forEach(u16);
        pad();
        final table = out.length;
        i32(table - vtable);
        for (final i in indices) {
          switch (fields[i]!) {
            case FbU8(:final value):
              out.addByte(value);
            case FbU32(:final value):
              u32(value);
            case FbU64(:final value):
              u64(value);
            case final reference:
              patches.add((out.length, reference));
              u32(0);
          }
        }
        return table;
      case FbTables(:final items):
        final at = out.length;
        u32(items.length);
        for (final item in items) {
          patches.add((out.length, item));
          u32(0);
        }
        return at;
      case FbString(:final value):
        final at = out.length;
        final bytes = utf8.encode(value);
        u32(bytes.length);
        out
          ..add(bytes)
          ..addByte(0);
        return at;
      case FbBytes(:final value):
        final at = out.length;
        u32(value.length);
        out.add(value);
        return at;
      case FbU8() || FbU32() || FbU64():
        throw ArgumentError('a scalar is inline, not referenced');
    }
  }

  u32(0); // the root offset, patched below
  patches.add((0, root));
  var next = 0;
  while (next < patches.length) {
    final (_, target) = patches[next++];
    placed[target] ??= place(target);
  }
  final bytes = out.toBytes();
  final data = ByteData.sublistView(bytes);
  for (final (at, target) in patches) {
    data.setUint32(at, placed[target]! - at, Endian.little);
  }
  return bytes;
}

/// A `LiteRtStamp` buffer: the SoC manufacturer and model, NUL-padded to 125
/// bytes each (LiteRT `build_stamp.h`).
Uint8List liteRtStamp(String vendor, String soc) {
  final stamp = Uint8List(250);
  stamp.setAll(0, ascii.encode(vendor));
  stamp.setAll(125, ascii.encode(soc));
  return stamp;
}

/// A TFLite model flatbuffer with metadata [entries] (name → buffer bytes),
/// each in its own `Buffer.data`, after an empty buffer 0 as TFLite keeps it.
/// With [appended], the buffers hold `offset`/`size` instead and the bytes
/// follow the flatbuffer, as large-model exports store them.
Uint8List tfliteModel(Map<String, List<int>> entries, {bool appended = false}) {
  final names = entries.keys.toList();
  if (!appended) {
    return buildFlatBuffer(
      FbTable({
        0: FbU32(3),
        4: FbTables([
          FbTable({}),
          for (final name in names) FbTable({0: FbBytes(entries[name]!)}),
        ]),
        6: FbTables([
          for (var i = 0; i < names.length; i++)
            FbTable({0: FbString(names[i]), 1: FbU32(i + 1)}),
        ]),
      }),
    );
  }
  // Two passes: the flatbuffer's size fixes where the appended bytes start.
  Uint8List build(int dataStart) {
    final offsets = <int>[];
    var offset = dataStart;
    for (final name in names) {
      offsets.add(offset);
      offset += entries[name]!.length;
    }
    return buildFlatBuffer(
      FbTable({
        0: FbU32(3),
        4: FbTables([
          FbTable({}),
          for (var i = 0; i < names.length; i++)
            FbTable({
              1: FbU64(offsets[i]),
              2: FbU64(entries[names[i]]!.length),
            }),
        ]),
        6: FbTables([
          for (var i = 0; i < names.length; i++)
            FbTable({0: FbString(names[i]), 1: FbU32(i + 1)}),
        ]),
      }),
    );
  }

  final size = build(0).length;
  final model = build(size);
  return Uint8List.fromList([
    ...model,
    for (final name in names) ...entries[name]!,
  ]);
}

/// One section of a container: its data type (`AnySectionDataType`), its
/// `model_type` item when it has one, and its bytes.
typedef Section = ({int type, String? modelType, List<int> bytes});

/// `AnySectionDataType` values used here.
const sectionTfliteModel = 3;
const sectionSpTokenizer = 4;
const sectionTfliteWeights = 7;
const sectionEmbeddingMetadata = 8;

/// A header key-value item: a `StringValue`, a `Bool` or a `UInt32`.
FbTable _keyValue(String key, Object value) => switch (value) {
  final String v => FbTable({
    0: FbString(key),
    1: FbU8(9), // VData.StringValue
    2: FbTable({0: FbString(v)}),
  }),
  final bool v => FbTable({
    0: FbString(key),
    1: FbU8(8), // VData.Bool
    2: FbTable({0: FbU8(v ? 1 : 0)}),
  }),
  final int v => FbTable({
    0: FbString(key),
    1: FbU8(5), // VData.UInt32
    2: FbTable({0: FbU32(v)}),
  }),
  _ => throw ArgumentError.value(value, key),
};

/// A `.litertlm` container holding [sections], in order. [items] adds
/// key-value items to the section at each index, after its `model_type`;
/// [system] replaces the system metadata (`author: test`).
Uint8List litertlmContainer(
  List<Section> sections, {
  Map<int, Map<String, Object>> items = const {},
  Map<String, Object> system = const {'author': 'test'},
}) {
  // The header's size depends on the section offsets only through their
  // values, not their encoding, so build it once with placeholders to learn
  // its length, then again with the real offsets.
  Uint8List header(List<(int, int)> ranges) => buildFlatBuffer(
    FbTable({
      0: FbTable({
        0: FbTables([
          for (final MapEntry(:key, :value) in system.entries)
            _keyValue(key, value),
        ]),
      }),
      1: FbTable({
        0: FbTables([
          for (var i = 0; i < sections.length; i++)
            FbTable({
              0: FbTables([
                if (sections[i].modelType case final modelType?)
                  _keyValue('model_type', modelType),
                for (final MapEntry(:key, :value)
                    in (items[i] ?? const <String, Object>{}).entries)
                  _keyValue(key, value),
              ]),
              1: FbU64(ranges[i].$1),
              2: FbU64(ranges[i].$2),
              3: FbU8(sections[i].type),
            }),
        ]),
      }),
    }),
  );

  final length = header([for (final _ in sections) (0, 0)]).length;
  final headerEnd = 32 + length;
  var at = (headerEnd + 15) & ~15;
  final ranges = <(int, int)>[];
  for (final section in sections) {
    ranges.add((at, at + section.bytes.length));
    at = (at + section.bytes.length + 15) & ~15;
  }
  final out = Uint8List(at);
  out.setAll(0, ascii.encode('LITERTLM'));
  ByteData.sublistView(out)
    ..setUint32(8, 1, Endian.little)
    ..setUint32(12, 7, Endian.little)
    ..setUint32(16, 0, Endian.little)
    ..setUint64(24, headerEnd, Endian.little);
  out.setAll(32, header(ranges));
  for (var i = 0; i < sections.length; i++) {
    out.setAll(ranges[i].$1, sections[i].bytes);
  }
  return out;
}

/// An EmbeddingGemma 2-shaped container: metadata, tokenizer, embedder,
/// text encoder (stamped for [textStamp] when given), optionally a vision
/// encoder (stamped for [visionStamp]) and an audio encoder with its adapter
/// (the 740m's section types), and the embedder's weights.
Uint8List eg2Container({
  (String, String)? textStamp,
  bool vision = false,
  (String, String)? visionStamp,
  bool audio = false,
  bool appendedStamp = false,
}) {
  Uint8List model((String, String)? stamp) => tfliteModel({
    'min_runtime_version': ascii.encode('2.17.0'),
    if (stamp != null) 'LiteRtStamp': liteRtStamp(stamp.$1, stamp.$2),
    'CONVERSION_METADATA': List.filled(96, 1),
  }, appended: appendedStamp);
  return litertlmContainer([
    (type: sectionEmbeddingMetadata, modelType: null, bytes: [1, 2, 3]),
    (type: sectionSpTokenizer, modelType: null, bytes: List.filled(64, 7)),
    (
      type: sectionTfliteModel,
      modelType: 'tf_lite_embedder',
      bytes: model(null),
    ),
    (
      type: sectionTfliteModel,
      modelType: 'tf_lite_text_encoder',
      bytes: model(textStamp),
    ),
    if (vision)
      (
        type: sectionTfliteModel,
        modelType: 'tf_lite_vision_encoder',
        bytes: model(visionStamp),
      ),
    if (audio) ...[
      (
        type: sectionTfliteModel,
        modelType: 'tf_lite_audio_encoder_hw',
        bytes: model(null),
      ),
      (
        type: sectionTfliteModel,
        modelType: 'tf_lite_audio_adapter',
        bytes: model(null),
      ),
    ],
    (
      type: sectionTfliteWeights,
      modelType: 'tf_lite_embedder',
      bytes: List.filled(128, 9),
    ),
  ]);
}
