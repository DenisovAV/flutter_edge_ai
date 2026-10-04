// On-device: tool calling through LiteRT-LM's own tool path — the runtime
// renders the declarations, the call comes back as `tool_calls`, and the result
// goes back as a role-`tool` message. Each case asserts what bare LiteRT-LM
// produced for the same model and prompt with greedy decoding, not merely that a
// call was detected. Until the result went back as role `tool`, every
// FunctionGemma answered it by calling the same function again, and a test that
// stopped at "a call was parsed" passed the whole time.
//
// Stage the models in the app documents dir (desktop/iOS) or
// /data/local/tmp/flutter_gemma_test/ (Android):
//   functiongemma-270M-it.litertlm      sasha-denisov/function-gemma-270M-it
//   mobile_actions_q8_ekv1024.litertlm  litert-community/functiongemma-270m-ft-mobile-actions
//   tiny_garden.litertlm                google/functiongemma-270m-it
//   gemma-4-E2B-it.litertlm             litert-community/gemma-4-E2B-it-litert-lm
//
// Run: flutter test integration_test/litertlm_native_tools_test.dart -d <device>
// CPU by default; --dart-define=TOOLS_BACKEND=gpu for the GPU backend.
import 'dart:io';

import 'package:flutter_edge_ai/core/parsing/sdk_response_parser.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

const _backendName = String.fromEnvironment(
  'TOOLS_BACKEND',
  defaultValue: 'cpu',
);

// The function-calling codelab's tools.
const _codelabTools = [
  Tool(
    name: 'multiply',
    description:
        'Multiply two numbers and return the exact product. Use this for any '
        'multiplication instead of working it out yourself.',
    parameters: {
      'type': 'object',
      'properties': {
        'a': {'type': 'number', 'description': 'The first number.'},
        'b': {'type': 'number', 'description': 'The second number.'},
      },
      'required': ['a', 'b'],
    },
  ),
  Tool(
    name: 'get_current_time',
    description:
        'Return the current local date and time on this device. Use this '
        'whenever the answer depends on what time it is now.',
    parameters: {'type': 'object', 'properties': <String, dynamic>{}},
  ),
  Tool(
    name: 'get_device_info',
    description:
        'Return the platform this app is running on. Use this when asked about '
        'the device, the operating system, or where the app is running.',
    parameters: {'type': 'object', 'properties': <String, dynamic>{}},
  ),
];

// lib/chat_screen.dart's tools.
const _exampleTools = [
  Tool(
    name: 'change_background_color',
    description: 'Changes the app background color',
    parameters: {
      'type': 'object',
      'properties': {
        'color': {
          'type': 'string',
          'description':
              'The color name (red, green, blue, yellow, purple, orange)',
        },
      },
      'required': ['color'],
    },
  ),
  Tool(
    name: 'change_app_title',
    description: 'Changes the application title text in the AppBar',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {
          'type': 'string',
          'description': 'The new title text to display',
        },
      },
      'required': ['title'],
    },
  ),
  Tool(
    name: 'show_alert',
    description: 'Shows an alert dialog with a custom message and title',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {
          'type': 'string',
          'description': 'The title of the alert dialog',
        },
        'message': {
          'type': 'string',
          'description': 'The message content of the alert dialog',
        },
      },
      'required': ['title', 'message'],
    },
  ),
];

// The first google/mobile-actions training row: its tools, developer message
// and question, which the Mobile Actions model was fine-tuned on.
const _mobileActionsSystem =
    'Current date and time given in YYYY-MM-DDTHH:MM:SS format: '
    '2025-06-04T15:29:23\nDay of week is Wednesday\n'
    'You are a model that can do function calling with the following '
    'functions\n';
