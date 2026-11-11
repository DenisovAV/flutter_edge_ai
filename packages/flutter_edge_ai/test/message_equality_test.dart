import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

// Media is compared and hashed by content (#823): a message rebuilt from the
// same bytes in new buffers (a decoded transcript, an isolate copy) is equal to
// the original and hashes alike.
void main() {
  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  void expectEqualAndSameHash(Message a, Message b) {
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect({a, b}, hasLength(1));
  }

  group('equal bytes in new buffers', () {
    test('images', () {
      expectEqualAndSameHash(
        Message(
          text: 'x',
          isUser: true,
          images: [
            bytes([1, 2]),
            bytes([3]),
          ],
        ),
        Message(
          text: 'x',
          isUser: true,
          images: [
            bytes([1, 2]),
            bytes([3]),
          ],
        ),
      );
    });

    test('imageBytes', () {
      expectEqualAndSameHash(
        Message(text: 'x', isUser: true, imageBytes: bytes([1, 2])),
        Message(text: 'x', isUser: true, imageBytes: bytes([1, 2])),
      );
    });

    test('audioBytes', () {
      expectEqualAndSameHash(
        Message(text: 'x', isUser: true, audioBytes: bytes([7, 8, 9])),
        Message(text: 'x', isUser: true, audioBytes: bytes([7, 8, 9])),
      );
    });

    test('a large image, longer than the hashed sample', () {
      final data = Uint8List(1 << 20)..fillRange(0, 1 << 20, 5);
      expectEqualAndSameHash(
        Message(text: 'x', isUser: true, imageBytes: data),
        Message(text: 'x', isUser: true, imageBytes: Uint8List.fromList(data)),
      );
    });
  });

  group('different media is not equal', () {
    test('a byte that differs in the middle of a large image', () {
      final a = Uint8List(1 << 20);
      final b = Uint8List.fromList(a)..[1 << 19] = 1;
      expect(
        Message(text: 'x', isUser: true, imageBytes: a),
        isNot(Message(text: 'x', isUser: true, imageBytes: b)),
      );
    });

    test('images in another order, or another count', () {
      final one = bytes([1]);
      final two = bytes([2]);
      final base = Message(text: 'x', isUser: true, images: [one, two]);
      expect(base, isNot(Message(text: 'x', isUser: true, images: [two, one])));
      expect(base, isNot(Message(text: 'x', isUser: true, images: [one])));
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

    test('audio against no audio', () {
      expect(
        Message(text: 'x', isUser: true, audioBytes: bytes([1])),
        isNot(const Message(text: 'x', isUser: true)),
      );
    });
  });
}
