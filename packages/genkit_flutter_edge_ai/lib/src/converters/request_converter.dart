import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as gemma;
import 'package:genkit/plugin.dart';
import 'package:http/http.dart' as http;

import 'file_reader.dart';

/// The largest media file downloaded from an `http(s)` URL.
const int kMaxMediaDownloadBytes = 20 * 1024 * 1024;

/// How long an `http(s)` media download may take in all, from the request to
/// the last byte.
const Duration kMediaDownloadTimeout = Duration(seconds: 30);

/// Extracts and concatenates all system messages into a single string.
///
/// Returns `null` if no system messages are present or all contain empty text.
/// Throws if a system message has content parts but no extractable text
/// (e.g. only media parts), since flutter_edge_ai only supports text system
/// instructions.
///
/// Used to pass system instructions natively via `createChat(systemInstruction:)`.
String? extractSystemInstruction(List<Message> messages) {
  final buffer = StringBuffer();
  for (final message in messages) {
    if (message.role == Role.system) {
      final text = _extractText(message.content);
      if (text.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(text);
      } else if (message.content.isNotEmpty) {
        throw GenkitException(
          'System message contains non-text parts which are not supported '
          'for system instructions. Only text content is used.',
          status: StatusCode.invalidArgument,
        );
      }
    }
  }
  return buffer.isEmpty ? null : buffer.toString();
}

/// Converts Genkit [ModelRequest] messages to flutter_edge_ai [gemma.Message] list.
///
/// Key mapping rules:
/// - `Role.system` → Skipped (handled via [extractSystemInstruction] + `createChat(systemInstruction:)`)
/// - `Role.user` → `Message(text: ..., isUser: true, images: ..., audioBytes: ...)`
/// - `Role.model` → `Message(text: ..., isUser: false)`
/// - `Role.tool` → one `Message.toolResponse(toolName: ..., response: ...)`
///   per tool response: Genkit puts every response of a turn in one message.
///
/// Media resolution supports `data:` URIs, `file://` paths, absolute paths,
/// and `http://`/`https://` URLs (downloaded on the fly, at most
/// [kMaxMediaDownloadBytes] within [kMediaDownloadTimeout]). A media part
/// without a `contentType` is typed from its data URI, its file extension or
/// its bytes. A user message may carry several images and one audio clip; a
/// part the plugin cannot pass on — video, documents, data or custom parts —
/// is an INVALID_ARGUMENT rather than silently dropped.
Future<List<gemma.Message>> convertMessages(
  List<Message> messages, {
  http.Client? httpClient,
  @visibleForTesting Duration downloadTimeout = kMediaDownloadTimeout,
}) async {
  final result = <gemma.Message>[];

  for (final message in messages) {
    final role = message.role;

    if (role == Role.system) {
      // System messages are handled natively via createChat(systemInstruction:).
      continue;
    } else if (role == Role.user) {
      final text = _extractText(message.content);
      final media = await _extractMedia(
        message.content,
        httpClient,
        downloadTimeout,
      );
      result.add(
        gemma.Message(
          text: text,
          isUser: true,
          images: media.images,
          audioBytes: media.audio,
        ),
      );
    } else if (role == Role.model) {
      final text = _extractText(message.content);
      final toolCallJson = _extractToolRequest(message.content);
      if (toolCallJson != null) {
        result.add(gemma.Message.toolCall(text: toolCallJson));
      } else {
        result.add(gemma.Message(text: text, isUser: false));
      }
    } else if (role == Role.tool) {
      final responses = _extractToolResponses(message.content);
      if (responses.isEmpty) {
        throw GenkitException(
          'Tool message contains no ToolResponsePart.',
          status: StatusCode.invalidArgument,
        );
      }
      for (final response in responses) {
        result.add(
          gemma.Message.toolResponse(
            toolName: response.toolName,
            response: response.response,
          ),
        );
      }
    }
  }

  return result;
}

/// Extracts concatenated text from message content parts.
/// Uses [PartExtension.isText] and [PartExtension.text] for type discrimination.
String _extractText(List<Part> parts) {
  final buffer = StringBuffer();
  for (final part in parts) {
    if (part.isText) {
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(part.text);
    }
  }
  return buffer.toString();
}

