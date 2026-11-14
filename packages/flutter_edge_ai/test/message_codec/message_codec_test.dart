// MessageTranscriptCodec (#824): a lossless, versioned JSON form of a list of
// messages. Round trips are checked with `==` (media by content since #823)
// and field by field, so a field `==` ignored would still be caught.
//
// Regenerate the golden after an intended format change (refused when CI is
// set; a format change also needs a new version):
//   UPDATE_GOLDENS=1 flutter test test/message_codec/message_codec_test.dart
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/element/element.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import '../public_surface/surface_analysis.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

/// One message of every factory, plus plain-constructor messages a factory
/// would change or refuse.
List<Message> _everyKind() => [
  const Message(text: 'plain'),
  Message.text(text: 'hello', isUser: true),
  Message.withImage(
    text: 'one image',
    imageBytes: _bytes([1, 2, 3]),
    isUser: true,
  ),
  Message.withImages(
    text: 'two images',
    imageBytes: [
      _bytes([4]),
      _bytes([5, 6]),
    ],
    isUser: true,
  ),
  Message.imageOnly(imageBytes: _bytes([7])),
  Message.imagesOnly(imageBytes: const []),
  Message.withAudio(text: 'listen', audioBytes: _bytes([8, 9]), isUser: true),
  Message.audioOnly(audioBytes: _bytes([])),
  Message.toolResponse(
    toolName: 'weather',
    response: {'temp': 21.5, 'ok': true},
    toolCallId: 'c1',
  ),
  Message.toolCall(
    calls: [
      const FunctionCallResponse(
        name: 'weather',
        args: {
          'city': 'Pune',
          'days': 3,
          'when': {
            'from': null,
            'hours': [6, 18],
          },
        },
        id: 'c1',
      ),
      const FunctionCallResponse(name: 'noop', args: {}),
    ],
  ),
  Message.toolCall(text: '{"tool_calls":[]}'),
  Message.systemInfo(text: 'calling weather', icon: 'tool'),
  Message.systemInfo(text: 'no icon'),
  Message.thinking(text: 'hmm'),
  // What the factories would not build: every field set, a tool response
  // from the model, a toolCall with no calls and empty text, an id on a
  // text message, imageBytes without images.
  Message(
    text: 'all fields',
    isUser: true,
    imageBytes: _bytes([10]),
    images: [
      _bytes([11]),
      _bytes([12, 13]),
    ],
    audioBytes: _bytes([14]),
    type: MessageType.toolResponse,
    toolName: 'odd',
    toolCalls: const [
      FunctionCallResponse(name: 'kept', args: {'a': 'b'}, id: 'x'),
    ],
    toolCallId: 'y',
  ),
  const Message(text: '', type: MessageType.toolCall),
  Message(text: 'only imageBytes', imageBytes: _bytes([15])),
];

/// Field by field, with media compared by content: independent of `==`.
void _expectSameFields(List<Message> actual, List<Message> expected) {
  expect(actual, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    final a = actual[i];
    final e = expected[i];
    final reason = 'message $i';
    expect(a.text, e.text, reason: reason);
    expect(a.isUser, e.isUser, reason: reason);
    expect(a.imageBytes?.toList(), e.imageBytes?.toList(), reason: reason);
    expect(
      [for (final image in a.images) image.toList()],
      [for (final image in e.images) image.toList()],
      reason: reason,
    );
    expect(a.audioBytes?.toList(), e.audioBytes?.toList(), reason: reason);
    expect(a.type, e.type, reason: reason);
    expect(a.toolName, e.toolName, reason: reason);
    expect(a.toolCalls, hasLength(e.toolCalls.length), reason: reason);
    for (var c = 0; c < e.toolCalls.length; c++) {
      expect(a.toolCalls[c].name, e.toolCalls[c].name, reason: reason);
      expect(a.toolCalls[c].id, e.toolCalls[c].id, reason: reason);
      expect(
        jsonEncode(a.toolCalls[c].args),
        jsonEncode(e.toolCalls[c].args),
        reason: reason,
      );
    }
    expect(a.toolCallId, e.toolCallId, reason: reason);
  }
}

/// Through a JSON string, as an app stores it.
Future<List<Message>> _roundTrip(
  List<Message> messages, [
  MessageTranscriptCodec codec = const MessageTranscriptCodec(),
]) async {
  final text = jsonEncode(await codec.encode(messages));
  return codec.decode(jsonDecode(text) as Map<String, Object?>);
}

