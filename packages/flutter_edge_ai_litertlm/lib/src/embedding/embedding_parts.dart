// How one `EmbeddingInput` becomes the parts of one LiteRT-LM embedding
// request (R5 §2.5). Pure Dart and private to this package; the `.litertlm`
// pass turns each part into a `LiteRtLmInputData`.
//
// The task prefix belongs to the TEXT part only: a media part is the encoded
// file, byte for byte. The order is fixed — text, then the images in order,
// then audio — so that an input carrying several of them (P3) always produces
// the same request.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';

/// What one part of an embedding request carries.
enum EmbeddingPartKind { text, image, audio }

/// One part of an embedding request: the UTF-8 of `prefix + text` for a text
/// part, the encoded file for an image or audio part.
typedef EmbeddingPart = ({EmbeddingPartKind kind, Uint8List bytes});

/// The parts of [input], in request order: the text (with [taskType]'s
/// prefix), then the images, then the audio clip.
List<EmbeddingPart> embeddingParts(EmbeddingInput input, TaskType taskType) => [
  if (input.text case final text?)
    (
      kind: EmbeddingPartKind.text,
      bytes: utf8.encode('${taskType.prefix}$text'),
    ),
  for (final image in input.images)
    (kind: EmbeddingPartKind.image, bytes: image),
  if (input.audio case final audio?)
    (kind: EmbeddingPartKind.audio, bytes: audio),
];
