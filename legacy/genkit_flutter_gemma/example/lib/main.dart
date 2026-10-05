import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_embeddings/flutter_gemma_embeddings.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';

import 'app_state.dart';
import 'screens/chat_screen.dart';
import 'screens/embeddings_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/tools_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // flutter_gemma 1.0.0: engines and embedding backends are opt-in. Register
  // the providers from the packages this example depends on — MediaPipe for
  // .task/.bin models, LiteRT-LM for .litertlm models, and the LiteRT
  // embedding backend for the embeddings demo.
  await FlutterGemma.initialize(
    inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
    embeddingBackends: const [LiteRtEmbeddingBackend()],
    embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
  );
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Genkit Flutter Gemma',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _appState = AppState();
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _appState.initialize();
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  void _goToSettings() {
    setState(() => _currentIndex = 3);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Genkit Flutter Gemma')),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          ChatScreen(appState: _appState, onGoToSettings: _goToSettings),
          EmbeddingsScreen(appState: _appState, onGoToSettings: _goToSettings),
          ToolsScreen(appState: _appState, onGoToSettings: _goToSettings),
          SettingsScreen(appState: _appState),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat), label: 'Chat'),
          NavigationDestination(
            icon: Icon(Icons.data_array),
            label: 'Embeddings',
          ),
          NavigationDestination(icon: Icon(Icons.build), label: 'Tools'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
