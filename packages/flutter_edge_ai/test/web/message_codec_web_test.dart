// MessageTranscriptCodec in a browser (#824): the round trip, and the number
// behaviour the class doc states for the web, where every number is a JS
// number. The full suite (golden file, analyzer field guard) runs on the VM in
// test/message_codec/.
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<Message>> _roundTrip(
  List<Message> messages, [
  MessageTranscriptCodec codec = const MessageTranscriptCodec(),
]) async {
  final text = jsonEncode(await codec.encode(messages));
  return codec.decode(jsonDecode(text) as Map<String, Object?>);
}

Message _call(Map<String, dynamic> args) => Message.toolCall(
  text: 'x',
  calls: [FunctionCallResponse(name: 'f', args: args, id: 'c1')],
);

void main() {
  test('messages with media and tool calls round trip', () async {
    final messages = [
      Message.withImages(
        text: 'two',
        imageBytes: [
          Uint8List.fromList([0, 1, 255]),
          Uint8List.fromList([7]),
        ],
        isUser: true,
      ),
      Message.withAudio(
        text: 'clip',
        audioBytes: Uint8List.fromList([82, 73, 70, 70]),
        isUser: true,
      ),
      _call({
        'city': 'Pune',
        'days': 3,
        'nested': {
          'list': [true, null, 'a'],
        },
      }),
      Message.toolResponse(
        toolName: 'f',
        response: {'ok': true},
        toolCallId: 'c1',
      ),
    ];
    expect(await _roundTrip(messages), messages);

    final store = <String, Uint8List>{};
    final codec = MessageTranscriptCodec(
      writeMedia: (bytes, kind) async {
        final ref = 'r${store.length}';
        store[ref] = Uint8List.fromList(bytes);
        return ref;
      },
      readMedia: (ref, kind) async => store[ref]!,
    );
    expect(await _roundTrip(messages, codec), messages);
    expect(store, hasLength(4));
  });

  test('an integral double reads back as an int, and integers past 2^53 '
      'lose precision', () async {
    // 2^53 + 1 cannot be a literal here; it arrives in stored JSON.
    const codec = MessageTranscriptCodec();
    final text = jsonEncode(
      await codec.encode([
        _call({'d': 1.0, 'big': 'BIG'}),
      ]),
    ).replaceFirst('"BIG"', '9007199254740993');
    final args = (await codec.decode(
      jsonDecode(text) as Map<String, Object?>,
    )).single.toolCalls.single.args;
    expect(args['d'], isA<int>());
    expect(args['d'], 1);
    // 2^53 + 1 is not a JS number: it reads back as 2^53.
    expect(args['big'], 9007199254740992);
  });

  test('infinity and NaN are refused', () async {
    // Compiled to JS, `double.infinity is int` is true: the codec checks
    // finiteness on num, not double.
    for (final value in [
      double.infinity,
      double.negativeInfinity,
      double.nan,
    ]) {
      await expectLater(
        const MessageTranscriptCodec().encode([
          _call({'v': value}),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            startsWith('messages[0].toolCalls[0].args.v: '),
          ),
        ),
      );
    }
  });
}
