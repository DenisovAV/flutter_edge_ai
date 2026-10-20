import 'package:flutter/material.dart';
import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize inference, embedding, speech, and skill runtimes. The RAG demo
  // owns its indexes independently and can switch storage without resetting
  // these core services.
  await bootstrapGemma();

  runApp(const ChatApp());
}

class ChatApp extends StatelessWidget {
  const ChatApp({super.key, this.debugBanner = true});

  /// Whether the DEBUG ribbon shows in debug builds; the Multimodal RAG demo
  /// recording turns it off.
  final bool debugBanner;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Edge AI Example',
      debugShowCheckedModeBanner: debugBanner,
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
