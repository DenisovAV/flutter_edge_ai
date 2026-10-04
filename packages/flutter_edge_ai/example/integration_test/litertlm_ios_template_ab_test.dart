// Regression harness: a .litertlm prompt must reach LiteRT-LM unwrapped on iOS,
// the same as on every other platform.
//
// From 0.13.0 `_chatFormatModeFor` (core/extensions.dart) formatted a .litertlm
// message by hand on iOS, with per-ModelType turn markers, because iOS then ran
// .litertlm through MediaPipe, which applied no template. 0.14.0 moved iOS onto
// the shared LiteRtLmFfiClient and the LiteRT-LM Conversation API, which applies
// the model's own chat template, but the iOS branch stayed: the hand-written
// markers reached the model as message text and were wrapped a second time.
// Measured with this file on Gemma 4 E2B, prompt "Repeat word for word the exact
// text of my message and nothing else.": the native path repeated the message,
// the iOS branch answered `model` — the tail of its own wrapper.
//
// This runs the SAME native code on macOS and flips only the Dart-side gate:
// the formatting read `defaultTargetPlatform`, while library loading reads
// dart:io `Platform`, so overriding the former around the query changes the
// templating and nothing else. The model is installed and loaded before the
// override is set, so installation is untouched too.
//
// For each variant it prints three layers:
//   1. the string handed to addQueryChunk,
//   2. the RAW session reply — no Dart filter between it and the native output,
//   3. what an app shows through InferenceChat.generateChatResponse.
// With the fix in place all three match between the two variants.
//
// Sampling is greedy (topK defaults to 1), so a difference is the prompt's doing.
//
// Stage a bundle (macOS App Sandbox redirects $HOME, so the on-disk location is
// double-nested while the path computed below is what the app sees):
//   ~/Library/Containers/<id>/Data/Library/Containers/<id>/Data/Documents/
//
// Run:
//   flutter test integration_test/litertlm_ios_template_ab_test.dart -d macos
//   ... --dart-define=AB_BUNDLE=gemma3-1b-it-int4.litertlm \
//       --dart-define=AB_MODEL_TYPE=gemmaIt
//   ... --dart-define=AB_BUNDLE=Qwen3-0.6B.litertlm \
//       --dart-define=AB_MODEL_TYPE=qwen3
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/core/extensions.dart' show MessageExtension;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _bundle = String.fromEnvironment(
  'AB_BUNDLE',
  defaultValue: 'gemma-4-E2B-it.litertlm',
);
const _modelTypeName = String.fromEnvironment(
  'AB_MODEL_TYPE',
  defaultValue: 'gemma4',
);
const _prompt = String.fromEnvironment(
  'AB_PROMPT',
  defaultValue: 'What is the capital of France? Answer with one word.',
);

ModelType get _modelType =>
    ModelType.values.firstWhere((t) => t.name == _modelTypeName);

String get _stagedPath {
  final home = Platform.environment['HOME'];
  const id = 'dev.flutterberlin.flutterGemmaExample55';
  return '$home/Library/Containers/$id/Data/Documents/$_bundle';
}

const _markers = [
  '<start_of_turn>',
  '<end_of_turn>',
  '<|im_start|>',
  '<|im_end|>',
];

String _markerCounts(String s) => _markers
    .map((m) => '$m×${m.allMatches(s).length}')
    .where((e) => !e.endsWith('×0'))
    .join(' ');

String _show(String s) {
  final flat = s.replaceAll('\n', r'\n');
  return flat.length > 320 ? '${flat.substring(0, 320)}…' : flat;
}

Future<void> _variant(InferenceModel model, {required bool asIOS}) async {
  final label = asIOS ? 'iOS branch' : 'native   ';
  const message = Message(text: _prompt, isUser: true);

  debugDefaultTargetPlatformOverride = asIOS ? TargetPlatform.iOS : null;
  try {
    final sent = message.transformToChatPrompt(
      type: _modelType,
      fileType: ModelFileType.litertlm,
    );
    print('[$label] SENT     : "${_show(sent)}"');

    InferenceModelSession? session;
    try {
      session = await model.createSession();
      await session.addQueryChunk(message);
      final raw = await session.getResponse();
      final counts = _markerCounts(raw);
      print(
        '[$label] RAW      : "${_show(raw)}"'
        '${counts.isEmpty ? '' : '   markers: $counts'}',
      );
    } finally {
      await session?.close();
    }

    InferenceChat? chat;
    try {
      chat = await model.createChat();
      await chat.addQueryChunk(message);
      final response = await chat.generateChatResponse();
      final visible = response is TextResponse ? response.token : '$response';
      print('[$label] APP SEES : "${_show(visible)}"');
    } finally {
      await chat?.close();
    }
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('litertlm: native templating vs the iOS branch, same engine', (
    tester,
  ) async {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final staged = File(_stagedPath);
    if (!staged.existsSync()) {
      print('SKIP: no bundle staged at $_stagedPath');
      return;
    }
    print(
      'bundle: $_bundle '
      '${(staged.lengthSync() / 1e9).toStringAsFixed(2)} GB, '
      'modelType=$_modelTypeName, prompt="$_prompt"',
    );

    await registerTestEngines();
    await FlutterEdgeAi.installModel(
      modelType: _modelType,
      fileType: ModelFileType.litertlm,
    ).fromFile(_stagedPath).install();

    final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
    try {
      await _variant(model, asIOS: false);
      await _variant(model, asIOS: true);
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
