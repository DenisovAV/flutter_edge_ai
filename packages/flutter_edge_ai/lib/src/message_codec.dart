import 'dart:convert';
import 'dart:typed_data';

import 'message.dart';
import 'model_response.dart';

/// Which media field a buffer belongs to: [Message.imageBytes] and
/// [Message.images] are [image], [Message.audioBytes] is [audio].
///
/// More kinds may be added: give a `switch` over it a default.
enum MessageMediaKind { image, audio }

/// A media buffer [MessageTranscriptCodec.encode] hands to its
/// [MessageTranscriptCodec.writeMedia].
final class MessageMedia {
  const MessageMedia({
    required this.bytes,
    required this.kind,
    required this.path,
  });

  /// The message's own buffer: copy it if you keep it past the call.
  final Uint8List bytes;

  final MessageMediaKind kind;

  /// Where the buffer is in the list being encoded, such as
  /// `messages[3].images[0]`: with a save id, enough for a unique, stable
  /// reference.
  final String path;
}

/// A media reference [MessageTranscriptCodec.decode] hands to its
/// [MessageTranscriptCodec.readMedia].
final class MessageMediaReference {
  const MessageMediaReference({
    required this.reference,
    required this.kind,
    required this.path,
  });

  /// What [MessageTranscriptCodec.writeMedia] returned.
  final String reference;

  final MessageMediaKind kind;

  /// Where the reference is in the transcript being decoded, such as
  /// `messages[3].images[0]`: the first place it appears.
  final String path;
}

/// Stores [MessageMedia.bytes] and returns a reference the app can resolve
/// later (a file name, a key), for [MessageTranscriptCodec.encode].
typedef MessageMediaWriter = Future<String> Function(MessageMedia media);

/// Returns the bytes a [MessageMediaWriter] stored under
/// [MessageMediaReference.reference], for [MessageTranscriptCodec.decode].
typedef MessageMediaReader =
    Future<Uint8List> Function(MessageMediaReference reference);

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
/// Every field of every message is kept, field for field. A decoded message is
/// `==` to the one encoded when its tool-call arguments are JSON values: null,
/// bool, a finite number, String, List, or a Map with String keys. [encode]
/// refuses any other argument, before it writes any media. Numbers are JSON
/// numbers, not Dart `int` or `double`: on the web an integral `1.0` reads back
/// as `1`, and an integer beyond 2^53 loses precision there.
///
/// `Message.withImage` puts one buffer in [Message.imageBytes] and
/// [Message.images]. [decode] gives both fields one buffer again whenever
/// `imageBytes` has the same bytes as the first image, so an engine that skips
/// the duplicate by identity still sees the photo once.
///
/// Media is written inline as base64 unless a [writeMedia] callback is given,
/// which stores the bytes and returns a reference to write instead. Base64
/// makes the JSON about a third larger than the media, so an app that saves
/// photos or audio should pass one. [decode] resolves a reference through
/// [readMedia] and refuses one when no reader is given; inline media needs
/// no reader. The two callbacks are independent.
///
/// The format is versioned: [decode] reads [formatVersion] only, so a file
/// written by a newer build is a [FormatException]. An app that wants to say
/// "saved by a newer version" compares `json['version']` with [formatVersion]
/// first.
final class MessageTranscriptCodec {
  const MessageTranscriptCodec({this.writeMedia, this.readMedia});

  /// The format version this codec writes, and the only one it reads.
  static const int formatVersion = 1;

  /// The value of the `format` key.
  static const String formatName = 'flutter_edge_ai.transcript';

  /// Called by [encode] in message order and, within a message,
  /// [Message.imageBytes], then [Message.images], then [Message.audioBytes];
  /// once per buffer: a buffer `identical` to one already written in the
  /// same call reuses its reference. Null = inline base64.
  ///
  /// A reference must stay unique across saves, or name the content (a hash):
  /// a later save that reuses it for other bytes changes what an earlier
  /// transcript reads back. Within one [encode], a reference returned for
  /// different bytes is a [StateError].
  final MessageMediaWriter? writeMedia;

  /// Called by [decode] once per distinct reference, in the same order, after
  /// the whole transcript is checked. Null = a reference is refused.
  final MessageMediaReader? readMedia;

