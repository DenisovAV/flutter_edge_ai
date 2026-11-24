// The user message of a turn with its media, for the native and the web
// session alike: litertlm_dart sends it as LiteRT-LM's conversation JSON on
// both.

import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

/// A user message of [text] with its media placed by [order]: images, then
/// audio, before the text or after it, as each [MediaPosition] says.
lm.Message liteRtLmUserMessage(
  String text, {
  List<Uint8List> images = const [],
  Uint8List? audio,
  required MultimodalOrder order,
}) {
  final before = <lm.Content>[];
  final after = <lm.Content>[];
  List<lm.Content> side(MediaPosition position) =>
      position == MediaPosition.beforeText ? before : after;
  for (final image in images) {
    side(order.images).add(lm.Content.imageBytes(image));
  }
  if (audio != null) side(order.audio).add(lm.Content.audioBytes(audio));
  return lm.Message(
    role: lm.Role.user,
    contents: [...before, lm.Content.text(text), ...after],
  );
}
