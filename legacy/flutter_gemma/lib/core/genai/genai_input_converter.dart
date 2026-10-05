import 'dart:convert';
import 'dart:typed_data';

import 'package:genai_primitives/genai_primitives.dart';

import '../message.dart';

/// Converts a genai_primitives [ChatMessage] into flutter_gemma [Message]s.
///
/// One ChatMessage may yield >1 Message (tool results become sibling messages).
/// The text/media parts collapse into a single [Message] emitted FIRST, then
/// one sibling [Message] per tool result in part order. A [ThinkingPart] on a
/// model turn is stripped by design (thoughts aren't fed back as history), so a
/// thought-only model turn yields no Message; a [ThinkingPart] on a user turn is
/// misuse and throws. A [LinkPart] also throws: this inference layer does not
/// fetch URLs or read files — resolve links to bytes caller-side and pass a
/// [DataPart]. Other unsupported content throws rather than being silently
/// dropped.
Future<List<Message>> messagesFromChatMessage(ChatMessage message) async {
  if (message.role == ChatMessageRole.system) {
    throw ArgumentError(
      'System messages are not input — set them via createChat(systemInstruction:).',
    );
  }
  final parts = message.parts;
  if (parts.isEmpty) {
    throw ArgumentError('ChatMessage has no parts.');
  }
  final isUser = message.role == ChatMessageRole.user;

  final images = <Uint8List>[];
  Uint8List? audio;
  final messages = <Message>[];

  for (final part in parts) {
    switch (part) {
      case DataPart(:final bytes, :final mimeType):
        audio = _routeMedia(bytes, mimeType, images, audio);
      case LinkPart():
        throw UnsupportedError(
          'LinkPart is not resolved by flutter_gemma: an on-device model needs '
          'the media bytes, and this inference layer does not fetch URLs or read '
          'files. Resolve the link yourself and pass a DataPart with the bytes. '
          '(For URL/web content behind a permission gate, use flutter_gemma_agent.)',
        );
      case ToolPart(kind: ToolPartKind.result, :final toolName, :final result):
        if (!isUser) {
          throw UnsupportedError(
            'A tool result is caller input, not model output.',
          );
        }
        final resp = result is Map<String, dynamic>
            ? result
            : {'result': result};
        messages.add(Message.toolResponse(toolName: toolName, response: resp));
      case ToolPart(kind: ToolPartKind.call, :final toolName, :final arguments):
        if (isUser) {
          throw UnsupportedError(
            'A tool call is model output, not user input.',
          );
        }
        messages.add(
          Message.toolCall(
            text: jsonEncode({'name': toolName, 'parameters': arguments ?? {}}),
          ),
        );
      case ThinkingPart():
        // A model turn's thought is stripped from history: Gemma re-feeds the
        // answer, not the reasoning (see the thinking docs' thought-stripping),
        // so a model turn returned by the output converter round-trips back in.
        // A user-role thought is misuse — thoughts are model output, fail loud.
        if (isUser) {
          throw UnsupportedError(
            'A ThinkingPart is model output, not user input.',
          );
        }
      case TextPart():
      // No-op: TextPart text is read from `message.text` after the loop.
    }
  }

  final text = message.text;
  if (text.isNotEmpty || images.isNotEmpty || audio != null) {
    messages.insert(
      0,
      Message(
        text: text,
        isUser: isUser,
        images: images,
        imageBytes: images.isNotEmpty ? images.first : null,
        audioBytes: audio,
      ),
    );
  }
  // A user turn that reduces to zero staged Messages (e.g. a lone empty
  // TextPart) would otherwise stage nothing and generate on stale context —
  // fail loud instead. A model turn legitimately reduces to [] (a thought-only
  // turn strips its ThinkingPart), so only guard user input.
  if (isUser && messages.isEmpty) {
    throw ArgumentError(
      'ChatMessage reduced to no staged content — a user turn needs text, '
      'media, or a tool result.',
    );
  }
  return messages;
}

/// Converts a list of [ChatMessage]s to flutter_gemma [Message]s in order,
/// concatenating each message's expansion (see [messagesFromChatMessage]).
Future<List<Message>> messagesFromChatMessages(
  List<ChatMessage> messages,
) async {
  final out = <Message>[];
  for (final m in messages) {
    out.addAll(await messagesFromChatMessage(m));
  }
  return out;
}

/// Adds an image part to [images], or returns audio bytes as the message audio.
/// Returns the audio value the caller should keep: [current] for an image,
/// the new bytes for an audio part. Throws on a second audio or a non-media mime.
Uint8List? _routeMedia(
  Uint8List bytes,
  String? mimeType,
  List<Uint8List> images,
  Uint8List? current,
) {
  final mime = mimeType ?? '';
  if (mime.startsWith('image/')) {
    images.add(bytes);
    return current;
  }
  if (mime.startsWith('audio/')) {
    if (current != null) {
      throw UnsupportedError('Only one audio part per message is supported.');
    }
    return bytes;
  }
  throw UnsupportedError('Unsupported DataPart mime "$mime".');
}

/// Throws if any message needs a capability the chat wasn't built with,
/// so the engine never silently drops image/audio/tool content.
void assertMessagesFitChat(
  List<Message> messages, {
  required bool supportImage,
  required bool supportAudio,
  required bool supportsFunctionCalls,
}) {
  for (final m in messages) {
    if (m.hasImage && !supportImage) {
      throw UnsupportedError(
        'This chat was created without image support; recreate it with a vision model.',
      );
    }
    if (m.hasAudio && !supportAudio) {
      throw UnsupportedError(
        'This chat was created without audio support; recreate it with an audio model.',
      );
    }
    if ((m.type == MessageType.toolResponse ||
            m.type == MessageType.toolCall) &&
        !supportsFunctionCalls) {
      throw UnsupportedError(
        'This chat was created without function-call support (tools were not passed to createChat).',
      );
    }
  }
}
