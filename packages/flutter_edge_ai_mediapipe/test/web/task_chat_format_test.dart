// Reading the chat format out of a `.task` file's TFLite metadata.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/task_chat_format.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/web_chat_template.dart';
import 'package:flutter_edge_ai_mediapipe/src/web/web_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

// --- A TFLite-shaped flatbuffer, written by hand. ---------------------------

Uint8List _varint(int n) {
  final out = <int>[];
  while (n >= 0x80) {
    out.add((n & 0x7f) | 0x80);
    n >>= 7;
  }
  out.add(n);
  return Uint8List.fromList(out);
}

Uint8List _field(int number, List<int> bytes) => Uint8List.fromList([
  ..._varint(number << 3 | 2),
  ..._varint(bytes.length),
  ...bytes,
]);

Uint8List _llmParameters({bool runtime = false, bool flat = true}) =>
    Uint8List.fromList([
      ..._field(5, utf8.encode('<eos>')),
      if (flat) ..._field(11, utf8.encode('<|turn>user\n')),
      if (flat) ..._field(13, utf8.encode('<|turn>model\n')),
      if (flat) ..._field(14, utf8.encode('<turn|>\n')),
      if (runtime) ..._field(17, [0x0a, 0x00]),
    ]);

/// Model { buffers (field 4): [Buffer], metadata (field 6): [Metadata{name,
/// buffer: 0}] }, laid out front to back because a FlatBuffers offset only
/// points forward. A large-file buffer keeps its bytes behind an offset and a
/// size (fields 1 and 2); an inline one has a data vector (field 0).
Uint8List _task(
  Uint8List params, {
  String name = 'odml.infra.proto.LlmParameters',
  bool inline = false,
}) {
  final nameBytes = utf8.encode(name);
  // Fixed positions, all 4-aligned.
  const modelVtable = 8; // 18 bytes
  const modelTable = 28; // 12 bytes
  const bufVec = 40; // 8
  const mdVec = 48; // 8
  const bufVtable = 56; // 10 -> 12
  const bufTable = 68; // 20
  const mdVtable = 88; // 8
  const mdTable = 96; // 12
  const nameAt = 108;
  final nameEnd = (nameAt + 4 + nameBytes.length + 1 + 3) & ~3;
  final dataAt = nameEnd; // inline: a vector (length first); else raw bytes
  final out = Uint8List(dataAt + 4 + params.length + 8);
  final v = ByteData.sublistView(out);
  void u16(int at, int x) => v.setUint16(at, x, Endian.little);
  void u32(int at, int x) => v.setUint32(at, x, Endian.little);
  void i32(int at, int x) => v.setInt32(at, x, Endian.little);

  u32(0, modelTable);
  out.setRange(4, 8, utf8.encode('TFL3'));

  u16(modelVtable, 18);
  u16(modelVtable + 2, 12);
  u16(modelVtable + 12, 4); // field 4: buffers
  u16(modelVtable + 16, 8); // field 6: metadata
  i32(modelTable, modelTable - modelVtable);
  u32(modelTable + 4, bufVec - (modelTable + 4));
  u32(modelTable + 8, mdVec - (modelTable + 8));

  u32(bufVec, 1);
  u32(bufVec + 4, bufTable - (bufVec + 4));
  u32(mdVec, 1);
  u32(mdVec + 4, mdTable - (mdVec + 4));

  u16(bufVtable, 10);
  u16(bufVtable + 2, inline ? 8 : 20);
  if (inline) {
    u16(bufVtable + 4, 4); // field 0: data
  } else {
    u16(bufVtable + 6, 4); // field 1: offset (u64)
    u16(bufVtable + 8, 12); // field 2: size (u64)
  }
  i32(bufTable, bufTable - bufVtable);
  if (inline) {
    u32(bufTable + 4, dataAt - (bufTable + 4));
    u32(dataAt, params.length);
    out.setRange(dataAt + 4, dataAt + 4 + params.length, params);
  } else {
    u32(bufTable + 4, dataAt);
    u32(bufTable + 12, params.length);
    out.setRange(dataAt, dataAt + params.length, params);
  }

  u16(mdVtable, 8);
  u16(mdVtable + 2, 12);
  u16(mdVtable + 4, 4); // field 0: name
  u16(mdVtable + 6, 8); // field 1: buffer index
  i32(mdTable, mdTable - mdVtable);
  u32(mdTable + 4, nameAt - (mdTable + 4));
  u32(mdTable + 8, 0);

  u32(nameAt, nameBytes.length);
  out.setRange(nameAt + 4, nameAt + 4 + nameBytes.length, nameBytes);
  return out;
}

