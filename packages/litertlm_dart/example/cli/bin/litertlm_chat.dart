// One prompt to a `.litertlm` model, the reply streamed to stdout, from a
// plain Dart program:
//
//   dart run bin/litertlm_chat.dart [--backend cpu|gpu|npu] <model.litertlm> [prompt]
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

const _usage =
    'usage: litertlm_chat [--backend cpu|gpu|npu] <model.litertlm> [prompt]\n'
    'e.g. gemma-4-E2B-it.litertlm from '
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm';

Future<void> main(List<String> arguments) async {
  final args = [...arguments];
  var backend = const Backend.cpu();
  final flag = args.indexOf('--backend');
  if (flag >= 0) {
    final chosen = switch (flag + 1 < args.length ? args[flag + 1] : null) {
      'cpu' => const Backend.cpu(),
      'gpu' => const Backend.gpu(),
      'npu' => Backend.npu(),
      _ => null,
    };
    if (chosen == null) {
      stderr.writeln(_usage);
      exitCode = 64;
      return;
    }
    backend = chosen;
    args.removeRange(flag, flag + 2);
  }
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  final prompt = args.length > 1
      ? args.skip(1).join(' ')
      : 'What is the capital of France? Answer in one sentence.';

  // A backend that cannot run here fails by name; it is never moved to
  // another one.
  final engine = await Engine.create(
    EngineConfig(modelPath: args.first, backend: backend),
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
