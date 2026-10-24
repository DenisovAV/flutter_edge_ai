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

/// How long a request's `http(s)` media may take to download, all of it
/// together, counted from the start of the request's conversion.
const Duration kMediaDownloadTimeout = Duration(seconds: 30);

/// Extracts and concatenates all system messages into a single string.
///
/// Returns `null` if no system messages are present or all contain empty text.
/// A system message with a part other than text is an INVALID_ARGUMENT:
/// flutter_edge_ai takes text system instructions only.
///
/// Used to pass system instructions natively via `createChat(systemInstruction:)`.
String? extractSystemInstruction(List<Message> messages) {
  final buffer = StringBuffer();
  for (final message in messages) {
    if (message.role == Role.system) {
      _checkSystemMessage(message);
      final text = _extractText(message.content);
      if (text.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(text);
      }
    }
  }
  return buffer.isEmpty ? null : buffer.toString();
}

void _checkSystemMessage(Message message) => _checkParts(
  message,
  (part) => part.isText,
  'System messages take text only.',
);

/// Throws INVALID_ARGUMENT for the first part of [message] that [allowed]
/// refuses: a part the model would never see must not vanish quietly.
void _checkParts(Message message, bool Function(Part) allowed, String rule) {
  for (final part in message.content) {
    if (!allowed(part)) {
      throw GenkitException(
        'Unsupported part in a ${message.role.value} message: '
        '${_partKind(part)}. $rule',
        status: StatusCode.invalidArgument,
      );
    }
  }
}

/// Converts Genkit [ModelRequest] messages to flutter_edge_ai [gemma.Message] list.
///
/// Key mapping rules:
/// - `Role.system` → Skipped (handled via [extractSystemInstruction] + `createChat(systemInstruction:)`)
/// - `Role.user` → `Message(text: ..., isUser: true, images: ..., audioBytes: ...)`
/// - `Role.model` → `Message(text: ..., isUser: false)`, or a tool call;
///   its reasoning is left out, as models do not read their own back
/// - `Role.tool` → one `Message.toolResponse(toolName: ..., response: ...)`
///   per tool response: Genkit puts every response of a turn in one message.
///
/// Media resolution supports `data:` URIs, `file://` paths, absolute paths,
/// and `http://`/`https://` URLs (downloaded on the fly, at most
/// [kMaxMediaDownloadBytes] each and [kMediaDownloadTimeout] for all of
/// them; [cancel] aborts a download in progress). A media part without a
/// `contentType` is typed from its data URI, the served Content-Type, its file
/// extension or its bytes. A user message may carry several images and one
/// audio clip; a part the plugin cannot pass on — video, documents, data or
/// custom parts, media outside a user message — and a role it does not know
/// are an INVALID_ARGUMENT rather than silently dropped.
Future<List<gemma.Message>> convertMessages(
  List<Message> messages, {
  http.Client? httpClient,
  CancellationToken? cancel,
  @visibleForTesting Duration downloadTimeout = kMediaDownloadTimeout,
}) async {
  final downloads = _MediaDownloads(
    client: httpClient,
    timeout: downloadTimeout,
    cancel: cancel,
  );
  try {
    final result = <gemma.Message>[];
    for (final message in messages) {
      cancel?.throwIfCancelled();
      final role = message.role;

      if (role == Role.system) {
        // Its text goes to createChat(systemInstruction:), see
        // extractSystemInstruction.
        _checkSystemMessage(message);
      } else if (role == Role.user) {
        final text = _extractText(message.content);
        final media = await _extractMedia(message.content, downloads);
        result.add(
          gemma.Message(
            text: text,
            isUser: true,
            images: media.images,
            audioBytes: media.audio,
          ),
        );
      } else if (role == Role.model) {
        _checkParts(
          message,
          (part) => part.isText || part.isToolRequest || part.isReasoning,
          'Model messages take text and tool requests.',
        );
        final text = _extractText(message.content);
        final toolCall = _toolCallMessage(message.content);
        if (toolCall != null) {
          result.add(toolCall);
        } else {
          result.add(gemma.Message(text: text, isUser: false));
        }
      } else if (role == Role.tool) {
        _checkParts(
          message,
          (part) => part.isToolResponse,
          'Tool messages take tool responses only.',
        );
        if (message.content.isEmpty) {
          throw GenkitException(
            'Tool message contains no ToolResponsePart.',
            status: StatusCode.invalidArgument,
          );
        }
        for (final part in message.content) {
          final response = part.toolResponse!;
          result.add(
            gemma.Message.toolResponse(
              toolName: response.name,
              response: _toolResponseBody(response),
              toolCallId: _callId(response.ref),
            ),
          );
        }
      } else {
        throw GenkitException(
          'Unsupported message role "${role.value}".',
          status: StatusCode.invalidArgument,
        );
      }
    }
    cancel?.throwIfCancelled();
    return result;
  } finally {
    downloads.close();
  }
}

