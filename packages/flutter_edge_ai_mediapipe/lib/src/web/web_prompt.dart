// The conversation of the MediaPipe web session, and how it is written into a
// prompt. Platform-neutral on purpose: no JS here, so VM tests cover it.
//
// `LlmInference.generateResponse` of `@mediapipe/tasks-genai` is stateless:
// every call builds a new native session, so nothing from the previous turn
// survives on the model's side. The session therefore keeps the turns itself,
// the model's replies included, and sends all of them on every call (#705).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';

/// Base class for prompt parts (text, image, audio)
abstract class PromptPart {}

/// Text prompt part
class TextPromptPart extends PromptPart {
  final String text;
  TextPromptPart(this.text);
}

/// Image prompt part with data URL
class ImagePromptPart extends PromptPart {
  final String dataUrl;
  ImagePromptPart(this.dataUrl);

  /// Create ImagePromptPart from Uint8List bytes
  factory ImagePromptPart.fromBytes(Uint8List bytes) {
    final base64String = base64Encode(bytes);
    final mimeType = detectImageMimeType(bytes);
    final dataUrl = 'data:$mimeType;base64,$base64String';
    return ImagePromptPart(dataUrl);
  }
}

/// Audio prompt part with raw audio bytes
/// For Gemma 3n E4B models - supports PCM audio (16kHz, 16-bit, mono)
class AudioPromptPart extends PromptPart {
  final Uint8List audioBytes;
  AudioPromptPart(this.audioBytes);
}

/// The markers a model's chat format writes around each turn.
final class WebChatTemplate {
  const WebChatTemplate({
    required this.userPrefix,
    required this.modelPrefix,
    required this.turnSuffix,
  });

  /// Opens a user turn.
  final String userPrefix;

  /// Opens a model turn. It also ends the prompt: the model writes its reply
  /// after it.
  final String modelPrefix;

  /// Closes a turn, user or model.
  final String turnSuffix;

  /// The format Gemma 4 was trained on.
  static const gemma4 = WebChatTemplate(
    userPrefix: '<|turn>user\n',
    modelPrefix: '<|turn>model\n',
    turnSuffix: '<turn|>\n',
  );

  /// The format of Gemma 3 and Gemma 3n.
  static const gemma3 = WebChatTemplate(
    userPrefix: '<start_of_turn>user\n',
    modelPrefix: '<start_of_turn>model\n',
    turnSuffix: '<end_of_turn>\n',
  );

  @override
  bool operator ==(Object other) =>
      other is WebChatTemplate &&
      other.userPrefix == userPrefix &&
      other.modelPrefix == modelPrefix &&
      other.turnSuffix == turnSuffix;

  @override
  int get hashCode => Object.hash(userPrefix, modelPrefix, turnSuffix);

  @override
  String toString() =>
      'WebChatTemplate(user: ${jsonEncode(userPrefix)}, '
      'model: ${jsonEncode(modelPrefix)}, '
      'end: ${jsonEncode(turnSuffix)})';
}

/// One turn: a user's, with its parts in the order the model reads them, or
/// the model's, as the raw text it wrote.
class _Turn {
  _Turn.user(List<PromptPart> parts)
    : isUser = true,
      parts = [...parts],
      modelText = '';
  _Turn.model(this.modelText) : isUser = false, parts = const [];

  final bool isUser;
  final List<PromptPart> parts;
  String modelText;
}

/// The turns of one session, in order, and what the model is sent for them.
///
/// Consecutive messages of one side form one turn, so a tools prompt followed
/// by the user's question is a single user turn.
final class WebConversation {
  /// [template] is the model's chat format; null writes the turns as plain
  /// text separated by a line break. [maxImages] is the number of images the
  /// model was loaded to accept in one prompt, and the history counts toward
  /// it: every call sends the earlier images again.
  ///
  /// With [preformatted] the messages already carry the model's markers (core
  /// writes them for a `.bin` file and for FunctionGemma), so the turns are
  /// joined as they are, with nothing added between or after them.
  WebConversation({this.template, this.maxImages, this.preformatted = false})
    : assert(!preformatted || template == null);

  final WebChatTemplate? template;
  final int? maxImages;
  final bool preformatted;

  final List<_Turn> _turns = [];
  bool _generating = false;