/// The images and the audio clip of one user message.
typedef _UserMedia = ({List<Uint8List> images, Uint8List? audio});

/// Loads every media part of a user message and sorts it into images and
/// audio. Text is read separately; any other kind of part is rejected.
Future<_UserMedia> _extractMedia(
  List<Part> parts,
  http.Client? httpClient,
  Duration downloadTimeout,
) async {
  final images = <Uint8List>[];
  Uint8List? audio;
  for (final part in parts) {
    if (part.isText) continue;
    if (!part.isMedia) {
      throw GenkitException(
        'Unsupported part in a user message: ${_partKind(part)}. Only text, '
        'image and audio parts are passed to the model.',
        status: StatusCode.invalidArgument,
      );
    }
    final media = part.media!;
    final (bytes, servedType) = await _loadMediaBytes(
      media.url,
      httpClient,
      downloadTimeout,
    );
    final kind = _mediaKind(media, bytes, servedType);
    switch (kind) {
      case 'image':
        images.add(bytes);
      case 'audio':
        if (audio != null) {
          throw GenkitException(
            'A user message may carry one audio clip; send further clips in '
            'separate messages.',
            status: StatusCode.invalidArgument,
          );
        }
        audio = bytes;
      case null:
        throw GenkitException(
          'Cannot tell whether a media part is an image or audio: it has no '
          'contentType, and neither its URL nor its bytes say. Set '
          'contentType, e.g. image/png or audio/wav.',
          status: StatusCode.invalidArgument,
        );
      default:
        throw GenkitException(
          'Unsupported media type "$kind": only images and audio are passed '
          'to the model.',
          status: StatusCode.invalidArgument,
        );
    }
  }
  return (images: images, audio: audio);
}

/// A short name for a part's kind, for error messages.
String _partKind(Part part) {
  if (part.isToolRequest) return 'tool request';
  if (part.isToolResponse) return 'tool response';
  if (part.isReasoning) return 'reasoning';
  if (part.isData) return 'data';
  if (part.isCustom) return 'custom';
  return part.toJson().keys.join(', ');
}

/// 'image', 'audio', another MIME type, or null when nothing says.
///
/// The declared contentType wins; then a `data:` URI's MIME type; then the
/// Content-Type an http(s) server sent ([servedType]); then the URL's file
/// extension; then, when none says or the type is `application/octet-stream`,
/// the bytes' signature.
String? _mediaKind(Media media, Uint8List bytes, String? servedType) {
  var type =
      _nonEmpty(media.contentType) ??
      _dataUriType(media.url) ??
      _nonEmpty(servedType?.split(';').first) ??
      _extensionType(media.url);
  // A generic binary type says nothing about what the bytes are.
  if (type == null || type == 'application/octet-stream') {
    type = _sniffType(bytes) ?? type;
  }
  if (type == null) return null;
  if (type.startsWith('image/')) return 'image';
  if (type.startsWith('audio/')) return 'audio';
  return type;
}

String? _nonEmpty(String? value) =>
    (value == null || value.trim().isEmpty) ? null : value.trim();

/// The MIME type of a `data:<type>[;base64],...` URI.
String? _dataUriType(String url) {
  if (!url.startsWith('data:')) return null;
  final end = url.indexOf(RegExp('[;,]'));
  if (end <= 5) return null;
  return _nonEmpty(url.substring(5, end));
}

const _imageExtensions = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'heif': 'image/heif',
};

const _audioExtensions = {
  'wav': 'audio/wav',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'opus': 'audio/opus',
};

/// The MIME type a URL's file extension names, ignoring query and fragment.
String? _extensionType(String url) {
  if (url.startsWith('data:')) return null;
  final path = Uri.tryParse(url)?.path ?? url;
  final dot = path.lastIndexOf('.');
  if (dot == -1 || dot == path.length - 1) return null;
  final ext = path.substring(dot + 1).toLowerCase();
  return _imageExtensions[ext] ?? _audioExtensions[ext];
}

bool _startsWith(Uint8List bytes, List<int> signature, [int offset = 0]) {
  if (bytes.length < offset + signature.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[offset + i] != signature[i]) return false;
  }
  return true;
}

