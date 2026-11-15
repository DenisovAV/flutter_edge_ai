// Which images a message stages: [Message.images] when it has any, else its
// [Message.imageBytes] — the rule of the MediaPipe, llama and built-in AI
// sessions. `Uint8List ==` is identity, so a message rebuilt from saved bytes
// (two equal copies) once sent its photo twice.
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the images each turn hands the conversation; no native code.
class _ImageRecordingHandle implements ConversationHandle {
  final List<List<Uint8List>?> sentImages = [];

  @override
  Future<int?> tokenCount(String text) async => null;

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) async* {
    sentImages.add(imageBytes);
    yield 'ok';
  }

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) async* {
    sentImages.add(imageBytes);
    yield '{"role":"assistant","content":[{"type":"text","text":"ok"}]}';
  }

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
  }) async* {
    yield '{"role":"assistant","content":[{"type":"text","text":"ok"}]}';
  }

  @override
  void cancelGeneration() {}

  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  ) async => StoppedTurnRewind.unsupported;

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  NativeLastTurnEnd? get lastTurnEnd => null;

  @override
  int? get lastTurnCode => null;

  @override
  void close() {}
}

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  for (final modelType in [ModelType.gemmaIt, ModelType.gemma4]) {
    group('${modelType.name} session', () {
      Future<List<Uint8List>?> stagedImages(Message message) async {
        final handle = _ImageRecordingHandle();
        final session = FfiInferenceModelSession(
          handle: handle,
          modelType: modelType,
          fileType: ModelFileType.litertlm,
          supportImage: true,
          supportAudio: false,
          onClose: () {},
        );
        await session.addQueryChunk(message);
        await session.getResponse();
        await session.close();
        return handle.sentImages.single;
      }

      test('imageBytes and an equal copy in images stage one image', () async {
        final images = await stagedImages(
          Message(
            text: 'what is this',
            isUser: true,
            imageBytes: _bytes([1, 2, 3]),
            images: [
              _bytes([1, 2, 3]),
            ],
          ),
        );
        expect(images, [
          _bytes([1, 2, 3]),
        ]);
      });

      test('Message.withImage stages its one image', () async {
        final images = await stagedImages(
          Message.withImage(
            text: 'what is this',
            imageBytes: _bytes([1, 2, 3]),
            isUser: true,
          ),
        );
        expect(images, [
          _bytes([1, 2, 3]),
        ]);
      });

      test('images, when present, are the images; imageBytes is not added '
          'to them', () async {
        final images = await stagedImages(
          Message(
            text: 'compare',
            isUser: true,
            imageBytes: _bytes([9]),
            images: [
              _bytes([1]),
              _bytes([2]),
            ],
          ),
        );
        expect(images, [
          _bytes([1]),
          _bytes([2]),
        ]);
      });

      test('imageBytes alone is the one image', () async {
        final images = await stagedImages(
          Message(text: 'what is this', isUser: true, imageBytes: _bytes([7])),
        );
        expect(images, [
          _bytes([7]),
        ]);
      });

      test('a text message stages no images', () async {
        expect(
          await stagedImages(const Message(text: 'hi', isUser: true)),
          isNull,
        );
      });
    });
  }
}
