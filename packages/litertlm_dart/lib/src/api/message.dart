// Messages, their parts, tool declarations and calls: LiteRT-LM's Kotlin and
// Swift `Message`, `Content`, `ToolCall`, with the Conversation API JSON they
// are sent and read as (`messageJson`, `messageFromJson`), internal.

import 'dart:async' show FutureOr;
import 'dart:convert' show base64Encode, jsonDecode, jsonEncode;
import 'dart:typed_data' show Uint8List;

import 'package:meta/meta.dart' show immutable;

/// Who said a message.
enum Role {
  system('system'),
  user('user'),
  model('assistant'),
  tool('tool');

  const Role(this.wireName);

  /// The `role` of the Conversation API JSON.
  final String wireName;

  static Role _fromWire(Object? name) => switch (name) {
    'system' => Role.system,
    'user' => Role.user,
    'tool' => Role.tool,
    _ => Role.model,
  };
}

/// One message: its [role], its parts in order, the calls a model reply
/// made, and its channel contents (a reply's thought is `channels['thought']`).
///
/// A streamed reply arrives as several messages, each a piece of it.
@immutable
final class Message {
  Message({
    required this.role,
    List<Content> contents = const [],
    List<ToolCall> toolCalls = const [],
    Map<String, String> channels = const {},
  }) : contents = List.unmodifiable(contents),
       toolCalls = List.unmodifiable(toolCalls),
       channels = Map.unmodifiable(channels);

  /// A user message of [text] alone.
  factory Message.user(String text) =>
      Message(role: Role.user, contents: [Content.text(text)]);

  /// A model reply of [text] alone (for history).
  factory Message.model(String text) =>
      Message(role: Role.model, contents: [Content.text(text)]);

  /// A system message of [text].
  factory Message.system(String text) =>
      Message(role: Role.system, contents: [Content.text(text)]);

  /// The answer to a reply's tool calls: one [ToolResponseContent] per call.
  factory Message.tool(List<Content> contents) =>
      Message(role: Role.tool, contents: contents);

  final Role role;
  final List<Content> contents;
  final List<ToolCall> toolCalls;
  final Map<String, String> channels;

  /// The text parts, joined.
  String get text =>
      contents.whereType<TextContent>().map((c) => c.text).join();

  @override
  String toString() =>
      'Message(${role.name}, $contents'
      '${toolCalls.isEmpty ? '' : ', toolCalls: $toolCalls'}'
      '${channels.isEmpty ? '' : ', channels: $channels'})';
}

/// One part of a message. Built with the factories; matched on the
/// subclasses.
@immutable
sealed class Content {
  const Content._();

  const factory Content.text(String text) = TextContent;

  /// An encoded image (JPEG, PNG, …) in memory.
  factory Content.imageBytes(Uint8List bytes) = ImageBytesContent;

  /// An image file LiteRT-LM reads itself.
  const factory Content.imageFile(String path) = ImageFileContent;

  /// Encoded audio (WAV, MP3, FLAC, …) in memory.
  factory Content.audioBytes(Uint8List bytes) = AudioBytesContent;

  /// An audio file LiteRT-LM reads itself.
  const factory Content.audioFile(String path) = AudioFileContent;

  /// The result of the tool call named [name]. A map is formatted as the
  /// call's fields; anything else goes in as it is. [id] is the call's
  /// [ToolCall.id], sent as the response's `id` when set: Swift's
  /// `Content.toolResponse(name:response:id:)` (Message.swift), which writes
  /// it only when not empty, as here. On the web it goes as
  /// `Tool <name> returned: <JSON>` user text (see the README, "On the
  /// web").
  const factory Content.toolResponse(
    String name,
    Object? response, {
    String? id,
  }) = ToolResponseContent;
}

final class TextContent extends Content {
  const TextContent(this.text) : super._();
  final String text;
  @override
  String toString() =>
      'text(${text.length > 40 ? '${text.substring(0, 40)}…' : text})';
}