  /// [messages] as a JSON-ready map: pass it to `jsonEncode`.
  ///
  /// Throws an [ArgumentError] naming the path (for example
  /// `messages[3].toolCalls[0].args.when`) when a tool-call argument is not a
  /// JSON value, a cycle included; every argument is checked before
  /// [writeMedia] is first called. An error from [writeMedia] is passed
  /// through.
  Future<Map<String, Object?>> encode(List<Message> messages) async {
    // Every argument first, with no await: a refused transcript writes no media.
    final calls = [
      for (var i = 0; i < messages.length; i++)
        [
          for (var c = 0; c < messages[i].toolCalls.length; c++)
            _encodeCall(messages[i].toolCalls[c], 'messages[$i].toolCalls[$c]'),
        ],
    ];
    final media = _MediaWriter(writeMedia);
    final encoded = <Object?>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final path = 'messages[$i]';
      final imageBytes = message.imageBytes;
      final audioBytes = message.audioBytes;
      encoded.add({
        'type': message.type.name,
        'isUser': message.isUser,
        'text': message.text,
        'imageBytes': imageBytes == null
            ? null
            : await media.write(
                imageBytes,
                MessageMediaKind.image,
                '$path.imageBytes',
              ),
        'images': [
          for (var m = 0; m < message.images.length; m++)
            await media.write(
              message.images[m],
              MessageMediaKind.image,
              '$path.images[$m]',
            ),
        ],
        'audioBytes': audioBytes == null
            ? null
            : await media.write(
                audioBytes,
                MessageMediaKind.audio,
                '$path.audioBytes',
              ),
        'toolName': message.toolName,
        'toolCalls': calls[i],
        'toolCallId': message.toolCallId,
      });
    }
    return {
      'format': formatName,
      'version': formatVersion,
      'messages': encoded,
    };
  }

  /// The messages [json] holds, as [encode] wrote them.
  ///
  /// Strict: [json] must be an object, its `format` [formatName] and its
  /// `version` exactly [formatVersion]; every key must be present, none may be
  /// added, each value must have its JSON type, and base64 must be the
  /// standard alphabet with padding. Anything else is a [FormatException]
  /// naming the path; nothing is defaulted. A media reference without a
  /// [readMedia] is a [FormatException] too. The whole transcript is checked
  /// before [readMedia] is first called; an error from it is passed through.
  Future<List<Message>> decode(Object? json) async {
    if (json is! Map) {
      throw FormatException(
        'transcript: expected an object, found ${_describe(json)}',
      );
    }
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
    final list = _list(json, 'messages', '');
    // The whole structure first, with no await: a malformed file reads no
    // media.
    final parsed = [
      for (var i = 0; i < list.length; i++)
        _parseMessage(list[i], 'messages[$i]'),
    ];
    final read = readMedia;
    final references = <String, Future<Uint8List>>{};
    Future<Uint8List> resolve(_Media media) async => switch (media) {
      _InlineMedia(:final bytes) => bytes,
      // Checked in _parseMedia: no reference without a reader.
      _ReferencedMedia(:final reference, :final kind, :final path) =>
        references[reference] ??= read!(
          MessageMediaReference(reference: reference, kind: kind, path: path),
        ),
    };
    final decoded = <Message>[];
    for (final message in parsed) {
      final imageBytes = message.imageBytes == null
          ? null
          : await resolve(message.imageBytes!);
      final images = [for (final image in message.images) await resolve(image)];
      if (imageBytes != null &&
          images.isNotEmpty &&
          !identical(imageBytes, images.first) &&
          _sameBytes(imageBytes, images.first)) {
        images[0] = imageBytes;
      }
      decoded.add(
        Message(
          type: message.type,
          isUser: message.isUser,
          text: message.text,
          imageBytes: imageBytes,
          images: images,
          audioBytes: message.audioBytes == null
              ? null
              : await resolve(message.audioBytes!),
          toolName: message.toolName,
          toolCalls: message.toolCalls,
          toolCallId: message.toolCallId,
        ),
      );
    }
    return decoded;
  }

  Map<String, Object?> _encodeCall(FunctionCallResponse call, String path) {
    _checkJsonValue(
      call.args,
      '$path.args',
      (where, what) => ArgumentError('$where: $what is not a JSON value'),
    );
    // A copy: the result cannot change between encode and jsonEncode.
    return {'name': call.name, 'args': frozenCopy(call.args), 'id': call.id};
  }

  _ParsedMessage _parseMessage(Object? json, String path) {
    if (json is! Map) {
      throw FormatException(
        '$path: expected an object, found ${_describe(json)}',
      );
    }
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
    return _ParsedMessage(
      type: type,
      isUser: _value<bool>(json, 'isUser', path),
      text: _value<String>(json, 'text', path),
      imageBytes: imageBytes == null
          ? null
          : _parseMedia(imageBytes, MessageMediaKind.image, '$path.imageBytes'),
      images: [
        for (var i = 0; i < images.length; i++)
          _parseMedia(images[i], MessageMediaKind.image, '$path.images[$i]'),
      ],
      audioBytes: audioBytes == null
          ? null
          : _parseMedia(audioBytes, MessageMediaKind.audio, '$path.audioBytes'),
      toolName: _nullable<String>(json, 'toolName', path),
      toolCalls: List.unmodifiable([
        for (var i = 0; i < toolCalls.length; i++)
          _decodeCall(toolCalls[i], '$path.toolCalls[$i]'),
      ]),
      toolCallId: _nullable<String>(json, 'toolCallId', path),
    );
  }

  _Media _parseMedia(Object? json, MessageMediaKind kind, String path) {
    if (json is! Map) {
      throw FormatException(
        '$path: expected a media object, found ${_describe(json)}',
      );
    }
    if (json.length == 1 && json.containsKey('base64')) {
      return _InlineMedia(
        _decodeBase64(_value<String>(json, 'base64', path), '$path.base64'),
      );
    }
    if (json.length == 1 && json.containsKey('ref')) {
      final reference = _value<String>(json, 'ref', path);
      if (readMedia == null) {
        throw FormatException(
          '$path.ref: a media reference needs a readMedia callback',
        );
      }
      return _ReferencedMedia(reference, kind, path);
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

/// The media writes of one [MessageTranscriptCodec.encode] call.
final class _MediaWriter {
  _MediaWriter(this._write);

  final MessageMediaWriter? _write;

  /// The reference written for each buffer, by identity.
  final _written = Map<Uint8List, String>.identity();

  /// The first buffer written under each reference, and where.
  final _owners = <String, MessageMedia>{};

  Future<Map<String, Object?>> write(
    Uint8List bytes,
    MessageMediaKind kind,
    String path,
  ) async {
    final write = _write;
    if (write == null) return {'base64': base64Encode(bytes)};
    final known = _written[bytes];
    if (known != null) return {'ref': known};
    final media = MessageMedia(bytes: bytes, kind: kind, path: path);
    final reference = await write(media);
    final owner = _owners[reference];
    if (owner == null) {
      _owners[reference] = media;
    } else if (!_sameBytes(owner.bytes, bytes)) {
      throw StateError(
        '$path: writeMedia returned "$reference", already returned for '
        'different bytes at ${owner.path}',
      );
    }
    _written[bytes] = reference;
    return {'ref': reference};
  }
}

/// A message checked by [MessageTranscriptCodec.decode], media not yet read.
final class _ParsedMessage {
  _ParsedMessage({
    required this.type,
    required this.isUser,
    required this.text,
    required this.imageBytes,
    required this.images,
    required this.audioBytes,
    required this.toolName,
    required this.toolCalls,
    required this.toolCallId,
  });

  final MessageType type;
  final bool isUser;
  final String text;
  final _Media? imageBytes;
  final List<_Media> images;
  final _Media? audioBytes;
  final String? toolName;
  final List<FunctionCallResponse> toolCalls;
  final String? toolCallId;
}

sealed class _Media {}

final class _InlineMedia extends _Media {
  _InlineMedia(this.bytes);

  final Uint8List bytes;
}

final class _ReferencedMedia extends _Media {
  _ReferencedMedia(this.reference, this.kind, this.path);

  final String reference;
  final MessageMediaKind kind;
  final String path;
}

/// The standard alphabet with padding: `base64Decode` alone also takes the
/// URL-safe one and `%3D`.
final _base64Pattern = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');
final _notBase64 = RegExp(r'[^A-Za-z0-9+/=]|=(?=[^=])');

Uint8List _decodeBase64(String data, String path) {
  if (data.length % 4 != 0 || !_base64Pattern.hasMatch(data)) {
    throw FormatException(
      '$path: expected standard base64 with padding',
      data,
      _notBase64.firstMatch(data)?.start ?? data.length,
    );
  }
  try {
    return base64Decode(data);
  } on FormatException catch (e) {
    throw FormatException('$path: ${e.message}', e.source, e.offset);
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Throws [error] at the first value under [value] that JSON cannot hold.
void _checkJsonValue(
  Object? value,
  String path,
  Object Function(String where, String what) error, [
  Set<Object>? enclosing,
]) {
  switch (value) {
    case null || bool() || String():
      return;
    // num, not double: on the web Infinity is also an int.
    case num():
      if (!value.isFinite) throw error(path, '$value');
    case List() || Map():
      // The collections on the current path only: a value repeated in two
      // places is fine, one that contains itself is a cycle.
      final open = enclosing ?? Set<Object>.identity();
      if (!open.add(value)) {
        throw error(path, 'a collection that contains itself');
      }
      if (value is List) {
        for (var i = 0; i < value.length; i++) {
          _checkJsonValue(value[i], '$path[$i]', error, open);
        }
      } else if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key;
          if (key is! String) {
            throw error(path, 'the non-string key ${_describe(key)}');
          }
          _checkJsonValue(entry.value, _keyPath(path, key), error, open);
        }
      }
      open.remove(value);
    default:
      throw error(path, 'a ${value.runtimeType}');
  }
}

final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// `args.city`, or `args["a.b"]` for a key that is not an identifier, so `a.b`
/// and `a` → `b` print different paths.
String _keyPath(String path, String key) =>
    _identifier.hasMatch(key) ? '$path.$key' : '$path[${jsonEncode(key)}]';

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
