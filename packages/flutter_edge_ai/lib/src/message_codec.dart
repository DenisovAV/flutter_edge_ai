import 'dart:convert';
import 'dart:typed_data';

import 'message.dart';
import 'model_response.dart';

/// Which media field a reference stands for: [Message.imageBytes] and
/// [Message.images] are [image], [Message.audioBytes] is [audio].
enum MessageMediaKind { image, audio }

/// Stores [bytes] and returns a reference the app can resolve later (a file
/// name, a key), for [MessageTranscriptCodec.encode].
typedef MessageMediaWriter =
    Future<String> Function(Uint8List bytes, MessageMediaKind kind);

/// Returns the bytes a [MessageMediaWriter] stored under [reference], for
/// [MessageTranscriptCodec.decode].
typedef MessageMediaReader =
    Future<Uint8List> Function(String reference, MessageMediaKind kind);

/// Writes a list of [Message]s as versioned JSON and reads it back (#824).
///
/// For saving a conversation as the user saw it, such as
/// `InferenceChat.fullHistory`. The transcript holds the messages only: not the
/// chat's system instruction, tools or response format, not what the model
/// still holds after a trim, and not its sampling. To continue a saved
/// conversation, open a chat with the app's own configuration and pass the
/// decoded messages to `clearHistory(replayHistory:)`; the model's context is
/// then rebuilt from them, not restored.
///
/// Every field of every message is kept, field for field: [Message.imageBytes]
/// and [Message.images] are written separately, so the same buffer in both
/// (as `Message.withImage` builds it) is written twice. A decoded message is
/// `==` to the one encoded when its tool-call arguments are JSON values: null,
/// bool, a finite number, String, List, or a Map with String keys. [encode]
/// refuses any other argument. Numbers are JSON numbers, not Dart `int` or
/// `double`: on the web an integral `1.0` reads back as `1`, and an integer
/// beyond 2^53 loses precision there.
///
/// Media is written inline as base64 unless a [writeMedia] callback is given,
/// which stores the bytes and returns a reference to write instead. Base64
/// makes the JSON about a third larger than the media, so an app that saves
/// photos or audio should pass one. [decode] resolves a reference through
/// [readMedia] and refuses one when no reader is given; inline media needs
/// no reader. The two callbacks are independent.
final class MessageTranscriptCodec {
  const MessageTranscriptCodec({this.writeMedia, this.readMedia});

  /// The format version this codec writes, and the only one it reads.
  static const int formatVersion = 1;

  /// The value of the `format` key.
  static const String formatName = 'flutter_edge_ai.transcript';

  /// Called once per media buffer by [encode], in message order and, within a
  /// message, [Message.imageBytes], then [Message.images], then
  /// [Message.audioBytes]. Null = inline base64.
  final MessageMediaWriter? writeMedia;

  /// Called once per media reference by [decode], in the same order. Null =
  /// a reference is refused.
  final MessageMediaReader? readMedia;

  /// [messages] as a JSON-ready map: pass it to `jsonEncode`.
  ///
  /// Throws an [ArgumentError] naming the path (for example
  /// `messages[3].toolCalls[0].args.when`) when a tool-call argument is not a
  /// JSON value. An error from [writeMedia] is passed through.
  Future<Map<String, Object?>> encode(List<Message> messages) async {
    final encoded = <Object?>[];
    for (var i = 0; i < messages.length; i++) {
      encoded.add(await _encodeMessage(messages[i], 'messages[$i]'));
    }
    return {
      'format': formatName,
      'version': formatVersion,
      'messages': encoded,
    };
  }