final class ImageBytesContent extends Content {
  ImageBytesContent(Uint8List bytes)
    : bytes = Uint8List.fromList(bytes),
      super._();
  final Uint8List bytes;
  @override
  String toString() => 'image(${bytes.length} bytes)';
}

final class ImageFileContent extends Content {
  const ImageFileContent(this.path) : super._();
  final String path;
  @override
  String toString() => 'image($path)';
}

final class AudioBytesContent extends Content {
  AudioBytesContent(Uint8List bytes)
    : bytes = Uint8List.fromList(bytes),
      super._();
  final Uint8List bytes;
  @override
  String toString() => 'audio(${bytes.length} bytes)';
}

final class AudioFileContent extends Content {
  const AudioFileContent(this.path) : super._();
  final String path;
  @override
  String toString() => 'audio($path)';
}

final class ToolResponseContent extends Content {
  const ToolResponseContent(this.name, this.response, {this.id}) : super._();
  final String name;
  final Object? response;

  /// The id of the call this answers; null or empty sends none.
  final String? id;
  @override
  String toString() => 'toolResponse($name${id == null ? '' : ', id: $id'})';
}

/// A call a model reply made: the function's [name], its [arguments], and
/// the call's [id] when the reply gave one.
@immutable
final class ToolCall {
  /// [id] is Swift's `ToolCall.id` (Message.swift): read from the call's
  /// `id` in the reply, written back as its `id` when the call is part of a
  /// message sent (history, `initialMessages`); null when the reply gave
  /// none. Kotlin's `ToolCall` has no id.
  ToolCall(this.name, Map<String, Object?> arguments, {this.id})
    : arguments = Map.unmodifiable(arguments);

  final String name;
  final Map<String, Object?> arguments;

  /// The call's id; null when the reply gave none.
  final String? id;

  @override
  String toString() =>
      'ToolCall($name, $arguments${id == null ? '' : ', id: $id'})';
}

/// A function the model may call: its [name], what it does, its parameters
/// as a JSON Schema object, and optionally the code that runs it.
@immutable
final class Tool {
  Tool({
    required this.name,
    this.description = '',
    Map<String, Object?> parameters = const {},
    this.execute,
  }) : parameters = Map.unmodifiable(parameters) {
    if (name.isEmpty) throw ArgumentError.value(name, 'name', 'is empty');
  }

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  /// Runs a call of this tool with the call's arguments and returns its
  /// result: any JSON value (a map, a list, a string, a number, a bool or
  /// null), sent back to the model as the call's response. A map is
  /// formatted as the response's fields.
  ///
  /// With `ConversationConfig.automaticToolCalling` on (the default), the
  /// conversation calls it itself and continues the reply, as Kotlin's and
  /// Swift's do. If it throws, or returns a value that is not JSON, the
  /// model gets the error as text (`Error: …`) instead of a result and the
  /// reply continues. Null: the call reaches the caller, who answers it
  /// with `Message.tool`. On the web the result goes as
  /// `Tool <name> returned: <JSON>` user text.
  final FutureOr<Object?> Function(Map<String, Object?> arguments)? execute;
}

/// [message] as the Conversation API JSON object native reads.
Map<String, Object?> messageJson(Message message) => {
  'role': message.role.wireName,
  if (message.contents.isNotEmpty || message.toolCalls.isEmpty)
    'content': [for (final c in message.contents) _contentJson(c)],
  if (message.toolCalls.isNotEmpty)
    'tool_calls': [
      for (final call in message.toolCalls)
        {
          if (call.id case final id? when id.isNotEmpty) 'id': id,
          'type': 'function',
          'function': {'name': call.name, 'arguments': call.arguments},
        },
    ],
  if (message.channels.isNotEmpty) 'channels': message.channels,
};

Map<String, Object?> _contentJson(Content content) => switch (content) {
  TextContent(:final text) => {'type': 'text', 'text': text},
  ImageBytesContent(:final bytes) => {
    'type': 'image',
    'blob': base64Encode(bytes),
  },
  ImageFileContent(:final path) => {'type': 'image', 'path': path},
  AudioBytesContent(:final bytes) => {
    'type': 'audio',
    'blob': base64Encode(bytes),
  },
  AudioFileContent(:final path) => {'type': 'audio', 'path': path},
  ToolResponseContent(:final name, :final response, :final id) => {
    'type': 'tool_response',
    'name': name,
    'response': response,
    if (id != null && id.isNotEmpty) 'id': id,
  },
};

