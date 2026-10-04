import 'package:flutter_edge_ai/core/function_call_parser.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/parsing/function_call_format_factory.dart';
import 'package:flutter_edge_ai/core/parsing/function_gemma_format.dart';
import 'package:flutter_edge_ai/core/parsing/sdk_passthrough_function_call_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FunctionGemma: the runtime picks the format', () {
    test('on .litertlm LiteRT-LM runs its tool calling (SDK passthrough)', () {
      expect(
        FunctionCallParser.usesSdkPassthrough(
          ModelType.functionGemma,
          fileType: ModelFileType.litertlm,
        ),
        isTrue,
      );
      expect(
        FunctionCallFormatFactory.create(
          ModelType.functionGemma,
          fileType: ModelFileType.litertlm,
        ),
        isA<SdkPassthroughFunctionCallFormat>(),
      );
    });

    test('on .task MediaPipe has no native tools (text wire format)', () {
      expect(
        FunctionCallParser.usesSdkPassthrough(
          ModelType.functionGemma,
          fileType: ModelFileType.task,
        ),
        isFalse,
      );
      expect(
        FunctionCallFormatFactory.create(
          ModelType.functionGemma,
          fileType: ModelFileType.task,
        ),
        isA<FunctionGemmaCallFormat>(),
      );
    });

    test('gemma4 is passthrough whatever the file type', () {
      for (final fileType in [null, ...ModelFileType.values]) {
        expect(
          FunctionCallParser.usesSdkPassthrough(
            ModelType.gemma4,
            fileType: fileType,
          ),
          isTrue,
          reason: 'gemma4 with fileType $fileType',
        );
      }
    });
  });

  group('FunctionCallParser.usesSdkPassthrough', () {
    test('true for the SDK-passthrough model (gemma4)', () {
      expect(FunctionCallParser.usesSdkPassthrough(ModelType.gemma4), isTrue);
    });

    test('false for text-stream function-call formats (parsed in-stream)', () {
      // These carry tool calls in the text stream, so the funcBuffer parses
      // them — they must NOT be swallowed by the SDK-passthrough path.
      for (final m in <ModelType?>[
        ModelType.qwen,
        ModelType.qwen3,
        ModelType.deepSeek,
        ModelType.phi,
        ModelType.llama,
        ModelType.functionGemma,
        ModelType.gemmaIt,
        ModelType.general,
        ModelType.hammer,
        null,
      ]) {
        expect(
          FunctionCallParser.usesSdkPassthrough(m),
          isFalse,
          reason: '$m must not be treated as SDK passthrough',
        );
      }
    });
  });

  group('FunctionCallFormatFactory for ModelType.gemma4', () {
    test('returns SdkPassthroughFunctionCallFormat', () {
      final format = FunctionCallFormatFactory.create(ModelType.gemma4);
      expect(format, isA<SdkPassthroughFunctionCallFormat>());
    });

    test('passthrough never reports a function call in text stream', () {
      final format = SdkPassthroughFunctionCallFormat();
      // Even text that looks like a tool call from another format is NOT a
      // function call here: SDK produces structured tool_calls separately.
      expect(
        format.isFunctionCallStart('<|tool_call>call:foo{}<tool_call|>'),
        isFalse,
      );
      expect(
        format.isFunctionCallComplete('<|tool_call>call:foo{}<tool_call|>'),
        isFalse,
      );
      expect(format.isDefinitelyText('any plain text'), isTrue);
      expect(format.parse('<|tool_call>call:foo{}<tool_call|>'), isNull);
      expect(format.parseAll('<|tool_call>call:foo{}<tool_call|>'), isEmpty);
    });
  });
}
