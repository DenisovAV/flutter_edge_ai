import 'package:flutter/material.dart';

/// Motormind blue, the seed every scheme derives from.
const _seed = Color(0xFF1F5F8B);

/// The app theme for [brightness]; Material 3 is the framework default.
ThemeData motormindTheme(Brightness brightness) =>
    ThemeData(brightness: brightness, colorSchemeSeed: _seed);
