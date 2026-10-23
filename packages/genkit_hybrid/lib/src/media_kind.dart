import 'package:genkit/genkit.dart';

import 'model_capability.dart';

final _imageExt = RegExp(
  r'\.(jpe?g|png|gif|webp|bmp|heic|heif|avif)$',
  caseSensitive: false,
);
final _audioExt = RegExp(
  r'\.(wav|mp3|m4a|aac|ogg|opus|flac|weba)$',
  caseSensitive: false,
);

// contentType is nullable; the Flutter image-picker path carries the type in
// a `data:<kind>/...` url, so check contentType, the data: url, and the URL
// extension (case-insensitively) — a hosted URL with neither a contentType nor
// a recognized media extension is still undetected.
bool isMediaOfKind(Media media, String kind) {
  final ct = media.contentType?.toLowerCase();
  final url = media.url.toLowerCase();
  if (ct != null && ct.startsWith('$kind/')) return true;
  if (url.startsWith('data:$kind/')) return true;
  // Match the extension against the URL PATH only — strip any query/fragment
  // so a `?x=photo.png` query value is not mistaken for a media extension.
  final path = url.split('?').first.split('#').first;
  return kind == 'image' ? _imageExt.hasMatch(path) : _audioExt.hasMatch(path);
}

/// The vision/audio capabilities the media parts of [messages] need.
Set<ModelCapability> mediaCapabilities(Iterable<Message> messages) {
  final caps = <ModelCapability>{};
  for (final message in messages) {
    for (final part in message.content) {
      if (!part.isMedia) continue;
      final media = part.media;
      if (media == null) continue;
      if (isMediaOfKind(media, 'image')) caps.add(ModelCapability.vision);
      if (isMediaOfKind(media, 'audio')) caps.add(ModelCapability.audio);
    }
  }
  return caps;
}
