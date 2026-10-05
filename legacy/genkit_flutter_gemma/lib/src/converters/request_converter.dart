import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:genkit/plugin.dart';
import 'package:http/http.dart' as http;

import 'file_reader.dart';

/// Extracts and concatenates all system messages into a single string.
///
/// Returns `null` if no system messages are present or all contain empty text.
/// Throws if a system message has content parts but no extractable text
/// (e.g. only media parts), since flutter_gemma only supports text system
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
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
    }
  }
  return buffer.isEmpty ? null : buffer.toString();
}

/// Converts Genkit [ModelRequest] messages to flutter_gemma [gemma.Message] list.
///
/// Key mapping rules:
/// - `Role.system` → Skipped (handled via [extractSystemInstruction] + `createChat(systemInstruction:)`)
/// - `Role.user` → `Message(text: ..., isUser: true, imageBytes: ..., audioBytes: ...)`
/// - `Role.model` → `Message(text: ..., isUser: false)`
/// - `Role.tool` → `Message.toolResponse(toolName: ..., response: ...)`
///
/// Media resolution supports `data:` URIs, `file://` paths, absolute paths,
/// and `http://`/`https://` URLs (downloaded on the fly).
Future<List<gemma.Message>> convertMessages(
  List<Message> messages, {
  http.Client? httpClient,
}) async {
  final result = <gemma.Message>[];

  for (final message in messages) {
    final role = message.role;

    if (role == Role.system) {
      // System messages are handled natively via createChat(systemInstruction:).
      continue;
    } else if (role == Role.user) {
      final text = _extractText(message.content);
      final imageBytes =
          await _extractMediaBytes(message.content, 'image', httpClient);
      final audioBytes =
          await _extractMediaBytes(message.content, 'audio', httpClient);

      if (imageBytes != null) {
        result.add(gemma.Message.withImage(
          text: text,
          imageBytes: imageBytes,
          isUser: true,
        ));
      } else if (audioBytes != null) {
        result.add(gemma.Message.withAudio(
          text: text,
          audioBytes: audioBytes,
          isUser: true,
        ));
      } else {
        result.add(gemma.Message(text: text, isUser: true));
      }
    } else if (role == Role.model) {
      final text = _extractText(message.content);
      final toolCallJson = _extractToolRequest(message.content);
      if (toolCallJson != null) {
        result.add(gemma.Message.toolCall(text: toolCallJson));
      } else {
        result.add(gemma.Message(text: text, isUser: false));
      }
    } else if (role == Role.tool) {
      final toolResponse = _extractToolResponse(message.content);
      if (toolResponse == null) {
        throw GenkitException(
          'Tool message contains no ToolResponsePart.',
          status: StatusCodes.INVALID_ARGUMENT,
        );
      }
      result.add(gemma.Message.toolResponse(
        toolName: toolResponse.toolName,
        response: toolResponse.response,
      ));
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

/// Extracts binary media data from content parts.
///
/// Supports:
/// - `data:` URI (base64) — decoded in-memory
/// - `file://` path — read from local filesystem
/// - Absolute path (`/...`) — read from local filesystem
/// - `http://` / `https://` URL — downloaded via HTTP GET
///
/// [mediaType] should be 'image' or 'audio'.
Future<Uint8List?> _extractMediaBytes(
  List<Part> parts,
  String mediaType,
  http.Client? httpClient,
) async {
  for (final part in parts) {
    if (part.isMedia) {
      final media = part.media!;
      final contentType = media.contentType ?? '';
      if (!contentType.startsWith(mediaType)) continue;

      final url = media.url;

      // data: URI (base64)
      if (url.startsWith('data:')) {
        final commaIndex = url.indexOf(',');
        if (commaIndex == -1) {
          throw GenkitException(
            'Malformed data: URI (missing comma separator)',
            status: StatusCodes.INVALID_ARGUMENT,
          );
        }
        try {
          return base64Decode(url.substring(commaIndex + 1));
        } on FormatException catch (e) {
          throw GenkitException(
            'Invalid base64 in media data URI: $e',
            status: StatusCodes.INVALID_ARGUMENT,
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
            status: StatusCodes.INVALID_ARGUMENT,
          );
        } on UnsupportedError catch (e) {
          throw GenkitException(
            'Unsupported file:// URI "$url": $e',
            status: StatusCodes.INVALID_ARGUMENT,
          );
        }
        return readFileBytes(path);
      }

      // Absolute path (starts with /)
      if (url.startsWith('/')) {
        return readFileBytes(url);
      }

      // HTTP/HTTPS URL — download
      if (url.startsWith('http://') || url.startsWith('https://')) {
        final client = httpClient ?? http.Client();
        try {
          final uri = Uri.tryParse(url);
          if (uri == null) {
            throw GenkitException(
              'Malformed media URL: $url',
              status: StatusCodes.INVALID_ARGUMENT,
            );
          }
          final response = await client.get(uri);
          if (response.statusCode == 200) {
            return response.bodyBytes;
          }
          throw GenkitException(
            'Failed to download media from $url: HTTP ${response.statusCode}',
            status: StatusCodes.INTERNAL,
          );
        } on GenkitException {
          rethrow;
        } catch (e) {
          throw GenkitException(
            'Failed to download media from $url: $e',
            status: StatusCodes.INTERNAL,
          );
        } finally {
          if (httpClient == null) client.close();
        }
      }

      // Unrecognized URL scheme — reject explicitly.
      throw GenkitException(
        'Unsupported media URL scheme: $url',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }
  }
  return null;
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
      calls.add({
        'name': toolReq.name,
        'parameters': toolReq.input,
      });
    }
  }
  if (calls.isEmpty) return null;
  if (calls.length == 1) return jsonEncode(calls.first);
  return jsonEncode(calls);
}

/// Extracts tool response data from content parts.
_ToolResponseData? _extractToolResponse(List<Part> parts) {
  for (final part in parts) {
    if (part.isToolResponse) {
      final toolResp = part.toolResponse!;
      final output = toolResp.output;
      return _ToolResponseData(
        toolName: toolResp.name,
        response: output is Map<String, dynamic>
            ? output
            : {'result': output},
      );
    }
  }
  return null;
}

class _ToolResponseData {
  const _ToolResponseData({required this.toolName, required this.response});
  final String toolName;
  final Map<String, dynamic> response;
}
