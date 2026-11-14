import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

// Media is compared and hashed by content (#823): a message rebuilt from the
// same bytes in new buffers, or in views at other offsets, is equal to the
// original and hashes alike. Unequal messages may still share a hash code
// (collisions are allowed), so nothing here asserts that they differ.
void main() {
  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  /// [values] as a view at [offset] into a larger buffer, not a copy.
  Uint8List viewAt(List<int> values, int offset) {
    final backing = Uint8List(offset + values.length + 3)
      ..fillRange(0, offset + values.length + 3, 0xEE)
      ..setRange(offset, offset + values.length, values);
    return Uint8List.sublistView(backing, offset, offset + values.length);
  }

  void expectEqualAndSameHash(Message a, Message b) {
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect({a, b}, hasLength(1));
  }

  const data = [1, 2, 3, 4, 5];

  for (final (field, build) in <(String, Message Function(Uint8List))>[
    ('imageBytes', (b) => Message(text: 'x', isUser: true, imageBytes: b)),
    ('images', (b) => Message(text: 'x', isUser: true, images: [b])),
    ('audioBytes', (b) => Message(text: 'x', isUser: true, audioBytes: b)),
  ]) {
    group(field, () {
      test('equal bytes in different buffers are equal and hash alike', () {
        expectEqualAndSameHash(build(bytes(data)), build(bytes(data)));
      });

      test('equal bytes in views at different offsets are equal and hash '
          'alike', () {
        expectEqualAndSameHash(build(viewAt(data, 0)), build(viewAt(data, 7)));
        expectEqualAndSameHash(build(viewAt(data, 3)), build(bytes(data)));
      });

      test('a difference in the middle of a large buffer is not equal', () {
        final a = Uint8List(1 << 20)..fillRange(0, 1 << 20, 5);
        final b = Uint8List.fromList(a)..[1 << 19] = 6;
        expect(build(a), isNot(build(b)));
      });
    });
  }

  test('no media and empty media are not equal', () {
    const none = Message(text: 'x', isUser: true);
    expect(
      none,
      isNot(Message(text: 'x', isUser: true, imageBytes: bytes([]))),
    );
    expect(
      none,
      isNot(Message(text: 'x', isUser: true, audioBytes: bytes([]))),
    );
  });

  group('images', () {
    test('several images in the same order are equal and hash alike', () {
      expectEqualAndSameHash(
        Message(
          text: 'x',
          isUser: true,
          images: [
            bytes([1]),
            bytes([2, 3]),
          ],
        ),
        Message(
          text: 'x',
          isUser: true,
          images: [
            bytes([1]),
            bytes([2, 3]),
          ],
        ),
      );
    });

    test('the same images in another order are not equal', () {
      expect(
        Message(
          text: 'x',
          isUser: true,
          images: [
            bytes([1]),
            bytes([2]),
          ],
        ),
        isNot(
          Message(
            text: 'x',
            isUser: true,
            images: [
              bytes([2]),
              bytes([1]),
            ],
          ),
        ),
      );
    });

    test('another number of images is not equal', () {
      expect(
        Message(
          text: 'x',
          isUser: true,
          images: [
            bytes([1]),
            bytes([2]),
          ],
        ),
        isNot(
          Message(
            text: 'x',
            isUser: true,
            images: [
              bytes([1]),
            ],
          ),
        ),
      );
    });

    test('the same bytes in imageBytes and in images are different fields', () {
      expect(
        Message(text: 'x', isUser: true, imageBytes: bytes([1, 2])),
        isNot(
          Message(
            text: 'x',
            isUser: true,
            images: [
              bytes([1, 2]),
            ],
          ),
        ),
      );
    });
  });

  test('a message rebuilt field by field from new buffers equals the '
      'original', () {
    final original = Message(
      text: 'look and listen',
      isUser: true,
      imageBytes: bytes([9, 8, 7]),
      images: [
        bytes([1, 2]),
        bytes([3, 4, 5]),
      ],
      audioBytes: bytes([6, 6, 6]),
    );
    final rebuilt = Message(
      text: original.text,
      isUser: original.isUser,
      imageBytes: Uint8List.fromList(original.imageBytes!),
      images: [for (final image in original.images) Uint8List.fromList(image)],
      audioBytes: Uint8List.fromList(original.audioBytes!),
      type: original.type,
      toolName: original.toolName,
      toolCalls: original.toolCalls,
      toolCallId: original.toolCallId,
    );
    expectEqualAndSameHash(original, rebuilt);
  });

  test('toolCalls with equal arguments in new maps are equal and hash '
      'alike', () {
    Message call() => Message.toolCall(
      calls: [
        FunctionCallResponse(
          name: 'search',
          args: {
            'q': 'pune',
            'filters': {
              'open': true,
              'tags': ['food'],
            },
          },
          id: 'c1',
        ),
      ],
    );
    expectEqualAndSameHash(call(), call());
  });
}
