// Phase 0b — Capture raw Gemma 4 model output to verify SDK applies
// chat_template.jinja itself when tools_json is passed.
//
// What this proves:
// 1. SDK reads `tools_json` and renders `<|tool>declaration:...<tool|>` natively
//    in the prompt (we never see this Dart-side; we only see model output).
// 2. Model emits `<|tool_call>call:NAME{...}<tool_call|>` in response when
//    user asks for an action — verifying native function-calling discipline.
// 3. The exact native arguments syntax (does the model emit `<|"|>str<|"|>`?
//    plain quotes? bare keys?) — this confirms what our parser must accept.
//
// We deliberately bypass `chat.dart` (no createToolsPrompt injection) and
// drive `LiteRtLmFfiClient` directly with OpenAI Chat Completions JSON.
//
// Run on macOS:
//   flutter test integration_test/gemma4_raw_output_capture.dart -d macos

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/core/sampling.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _sampling = ResolvedSampling(
  temperature: 0.6,
  topK: 40,
  topP: 0.95,
  randomSeed: 42,
);

const _gemma4Path =
    '/Users/sashadenisov/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/gemma-4-E2B-it.litertlm';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Phase 0b: Gemma 4 raw output with tools_json', (t) async {
    expect(
      File(_gemma4Path).existsSync(),
      isTrue,
      reason: 'Place gemma-4-E2B-it.litertlm at $_gemma4Path',
    );

    final ffi = LiteRtLmFfiClient();
    final cacheDir = await getApplicationCacheDirectory();

    await ffi.initialize(
      modelPath: _gemma4Path,
      backend: 'gpu',
      maxTokens: 2048,
      cacheDir: cacheDir.path,
    );

    final tools = jsonEncode([
      {
        'type': 'function',
        'function': {
          'name': 'change_color',
          'description': 'Change the UI background color.',
          'parameters': {
            'type': 'object',
            'properties': {
              'color': {
                'type': 'string',
                'description': 'A color name like red, blue, green.',
              },
            },
            'required': ['color'],
          },
        },
      },
    ]);

    await ffi.createConversation(toolsJson: tools, sampling: _sampling);

    final messageJson = LiteRtLmFfiClient.buildMessageJson(
      'Make the background red.',
    );

    print('=== gemma4_raw_output_capture: SENDING ===');
    print('tools_json: $tools');
    print('message_json: $messageJson');

    final raw = await ffi.sendMessage(messageJson);

    print('=== RAW RESPONSE (length=${raw.length}) ===');
    print(raw);
    print('=== END RAW RESPONSE ===');

    // Save for offline inspection (use sandboxed temp dir).
    final tmpDir = await getTemporaryDirectory();
    final out = File('${tmpDir.path}/gemma4_raw_output.json');
    out.writeAsStringSync(raw);
    print('Saved to ${out.path}');

    // Sanity: not empty, not error.
    expect(raw, isNotEmpty);

    // Check: SDK already returned parsed OpenAI Chat Completions JSON?
    Map<String, dynamic>? parsed;
    try {
      parsed = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
    print('parsed top-level keys: ${parsed?.keys.toList()}');
    final toolCalls = parsed?['tool_calls'] as List?;
    print('tool_calls count: ${toolCalls?.length}');
    if (toolCalls != null && toolCalls.isNotEmpty) {
      final fn = (toolCalls.first as Map)['function'] as Map?;
      print('tool_call name: ${fn?['name']}');
      print('tool_call arguments: ${fn?['arguments']}');
    }

    // Check raw native markers (just in case).
    final hasNativeCall =
        raw.contains('<|tool_call>') && raw.contains('<tool_call|>');
    print('contains <|tool_call>...<tool_call|>: $hasNativeCall');

    // Plain text response check.
    final content = parsed?['content'] as List?;
    print('plain content blocks: ${content?.length}');
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('Phase 0b: Gemma 4 plain text query (no tools)', (t) async {
    // Control test — without tools, output should be plain text response,
    // not tool_calls. Verifies SDK only renders <|tool>...<tool|> when
    // tools_json is present.
    final ffi = LiteRtLmFfiClient();
    final cacheDir = await getApplicationCacheDirectory();

    await ffi.initialize(
      modelPath: _gemma4Path,
      backend: 'gpu',
      maxTokens: 2048,
      cacheDir: cacheDir.path,
    );
    await ffi.createConversation(sampling: _sampling);

    final messageJson = LiteRtLmFfiClient.buildMessageJson(
      'What is the capital of France?',
    );
    final raw = await ffi.sendMessage(messageJson);

    print('=== plain query RAW (length=${raw.length}) ===');
    print(raw);
    print('=== END plain query ===');

    expect(raw, isNotEmpty);
    expect(
      raw.contains('Paris'),
      isTrue,
      reason: 'plain text answer expected to mention Paris',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