const _mobileActionsTools = [
  Tool(
    name: 'turn_off_flashlight',
    description: 'Turns the flashlight off.',
    parameters: {'type': 'OBJECT', 'properties': <String, dynamic>{}},
  ),
  Tool(
    name: 'open_wifi_settings',
    description: 'Opens the Wi-Fi settings.',
    parameters: {'type': 'OBJECT', 'properties': <String, dynamic>{}},
  ),
  Tool(
    name: 'create_calendar_event',
    description: 'Creates a new calendar event.',
    parameters: {
      'type': 'OBJECT',
      'properties': {
        'datetime': {
          'type': 'STRING',
          'description':
              'The date and time of the event in the format '
              'YYYY-MM-DDTHH:MM:SS.',
        },
        'title': {'type': 'STRING', 'description': 'The title of the event.'},
      },
      'required': ['title', 'datetime'],
    },
  ),
  Tool(
    name: 'show_map',
    description: 'Shows a location on the map.',
    parameters: {
      'type': 'OBJECT',
      'properties': {
        'query': {
          'type': 'STRING',
          'description':
              'The location to search for. May be the name of a place, a '
              'business, or an address.',
        },
      },
      'required': ['query'],
    },
  ),
  Tool(
    name: 'send_email',
    description: 'Sends an email.',
    parameters: {
      'type': 'OBJECT',
      'properties': {
        'body': {'type': 'STRING', 'description': 'The body of the email.'},
        'subject': {
          'type': 'STRING',
          'description': 'The subject of the email.',
        },
        'to': {
          'type': 'STRING',
          'description': 'The email address of the recipient.',
        },
      },
      'required': ['to', 'subject'],
    },
  ),
  Tool(
    name: 'turn_on_flashlight',
    description: 'Turns the flashlight on.',
    parameters: {'type': 'OBJECT', 'properties': <String, dynamic>{}},
  ),
  Tool(
    name: 'create_contact',
    description: "Creates a contact in the phone's contact list.",
    parameters: {
      'type': 'OBJECT',
      'properties': {
        'last_name': {
          'type': 'STRING',
          'description': 'The last name of the contact.',
        },
        'first_name': {
          'type': 'STRING',
          'description': 'The first name of the contact.',
        },
        'phone_number': {
          'type': 'STRING',
          'description': 'The phone number of the contact.',
        },
        'email': {
          'type': 'STRING',
          'description': 'The email address of the contact.',
        },
      },
      'required': ['first_name', 'last_name'],
    },
  ),
];

// google-ai-edge/gallery TinyGardenTask.kt SYSTEM_PROMPT and TinyGardenTools.kt.
const _tinyGardenSystem = '''
You are an assistant helping the user play a game about gardening.

The environment is a 3x3 grid of garden plots. The plots are numbered 1 through 9.

**Garden Plot Layout**:

- Row 1: Plots 1, 2, 3 (top row)
- Row 2: Plots 4, 5, 6 (middle row)
- Row 3: Plots 7, 8, 9 (bottom row)

Help the user plant seeds, water plots, and harvest flowers.

There are 4 kinds of seeds you can plant:

1. sunflower
2. daisy
3. rose
4. special (edge gallery, special, secret)

Plot Array: For each action, identify all individual plot numbers (1-9) or implied plots (e.g., 'top row' -> 1, 2, 3) and collect them into the `plots` list.

Tips:

- ""top row"" has plots 1, 2, 3.
- ""middle row"" has plots 4, 5, 6.
- ""bottom row"" has plots 7, 8, 9.
- ""left column"" has plots 1, 4, 7.
- ""middle column"" has plots 2, 5, 8.
- ""right column"" has plots 3, 6, 9.
''';
const _plots = {
  'type': 'array',
  'items': {'type': 'integer'},
};
const _tinyGardenTools = [
  Tool(
    name: 'water_plots',
    description: 'Water one or more garden plots.',
    parameters: {
      'type': 'object',
      'properties': {
        'plots': {..._plots, 'description': 'The IDs of the plots to water.'},
      },
      'required': ['plots'],
    },
  ),
  Tool(
    name: 'plant_seed',
    description: 'Plant a seed in one or more garden plots.',
    parameters: {
      'type': 'object',
      'properties': {
        'seed': {
          'type': 'string',
          'description': 'The name of the seed to plant.',
        },
        'plots': {
          ..._plots,
          'description': 'The IDs of the plots to plant a seed in.',
        },
      },
      'required': ['seed', 'plots'],
    },
  ),
  Tool(
    name: 'harvest_plots',
    description: 'Harvest one or more garden plots.',
    parameters: {
      'type': 'object',
      'properties': {
        'plots': {..._plots, 'description': 'The IDs of the plots to harvest.'},
      },
      'required': ['plots'],
    },
  ),
];

