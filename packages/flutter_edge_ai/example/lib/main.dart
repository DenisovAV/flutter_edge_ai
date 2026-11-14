import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/home_screen.dart';
import 'package:material_ui/material_ui.dart';

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
      // flutter_edge_ai_agent's widgets (the Agent Skills demo) are still built
      // on package:flutter/material.dart, whose Theme and MaterialLocalizations
      // are separate types from material_ui's. The bridge gives them both, here
      // above the Navigator so the agent's dialogs and bottom sheets see them
      // too. flutter_markdown (chat replies) is built on it as well and takes
      // its heading, link and list styles from that Theme. Remove the bridge
      // only once neither depends on package:flutter/material.dart.
      // ignore: deprecated_member_use
      builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
      home: const SafeArea(child: HomeScreen()),
    );
  }
}
