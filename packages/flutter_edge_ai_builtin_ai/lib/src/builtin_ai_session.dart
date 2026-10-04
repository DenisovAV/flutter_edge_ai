import 'dart:typed_data' show Uint8List;

import 'package:flutter_edge_ai/core/extensions.dart' show MessageExtension;
import 'package:flutter_edge_ai/core/message.dart' show Message;
import 'package:flutter_edge_ai/core/model.dart' show ModelFileType, ModelType;
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show InferenceModelSession, SessionMetrics;
import 'package:flutter_local_ai/flutter_local_ai.dart' show LocalAiSession;
import 'package:meta/meta.dart' show experimental;

/// A generation session on an OS built-in model, adapting flutter_local_ai's
/// [LocalAiSession] to flutter_edge_ai's [InferenceModelSession].
///
/// Thin by design: buffering, streaming, cancellation, session demultiplexing
/// and token counting all live in flutter_local_ai. This class only translates
/// flutter_edge_ai's [Message] into the text and images the session takes.
class BuiltInAiSession extends InferenceModelSession {
  BuiltInAiSession({
    required this._session,
    required this.modelType,
    required this.fileType,
    required this.supportImage,
    required this._onClose,
    this.maxNumImages,
  });

  final LocalAiSession _session;
  final ModelType modelType;
  final ModelFileType fileType;
  final bool supportImage;
  final int? maxNumImages;
  final void Function() _onClose;

  /// The underlying flutter_local_ai session.
  ///
  /// This is the supported escape hatch for the capabilities flutter_edge_ai's
  /// [InferenceModelSession] has no slot for — native tool calling and
  /// schema-constrained output (`getStructuredResponse`). It is the same
  /// native session this adapter drives, so anything read or generated through
  /// it shares this session's context.
  ///
  /// Experimental: this is a `flutter_local_ai` type, so it may change with
  /// that package's next major release independently of this one.
  @experimental
  LocalAiSession get localAiSession => _session;

  @override
  Future<void> addQueryChunk(Message message) async {
    if (message.hasAudio) {
      throw UnsupportedError('Audio is not supported by built-in OS models');
    }
    if (message.hasImage && !supportImage) {
      throw UnsupportedError('Enable vision before adding an image.');
    }
    final imageCount = message.images.isNotEmpty
        ? message.images.length
        : (message.hasImage ? 1 : 0);
    if (maxNumImages != null && imageCount > maxNumImages!) {
      throw ArgumentError('Message exceeds maxNumImages ($maxNumImages).');
    }
    final prompt = message.transformToChatPrompt(
      type: modelType,
      fileType: fileType,
    );
    // Images first, so the host has them buffered before the text that refers
    // to them — the ordering the native multimodal requests expect.
    if (message.hasImage && supportImage) {
      final images = message.images.isNotEmpty
          ? message.images
          : (message.imageBytes != null
                ? <Uint8List>[message.imageBytes!]
                : const <Uint8List>[]);
      for (final image in images) {
        await _session.addImage(image);
      }
    }
    await _session.addQueryChunk(prompt);
  }

  @override
  Future<String> getResponse() => _session.getResponse();

  @override
  Stream<String> getResponseAsync() => _session.getResponseAsync();

  @override
  Future<int> sizeInTokens(String text) => _session.sizeInTokens(text);

  @override
  Future<void> stopGeneration() => _session.stopGeneration();

  /// Built-in OS models expose no benchmark counters, so there is nothing
  /// truthful to report here. Empty metrics beat invented ones; use
  /// [sizeInTokens] for the one number that is real.
  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {
    // Only once the native session is gone: a failed close leaves it open and
    // owned by the model, so it can be retried.
    await _session.close();
    _onClose();
  }
}
