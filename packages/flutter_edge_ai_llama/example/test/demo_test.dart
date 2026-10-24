import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama_demo/main.dart' as demo;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('model URL validation refuses names before model replacement', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final value in [
      'chat.gguf',
      '/models/chat.gguf',
      'https://',
      'file:///chat.gguf',
      'http://remote.example/chat.gguf',
      'https://models.example',
      'https://models.example/',
      'https://models.example/models/',
    ]) {
      expect(() => demo.validateModelUrl(value), throwsArgumentError);
    }
    for (final value in [
      'https://models.example/chat.gguf',
      'http://127.0.0.1:8098/chat.gguf',
    ]) {
      expect(() => demo.validateModelUrl(value), returnsNormally);
    }
  });
  test('Android rejects cleartext before closing the current model', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      expect(
        () => demo.validateModelUrl('http://127.0.0.1:8098/chat.gguf'),
        throwsArgumentError,
      );
      expect(
        () => demo.validateModelUrl('https://models.example/chat.gguf'),
        returnsNormally,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
  test('restart cache paths never become Android replacement URLs', () {
    final restored = edge.ModelSource.file('/app/models/old.gguf');
    expect(demo.restoredModelInput(restored, urlsOnly: true), isEmpty);
    expect(
      demo.restoredModelInput(restored, urlsOnly: false),
      '/app/models/old.gguf',
    );
    expect(
      demo.restoredModelInput(
        edge.ModelSource.network('https://models.example/old.gguf'),
        urlsOnly: true,
      ),
      'https://models.example/old.gguf',
    );
    final previous = edge.InferenceModelSpec(
      name: 'old.gguf',
      modelSource: restored,
      modelType: edge.ModelType.general,
      fileType: edge.ModelFileType.gguf,
    );
    final replacement = edge.InferenceModelSpec(
      name: 'new.gguf',
      modelSource: edge.ModelSource.network('https://models.example/new.gguf'),
      modelType: edge.ModelType.general,
      fileType: edge.ModelFileType.gguf,
    );
    expect(demo.shouldUninstallPreviousModel(previous, replacement), isTrue);
    expect(demo.shouldUninstallPreviousModel(previous, previous), isFalse);
    expect(demo.shouldUninstallPreviousModel(previous, null), isFalse);
  });

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
        find.widgetWithText(FilledButton, 'Load URL'),
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
  testWidgets('iOS picker supplies UTIs and Android supports URL entry', (
    tester,
  ) async {
    final originalPaths = PathProviderPlatform.instance;
    final originalSelector = FileSelectorPlatform.instance;
    final picker = _Picker();
    late Directory scratch;
    addTearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      FileSelectorPlatform.instance = originalSelector;
      PathProviderPlatform.instance = originalPaths;
      await scratch.delete(recursive: true);
    });
    await tester.runAsync(() async {
      scratch = await Directory.systemTemp.createTemp('edge-llama-picker-');
      PathProviderPlatform.instance = _Paths(scratch.path);
      SharedPreferences.setMockInitialValues({});
      FileSelectorPlatform.instance = picker;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await demo.main();
    });
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Choose model'));
    await tester.pumpAndSettle();
    expect(picker.groups.single.uniformTypeIdentifiers, ['public.data']);
    expect(picker.groups.single.extensions, ['gguf']);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(demo.main);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Load URL'), findsOneWidget);
    final modelField = tester.widget<TextField>(find.byType(TextField).first);
    expect(modelField.readOnly, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

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

class _Picker extends FileSelectorPlatform {
  List<XTypeGroup> groups = [];
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    groups = acceptedTypeGroups ?? [];
    return null;
  }
}
