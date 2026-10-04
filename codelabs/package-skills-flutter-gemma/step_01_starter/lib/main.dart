import 'package:flutter/material.dart';

void main() => runApp(const SkillsApp());

/// The whole starter.
///
/// The chat and the tool call are your coding assistant's work in this
/// codelab, so this app only has to run: that proves the platform setup is
/// sound before anything else changes. `flutter_edge_ai` and
/// `flutter_edge_ai_litertlm` are already dependencies, and nothing imports them
/// yet — they are here because `dart run skills@ get` finds skills by scanning
/// an app's dependencies.
class SkillsApp extends StatelessWidget {
  const SkillsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Edge AI Skills',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Nothing here yet.\n'
              'Ask your coding assistant to build the chat.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
