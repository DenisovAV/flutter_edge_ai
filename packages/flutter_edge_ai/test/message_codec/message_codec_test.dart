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
  return codec.decode(jsonDecode(text));
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
        final written = <String>[];
        final read = <String>[];
        final codec = MessageTranscriptCodec(
          writeMedia: (media) async {
            final ref = 'm${store.length}';
            store[ref] = Uint8List.fromList(media.bytes);
            written.add('${media.path} ${media.kind.name}');
            return ref;
          },
          readMedia: (ref) async {
            read.add('${ref.path} ${ref.kind.name} ${ref.reference}');
            return store[ref.reference]!;
          },
        );
        final messages = _everyKind();
        final encoded = await codec.encode(messages);
        expect(jsonEncode(encoded), isNot(contains('base64')));
        final decoded = await codec.decode(jsonDecode(jsonEncode(encoded)));
        expect(decoded, messages);
        _expectSameFields(decoded, messages);

        // Message order, then imageBytes, images, audioBytes. The factories'
        // shared first image (messages[2], [3], [4]) is written once; an
        // empty buffer still is.
        const order = [
          'messages[2].imageBytes image',
          'messages[3].imageBytes image',
          'messages[3].images[1] image',
          'messages[4].imageBytes image',
          'messages[6].audioBytes audio',
          'messages[7].audioBytes audio',
          'messages[14].imageBytes image',
          'messages[14].images[0] image',
          'messages[14].images[1] image',
          'messages[14].audioBytes audio',
          'messages[16].imageBytes image',
        ];
        expect(written, order);
        expect(read, [
          for (var i = 0; i < order.length; i++) '${order[i]} m$i',
        ]);
      },
    );

    test('one buffer in imageBytes and images[0] comes back as one buffer, '
        'written once', () async {
      final photo = Message.withImage(
        text: 'photo',
        imageBytes: _bytes([1, 2, 3]),
        isUser: true,
      );
      expect(identical(photo.imageBytes, photo.images.first), isTrue);

      // Inline: written field for field, one buffer after decode.
      final inline = (await _roundTrip([photo])).single;
      expect(identical(inline.imageBytes, inline.images.single), isTrue);

      // Through a writer: one write, the reference repeated, one read.
      final store = <String, Uint8List>{};
      var reads = 0;
      final codec = MessageTranscriptCodec(
        writeMedia: (media) async {
          store[media.path] = Uint8List.fromList(media.bytes);
          return media.path;
        },
        readMedia: (ref) async {
          reads++;
          return store[ref.reference]!;
        },
      );
      final encoded = await codec.encode([photo]);
      final message = (encoded['messages']! as List).single as Map;
      expect(message['imageBytes'], {'ref': 'messages[0].imageBytes'});
      expect(message['images'], [
        {'ref': 'messages[0].imageBytes'},
      ]);
      expect(store, hasLength(1));
      final decoded = (await codec.decode(encoded)).single;
      expect(reads, 1);
      expect(identical(decoded.imageBytes, decoded.images.single), isTrue);
      expect(decoded, photo);
    });

    test(
      'different bytes in imageBytes and images[0] stay two buffers',
      () async {
        final decoded = (await _roundTrip([
          Message(
            text: 'two',
            imageBytes: _bytes([1]),
            images: [
              _bytes([2]),
            ],
          ),
        ])).single;
        expect(decoded.imageBytes, [1]);
        expect(decoded.images.single, [2]);
      },
    );

    test('a reader alone decodes inline media', () async {
      final messages = _everyKind();
      final encoded = await const MessageTranscriptCodec().encode(messages);
      final decoded = await MessageTranscriptCodec(
        readMedia: (ref) => fail('no reference was written'),
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
        jsonDecode(golden.readAsStringSync()),
      );
      expect(decoded, fixed());
      _expectSameFields(decoded, fixed());
    });

    final refsGolden = File(
      'test/message_codec/transcript_v1_refs.golden.json',
    );
    final store = <String, Uint8List>{};
    final byPath = MessageTranscriptCodec(
      writeMedia: (media) async {
        store[media.path] = Uint8List.fromList(media.bytes);
        return media.path;
      },
      readMedia: (ref) async => store[ref.reference]!,
    );

    test(
      'with a writer, the encoder writes the committed v1 refs golden',
      () async {
        final encoded = await byPath.encode(fixed());
        expectGolden(
          refsGolden,
          '${const JsonEncoder.withIndent('  ').convert(encoded)}\n',
          (expected, actual) =>
              'transcript v1 (refs) changed. A change to the written format '
              'needs a new version.\n'
              '${describeLineDrift('golden', expected, actual)}',
        );
      },
    );

    test(
      'the committed v1 refs golden decodes to the fixed messages',
      () async {
        await byPath.encode(fixed());
        final decoded = await byPath.decode(
          jsonDecode(refsGolden.readAsStringSync()),
        );
        expect(decoded, fixed());
        _expectSameFields(decoded, fixed());
      },
    );
  });

  test('the encoder writes a key for every field of Message', () async {
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

    final call = names['FunctionCallResponse']! as InterfaceElement;
    final callFields = {
      for (final field in call.fields)
        if (!field.isStatic && field.isOriginDeclaration && field.isPublic)
          field.name!,
    };
    final withCall = await const MessageTranscriptCodec().encode([
      const Message(
        text: '',
        toolCalls: [FunctionCallResponse(name: 'f', args: {})],
      ),
    ]);
    final callKeys =
        ((((withCall['messages']! as List).single as Map)['toolCalls']! as List)
                    .single
                as Map)
            .keys
            .toSet();
    expect(callKeys, callFields);
    expect(callFields, hasLength(3));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('MessageType has the v1 values', () {
    // v1 writes the type by name. A new value would be written as version 1
    // and refused by every older build: it needs a new version.
    expect(MessageType.values.map((t) => t.name), [
      'text',
      'toolResponse',
      'toolCall',
      'systemInfo',
      'thinking',
    ]);
  });

  group('decode refuses', () {
    Future<void> refuses(Object? json, String detail) => expectLater(
      const MessageTranscriptCodec().decode(json),
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
          await MessageTranscriptCodec(writeMedia: (media) async => 'r').encode(
            [
              Message.withImage(text: 'x', imageBytes: _bytes([1])),
            ],
          );
      await refuses(
        encoded,
        'messages[0].imageBytes.ref: a media reference '
        'needs a readMedia callback',
      );
    });
    test('a top level that is not an object', () async {
      await refuses([], 'transcript: expected an object, found a List');
    });

    for (final (what, data) in [
      ('the URL-safe alphabet', '-_8='),
      ('%3D padding', 'AQ%3D%3D'),
      ('no padding', 'AQ'),
    ]) {
      test('base64 with $what', () async {
        final json = await valid();
        final second = (json['messages']! as List)[1] as Map;
        second['imageBytes'] = {'base64': data};
        await expectLater(
          const MessageTranscriptCodec().decode(json),
          throwsA(
            isA<FormatException>()
                .having(
                  (e) => e.message,
                  'message',
                  'messages[1].imageBytes.base64: expected standard base64 '
                      'with padding',
                )
                .having((e) => e.source, 'source', data),
          ),
        );
      });
    }

    test('a cycle in arguments passed to decode', () async {
      final json = await valid();
      final args =
          ((first(json)['toolCalls']! as List).single as Map)['args'] as Map;
      args['self'] = args;
      await refuses(
        json,
        'messages[0].toolCalls[0].args.self: a collection that contains '
        'itself',
      );
    });

    test('a malformed file, before reading any media', () async {
      final encoded =
          await MessageTranscriptCodec(
            writeMedia: (media) async => media.path,
          ).encode([
            Message.withImage(text: 'x', imageBytes: _bytes([1])),
            Message.text(text: 'y'),
          ]);
      ((encoded['messages']! as List)[1] as Map)['isUser'] = 'no';
      await expectLater(
        MessageTranscriptCodec(
          readMedia: (ref) => fail('read before the file was checked'),
        ).decode(encoded),
        throwsA(isA<FormatException>()),
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

  group('encode', () {
    test('checks every argument before writing any media', () async {
      await expectLater(
        MessageTranscriptCodec(
          writeMedia: (media) => fail('media written before the check'),
        ).encode([
          Message.withImage(text: 'x', imageBytes: _bytes([1])),
          Message.toolCall(
            text: 'x',
            calls: [
              FunctionCallResponse(name: 'f', args: {'n': BigInt.one}),
            ],
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('refuses a cycle, allows a repeated value', () async {
      final args = <String, dynamic>{};
      args['self'] = args;
      await expectLater(
        const MessageTranscriptCodec().encode([
          // The plain constructor: the factories would copy the cycle first.
          Message(
            text: 'x',
            type: MessageType.toolCall,
            toolCalls: [FunctionCallResponse(name: 'f', args: args)],
          ),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'messages[0].toolCalls[0].args.self: a collection that contains '
                'itself is not a JSON value',
          ),
        ),
      );

      final shared = [1, 2];
      final decoded = (await _roundTrip([
        Message(
          text: 'x',
          type: MessageType.toolCall,
          toolCalls: [
            FunctionCallResponse(
              name: 'f',
              args: {
                'a': shared,
                'b': {'c': shared},
              },
            ),
          ],
        ),
      ])).single;
      expect(decoded.toolCalls.single.args, {
        'a': [1, 2],
        'b': {
          'c': [1, 2],
        },
      });
    });

    test('quotes a key that is not an identifier in the path', () async {
      Future<String> pathOf(Map<String, dynamic> args) async {
        try {
          await const MessageTranscriptCodec().encode([
            Message(
              text: 'x',
              type: MessageType.toolCall,
              toolCalls: [FunctionCallResponse(name: 'f', args: args)],
            ),
          ]);
        } on ArgumentError catch (e) {
          return (e.message as String).split(':').first;
        }
        return fail('not refused');
      }

      final dotted = await pathOf({'a.b': double.nan});
      final nested = await pathOf({
        'a': {'b': double.nan},
      });
      expect(dotted, 'messages[0].toolCalls[0].args["a.b"]');
      expect(nested, 'messages[0].toolCalls[0].args.a.b');
    });

    test('returns a copy of the arguments', () async {
      final args = <String, dynamic>{'n': 1};
      final encoded = await const MessageTranscriptCodec().encode([
        Message(
          text: 'x',
          type: MessageType.toolCall,
          toolCalls: [FunctionCallResponse(name: 'f', args: args)],
        ),
      ]);
      args['n'] = 2;
      expect(jsonEncode(encoded), contains('"args":{"n":1}'));
    });

    test(
      'refuses a writer that returns one reference for different bytes',
      () async {
        await expectLater(
          MessageTranscriptCodec(writeMedia: (media) async => 'same').encode([
            Message.withImage(text: 'x', imageBytes: _bytes([1])),
            Message.withAudio(text: 'y', audioBytes: _bytes([2])),
          ]),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'messages[1].audioBytes: writeMedia returned "same", already '
                  'returned for different bytes at messages[0].imageBytes',
            ),
          ),
        );
      },
    );

    test('allows one reference for the same bytes in two buffers', () async {
      // A content-addressed writer.
      final store = <String, Uint8List>{};
      final codec = MessageTranscriptCodec(
        writeMedia: (media) async {
          final ref = base64Encode(media.bytes);
          store[ref] = Uint8List.fromList(media.bytes);
          return ref;
        },
        readMedia: (ref) async => store[ref.reference]!,
      );
      final messages = [
        Message.withImage(text: 'x', imageBytes: _bytes([1, 2])),
        Message.withImage(text: 'y', imageBytes: _bytes([1, 2])),
      ];
      expect(await _roundTrip(messages, codec), messages);
      expect(store, hasLength(1));
    });
  });
}
