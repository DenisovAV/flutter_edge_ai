import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Widget;

/// The outcome of running a [Skill] through a [SkillExecutor].
///
/// Sealed so the agent loop / UI can exhaustively `switch` on the variant to
/// render it (text bubble, inline image, native widget, embedded webview) or
/// surface an error. Mirrors the `{result | image | webview | error}` shapes a
/// Gallery JS skill returns from `window.ai_edge_gallery_get_result`.
sealed class SkillResult {
  const SkillResult();
}

/// Plain text to feed back to the model and/or show to the user.
class TextResult extends SkillResult {
  const TextResult(this.text);

  final String text;

  @override
  String toString() => 'TextResult(${text.length} chars)';
}

/// Raw image bytes (e.g. a generated QR code / card) to render inline.
class ImageResult extends SkillResult {
  const ImageResult(this.bytes);

  final Uint8List bytes;

  @override
  String toString() => 'ImageResult(${bytes.length} bytes)';
}

/// A native Flutter widget to render inline — our cross-platform edge over
/// Gallery's webview-only rendering.
class WidgetResult extends SkillResult {
  const WidgetResult(this.widget);

  final Widget widget;

  @override
  String toString() => 'WidgetResult($widget)';
}

/// A web page to embed. [iframe] true means render it inline (an embedded
/// webview); false means it is intended to open externally.
class WebviewResult extends SkillResult {
  const WebviewResult(this.url, {this.iframe = true});

  final String url;
  final bool iframe;

  @override
  String toString() => 'WebviewResult($url, iframe: $iframe)';
}

/// An execution failure — the message is fed back to the model so it can
/// recover, and surfaced to the user.
class ErrorResult extends SkillResult {
  const ErrorResult(this.message);

  final String message;

  @override
  String toString() => 'ErrorResult($message)';
}