  /// The messages [json] holds, as [encode] wrote them.
  ///
  /// Strict: the `format` must be [formatName] and the `version` exactly
  /// [formatVersion], and every key must be present, none may be added, and
  /// each value must have its JSON type. Anything else is a [FormatException]
  /// naming the path; nothing is defaulted. A media reference without a
  /// [readMedia] is a [FormatException] too. An error from [readMedia] is
  /// passed through.
  Future<List<Message>> decode(Map<String, Object?> json) async {
    final format = json['format'];
    if (format != formatName) {
      throw FormatException(
        'format: expected "$formatName", found ${_describe(format)}',
      );
    }
    final version = json['version'];
    if (version is! int || version != formatVersion) {
      throw FormatException(
        'version: this codec reads version $formatVersion only, found '
        '${_describe(version)}',
      );
    }
    _expectKeys(json, const {'format', 'version', 'messages'}, '');
    final messages = _list(json, 'messages', '');
    final decoded = <Message>[];
    for (var i = 0; i < messages.length; i++) {
      final path = 'messages[$i]';
      final message = messages[i];
      if (message is! Map) {
        throw FormatException(
          '$path: expected an object, found '
          '${_describe(message)}',
        );
      }
      decoded.add(await _decodeMessage(message, path));
    }
    return decoded;
  }

  Future<Map<String, Object?>> _encodeMessage(
    Message message,
    String path,
  ) async {
    final imageBytes = message.imageBytes;
    final audioBytes = message.audioBytes;
    return {
      'type': message.type.name,
      'isUser': message.isUser,
      'text': message.text,
      'imageBytes': imageBytes == null
          ? null
          : await _encodeMedia(imageBytes, MessageMediaKind.image),
      'images': [
        for (final image in message.images)
          await _encodeMedia(image, MessageMediaKind.image),
      ],
      'audioBytes': audioBytes == null
          ? null
          : await _encodeMedia(audioBytes, MessageMediaKind.audio),
      'toolName': message.toolName,
      'toolCalls': [
        for (var i = 0; i < message.toolCalls.length; i++)
          _encodeCall(message.toolCalls[i], '$path.toolCalls[$i]'),
      ],
      'toolCallId': message.toolCallId,
    };
  }

  Future<Map<String, Object?>> _encodeMedia(
    Uint8List bytes,
    MessageMediaKind kind,
  ) async {
    final write = writeMedia;
    if (write == null) return {'base64': base64Encode(bytes)};
    return {'ref': await write(bytes, kind)};
  }

  Map<String, Object?> _encodeCall(FunctionCallResponse call, String path) {
    _checkJsonValue(
      call.args,
      '$path.args',
      (where, what) => ArgumentError('$where: $what is not a JSON value'),
    );
    return {'name': call.name, 'args': call.args, 'id': call.id};
  }

  Future<Message> _decodeMessage(
    Map<Object?, Object?> json,
    String path,
  ) async {
    _expectKeys(json, const {
      'type',
      'isUser',
      'text',
      'imageBytes',
      'images',
      'audioBytes',
      'toolName',
      'toolCalls',
      'toolCallId',
    }, path);
    final typeName = _value<String>(json, 'type', path);
    final type = MessageType.values.asNameMap()[typeName];
    if (type == null) {
      throw FormatException('$path.type: unknown message type "$typeName"');
    }
    final imageBytes = json['imageBytes'];
    final audioBytes = json['audioBytes'];
    final images = _list(json, 'images', path);
    final toolCalls = _list(json, 'toolCalls', path);
    return Message(
      type: type,
      isUser: _value<bool>(json, 'isUser', path),
      text: _value<String>(json, 'text', path),
      imageBytes: imageBytes == null
          ? null
          : await _decodeMedia(
              imageBytes,
              MessageMediaKind.image,
              '$path.imageBytes',
            ),
      images: [
        for (var i = 0; i < images.length; i++)
          await _decodeMedia(
            images[i],
            MessageMediaKind.image,
            '$path.images[$i]',
          ),
      ],
      audioBytes: audioBytes == null
          ? null
          : await _decodeMedia(
              audioBytes,
              MessageMediaKind.audio,
              '$path.audioBytes',
            ),
      toolName: _nullable<String>(json, 'toolName', path),
      toolCalls: List.unmodifiable([
        for (var i = 0; i < toolCalls.length; i++)
          _decodeCall(toolCalls[i], '$path.toolCalls[$i]'),
      ]),
      toolCallId: _nullable<String>(json, 'toolCallId', path),
    );
  }