/// Where [file] is staged. The iOS Simulator can read the host filesystem, so
/// `--dart-define=IOS_TEST_DOCS_DIR=<host dir>` reuses models already on the
/// Mac instead of copying gigabytes into an app container that `flutter test`
/// removes after every run — the convention litertlm_ffi_test.dart uses.
Future<String?> _modelPath(String file) async {
  const hostDir = String.fromEnvironment('IOS_TEST_DOCS_DIR');
  if (Platform.isIOS && hostDir.isNotEmpty) {
    final path = '$hostDir/$file';
    return File(path).existsSync() ? path : null;
  }
  return stagedModelPath(file);
}

Future<InferenceModel> _load(
  String file,
  ModelType modelType, {
  int maxTokens = 1024,
}) async {
  await registerTestEngines();
  final path = await _modelPath(file);
  expect(
    path,
    isNotNull,
    reason:
        'stage $file in the app documents dir (desktop/iOS), in '
        '/data/local/tmp/flutter_gemma_test/ (Android), or pass its directory '
        'as --dart-define=IOS_TEST_DOCS_DIR on the iOS Simulator',
  );
  await FlutterEdgeAi.installModel(
    modelType: modelType,
    fileType: ModelFileType.litertlm,
  ).fromFile(path!).install();
  return FlutterEdgeAi.getActiveModel(
    maxTokens: maxTokens,
    preferredBackend: PreferredBackend.values.byName(_backendName),
  );
}

