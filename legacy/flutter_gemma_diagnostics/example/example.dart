// ignore_for_file: avoid_print
import 'package:flutter_gemma_diagnostics/flutter_gemma_diagnostics.dart';

/// Measures what an operation costs in memory the OS enforces.
Future<void> main() async {
  if (!FlutterGemmaDiagnostics.isSupported) {
    print('Memory diagnostics run on Android and iOS only.');
    return;
  }

  final before = await FlutterGemmaDiagnostics.memorySnapshot();
  // ... load a model or run a generation here ...
  final after = await FlutterGemmaDiagnostics.memorySnapshot();

  final anonBefore = before.anonymousBytes;
  final anonAfter = after.anonymousBytes;
  if (anonBefore != null && anonAfter != null) {
    final mib = (anonAfter - anonBefore) / (1024 * 1024);
    print('Anonymous footprint changed by ${mib.toStringAsFixed(1)} MiB');
  }
  print('Available now: ${after.availableBytes ?? 'unknown'} bytes');
}
