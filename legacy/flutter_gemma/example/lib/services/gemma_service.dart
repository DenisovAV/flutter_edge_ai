import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

class GemmaLocalService {
  final InferenceChat _chat;

  GemmaLocalService(this._chat);

  Future<void> addQuery(Message message) => _chat.addQuery(message);

  /// Process message and return stream with sync/async mode support
  Future<Stream<ModelResponse>> processMessage(
    Message message, {
    bool useSyncMode = false,
  }) async {
    debugPrint(
      'GemmaLocalService: processMessage() called with: "${message.text}"',
    );
    debugPrint('GemmaLocalService: Adding query to chat: "${message.text}"');
    await _chat.addQuery(message);

    if (useSyncMode) {
      debugPrint('GemmaLocalService: Using SYNC mode');
      final response = await _chat.generateChatResponse();
      return Stream.fromIterable([response]);
    } else {
      debugPrint('GemmaLocalService: Using ASYNC streaming mode');
      return _chat.generateChatResponseAsync();
    }
  }

  /// Legacy method for backward compatibility
  Stream<ModelResponse> processMessageAsync(Message message) async* {
    await _chat.addQuery(message);
    yield* _chat.generateChatResponseAsync();
  }
}
