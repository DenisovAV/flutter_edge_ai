// A web session over a stub `@litert-lm/core` Conversation (a plain JS
// object): the adapter's LiteRtLmWebSession, over litertlm_dart's shared
// Conversation, over its WebConversationHandle — the whole path a real
// session takes, short of the runtime.
library;

import 'dart:js_interop';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/web_inference_model.dart';
import 'package:litertlm_dart/internal_web.dart'
    show JsLiteRtLmConversation, WebConversationHandle, conversationForTest;
import 'package:mutex/mutex.dart';

LiteRtLmWebSession webSessionOver(
  JSObject conversation, {
  ModelType modelType = ModelType.gemmaIt,
  Mutex? generationMutex,
  int? maxOutputTokens,
  void Function()? onClose,
  bool supportImage = false,
  bool supportAudio = false,
}) {
  final handle = WebConversationHandle(
    conversation as JsLiteRtLmConversation,
    enableThinking: false,
    extraContext: const {},
    onGeneration: () {},
    // A stop marks the conversation for a rebuild before its NEXT turn; these
    // suites send none after a stop.
    rebuild: (_) => throw StateError('no rebuild in this fixture'),
    vision: supportImage,
    audio: supportAudio,
  );
  return LiteRtLmWebSession(
    conversation: conversationForTest(handle),
    modelType: modelType,
    fileType: ModelFileType.litertlm,
    generationMutex: generationMutex ?? Mutex(),
    maxOutputTokens: maxOutputTokens,
    onClose: onClose ?? () {},
    supportImage: supportImage,
    supportAudio: supportAudio,
    multimodalOrder: MultimodalOrder.forModelType(modelType),
  );
}
