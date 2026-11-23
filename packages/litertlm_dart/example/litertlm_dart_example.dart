// Loads a `.litertlm` model and streams a reply, the same code natively and
// on the web.
//
// Natively: `dart run example/litertlm_dart_example.dart <model.litertlm>`
// inside a Flutter app (see the README's "Where it runs today"); the build
// hook bundles libLiteRtLm.
//
// On the web: compile it into a page whose index.html loads @litert-lm/core
// 0.18.0 (the README's "On the web"), with the model's web export as a URL
// the page can fetch, e.g. gemma-4-E2B-it-web.litertlm.
import 'package:litertlm_dart/litertlm_dart.dart';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args.first
      : 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
            'resolve/main/gemma-4-E2B-it-web.litertlm';
  final engine = await Engine.create(
    EngineConfig(modelPath: modelPath, backend: const Backend.gpu()),
  );
  try {
    final conversation = await engine.createConversation(
      ConversationConfig(
        systemInstruction: 'Answer in one sentence.',
        samplerConfig: SamplerConfig(topK: 40, topP: 0.95, temperature: 0.8),
      ),
    );
    final reply = StringBuffer();
    await for (final piece in conversation.sendMessageStream(
      Message.user('What is the capital of France?'),
    )) {
      reply.write(piece.text);
    }
    print(reply);
    await conversation.close();
  } finally {
    await engine.close();
  }
}
