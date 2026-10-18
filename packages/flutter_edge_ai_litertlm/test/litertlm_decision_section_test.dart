// The `litetune.decision` section reader, on containers built to the
// header schema. The real decision-tuned bundle is read by
// example/integration_test/litertlm_inference_decider_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/litertlm_decision_section.dart';
import 'package:flutter_test/flutter_test.dart';

import 'litertlm_container_fixture.dart';

/// `AnySectionDataType.GenericBinaryData`.
const _generic = 1;

const _payload =
    '{"contract_version":1,"type":"choice","question":"Which emotion does '
    'the text express?","options":[{"id":"joy"},{"id":"fear"}],'
    '"none_option":null,"scoring":"unique_prefix","terminator":"<end_of_turn>",'
    '"scored_lengths":[1,1],"temperature":1.2,"abstain_rule":"error_budget",'
    '"abstain_below":0.5}';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('decision_section'));
  tearDown(() => dir.deleteSync(recursive: true));

  String write(Uint8List bytes) {
    final file = File('${dir.path}/model.litertlm')..writeAsBytesSync(bytes);
    return file.path;
  }

  Section tflite() => (
    type: sectionTfliteModel,
    modelType: 'tf_lite_prefill_decode',
    bytes: List.filled(64, 7),
  );

  Section generic(List<int> bytes) =>
      (type: _generic, modelType: null, bytes: bytes);

  test('reads the payload of the section named litetune.decision', () async {
    final path = write(
      litertlmContainer(
        [tflite(), generic(utf8.encode(_payload))],
        items: {
          1: {'name': litetuneDecisionSectionName},
        },
      ),
    );
    expect(await readLitetuneDecisionSection(path), _payload);
  });

  test('a bundle without it has none', () async {
    final path = write(litertlmContainer([tflite()]));
    expect(await readLitetuneDecisionSection(path), isNull);
  });

  test('a generic section of another name is not it', () async {
    final path = write(
      litertlmContainer(
        [tflite(), generic(utf8.encode(_payload))],
        items: {
          1: {'name': 'something.else'},
        },
      ),
    );
    expect(await readLitetuneDecisionSection(path), isNull);
  });

  test('the name on a section of another type is refused, not taken for '
      '"no section"', () async {
    final path = write(
      litertlmContainer(
        [tflite()],
        items: {
          0: {'name': litetuneDecisionSectionName},
        },
      ),
    );
    await expectLater(
      readLitetuneDecisionSection(path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('data type'),
        ),
      ),
    );
  });

  test('a generic section whose name is not a string is refused', () async {
    final path = write(
      litertlmContainer(
        [generic(utf8.encode(_payload))],
        items: {
          0: {'name': 7},
        },
      ),
    );
    await expectLater(
      readLitetuneDecisionSection(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('a load-time read captures an unreadable file as the decision\'s '
      'error', () async {
    final read = await LitetuneDecisionRead.read(
      '${dir.path}/missing.litertlm',
    );
    expect(read.payload, isNull);
    expect(read.error, isA<FormatException>());
    final good = await LitetuneDecisionRead.read(
      write(
        litertlmContainer(
          [generic(utf8.encode(_payload))],
          items: {
            0: {'name': litetuneDecisionSectionName},
          },
        ),
      ),
    );
    expect(good.payload, _payload);
    expect(good.error, isNull);
  });

  test('two decision sections are refused, not one picked', () async {
    final path = write(
      litertlmContainer(
        [generic(utf8.encode(_payload)), generic(utf8.encode(_payload))],
        items: {
          0: {'name': litetuneDecisionSectionName},
          1: {'name': litetuneDecisionSectionName},
        },
      ),
    );
    await expectLater(
      readLitetuneDecisionSection(path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('twice'),
        ),
      ),
    );
  });

  test('a payload that is not UTF-8 is refused', () async {
    final path = write(
      litertlmContainer(
        [
          generic([0xff, 0xfe, 0x00]),
        ],
        items: {
          0: {'name': litetuneDecisionSectionName},
        },
      ),
    );
    await expectLater(
      readLitetuneDecisionSection(path),
      throwsA(isA<FormatException>()),
    );
  });

  test('a file that is not a .litertlm container is refused', () async {
    final path = write(
      Uint8List.fromList(
        utf8.encode(
          'not a model at all, '
          'just some text that is longer than the preamble',
        ),
      ),
    );
    await expectLater(
      readLitetuneDecisionSection(path),
      throwsA(isA<FormatException>()),
    );
  });
}
