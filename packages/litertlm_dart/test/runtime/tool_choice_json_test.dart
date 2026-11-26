// ToolChoice as the C API's JSON (OpenAI tool_choice) and its checks.
import 'dart:convert';

import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:litertlm_dart/src/runtime/tool_choice_json.dart';
import 'package:test/test.dart';

Object? _json(ToolChoice? choice) {
  final text = toolChoiceJson(
    choice,
    toolNames: const ['show_alert', 'set_color'],
    hasResponseFormat: false,
  );
  return text == null ? null : jsonDecode(text);
}

void main() {
  test(
    'each choice as the C API documents it; auto and no choice send none',
    () {
      expect(_json(null), isNull);
      expect(_json(ToolChoice.auto), isNull);
      expect(_json(ToolChoice.none), 'none');
      expect(_json(ToolChoice.required), 'required');
      expect(_json(const ToolChoice.forcedFunction('set_color')), {
        'type': 'function',
        'function': {'name': 'set_color'},
      });
      expect(_json(const ToolChoice.allowedTools(['show_alert'])), {
        'type': 'allowed_tools',
        'allowed_tools': {
          'mode': 'auto',
          'tools': [
            {
              'type': 'function',
              'function': {'name': 'show_alert'},
            },
          ],
        },
      });
      expect(
        (_json(
              const ToolChoice.allowedTools([
                'show_alert',
                'set_color',
              ], required: true),
            )!
            as Map)['allowed_tools']['mode'],
        'required',
      );
    },
  );

  test('a choice the conversation cannot take is an ArgumentError', () {
    String? encode(
      ToolChoice choice, {
      List<String> tools = const ['t'],
      bool format = false,
    }) => toolChoiceJson(choice, toolNames: tools, hasResponseFormat: format);
    expect(() => encode(ToolChoice.none, tools: []), throwsArgumentError);
    expect(
      () => encode(ToolChoice.required, format: true),
      throwsArgumentError,
    );
    expect(
      () => encode(const ToolChoice.forcedFunction('')),
      throwsArgumentError,
    );
    expect(
      () => encode(const ToolChoice.forcedFunction('u')),
      throwsArgumentError,
    );
    expect(
      () => encode(const ToolChoice.allowedTools([])),
      throwsArgumentError,
    );
    expect(
      () => encode(const ToolChoice.allowedTools(['t', 'u'])),
      throwsArgumentError,
    );
    // auto needs nothing: it is what native does without a choice.
    expect(encode(ToolChoice.auto, tools: [], format: true), isNull);
  });

  test('SpeculativeDecodingConfig: lenience in [0, 1]', () {
    for (final l in [0.0, 0.5, 1.0, null]) {
      expect(
        SpeculativeDecodingConfig(
          mode: SpeculativeDecodingMode.on,
          lenience: l,
        ).lenience,
        l,
      );
    }
    for (final l in [-0.1, 1.1, double.nan]) {
      expect(
        () => SpeculativeDecodingConfig(
          mode: SpeculativeDecodingMode.on,
          lenience: l,
        ),
        throwsArgumentError,
      );
    }
  });

  test('EngineConfig.selectedSignatures: empty or with an empty name is an '
      'ArgumentError', () {
    for (final names in [
      <String>[],
      ['decode', ''],
    ]) {
      expect(
        () => EngineConfig(modelPath: 'm', selectedSignatures: names),
        throwsArgumentError,
      );
    }
    expect(
      EngineConfig(
        modelPath: 'm',
        selectedSignatures: ['prefill_128', 'decode'],
      ).selectedSignatures,
      ['prefill_128', 'decode'],
    );
  });
}
