import 'package:flutter/material.dart';
import 'package:flutter_gemma_example/integration_test_screen.dart';

/// Separate entry point for Integration Tests
///
/// Run with: flutter run -t lib/main_integration_tests.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IntegrationTestApp());
}

class IntegrationTestApp extends StatelessWidget {
  const IntegrationTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartDownloader Integration Tests',
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.white),
          bodyMedium: TextStyle(color: Colors.white),
        ),
      ),
      themeMode: ThemeMode.dark,
      home: const SafeArea(child: IntegrationTestScreen()),
    );
  }
}