void main() {
  group('round trip', () {
    test('every kind of message, media inline', () async {
      final messages = _everyKind();
      final decoded = await _roundTrip(messages);
      expect(decoded, messages);
      _expectSameFields(decoded, messages);
    });

    test(
      'every kind of message, media through a writer and a reader',
      () async {
        final store = <String, Uint8List>{};
        final written = <(int, MessageMediaKind)>[];
        final codec = MessageTranscriptCodec(
          writeMedia: (bytes, kind) async {
            final ref = 'm${store.length}';
            store[ref] = Uint8List.fromList(bytes);
            written.add((bytes.length, kind));
            return ref;
          },
          readMedia: (ref, kind) async => store[ref]!,
        );
        final messages = _everyKind();
        final encoded = await codec.encode(messages);
        expect(jsonEncode(encoded), isNot(contains('base64')));
        final decoded = await codec.decode(
          jsonDecode(jsonEncode(encoded)) as Map<String, Object?>,
        );
        expect(decoded, messages);
        _expectSameFields(decoded, messages);

        // Message.withImage keeps the buffer in imageBytes and images: written
        // twice, field for field. Order: imageBytes, images, audioBytes.
        expect(written.take(2), [
          (3, MessageMediaKind.image),
          (3, MessageMediaKind.image),
        ]);
        final all = messages.last;
        expect(all.imageBytes, isNotNull);
        final audio = written.where((w) => w.$2 == MessageMediaKind.audio);
        expect(audio.map((w) => w.$1), [2, 0, 1]);
      },
    );

    test('a reader alone decodes inline media', () async {
      final messages = _everyKind();
      final encoded = await const MessageTranscriptCodec().encode(messages);
      final decoded = await MessageTranscriptCodec(
        readMedia: (ref, kind) => fail('no reference was written'),
      ).decode(encoded);
      expect(decoded, messages);
    });

    test('an empty list', () async {
      expect(await _roundTrip(const []), isEmpty);
    });

    test('decodes through the plain constructor: no factory rewrites a '
        'field', () async {
      // Message.toolResponse would force isUser: true, Message.toolCall
      // would refuse empty text without calls.
      const messages = [
        Message(text: '{}', type: MessageType.toolResponse, toolName: 't'),
        Message(text: '', type: MessageType.toolCall),
      ];
      final decoded = await _roundTrip(messages);
      expect(decoded.first.isUser, isFalse);
      expect(decoded.last.text, '');
      expect(decoded.last.toolCalls, isEmpty);
    });

    test(
      'decoded tool calls are frozen, as Message.toolCall stores them',
      () async {
        final decoded = (await _roundTrip(
          _everyKind(),
        )).firstWhere((m) => m.toolCalls.length == 2);
        final call = decoded.toolCalls.first;
        expect(() => decoded.toolCalls.add(call), throwsUnsupportedError);
        expect(() => call.args['city'] = 'x', throwsUnsupportedError);
        final when = call.args['when'] as Map;
        expect(() => when['from'] = 1, throwsUnsupportedError);
        expect(() => (when['hours'] as List).add(1), throwsUnsupportedError);
      },
    );

    test('numbers are JSON numbers', () async {
      // On the VM an integral double stays a double and an int beyond 2^53
      // is exact; on the web both are JS numbers (1.0 reads back as 1, and
      // precision is lost past 2^53), which the class doc states.
      final messages = [
        Message.toolCall(
          calls: [
            const FunctionCallResponse(
              name: 'n',
              args: {'d': 1.0, 'big': 9007199254740993, 'neg': -0.5},
            ),
          ],
        ),
      ];
      final args = (await _roundTrip(messages)).single.toolCalls.single.args;
      expect(args['d'], isA<double>());
      expect(args['d'], 1.0);
      expect(args['big'], 9007199254740993);
      expect(args['neg'], -0.5);
    });
  });

  group('golden', () {
    final golden = File('test/message_codec/transcript_v1.golden.json');

    List<Message> fixed() => [
      Message.text(text: 'What is the weather in Pune?', isUser: true),
      Message.withImage(
        text: 'and this photo',
        imageBytes: _bytes([0, 1, 254, 255]),
        isUser: true,
      ),
      Message.thinking(text: 'Need the weather tool.'),
      Message.toolCall(
        calls: [
          const FunctionCallResponse(
            name: 'get_weather',
            args: {
              'city': 'Pune',
              'days': 2,
              'units': ['c'],
            },
            id: 'c1',
          ),
        ],
      ),
      Message.systemInfo(text: 'Calling get_weather', icon: 'tool'),
      Message.toolResponse(
        toolName: 'get_weather',
        response: {'temp': 21},
        toolCallId: 'c1',
      ),
      Message.audioOnly(audioBytes: _bytes([82, 73, 70, 70]), isUser: true),
      Message.text(text: 'It is 21 degrees.'),
    ];

    test('the encoder writes the committed v1 golden', () async {
      final encoded = await const MessageTranscriptCodec().encode(fixed());
      expectGolden(
        golden,
        '${const JsonEncoder.withIndent('  ').convert(encoded)}\n',
        (expected, actual) =>
            'transcript v1 changed. A change to the written format needs a '
            'new version.\n${describeLineDrift('golden', expected, actual)}',
      );
    });

    test('the committed v1 golden decodes to the fixed messages', () async {
      final decoded = await const MessageTranscriptCodec().decode(
        jsonDecode(golden.readAsStringSync()) as Map<String, Object?>,
      );
      expect(decoded, fixed());
      _expectSameFields(decoded, fixed());
    });
  });

  test(
    'the encoder writes a key for every field of Message',
    () async {
      // Read from Message itself, so a field added later fails here until the
      // codec writes it (and the format gets a new version).
      final names = await exportNamespace('flutter_edge_ai.dart');
      final message = names['Message']! as InterfaceElement;
      final fields = {
        for (final field in message.fields)
          if (!field.isStatic && field.isOriginDeclaration && field.isPublic)
            field.name!,
      };
      final encoded = await const MessageTranscriptCodec().encode([
        const Message(text: ''),
      ]);
      final keys = ((encoded['messages']! as List).single as Map).keys.toSet();
      expect(keys, fields);
      expect(fields, hasLength(9));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  group('decode refuses', () {
    Future<void> refuses(Object? json, String detail) => expectLater(
      const MessageTranscriptCodec().decode(json! as Map<String, Object?>),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains(detail),
        ),
      ),
    );

    Future<Map<String, Object?>> valid() async =>
        jsonDecode(
              jsonEncode(
                await const MessageTranscriptCodec().encode([
                  Message.toolCall(
                    calls: [
                      const FunctionCallResponse(
                        name: 'f',
                        args: {'a': 1},
                        id: 'i',
                      ),
                    ],
                  ),
                  Message.withImage(text: 'x', imageBytes: _bytes([1])),
                ]),
              ),
            )
            as Map<String, Object?>;

    Map<String, Object?> first(Map<String, Object?> json) =>
        (json['messages']! as List).first as Map<String, Object?>;

    for (final version in [0, -1, 2, '1', null]) {
      test('version $version', () async {
        final json = await valid();
        json['version'] = version;
        await refuses(json, 'version');
      });
    }

    test('a missing version', () async {
      await refuses(
        await valid()
          ..remove('version'),
        'version',
      );
    });

    test('another format', () async {
      await refuses(
        await valid()
          ..['format'] = 'other',
        'format',
      );
    });

    test('an extra top-level key', () async {
      await refuses(
        await valid()
          ..['extra'] = 1,
        'unknown key "extra"',
      );
    });

    test('an extra message key', () async {
      final json = await valid();
      first(json)['extra'] = 1;
      await refuses(json, 'messages[0]: unknown key "extra"');
    });

    test('a missing message key, even a null one', () async {
      final json = await valid();
      first(json).remove('toolCallId');
      await refuses(json, 'messages[0]: missing key "toolCallId"');
    });

    test('an unknown type', () async {
      final json = await valid();
      first(json)['type'] = 'image';
      await refuses(json, 'messages[0].type: unknown message type');
    });

    test('a value of the wrong JSON type', () async {
      final json = await valid();
      first(json)['isUser'] = 'false';
      await refuses(json, 'messages[0].isUser: expected bool');
    });

    test('null images', () async {
      final json = await valid();
      first(json)['images'] = null;
      await refuses(json, 'messages[0].images: expected a list');
    });

    test('an extra tool-call key', () async {
      final json = await valid();
      ((first(json)['toolCalls']! as List).single as Map)['extra'] = 1;
      await refuses(json, 'messages[0].toolCalls[0]: unknown key "extra"');
    });

    test('media with both base64 and ref', () async {
      final json = await valid();
      final second = (json['messages']! as List)[1] as Map;
      (second['imageBytes']! as Map)['ref'] = 'r';
      await refuses(json, 'messages[1].imageBytes: expected exactly one');
    });

    test('invalid base64', () async {
      final json = await valid();
      final second = (json['messages']! as List)[1] as Map;
      second['imageBytes'] = {'base64': '***'};
      await refuses(json, 'messages[1].imageBytes.base64');
    });

    test('a media reference without a reader', () async {
      final encoded =
          await MessageTranscriptCodec(
            writeMedia: (bytes, kind) async => 'r',
          ).encode([
            Message.withImage(text: 'x', imageBytes: _bytes([1])),
          ]);
      await refuses(
        encoded,
        'messages[0].imageBytes.ref: a media reference '
        'needs a readMedia callback',
      );
    });
  });

  group('encode refuses tool-call arguments JSON cannot hold', () {
    for (final (what, args, path) in <(String, Map<String, dynamic>, String)>[
      ('a BigInt', {'n': BigInt.one}, 'messages[1].toolCalls[0].args.n'),
      ('NaN', {'n': double.nan}, 'messages[1].toolCalls[0].args.n'),
      (
        'infinity',
        {
          'l': [double.infinity],
        },
        'messages[1].toolCalls[0].args.l[0]',
      ),
      (
        'a non-string key',
        {
          'm': {1: 'one'},
        },
        'messages[1].toolCalls[0].args.m',
      ),
      (
        'a DateTime',
        {'when': DateTime(2026)},
        'messages[1].toolCalls[0].args.when',
      ),
    ]) {
      test(what, () async {
        await expectLater(
          const MessageTranscriptCodec().encode([
            Message.text(text: 'first'),
            // With text: built from the calls, the text would already fail.
            Message.toolCall(
              text: 'x',
              calls: [FunctionCallResponse(name: 'f', args: args)],
            ),
          ]),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              startsWith('$path: '),
            ),
          ),
        );
      });
    }
  });
}