/// The MIME type a file's leading bytes identify, for the formats an
/// on-device model takes.
String? _sniffType(Uint8List bytes) {
  if (_startsWith(bytes, const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (_startsWith(bytes, const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (_startsWith(bytes, ascii.encode('GIF8'))) return 'image/gif';
  if (_startsWith(bytes, ascii.encode('BM'))) return 'image/bmp';
  if (_startsWith(bytes, ascii.encode('RIFF'))) {
    if (_startsWith(bytes, ascii.encode('WEBP'), 8)) return 'image/webp';
    if (_startsWith(bytes, ascii.encode('WAVE'), 8)) return 'audio/wav';
  }
  if (_startsWith(bytes, ascii.encode('ID3'))) return 'audio/mpeg';
  if (_startsWith(bytes, ascii.encode('fLaC'))) return 'audio/flac';
  if (_startsWith(bytes, ascii.encode('OggS'))) return 'audio/ogg';
  // An MPEG audio frame or an ADTS AAC header: eleven set sync bits. JPEG's
  // FF D8 does not match (D8 has the third bit clear).
  if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
    return (bytes[1] & 0xF6) == 0xF0 ? 'audio/aac' : 'audio/mpeg';
  }
  // ISO base media (`ftyp` box): the brand says HEIF image, M4A audio, or
  // something else (mp4 video, typically).
  if (_startsWith(bytes, ascii.encode('ftyp'), 4) && bytes.length >= 12) {
    final brand = ascii.decode(bytes.sublist(8, 12), allowInvalid: true);
    if (const {
      'heic',
      'heix',
      'heim',
      'heis',
      'mif1',
      'msf1',
    }.contains(brand)) {
      return 'image/heif';
    }
    if (const {'M4A ', 'M4B '}.contains(brand)) return 'audio/mp4';
    return 'video/mp4';
  }
  return null;
}

/// Reads a media part's bytes from a `data:` URI, a `file://` URI, an
/// absolute path or an `http(s)` URL, with the Content-Type an http(s) server
/// sent.
Future<(Uint8List, String?)> _loadMediaBytes(
  String url,
  http.Client? httpClient,
  Duration downloadTimeout,
) async {
  // data: URI (base64)
  if (url.startsWith('data:')) {
    final commaIndex = url.indexOf(',');
    if (commaIndex == -1) {
      throw GenkitException(
        'Malformed data: URI (missing comma separator)',
        status: StatusCode.invalidArgument,
      );
    }
    try {
      return (base64Decode(url.substring(commaIndex + 1)), null);
    } on FormatException catch (e) {
      throw GenkitException(
        'Invalid base64 in media data URI: $e',
        status: StatusCode.invalidArgument,
      );
    }
  }

  // file:// path
  if (url.startsWith('file://')) {
    final String path;
    try {
      path = Uri.parse(url).toFilePath();
    } on FormatException catch (e) {
      throw GenkitException(
        'Malformed file:// URI "$url": $e',
        status: StatusCode.invalidArgument,
      );
    } on UnsupportedError catch (e) {
      throw GenkitException(
        'Unsupported file:// URI "$url": $e',
        status: StatusCode.invalidArgument,
      );
    }
    return (await readFileBytes(path), null);
  }

  // Absolute path (starts with /)
  if (url.startsWith('/')) {
    return (await readFileBytes(url), null);
  }

  if (url.startsWith('http://') || url.startsWith('https://')) {
    return _download(url, httpClient, downloadTimeout);
  }

  // Unrecognized URL scheme — reject explicitly.
  final scheme = Uri.tryParse(url)?.scheme;
  throw GenkitException(
    'Unsupported media URL scheme${scheme == null || scheme.isEmpty ? '' : ' "$scheme"'}: '
    'use a data:, file:// or http(s) URL, or an absolute path.',
    status: StatusCode.invalidArgument,
  );
}

/// Downloads an `http(s)` media URL, bounded in size and by one deadline for
/// the whole transfer: conversion runs under the model's lock, so a server
/// that keeps sending a byte now and then must not hold every later request.
/// Errors name the host only: a signed URL's query is a credential.
Future<(Uint8List, String?)> _download(
  String url,
  http.Client? httpClient,
  Duration timeout,
) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    throw GenkitException(
      'Malformed media URL.',
      status: StatusCode.invalidArgument,
    );
  }
  final host = uri.host;
  final deadline = Stopwatch()..start();
  Duration remaining() {
    final left = timeout - deadline.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  final client = httpClient ?? http.Client();
  try {
    final response = await client
        .send(http.Request('GET', uri))
        .timeout(remaining());
    if (response.statusCode != 200) {
      // Release the body: on a shared client an unread one keeps its
      // connection busy.
      await response.stream.listen(null).cancel();
      throw GenkitException(
        'Failed to download media from $host: HTTP ${response.statusCode}',
        status: StatusCode.unavailable,
      );
    }
    final declared = response.contentLength;
    if (declared != null && declared > kMaxMediaDownloadBytes) {
      await response.stream.listen(null).cancel();
      throw GenkitException(
        'Media from $host is $declared bytes, over the '
        '$kMaxMediaDownloadBytes-byte limit.',
        status: StatusCode.invalidArgument,
      );
    }
    final bytes = await _readBounded(response.stream, host, remaining());
    return (bytes, response.headers['content-type']);
  } on GenkitException {
    rethrow;
  } on TimeoutException {
    throw GenkitException(
      'Downloading media from $host took longer than '
      '${timeout.inSeconds} s.',
      status: StatusCode.deadlineExceeded,
    );
  } catch (e) {
    throw GenkitException(
      'Failed to download media from $host: ${e.runtimeType}',
      status: StatusCode.unavailable,
    );
  } finally {
    if (httpClient == null) client.close();
  }
}

/// Reads [body] to its end within [timeout] and [kMaxMediaDownloadBytes],
/// cancelling it as soon as either is exceeded.
Future<Uint8List> _readBounded(
  Stream<List<int>> body,
  String host,
  Duration timeout,
) {
  final builder = BytesBuilder(copy: false);
  final done = Completer<Uint8List>();
  late final StreamSubscription<List<int>> subscription;
  void fail(Object error) {
    if (done.isCompleted) return;
    unawaited(subscription.cancel());
    done.completeError(error);
  }

  final timer = Timer(timeout, () => fail(TimeoutException(null, timeout)));
  subscription = body.listen(
    (chunk) {
      builder.add(chunk);
      if (builder.length > kMaxMediaDownloadBytes) {
        fail(
          GenkitException(
            'Media from $host is over the $kMaxMediaDownloadBytes-byte limit.',
            status: StatusCode.invalidArgument,
          ),
        );
      }
    },
    onError: (Object error, StackTrace stack) {
      if (done.isCompleted) return;
      done.completeError(error, stack);
    },
    onDone: () {
      if (!done.isCompleted) done.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  return done.future.whenComplete(timer.cancel);
}

/// Extracts tool requests (function calls) as JSON string from content parts.
///
/// If a single tool call is found, returns a JSON object: `{"name": ..., "parameters": ...}`.
/// If multiple tool calls are found (parallel calls), returns a JSON array of objects.
String? _extractToolRequest(List<Part> parts) {
  final calls = <Map<String, dynamic>>[];
  for (final part in parts) {
    if (part.isToolRequest) {
      final toolReq = part.toolRequest!;
      calls.add({'name': toolReq.name, 'parameters': toolReq.input});
    }
  }
  if (calls.isEmpty) return null;
  if (calls.length == 1) return jsonEncode(calls.first);
  return jsonEncode(calls);
}

/// Every tool response in a tool message, in order.
List<_ToolResponseData> _extractToolResponses(List<Part> parts) => [
  for (final part in parts)
    if (part.isToolResponse)
      _ToolResponseData(
        toolName: part.toolResponse!.name,
        response: switch (part.toolResponse!.output) {
          final Map<String, dynamic> output => output,
          final output => {'result': output},
        },
      ),
];

class _ToolResponseData {
  const _ToolResponseData({required this.toolName, required this.response});
  final String toolName;
  final Map<String, dynamic> response;
}