  Future<Uint8List> _decodeMedia(
    Object? json,
    MessageMediaKind kind,
    String path,
  ) async {
    if (json is! Map) {
      throw FormatException(
        '$path: expected a media object, found ${_describe(json)}',
      );
    }
    if (json.length == 1 && json.containsKey('base64')) {
      final data = _value<String>(json, 'base64', path);
      try {
        return base64Decode(data);
      } on FormatException catch (e) {
        throw FormatException('$path.base64: ${e.message}');
      }
    }
    if (json.length == 1 && json.containsKey('ref')) {
      final reference = _value<String>(json, 'ref', path);
      final read = readMedia;
      if (read == null) {
        throw FormatException(
          '$path.ref: a media reference needs a readMedia callback',
        );
      }
      return read(reference, kind);
    }
    throw FormatException(
      '$path: expected exactly one of "base64" or "ref", found keys '
      '${json.keys.toList()}',
    );
  }

  FunctionCallResponse _decodeCall(Object? json, String path) {
    if (json is! Map) {
      throw FormatException(
        '$path: expected an object, found ${_describe(json)}',
      );
    }
    _expectKeys(json, const {'name', 'args', 'id'}, path);
    final args = json['args'];
    if (args is! Map) {
      throw FormatException(
        '$path.args: expected an object, found ${_describe(args)}',
      );
    }
    _checkJsonValue(
      args,
      '$path.args',
      (where, what) => FormatException('$where: $what is not a JSON value'),
    );
    return FunctionCallResponse(
      name: _value<String>(json, 'name', path),
      // Frozen, as Message.toolCall stores its calls.
      args: Map<String, dynamic>.unmodifiable({
        for (final e in args.entries) e.key as String: frozenCopy(e.value),
      }),
      id: _nullable<String>(json, 'id', path),
    );
  }
}

/// Throws [error] at the first value under [value] that JSON cannot hold.
void _checkJsonValue(
  Object? value,
  String path,
  Object Function(String where, String what) error,
) {
  switch (value) {
    case null || bool() || String():
      return;
    // num, not double: on the web Infinity is also an int.
    case num():
      if (!value.isFinite) throw error(path, '$value');
    case List():
      for (var i = 0; i < value.length; i++) {
        _checkJsonValue(value[i], '$path[$i]', error);
      }
    case Map():
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw error(path, 'the non-string key ${_describe(key)}');
        }
        _checkJsonValue(entry.value, '$path.$key', error);
      }
    default:
      throw error(path, 'a ${value.runtimeType}');
  }
}

void _expectKeys(Map<Object?, Object?> json, Set<String> keys, String path) {
  final where = path.isEmpty ? '' : '$path: ';
  for (final key in json.keys) {
    if (!keys.contains(key)) {
      throw FormatException('${where}unknown key ${_describe(key)}');
    }
  }
  for (final key in keys) {
    if (!json.containsKey(key)) {
      throw FormatException('${where}missing key "$key"');
    }
  }
}

T _value<T extends Object>(
  Map<Object?, Object?> json,
  String key,
  String path,
) {
  final value = json[key];
  if (value is! T) {
    throw FormatException(
      '${_join(path, key)}: expected $T, found ${_describe(value)}',
    );
  }
  return value;
}

T? _nullable<T extends Object>(
  Map<Object?, Object?> json,
  String key,
  String path,
) => json[key] == null ? null : _value<T>(json, key, path);

List<Object?> _list(Map<Object?, Object?> json, String key, String path) {
  final value = json[key];
  if (value is! List) {
    throw FormatException(
      '${_join(path, key)}: expected a list, found ${_describe(value)}',
    );
  }
  return value;
}

String _join(String path, String key) => path.isEmpty ? key : '$path.$key';

String _describe(Object? value) => switch (value) {
  null => 'null',
  String() => '"$value"',
  num() || bool() => '$value',
  _ => 'a ${value.runtimeType}',
};
