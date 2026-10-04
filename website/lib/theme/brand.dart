import 'package:jaspr/dom.dart';

/// Brand design tokens for the flutter_edge_ai website.
///
/// Palette derived from the example app's dark UI: a deep navy canvas with
/// blue / orange / green accents mapped onto feature categories
/// (CTA / multimodal / RAG-embeddings respectively).
abstract final class Brand {
  // Surfaces
  static const navy = Color('#0B2351'); // primary background
  static const navyLight = Color('#1A3A5C'); // cards / raised surfaces
  static const navyDeep = Color('#071A3D'); // hero gradient bottom

  // Accents
  static const blue = Color('#3B82F6'); // primary CTA / links
  static const blueLight = Color('#93C5FD'); // links in dark mode
  static const orange = Color('#F59E0B'); // multimodal (vision + audio)
  static const green = Color('#10B981'); // RAG / embeddings

  // Text
  static const white = Color('#FFFFFF');
  static const white70 = Color('rgba(255, 255, 255, 0.70)');
  static const white50 = Color('rgba(255, 255, 255, 0.50)');

  // Light-mode surface (docs reading mode)
  static const slate50 = Color('#F8FAFC');

  // Typography
  static const fontSans = FontFamily.list([
    FontFamily('Inter'),
    FontFamilies.systemUi,
    FontFamilies.sansSerif,
  ]);
  static const fontMono = FontFamily.list([
    FontFamily('JetBrains Mono'),
    FontFamily('SF Mono'),
    FontFamilies.monospace,
  ]);
}
