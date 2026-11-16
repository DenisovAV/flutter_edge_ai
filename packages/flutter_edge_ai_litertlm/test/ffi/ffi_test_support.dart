// Test helpers: an FfiInferenceModel over a fake LiteRtLmFfiClient, and an
// FfiInferenceModelSession over a fake ConversationHandle, through
// litertlm_dart's test constructors.
import 'dart:convert';

import 'package:flutter/foundation.dart' show Uint8List, VoidCallback;
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/litertlm_decision_section.dart';
import 'package:litertlm_dart/internal_io.dart'
    show ConversationHandle, LiteRtLmFfiClient, OpenSessionBacking;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

/// A model over [ffiClient], for tests that drive it with a fake client.
FfiInferenceModel ffiModelForClient({
  required LiteRtLmFfiClient ffiClient,
  required int maxTokens,
  required ModelType modelType,
  required PreferredBackend? activeBackend,
  LitetuneDecisionRead? decisionRead,
  ModelFileType fileType = ModelFileType.litertlm,
  bool supportImage = false,
  bool supportAudio = false,
  MultimodalOrder? multimodalOrder,
  int? maxConcurrentSessions,
  OpenSessionBacking openSessionBacking = OpenSessionBacking.virtual,
  bool? linearAttentionState = false,
  int? thinkingTokenBudget,
  StructuredOutputSupport structuredOutput = const StructuredOutputSupport.none(
    'This LiteRT-LM model was not loaded through LiteRtLmEngine.',
  ),
  required VoidCallback onClose,
}) => FfiInferenceModel(
  engine: lm.Engine.forTest(
    ffiClient,
    backend: switch (activeBackend) {
      PreferredBackend.gpu => const lm.Backend.gpu(),
      PreferredBackend.npu => const lm.Backend.npu(),
      PreferredBackend.cpu || null => const lm.Backend.cpu(),
    },
    maxNumTokens: maxTokens,
    backing: openSessionBacking,
    linearAttentionState: linearAttentionState,
  ),
  maxTokens: maxTokens,
  modelType: modelType,
  activeBackend: activeBackend,
  decisionRead: decisionRead,
  fileType: fileType,
  supportImage: supportImage,
  supportAudio: supportAudio,
  multimodalOrder: multimodalOrder,
  maxConcurrentSessions: maxConcurrentSessions,
  thinkingTokenBudget: thinkingTokenBudget,
  structuredOutput: structuredOutput,
  onClose: onClose,
);

/// A session over [handle], for tests that drive it with a fake.
FfiInferenceModelSession ffiSessionForHandle({
  required ConversationHandle handle,
  required ModelType modelType,
  required ModelFileType fileType,
  required bool supportImage,
  required bool supportAudio,
  MultimodalOrder multimodalOrder = const MultimodalOrder(),
  bool enableThinking = false,
  int? thinkingTokenBudget,
  int? maxOutputTokens,
  required VoidCallback onClose,
}) => FfiInferenceModelSession(
  conversation: lm.Conversation.forTest(handle),
  modelType: modelType,
  fileType: fileType,
  supportImage: supportImage,
  supportAudio: supportAudio,
  multimodalOrder: multimodalOrder,
  enableThinking: enableThinking,
  thinkingTokenBudget: thinkingTokenBudget,
  maxOutputTokens: maxOutputTokens,
  onClose: onClose,
);

/// What a message the session sent carries, read back from its JSON: its
/// role, its text parts joined, its images and its audio, in order.
({
  String role,
  String text,
  List<Uint8List> images,
  Uint8List? audio,
  List<String> order,
})
sentMessage(String messageJson) {
  final json = jsonDecode(messageJson) as Map<String, Object?>;
  final text = StringBuffer();
  final images = <Uint8List>[];
  Uint8List? audio;
  final order = <String>[];
  for (final part in (json['content'] as List<Object?>? ?? const [])) {
    final p = part! as Map<String, Object?>;
    order.add(p['type']! as String);
    switch (p['type']) {
      case 'text':
        text.write(p['text']);
      case 'image':
        images.add(base64Decode(p['blob']! as String));
      case 'audio':
        audio = base64Decode(p['blob']! as String);
    }
  }
  return (
    role: json['role']! as String,
    text: text.toString(),
    images: images,
    audio: audio,
    order: order,
  );
}
