import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart' as gemma;

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_flutter_gemma/src/converters/request_converter.dart';

void main() {
  group('convertMessages', () {
    test('converts user text message', () async {
      final messages = [
        Message(role: Role.user, content: [TextPart(text: 'Hello')]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].text, 'Hello');
      expect(result[0].isUser, isTrue);
    });

    test('converts model text message', () async {
      final messages = [
        Message(role: Role.model, content: [TextPart(text: 'Hi there')]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].text, 'Hi there');
      expect(result[0].isUser, isFalse);
    });

    test('skips system messages (handled via extractSystemInstruction)',
        () async {
      final messages = [
        Message(
          role: Role.system,
          content: [TextPart(text: 'You are helpful.')],
        ),
        Message(role: Role.user, content: [TextPart(text: 'Hello')]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].text, 'Hello');
      expect(result[0].isUser, isTrue);
    });

    test('skips multiple system messages', () async {
      final messages = [
        Message(role: Role.system, content: [TextPart(text: 'Rule 1')]),
        Message(role: Role.system, content: [TextPart(text: 'Rule 2')]),
        Message(role: Role.user, content: [TextPart(text: 'Hello')]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].text, 'Hello');
      expect(result[0].isUser, isTrue);
    });

    test('returns empty list for system-only messages', () async {
      final messages = [
        Message(
          role: Role.system,
          content: [TextPart(text: 'System only')],
        ),
      ];

      final result = await convertMessages(messages);

      expect(result, isEmpty);
    });

    test('converts multi-turn conversation', () async {
      final messages = [
        Message(role: Role.user, content: [TextPart(text: 'Hi')]),
        Message(role: Role.model, content: [TextPart(text: 'Hello!')]),
        Message(
          role: Role.user,
          content: [TextPart(text: 'How are you?')],
        ),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(3));
      expect(result[0].isUser, isTrue);
      expect(result[1].isUser, isFalse);
      expect(result[2].isUser, isTrue);
    });

    test('handles user message with base64 image', () async {
      final imageData = Uint8List.fromList([0xFF, 0xD8, 0xFF]);
      final base64Data = base64Encode(imageData);
      final dataUrl = 'data:image/jpeg;base64,$base64Data';

      final messages = [
        Message(role: Role.user, content: [
          TextPart(text: 'Describe this'),
          MediaPart(media: Media(url: dataUrl, contentType: 'image/jpeg')),
        ]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].text, 'Describe this');
      expect(result[0].isUser, isTrue);
      expect(result[0].hasImage, isTrue);
    });

    test('handles user message with file:// image', () async {
      final tempDir = Directory.systemTemp.createTempSync('genkit_test_');
      final tempFile = File('${tempDir.path}/test_image.jpg');
      final imageData = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      tempFile.writeAsBytesSync(imageData);

      try {
        final fileUrl = tempFile.uri.toString(); // file:///...
        final messages = [
          Message(role: Role.user, content: [
            TextPart(text: 'Describe'),
            MediaPart(
                media: Media(url: fileUrl, contentType: 'image/jpeg')),
          ]),
        ];

        final result = await convertMessages(messages);

        expect(result, hasLength(1));
        expect(result[0].hasImage, isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('handles user message with absolute path image', () async {
      final tempDir = Directory.systemTemp.createTempSync('genkit_test_');
      final tempFile = File('${tempDir.path}/test_image.jpg');
      final imageData = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      tempFile.writeAsBytesSync(imageData);

      try {
        final messages = [
          Message(role: Role.user, content: [
            TextPart(text: 'Describe'),
            MediaPart(
              media: Media(
                url: tempFile.path, // /tmp/.../test_image.jpg
                contentType: 'image/jpeg',
              ),
            ),
          ]),
        ];

        final result = await convertMessages(messages);

        expect(result, hasLength(1));
        expect(result[0].hasImage, isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('handles tool response message', () async {
      final messages = [
        Message(role: Role.tool, content: [
          ToolResponsePart(
            toolResponse: ToolResponse(
              name: 'get_weather',
              output: {'temp': '15C'},
            ),
          ),
        ]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].type, gemma.MessageType.toolResponse);
    });

    test('handles model message with tool request', () async {
      final messages = [
        Message(role: Role.model, content: [
          ToolRequestPart(
            toolRequest: ToolRequest(
              name: 'get_weather',
              input: {'location': 'Paris'},
            ),
          ),
        ]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].type, gemma.MessageType.toolCall);
    });

    test('handles model message with parallel tool requests', () async {
      final messages = [
        Message(role: Role.model, content: [
          ToolRequestPart(
            toolRequest: ToolRequest(
              name: 'get_weather',
              input: {'location': 'Paris'},
            ),
          ),
          ToolRequestPart(
            toolRequest: ToolRequest(
              name: 'get_time',
              input: {'timezone': 'CET'},
            ),
          ),
        ]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].type, gemma.MessageType.toolCall);
      // Verify the JSON contains both calls as an array.
      final decoded = jsonDecode(result[0].text);
      expect(decoded, isList);
      expect(decoded, hasLength(2));
      expect(decoded[0]['name'], 'get_weather');
      expect(decoded[1]['name'], 'get_time');
    });

    test('handles empty message list', () async {
      final result = await convertMessages([]);
      expect(result, isEmpty);
    });

    test('concatenates multiple text parts', () async {
      final messages = [
        Message(role: Role.user, content: [
          TextPart(text: 'Part 1'),
          TextPart(text: 'Part 2'),
        ]),
      ];

      final result = await convertMessages(messages);

      expect(result, hasLength(1));
      expect(result[0].text, 'Part 1\nPart 2');
    });
  });

  group('extractSystemInstruction', () {
    test('extracts single system message', () {
      final messages = [
        Message(
          role: Role.system,
          content: [TextPart(text: 'You are helpful.')],
        ),
        Message(role: Role.user, content: [TextPart(text: 'Hello')]),
      ];

      expect(extractSystemInstruction(messages), 'You are helpful.');
    });

    test('concatenates multiple system messages', () {
      final messages = [
        Message(role: Role.system, content: [TextPart(text: 'Rule 1')]),
        Message(role: Role.system, content: [TextPart(text: 'Rule 2')]),
        Message(role: Role.user, content: [TextPart(text: 'Hello')]),
      ];

      expect(extractSystemInstruction(messages), 'Rule 1\nRule 2');
    });

    test('returns null when no system messages', () {
      final messages = [
        Message(role: Role.user, content: [TextPart(text: 'Hello')]),
      ];

      expect(extractSystemInstruction(messages), isNull);
    });

    test('returns null for empty messages', () {
      expect(extractSystemInstruction([]), isNull);
    });

    test('throws on system message with non-text parts only', () {
      final messages = [
        Message(role: Role.system, content: [
          MediaPart(
            media: Media(
              url: 'data:image/png;base64,iVBOR',
              contentType: 'image/png',
            ),
          ),
        ]),
      ];

      expect(
        () => extractSystemInstruction(messages),
        throwsA(isA<GenkitException>()),
      );
    });
  });
}
