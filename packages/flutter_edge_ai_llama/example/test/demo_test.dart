import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai_llama_demo/main.dart' as demo;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final size in const [
    Size(900, 650),
    Size(640, 480),
    Size(360, 640),
    Size(320, 568),
  ]) {
    testWidgets('idle demo renders at $size with a usable model picker', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final originalPaths = PathProviderPlatform.instance;
      Directory? scratch;
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        PathProviderPlatform.instance = originalPaths;
        await scratch?.delete(recursive: true);
      });
      await tester.runAsync(() async {
        scratch = await Directory.systemTemp.createTemp('edge-llama-widget-');
        PathProviderPlatform.instance = _Paths(scratch!.path);
        SharedPreferences.setMockInitialValues({});
        await demo.main();
      });
      await tester.pumpAndSettle();
      expect(find.text('GGUF Lab'), findsOneWidget);
      expect(find.text('Flutter Edge AI × llamadart'), findsOneWidget);
      final picker = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Choose model'),
      );
      expect(picker.onPressed, isNotNull);
      final send = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Send'),
      );
      expect(send.onPressed, isNull);
      expect(
        tester.takeException(),
        isNull,
        reason: 'No overflow or startup exception at $size',
      );
    });
  }
  testWidgets('phone composer stays visible when the keyboard opens', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    final original = PathProviderPlatform.instance;
    late Directory scratch;
    addTearDown(() async {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
      PathProviderPlatform.instance = original;
      await scratch.delete(recursive: true);
    });
    await tester.runAsync(() async {
      scratch = await Directory.systemTemp.createTemp('edge-llama-keyboard-');
      PathProviderPlatform.instance = _Paths(scratch.path);
      SharedPreferences.setMockInitialValues({});
      await demo.main();
    });
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Send'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}