/// The http(s) downloads of one request: one client, one deadline for all of
/// them, and the request's cancel.
class _MediaDownloads {
  _MediaDownloads({
    required http.Client? client,
    required this.timeout,
    required this.cancel,
  }) : _given = client;

  final http.Client? _given;
  http.Client? _own;
  final Duration timeout;
  final CancellationToken? cancel;
  final Stopwatch _clock = Stopwatch()..start();

  http.Client get client => _given ?? (_own ??= http.Client());

  /// What is left of [timeout].
  Duration get remaining {
    final left = timeout - _clock.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// Closes the client this made, if it made one.
  void close() => _own?.close();
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
  _MediaDownloads downloads,
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
    final (bytes, servedType) = await _loadMediaBytes(media.url, downloads);
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
  if (part.isText) return 'text';
  if (part.isMedia) return 'media';
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
/// Content-Type an http(s) server sent ([servedType]) when it names an image
/// or audio, since servers label media generically often enough
/// (`text/plain`, `binary/octet-stream`); then the URL's file extension;
/// then, when none says or the type is `application/octet-stream`, the bytes'
/// signature. Types are compared without case.
String? _mediaKind(Media media, Uint8List bytes, String? servedType) {
  final served = _mimeType(servedType);
  final servedMedia =
      served != null &&
          (served.startsWith('image/') || served.startsWith('audio/'))
      ? served
      : null;
  var type =
      _mimeType(media.contentType) ??
      _dataUriType(media.url) ??
      servedMedia ??
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

/// [value]'s media type, lowercase and without parameters, or null when
/// there is none.
String? _mimeType(String? value) {
  final type = value?.split(';').first.trim().toLowerCase();
  return (type == null || type.isEmpty) ? null : type;
}

/// The MIME type of a `data:<type>[;base64],...` URI.
String? _dataUriType(String url) {
  if (!url.startsWith('data:')) return null;
  final end = url.indexOf(RegExp('[;,]'));
  if (end <= 5) return null;
  return _mimeType(url.substring(5, end));
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
  _MediaDownloads downloads,
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
    return _download(url, downloads);
  }

  // Unrecognized URL scheme — reject explicitly.
  final scheme = Uri.tryParse(url)?.scheme;
  throw GenkitException(
    'Unsupported media URL scheme${scheme == null || scheme.isEmpty ? '' : ' "$scheme"'}: '
    'use a data:, file:// or http(s) URL, or an absolute path.',
    status: StatusCode.invalidArgument,
  );
}

/// Downloads an `http(s)` media URL within [downloads]' deadline and
/// [kMaxMediaDownloadBytes]. A cancel, the deadline or an oversized body
/// aborts the transfer at once: the request may be waiting to reach a model
/// other requests are queued for, and a server that sends a byte now and then
/// must not hold them. Errors name the host only: a signed URL's query is a
/// credential.
Future<(Uint8List, String?)> _download(String url, _MediaDownloads downloads) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    throw GenkitException(
      'Malformed media URL.',
      status: StatusCode.invalidArgument,
    );
  }
  final host = uri.host;
  final done = Completer<(Uint8List, String?)>();
  // Completing it aborts the request on the clients that support it, the
  // dart:io and browser ones among them.
  final abort = Completer<void>();
  StreamSubscription<List<int>>? body;
  Timer? timer;
  void Function()? detachCancel;

  void finish() {
    timer?.cancel();
    detachCancel?.call();
    if (!abort.isCompleted) abort.complete();
  }

  void fail(Object error, [StackTrace? stack]) {
    if (done.isCompleted) return;
    body?.cancel().ignore();
    finish();
    done.completeError(error, stack);
  }

  // Release an unread body: on a shared client it keeps its connection busy.
  void discard(http.StreamedResponse response) =>
      response.stream.listen(null).cancel().ignore();

  timer = Timer(
    downloads.remaining,
    () => fail(
      GenkitException(
        'Downloading the media of this request took longer than '
        '${downloads.timeout.inSeconds} s (at $host).',
        status: StatusCode.deadlineExceeded,
      ),
    ),
  );
  final cancel = downloads.cancel;
  if (cancel != null) {
    detachCancel = cancel.onCancel(
      () => fail(CancelledException(reason: cancel.reason, token: cancel)),
    );
  }
  if (done.isCompleted) return done.future;