/// The `tools_json` native reads for [tools], or null for none.
String? toolsJson(List<Tool> tools) => tools.isEmpty
    ? null
    : jsonEncode([
        for (final tool in tools)
          {
            'type': 'function',
            'function': {
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
            },
          },
      ]);

/// The JSON native wrote for a message parsed from a reply chunk
/// ([messageFromChunk]).
final _rawJson = Expando<String>('rawJson');

/// The JSON native wrote for [message], when it was parsed from a reply
/// chunk: the Flutter adapter hands it to core's own parser, which reads what
/// [Message] does not keep (a call's id).
String? messageRawJson(Message message) => _rawJson[message];

/// The message one streamed chunk of a reply carries. A chunk that is not a
/// JSON object is text.
Message messageFromChunk(String chunk) {
  final Object? json;
  try {
    json = jsonDecode(chunk);
  } on FormatException {
    return Message.model(chunk);
  }
  if (json is! Map<String, Object?>) return Message.model(chunk);
  final message = messageFromJson(json);
  _rawJson[message] = chunk;
  return message;
}

/// A Conversation API JSON object as a [Message]. Parts of a type it does not
/// know are left out.
Message messageFromJson(Map<String, Object?> json) {
  final contents = <Content>[];
  switch (json['content']) {
    case final String text:
      contents.add(Content.text(text));
    case final List<Object?> parts:
      for (final part in parts) {
        if (part case {'type': 'text', 'text': final String text}) {
          contents.add(Content.text(text));
        }
      }
    case null:
      break;
    case final other:
      throw StateError(
        'LiteRT-LM response content is ${other.runtimeType}, not a string '
        'or a list of parts: ${jsonEncode(json)}',
      );
  }
  final calls = switch (json['tool_calls']) {
    final List<Object?> list => _wholeTurn(list),
    _ => const <ToolCall>[],
  };
  final channels = <String, String>{};
  if (json['channels'] case final Map<String, Object?> map) {
    for (final MapEntry(:key, :value) in map.entries) {
      if (value is String) channels[key] = value;
    }
  }
  return Message(
    role: Role._fromWire(json['role']),
    contents: contents,
    toolCalls: calls,
    channels: channels,
  );
}

/// Every call of [items], or none when one of them cannot be read, as core's
/// parser reads a turn: a call with arguments that are not a JSON object
/// would run with none, and a reply cut mid-arguments by maxOutputTokens is
/// one. A call is OpenAI's `{type: function, function: {name, arguments}}`
/// or a flat `{name, arguments}`.
List<ToolCall> _wholeTurn(List<Object?> items) {
  final calls = <ToolCall>[];
  for (final item in items) {
    final call = _call(item);
    if (call == null) return const [];
    calls.add(call);
  }
  return calls;
}

ToolCall? _call(Object? raw) {
  if (raw is! Map<String, Object?>) return null;
  final function = switch (raw['function']) {
    final Map<String, Object?> function => function,
    _ => raw,
  };
  final name = function['name'];
  if (name is! String || name.isEmpty) return null;
  final arguments = _arguments(function['arguments']);
  if (arguments == null) return null;
  // The id sits beside `function` in OpenAI's shape (Swift reads
  // `item["id"]`), beside the name in the flat one.
  final id = raw['id'];
  return ToolCall(name, arguments, id: id is String ? id : null);
}

/// A call's arguments: absent or blank is none, an object, or a string
/// holding one; anything else cannot be read (null).
Map<String, Object?>? _arguments(Object? arguments) {
  if (arguments == null) return const {};
  if (arguments is Map<String, Object?>) return arguments;
  if (arguments is! String) return null;
  if (arguments.trim().isEmpty) return const {};
  try {
    return switch (jsonDecode(arguments)) {
      final Map<String, Object?> map => map,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}
