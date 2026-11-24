// One prompt to a `.litertlm` model on the CPU, the reply streamed to stdout,
// from a plain Dart program:
//
//   dart run bin/litertlm_chat.dart <model.litertlm> [prompt]
//
// or as a bundle that runs on a machine without the Dart SDK:
//
//   dart build cli
//   build/cli/<os>_<arch>/bundle/bin/litertlm_chat <model.litertlm> [prompt]
//
// litertlm_dart's build hook bundles libLiteRtLm; on macOS this package's
// pubspec.yaml sets the `macos_companions: code_assets` define it needs.
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: litertlm_chat <model.litertlm> [prompt]\n'
      'e.g. gemma-4-E2B-it.litertlm from '
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm',
    );
    exitCode = 64;
    return;
  }
  final prompt = args.length > 1
      ? args.skip(1).join(' ')
      : 'What is the capital of France? Answer in one sentence.';

  // A plain Dart program runs LiteRT-LM on the CPU only in this release.
  final engine = await Engine.create(
    EngineConfig(modelPath: args.first, backend: const Backend.cpu()),
  );
  try {
    final conversation = await engine.createConversation();
    try {
      await for (final piece in conversation.sendMessageStream(
        Message.user(prompt),
      )) {
        stdout.write(piece.text);
      }
      stdout.writeln();
    } finally {
      await conversation.close();
    }
  } finally {
    await engine.close();
  }
}