  downloads.client
      .send(http.AbortableRequest('GET', uri, abortTrigger: abort.future))
      .then(
        (response) {
          if (done.isCompleted) return discard(response);
          final status = response.statusCode;
          if (status != 200) {
            discard(response);
            return fail(
              GenkitException(
                'Failed to download media from $host: HTTP $status',
                status: _httpFailureStatus(status),
              ),
            );
          }
          final declared = response.contentLength;
          if (declared != null && declared > kMaxMediaDownloadBytes) {
            discard(response);
            return fail(
              GenkitException(
                'Media from $host is $declared bytes, over the '
                '$kMaxMediaDownloadBytes-byte limit.',
                status: StatusCode.invalidArgument,
              ),
            );
          }
          final builder = BytesBuilder(copy: false);
          body = response.stream.listen(
            (chunk) {
              builder.add(chunk);
              if (builder.length > kMaxMediaDownloadBytes) {
                fail(
                  GenkitException(
                    'Media from $host is over the '
                    '$kMaxMediaDownloadBytes-byte limit.',
                    status: StatusCode.invalidArgument,
                  ),
                );
              }
            },
            onError: (Object error, StackTrace stack) =>
                fail(_transferError(error, host), stack),
            onDone: () {
              if (done.isCompleted) return;
              finish();
              done.complete((
                builder.takeBytes(),
                response.headers['content-type'],
              ));
            },
            cancelOnError: true,
          );
        },
        onError: (Object error, StackTrace stack) =>
            fail(_transferError(error, host), stack),
      )
      // A throw inside the response handler above would otherwise land on a
      // future nobody listens to; it fails the download instead.
      .catchError((Object error, StackTrace stack) => fail(error, stack));
  return done.future;
}

/// A server error, a timeout or a rate limit may pass; any other refusal
/// (not found, forbidden, an expired signed URL) is the URL's.
StatusCode _httpFailureStatus(int status) =>
    (status >= 500 || status == 408 || status == 429)
    ? StatusCode.unavailable
    : StatusCode.invalidArgument;

/// The error for a transfer that failed: a network failure is UNAVAILABLE,
/// with the client's message, which does not carry the URL. An [Error] is a
/// bug and stays one.
Object _transferError(Object error, String host) => switch (error) {
  GenkitException() => error,
  http.ClientException(:final message) => GenkitException(
    'Failed to download media from $host: $message',
    status: StatusCode.unavailable,
  ),
  Exception() => GenkitException(
    'Failed to download media from $host: $error',
    status: StatusCode.unavailable,
  ),
  _ => error,
};

/// The tool requests (function calls) of a model message as one
/// `Message.toolCall`, or null when it has none.
///
/// Its text is a JSON object `{"name": ..., "parameters": ...}` for one call
/// and a JSON array of them for parallel calls. Its calls carry each request's
/// `ref` as their id, so `ToolResponse.ref` pairs a result with its call; they
/// are left out when an input is not a JSON object, and the text stands alone.
gemma.Message? _toolCallMessage(List<Part> parts) {
  final requests = [
    for (final part in parts)
      if (part.isToolRequest) part.toolRequest!,
  ];
  if (requests.isEmpty) return null;
  final json = [
    for (final request in requests)
      {'name': request.name, 'parameters': request.input},
  ];
  final calls = <gemma.FunctionCallResponse>[];
  for (final request in requests) {
    final input = request.input;
    if (input != null && input is! Map) {
      calls.clear();
      break;
    }
    calls.add(
      gemma.FunctionCallResponse(
        name: request.name,
        args: input == null ? {} : Map<String, dynamic>.from(input as Map),
        id: _callId(request.ref),
      ),
    );
  }
  return gemma.Message.toolCall(
    text: jsonEncode(json.length == 1 ? json.single : json),
    calls: calls,
  );
}

/// A tool response as the map the model reads: its output, under `result`
/// when it is not a map, and the text of its multipart content, if any, under
/// `content`. Content other than text cannot be passed on.
Map<String, dynamic> _toolResponseBody(ToolResponse response) {
  final texts = <String>[];
  for (final item in response.content ?? const <dynamic>[]) {
    final part = switch (item) {
      final Part part => part,
      final Map<dynamic, dynamic> json => Part.fromJson(
        Map<String, dynamic>.from(json),
      ),
      _ => null,
    };
    if (part == null || !part.isText) {
      throw GenkitException(
        'The response of tool "${response.name}" carries '
        '${part == null ? 'content that is not a part' : _partKind(part)}; '
        'only text content is passed to the model.',
        status: StatusCode.invalidArgument,
      );
    }
    texts.add(part.text!);
  }
  final body = switch (response.output) {
    final Map<String, dynamic> output => {...output},
    final output => <String, dynamic>{'result': output},
  };
  if (texts.isNotEmpty) {
    if (body.containsKey('content')) {
      throw GenkitException(
        'The response of tool "${response.name}" has both an output with a '
        '"content" key and multipart content.',
        status: StatusCode.invalidArgument,
      );
    }
    body['content'] = texts.join('\n');
  }
  return body;
}

/// A Genkit `ref` as a call id: an empty ref is no id, as genai and the
/// engines' parsers read one.
String? _callId(String? ref) => ref == null || ref.isEmpty ? null : ref;
