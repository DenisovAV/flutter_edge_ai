/// litertlm_dart's automatic tool calling on the real `@litert-lm/core`
/// (litertlm_dart's `liteRtLmWebRuntimeVersion`) with Gemma 4 E2B's GPU
/// export: what the runtime keeps of an automatic round, measured through its
/// own `getHistory()`, and how a stop in a round after the tools ran is
/// rebuilt. Recorded, never asserted, except that the probe ran (Rule 6b):
/// - the reply of a message whose tool ran automatically, and the tool's
///   calls;
/// - `getHistory()` after that turn: does it keep the assistant `tool_calls`
///   and the `tool` message;
/// - a second message stopped (`cancel()`) at its first text after the tools
///   ran, and the next message: the preface the rebuilt runtime conversation
///   was created with, and its reply.
///
/// Run from packages/flutter_edge_ai/example (one GPU workload at a time):
///   chromedriver --port=4444 &
///   flutter drive --driver=test_driver/web_embeddings_driver.dart \
///     --target=integration_test/web_auto_tools_probe_test.dart \
///     -d web-server --browser-name=chrome \
///     --dart-define=LLM_MODEL_URL=http://<host>/gemma-4-E2B-it-gpu.litertlm
/// The record is build/web_auto_tools_probe_response.json.
@TestOn('chrome')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:litertlm_dart/internal.dart' show liteRtLmWebRuntime;
import 'package:litertlm_dart/litertlm_dart.dart';

import 'web_embeddings_support.dart';

const _modelUrl = String.fromEnvironment(
  'LLM_MODEL_URL',
  defaultValue:
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
      'resolve/cccc664ea93091c52eeb7867ad4e5466357e14f3/'
      'gemma-4-E2B-it-gpu.litertlm',
);

// Wraps the runtime's Engine.create so the page keeps every runtime
// conversation litertlm_dart creates and the options it created it with.
const _capture = r'''
window.__autoToolsInstall = async () => {
  await window.litertLmReady;
  const p = window.__autoTools = {conversations: [], options: []};
  const create = window.Engine.create;
  window.Engine.create = async (...args) => {
    const engine = await create(...args);
    const createConversation = engine.createConversation.bind(engine);
    engine.createConversation = async (options) => {
      p.options.push(JSON.stringify(options || null));
      const c = await createConversation(options);
      p.conversations.push(c);
      return c;
    };
    return engine;
  };
};
window.__autoToolsHistory = async () => {
  const c = window.__autoTools.conversations.at(-1);
  return JSON.stringify(await c.getHistory(), (k, v) =>
      v && v.bytes ? `<${v.bytes.length} bytes>` : v);
};
''';

Future<String> _history() => globalContext
    .callMethod<JSPromise<JSString>>('__autoToolsHistory'.toJS)
    .toDart
    .then((s) => s.toDart);

List<String> _options() =>
    ((globalContext['__autoTools']! as JSObject)['options']! as JSArray).toDart
        .map((o) => (o! as JSString).toDart)
        .toList();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reportTo('web_auto_tools_probe_response');

  testWidgets('$liteRtLmWebRuntime: automatic tool calling with Gemma 4 E2B', (
    tester,
  ) async {
    report('runtime', liteRtLmWebRuntime);
    final steps = <String>[];
    await tester.runAsync(() async {
      try {
        await _probe(steps);
      } catch (e, st) {
        report('error', '$e\n$st');
      }
    });
    report('steps', steps);
    // ignore: avoid_print
    print(
      'AUTO_TOOLS ${jsonEncode(IntegrationTestWidgetsFlutterBinding.instance.reportData)}',
    );
    expect(steps, ['first', 'stopped', 'next']);
  });
}

Future<void> _probe(List<String> steps) async {
  globalContext.callMethod('eval'.toJS, _capture.toJS);
  await globalContext.callMethod<JSPromise>('__autoToolsInstall'.toJS).toDart;
  final engine = await Engine.create(
    EngineConfig(modelPath: _modelUrl, backend: const Backend.gpu()),
  );
  try {
    final calls = <String>[];
    final conversation = await engine.createConversation(
      ConversationConfig(
        tools: [
          Tool(
            name: 'get_weather',
            description: 'Get the current weather for a city.',
            parameters: const {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
              'required': ['city'],
            },
            execute: (a) {
              calls.add(jsonEncode(a));
              return {
                'city': a['city'],
                'temperature': 18,
                'condition': 'rain',
              };
            },
          ),
        ],
      ),
    );
    final first = await conversation.sendMessage(
      Message.user("What's the weather in Paris?"),
    );
    report('first_calls', [...calls]);
    report('first_reply', first.text);
    report('history_after_first', await _history());
    steps.add('first');

    final before = calls.length;
    final stopped = StringBuffer();
    await for (final piece in conversation.sendMessageStream(
      Message.user('And in Rome?'),
    )) {
      stopped.write(piece.text);
      if (calls.length > before && piece.text.isNotEmpty) {
        conversation.cancel();
      }
    }
    report('stopped_calls', calls.sublist(before));
    report('stopped_reply', stopped.toString());
    steps.add('stopped');

    final next = await conversation.sendMessage(
      Message.user('Thanks. Which cities did you look up?'),
    );
    report('next_reply', next.text);
    report('runtime_conversation_options', _options());
    report('history_after_next', await _history());
    steps.add('next');
    await conversation.close();
  } finally {
    await engine.close();
  }
}