void main() {
  test('reads the markers from a large-file buffer', () {
    final format = readTaskChatFormat(_task(_llmParameters()))!;
    expect(format.template, WebChatTemplate.gemma4);
    expect(format.hasRuntimePromptTemplates, isFalse);
  });

  test('reads the markers from an inline buffer', () {
    expect(
      readTaskChatFormat(_task(_llmParameters(), inline: true))!.template,
      WebChatTemplate.gemma4,
    );
  });

  test('reports prompt_templates (field 17) when the file has it', () {
    final format = readTaskChatFormat(_task(_llmParameters(runtime: true)))!;
    expect(format.hasRuntimePromptTemplates, isTrue);
  });

  test('a ten-byte varint (a negative int32) does not stop the read', () {
    final negative = Uint8List.fromList([
      0x08, // field 1, varint
      ...List.filled(9, 0xff),
      0x01,
      ..._llmParameters(),
    ]);
    expect(
      readTaskChatFormat(_task(negative))!.template,
      WebChatTemplate.gemma4,
    );
  });

  test('a file without the flat markers declares no template', () {
    final format = readTaskChatFormat(
      _task(_llmParameters(flat: false, runtime: true)),
    )!;
    expect(format.template, isNull);
    expect(format.hasRuntimePromptTemplates, isTrue);
  });

  test(
    'no LlmParameters entry, not a TFLite file, or a cut file answer null',
    () {
      expect(
        readTaskChatFormat(
          _task(_llmParameters(), name: 'min_runtime_version'),
        ),
        isNull,
      );
      expect(readTaskChatFormat(Uint8List(0)), isNull);
      expect(
        readTaskChatFormat(Uint8List.fromList(List.filled(64, 7))),
        isNull,
      );
      final cut = _task(_llmParameters());
      expect(
        readTaskChatFormat(Uint8List.sublistView(cut, 0, cut.length - 20)),
        isNull,
      );
    },
  );

  test('truncated at every length never throws', () {
    final whole = _task(_llmParameters());
    for (var n = 0; n < whole.length; n++) {
      readTaskChatFormat(Uint8List.sublistView(whole, 0, n));
    }
  });

  // The real thing: set TASK_FILE_GEMMA4 to a Gemma 4 web `.task`.
  final real = Platform.environment['TASK_FILE_GEMMA4'];
  test('a real Gemma 4 web .task declares the gemma4 markers', () {
    final f = File(real!).openSync();
    final prefix = f.readSync(taskMetadataPrefixBytes);
    f.closeSync();
    final format = readTaskChatFormat(prefix)!;
    expect(format.template, WebChatTemplate.gemma4);
  }, skip: real == null ? 'set TASK_FILE_GEMMA4' : false);

  group('resolveWebChatTemplate', () {
    Future<(WebChatTemplate?, List<String>)> resolve(
      Future<Uint8List> Function() read, {
      ModelType type = ModelType.gemma4,
    }) async {
      final printed = <String>[];
      final template = await runZoned(
        () => resolveWebChatTemplate(readPrefix: read, modelType: type),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      return (template, printed);
    }

    test('a file with prompt_templates (field 17) gets no markers of ours, '
        'and says so', () async {
      final (template, printed) = await resolve(
        () async => _task(_llmParameters(runtime: true)),
      );
      expect(template, isNull);
      expect(printed, [contains('prompt templates')]);
    });

    test('a declared template wins over the model type', () async {
      final (template, printed) = await resolve(
        () async => _task(_llmParameters()),
        type: ModelType.gemmaIt,
      );
      expect(template, WebChatTemplate.gemma4);
      expect(
        printed.where((l) => l.contains('flutter_edge_ai_mediapipe')),
        isEmpty,
      );
    });

    test(
      'no declared format: the model type decides, and it is printed',
      () async {
        final (template, printed) = await resolve(
          () async => _task(_llmParameters(flat: false)),
          type: ModelType.gemmaIt,
        );
        expect(template, WebChatTemplate.gemma3);
        expect(printed, [contains('declares no chat format')]);
      },
    );

    test('a file that could not be read prints the error, not the claim that '
        'it declares nothing', () async {
      final (template, printed) = await resolve(
        () async => throw StateError('range not satisfiable'),
        type: ModelType.qwen,
      );
      expect(template, isNull);
      expect(printed, hasLength(1));
      expect(printed.single, contains('range not satisfiable'));
      expect(printed.single, isNot(contains('declares no chat format')));
    });
  });
}