/// One user question through [InferenceChat.generateChatResponseWithTools],
/// answering every call with [answer].
Future<({List<FunctionCallResponse> calls, String text, bool capped})> _round(
  InferenceChat chat,
  String question,
  Map<String, dynamic> Function(FunctionCallResponse call) answer,
) async {
  await chat.addQueryChunk(Message(text: question, isUser: true));
  final calls = <FunctionCallResponse>[];
  final text = StringBuffer();
  var capped = false;
  await for (final r in chat.generateChatResponseWithTools(
    onToolCall: (call) async {
      calls.add(call);
      return answer(call);
    },
    maxToolTurns: 4,
    onMaxToolTurns: () => capped = true,
  )) {
    if (r is TextResponse) text.write(r.token);
  }
  return (calls: calls, text: text.toString(), capped: capped);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FunctionGemma: calls multiply, then reads the result back', (
    tester,
  ) async {
    final model = await _load(
      'functiongemma-270M-it.litertlm',
      ModelType.functionGemma,
    );
    try {
      final chat = await model.createChat(
        topK: 1,
        tools: _codelabTools,
        supportsFunctionCalls: true,
        modelType: ModelType.functionGemma,
      );
      // Not the codelab's "what is 1234 times 5678?": with these declarations
      // the base 270M model calls get_device_info for that one, on bare
      // LiteRT-LM exactly as here, and adding `required: []` to the no-argument
      // tools fixes it only by breaking a different question. This one calls
      // multiply either way, so it tests the tool path, not the model's luck.
      final round = await _round(
        chat,
        'how much is 12 times 12?',
        (_) => {'result': 144},
      );

      expect(
        round.capped,
        isFalse,
        reason: 'the model answered its tool result by calling again',
      );
      expect(round.calls, hasLength(1));
      expect(round.calls.single.name, 'multiply');
      expect(round.calls.single.args, {'a': 12, 'b': 12});
      expect(round.text, contains('144'));
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('FunctionGemma: the example app flow, call then tool response', (
    tester,
  ) async {
    final model = await _load(
      'functiongemma-270M-it.litertlm',
      ModelType.functionGemma,
    );
    try {
      final chat = await model.createChat(
        topK: 1,
        tools: _exampleTools,
        supportsFunctionCalls: true,
        modelType: ModelType.functionGemma,
      );
      // lib/chat_screen.dart: generate, run the tool, add its response, generate.
      await chat.addQuery(
        const Message(
          text: 'Change the background color to blue',
          isUser: true,
        ),
      );
      final first = await chat.generateChatResponse();
      expect(first, isA<FunctionCallResponse>());
      final call = first as FunctionCallResponse;
      expect(call.name, 'change_background_color');
      expect(call.args, {'color': 'blue'});

      await chat.addQuery(
        Message.toolResponse(
          toolName: call.name,
          response: {
            'status': 'success',
            'message': 'Background color changed to blue',
          },
        ),
      );
      final second = await chat.generateChatResponse();
      expect(
        second,
        isA<TextResponse>(),
        reason: 'the model called again instead of answering: $second',
      );
      expect((second as TextResponse).token.toLowerCase(), contains('blue'));
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('Mobile Actions (Google fine-tune): event, then confirmation', (
    tester,
  ) async {
    final model = await _load(
      'mobile_actions_q8_ekv1024.litertlm',
      ModelType.functionGemma,
    );
    try {
      final chat = await model.createChat(
        topK: 1,
        tools: _mobileActionsTools,
        supportsFunctionCalls: true,
        modelType: ModelType.functionGemma,
        systemInstruction: _mobileActionsSystem,
      );
      final round = await _round(
        chat,
        'Please set a reminder for a "Team Sync Meeting" this Friday, June 6th, '
        '2025, at 2 PM.',
        (_) => {'status': 'success'},
      );

      expect(round.capped, isFalse);
      expect(round.calls, hasLength(1));
      expect(round.calls.single.name, 'create_calendar_event');
      expect(round.calls.single.args, {
        'datetime': '2025-06-06T14:00:00',
        'title': 'Team Sync Meeting',
      });
      expect(round.text, contains('Team Sync Meeting'));
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('Tiny Garden (Google fine-tune): one call per command', (
    tester,
  ) async {
    final model = await _load('tiny_garden.litertlm', ModelType.functionGemma);
    try {
      // The bundle declares a function-call-only constraint: it answers with
      // calls and nothing else, so there is no text to wait for — only no
      // repeated call.
      final chat = await model.createChat(
        topK: 1,
        tools: _tinyGardenTools,
        supportsFunctionCalls: true,
        modelType: ModelType.functionGemma,
        systemInstruction: _tinyGardenSystem,
      );
      final round = await _round(
        chat,
        'Plant sunflowers in the top row',
        (call) => {'result': 'success', ...call.args},
      );

      expect(round.capped, isFalse);
      expect(round.calls, hasLength(1));
      expect(round.calls.single.name, 'plant_seed');
      expect(round.calls.single.args, {
        'seed': 'sunflower',
        'plots': [1, 2, 3],
      });
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('Gemma 4: calls multiply, then reads the result back', (
    tester,
  ) async {
    final model = await _load(
      'gemma-4-E2B-it.litertlm',
      ModelType.gemma4,
      maxTokens: 2048,
    );
    try {
      final chat = await model.createChat(
        topK: 1,
        tools: _codelabTools,
        supportsFunctionCalls: true,
        modelType: ModelType.gemma4,
      );
      final round = await _round(
        chat,
        'What is 1234 times 5678? Use your tools.',
        (_) => {'result': 7006652},
      );

      expect(round.capped, isFalse);
      expect(round.calls, hasLength(1));
      expect(round.calls.single.name, 'multiply');
      expect(round.calls.single.args, {'a': 1234, 'b': 5678});
      expect(round.text.replaceAll(',', ''), contains('7006652'));
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('Gemma 4: a tool round survives a session switch (openSession)', (
    tester,
  ) async {
    final model = await _load(
      'gemma-4-E2B-it.litertlm',
      ModelType.gemma4,
      maxTokens: 2048,
    );
    try {
      final a = await model.openSession(topK: 1, tools: _codelabTools);
      final b = await model.openSession(topK: 1);

      await a.addQueryChunk(
        const Message(
          text: 'What is 1234 times 5678? Use your tools.',
          isUser: true,
        ),
      );
      await a.getResponse();
      final calls = SdkResponseParser.extractToolCalls(
        (a as RawSdkResponseSession).lastRawResponse ?? '',
      );
      expect(calls.single.name, 'multiply');
      await a.addQueryChunk(
        Message.toolResponse(
          toolName: 'multiply',
          response: {'result': 7006652},
        ),
      );
      final answer = await a.getResponse();
      expect(answer.replaceAll(',', ''), contains('7006652'));

      // The engine holds one live conversation, so B's turn takes it over and
      // A's next turn has to rebuild A from its recorded history — the
      // assistant tool_calls and the role-tool result included.
      await b.addQueryChunk(const Message(text: 'Say hello.', isUser: true));
      await b.getResponse();

      await a.addQueryChunk(
        const Message(
          text: 'Repeat the product you just told me, digits only.',
          isUser: true,
        ),
      );
      final recalled = await a.getResponse();
      expect(recalled.replaceAll(RegExp(r'[^0-9]'), ''), contains('7006652'));

      await a.close();
      await b.close();
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
