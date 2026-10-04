import 'package:flutter_edge_ai/core/parsing/json_function_call_format.dart';
import 'package:flutter_edge_ai/core/parsing/sdk_passthrough_function_call_format.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the text of every chunk staged into the session, so a test can
/// assert whether [InferenceChat] wove its own JSON tools prompt (the
/// "You have access to functions" instruction) or skipped it because the
/// runtime injects tool declarations itself.
class _RecordingSession extends InferenceModelSession {
  final List<String> staged = [];

  @override
  Future<void> addQueryChunk(Message message) async => staged.add(message.text);

  @override
  Future<String> getResponse() async => '';

  @override
  Stream<String> getResponseAsync() => const Stream<String>.empty();

  @override
  Future<int> sizeInTokens(String text) async => 0;

  @override
  Future<void> stopGeneration() async {}

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  Future<void> close() async {}
}

const _tool = Tool(name: 'get_time', description: 'Get the current time.');

/// True if any staged chunk is the core JSON tools prompt (the marker phrase
/// from [InferenceChat.createToolsPrompt]'s JSON format).
bool _woveToolsPrompt(_RecordingSession s) =>
    s.staged.any((t) => t.contains('You have access to functions'));

/// True if any staged chunk carries FunctionGemma's hand-rendered declarations.
bool _woveFunctionGemmaDeclarations(_RecordingSession s) =>
    s.staged.any((t) => t.contains('<start_function_declaration>'));

Future<(InferenceChat, _RecordingSession)> _chat({
  ModelType modelType = ModelType.gemmaIt,
  ModelFileType fileType = ModelFileType.task,
  bool? runtimeInjectsToolDeclarations,
  bool supportsFunctionCalls = true,
  ToolChoice toolChoice = ToolChoice.auto,
}) async {
  final session = _RecordingSession();
  final chat = InferenceChat(
    sessionCreator: () async => session,
    maxTokens: 1024,
    supportsFunctionCalls: supportsFunctionCalls,
    tools: const [_tool],
    modelType: modelType,
    fileType: fileType,
    toolChoice: toolChoice,
    runtimeInjectsToolDeclarations: runtimeInjectsToolDeclarations,
  );
  await chat.initSession();
  return (chat, session);
}

void main() {
  group('FunctionCallFormat.runtimeInjectsToolDeclarations', () {
    test('true only for the SDK-passthrough format (gemma4)', () {
      expect(
        SdkPassthroughFunctionCallFormat().runtimeInjectsToolDeclarations,
        isTrue,
      );
      expect(JsonFunctionCallFormat().runtimeInjectsToolDeclarations, isFalse);
    });

    test('FunctionCallParser helper mirrors the format', () {
      expect(
        FunctionCallParser.runtimeInjectsToolDeclarations(ModelType.gemma4),
        isTrue,
      );
      for (final m in <ModelType?>[
        ModelType.gemmaIt,
        ModelType.general,
        ModelType.qwen,
        ModelType.qwen3,
        ModelType.deepSeek,
        ModelType.phi,
        ModelType.llama,
        ModelType.functionGemma,
        ModelType.hammer,
        null,
      ]) {
        expect(
          FunctionCallParser.runtimeInjectsToolDeclarations(m),
          isFalse,
          reason: '$m must not skip Dart-side tool-prompt weaving',
        );
      }
    });
  });

  group('InferenceChat resolves runtimeInjectsToolDeclarations', () {
    test('derives true from the gemma4 format when no override', () async {
      final (chat, _) = await _chat(modelType: ModelType.gemma4);
      expect(chat.runtimeInjectsToolDeclarations, isTrue);
    });

    test('derives false for a text-stream model when no override', () async {
      final (chat, _) = await _chat(modelType: ModelType.gemmaIt);
      expect(chat.runtimeInjectsToolDeclarations, isFalse);
    });

    test(
      'explicit override wins over the format default (true on gemmaIt)',
      () async {
        final (chat, _) = await _chat(
          modelType: ModelType.gemmaIt,
          runtimeInjectsToolDeclarations: true,
        );
        expect(chat.runtimeInjectsToolDeclarations, isTrue);
      },
    );

    test(
      'explicit override wins over the format default (false on gemma4)',
      () async {
        final (chat, _) = await _chat(
          modelType: ModelType.gemma4,
          runtimeInjectsToolDeclarations: false,
        );
        expect(chat.runtimeInjectsToolDeclarations, isFalse);
      },
    );
  });

  group('addQueryChunk weaving obeys runtimeInjectsToolDeclarations', () {
    test('text-stream model (default): weaves the core tools prompt', () async {
      final (chat, session) = await _chat(modelType: ModelType.gemmaIt);
      await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
      expect(_woveToolsPrompt(session), isTrue);
    });

    test(
      'gemma4 (format-derived): does NOT weave (SDK injects) — unchanged',
      () async {
        final (chat, session) = await _chat(modelType: ModelType.gemma4);
        await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
        expect(_woveToolsPrompt(session), isFalse);
      },
    );

    test('override true (native-assisted path): does NOT weave', () async {
      final (chat, session) = await _chat(
        modelType: ModelType.gemmaIt,
        runtimeInjectsToolDeclarations: true,
      );
      await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
      expect(_woveToolsPrompt(session), isFalse);
    });

    test('override false FORCES weaving even on gemma4 (proves flag, not model '
        'type, drives it)', () async {
      final (chat, session) = await _chat(
        modelType: ModelType.gemma4,
        runtimeInjectsToolDeclarations: false,
      );
      await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
      expect(_woveToolsPrompt(session), isTrue);
    });

    test(
      'FunctionGemma on .litertlm: does NOT weave (LiteRT-LM renders them)',
      () async {
        final (chat, session) = await _chat(
          modelType: ModelType.functionGemma,
          fileType: ModelFileType.litertlm,
        );
        await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
        expect(chat.runtimeInjectsToolDeclarations, isTrue);
        expect(_woveFunctionGemmaDeclarations(session), isFalse);
      },
    );

    test('FunctionGemma on .task: weaves its own declarations', () async {
      final (chat, session) = await _chat(
        modelType: ModelType.functionGemma,
        fileType: ModelFileType.task,
      );
      await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
      expect(chat.runtimeInjectsToolDeclarations, isFalse);
      expect(_woveFunctionGemmaDeclarations(session), isTrue);
    });

    test('ToolChoice.none: never weaves regardless of the flag', () async {
      final (chat, session) = await _chat(
        modelType: ModelType.gemmaIt,
        toolChoice: ToolChoice.none,
      );
      await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
      expect(_woveToolsPrompt(session), isFalse);
    });

    test('supportsFunctionCalls false: never weaves', () async {
      final (chat, session) = await _chat(
        modelType: ModelType.gemmaIt,
        supportsFunctionCalls: false,
      );
      await chat.addQueryChunk(const Message(text: 'hi', isUser: true));
      expect(_woveToolsPrompt(session), isFalse);
    });
  });
}
