import 'dart:typed_data';

/// Detects the image MIME type (e.g. `image/jpeg`, `image/png`, `image/webp`)
/// from a byte buffer's magic-number signature. Shared by the MediaPipe web
/// path (`ImagePromptPart`) and the LiteRT-LM web session. Public so the
/// extracted `flutter_gemma_litertlm` web package can reuse it.
String detectImageMimeType(Uint8List bytes) {
  if (bytes.length < 4) return 'image/png'; // default fallback

  // JPEG magic number: FF D8 FF
  if (_matchesSignature(bytes, [0xFF, 0xD8, 0xFF])) {
    return 'image/jpeg';
  }

  // PNG magic number: 89 50 4E 47
  if (_matchesSignature(bytes, [0x89, 0x50, 0x4E, 0x47])) {
    return 'image/png';
  }

  // WebP magic number: RIFF at start, WEBP at offset 8
  if (bytes.length >= 12 &&
      _matchesSignature(bytes, [0x52, 0x49, 0x46, 0x46]) &&
      _matchesSignature(bytes.sublist(8), [0x57, 0x45, 0x42, 0x50])) {
    return 'image/webp';
  }

  return 'image/png'; // default fallback
}

bool _matchesSignature(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) return false;
  for (int i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return false;
  }
  return true;
}