  /// Whether a generation has begun and not ended.
  bool get isGenerating => _generating;

  /// The number of images in the conversation.
  int get imageCount => _turns.fold(
    0,
    (n, turn) => n + turn.parts.whereType<ImagePromptPart>().length,
  );

  /// Whether the last turn is a user turn the model has not answered.
  bool get hasPendingUserTurn => _turns.isNotEmpty && _turns.last.isUser;

  /// Adds what the user said: [parts] in the order the model should read them.
  ///
  /// Throws [StateError] when the images would exceed [maxImages] or a
  /// generation is running, leaving the conversation as it was. Nothing is
  /// dropped to make room.
  void addUser(List<PromptPart> parts) {
    _requireIdle();
    final added = parts.whereType<ImagePromptPart>().length;
    final limit = maxImages;
    if (limit != null && imageCount + added > limit) {
      throw StateError(
        'This conversation would hold ${imageCount + added} images, but the '
        'model was loaded with maxNumImages: $limit. MediaPipe web sends '
        'every earlier image again with each turn, so the history counts. '
        'Raise maxNumImages when the model is created, or start a new chat.',
      );
    }
    if (hasPendingUserTurn) {
      _turns.last.parts
        ..add(TextPromptPart(preformatted ? '' : '\n'))
        ..addAll(parts);
    } else {
      _turns.add(_Turn.user(parts));
    }
  }

  /// Adds a reply of the model that did not come from this session: a message
  /// the chat replays after it rebuilt the session.
  ///
  /// Throws [StateError] while a generation is running.
  void addModel(String text) {
    _requireIdle();
    _appendModel(text);
  }

  /// A message added while a generation runs would join the turn that is being
  /// answered and leave the next prompt without a user turn to answer.
  void _requireIdle() {
    if (_generating) {
      throw StateError(
        'A generation is running in this session. Wait for it to end, or '
        'stop it, before adding a message.',
      );
    }
  }

  void _appendModel(String text) {
    if (_turns.isNotEmpty && !_turns.last.isUser) {
      _turns.last.modelText += text;
    } else {
      _turns.add(_Turn.model(text));
    }
  }

  /// Starts a generation and returns the prompt for it. Throws [StateError]
  /// when one is running.
  List<PromptPart> beginGeneration() {
    if (_generating) {
      throw StateError('A generation is already running in this session.');
    }
    _generating = true;
    return render();
  }

  /// The generation produced [reply], the raw text of the model.
  void completeGeneration(String reply) {
    _generating = false;
    _appendModel(reply);
  }

  /// The generation was stopped. What was generated until then stays in the
  /// conversation as the model's reply, as it does in a native session's
  /// cache; when nothing was, the user turn stays unanswered.
  void stopGeneration(String generated) {
    _generating = false;
    if (generated.isNotEmpty) _appendModel(generated);
  }

  /// The generation failed. The user's turn stays unanswered, with everything
  /// in it (a system instruction, a tools prompt), as a failed message stays
  /// in the history of a native chat; a retry answers it.
  void failGeneration() {
    _generating = false;
  }

  /// Forgets the conversation.
  void clear() {
    _turns.clear();
    _generating = false;
  }

  /// The prompt for the conversation as it is: every turn, then the opening of
  /// the model's turn. Adjacent text is one part.
  List<PromptPart> render() {
    final t = template;
    final out = <PromptPart>[];
    void text(String s) {
      if (s.isEmpty) return;
      if (out.isNotEmpty && out.last is TextPromptPart) {
        out[out.length - 1] = TextPromptPart(
          (out.last as TextPromptPart).text + s,
        );
      } else {
        out.add(TextPromptPart(s));
      }
    }

    for (var i = 0; i < _turns.length; i++) {
      final turn = _turns[i];
      if (t == null) {
        if (i > 0 && !preformatted) text('\n');
      } else {
        text(turn.isUser ? t.userPrefix : t.modelPrefix);
      }
      if (turn.isUser) {
        for (final part in turn.parts) {
          if (part is TextPromptPart) {
            text(part.text);
          } else {
            out.add(part);
          }
        }
      } else {
        text(turn.modelText);
      }
      if (t != null) text(t.turnSuffix);
    }
    if (t != null) text(t.modelPrefix);
    return out;
  }
}
