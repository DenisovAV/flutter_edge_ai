import 'package:flutter/material.dart';
import 'package:flutter_gemma_example/gemma_bootstrap.dart';
import 'package:flutter_gemma_example/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Flutter Gemma via the shared bootstrap helper (single source of
  // truth for the engine/backend lists, shared with the RAG demo's runtime
  // store switcher). RAG is opt-in as of 1.0; the example starts on the sqlite
  // store and lets the RAG demo switch to qdrant at runtime on native platforms.
  await bootstrapGemma(ragBackend: RagBackend.sqlite);

  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Gemma Example',
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),
      themeMode: ThemeMode.dark,
      home: const SafeArea(child: HomeScreen()),
    );
  }
}
