import 'package:flutter/material.dart';

import 'multimodal_rag_item.dart';

/// The Multimodal RAG screen's own Material 3 theme, seeded from one color and
/// following the app's brightness.
ThemeData multimodalRagTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF5B7CFA),
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
  );
}

/// Each kind's accent, readable on both brightnesses.
Color kindColor(MultimodalRagKind kind, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (kind) {
    MultimodalRagKind.note =>
      dark ? const Color(0xFFFFC857) : const Color(0xFFB7791F),
    MultimodalRagKind.photo =>
      dark ? const Color(0xFF4CD6A8) : const Color(0xFF138A64),
    MultimodalRagKind.memo =>
      dark ? const Color(0xFFC39BFF) : const Color(0xFF7B3FD6),
  };
}

IconData kindIcon(MultimodalRagKind kind) => switch (kind) {
  MultimodalRagKind.note => Icons.sticky_note_2_outlined,
  MultimodalRagKind.photo => Icons.photo_outlined,
  MultimodalRagKind.memo => Icons.graphic_eq,
};

/// `m:ss`, for a memo's length.
String clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// A short duration: "45 ms", "1.2 s".
String shortDuration(Duration d) => d.inMilliseconds < 1000
    ? '${d.inMilliseconds} ms'
    : '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
