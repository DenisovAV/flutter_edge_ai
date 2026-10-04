// File-less `fromHuggingFace(repo)` — resolve the manifest, install the
// revision-pinned variant, and GENERATE, on real hardware.
//
// Why this file exists: `fromHuggingFace` shipped in 1.7.0 with unit coverage
// only (`from_hugging_face_test.dart`, the manifest resolver suites) plus an
// arm64 EMULATOR pass in #489. Nothing has ever driven the file-less path to an
// actual token on a physical device, which is exactly what
// https://github.com/DenisovAV/flutter_edge_ai/issues/454 asks for.
//
// Model: litert-community/LFM2.5-230M — the smallest entry in the shipped
// catalogue (int4 ≈ 177 MB), chosen so the same test is affordable to run on
// four platforms rather than one.
//
// Run:
//   macOS    flutter test integration_test/hf_fileless_install_device_test.dart -d macos
//   Linux    xvfb-run -a flutter test integration_test/hf_fileless_install_device_test.dart -d linux
//   Windows  flutter test integration_test/hf_fileless_install_device_test.dart -d windows
//   Android  physical device by id, or FTL (see tool/ftl notes) — NOT an emulator,
//            an emulator answers a different question than the one being asked.
//
// The test PRINTS the line the issue asked for:
//   model / device+OS / versions / backend / works or first adjustment
// so the answer posted upstream is a transcript, not a recollection.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _repo = 'litert-community/LFM2.5-230M';
const _hfToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

String get _platform {
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isWindows) return 'Windows';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  return 'unknown';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fromHuggingFace(repo) installs and generates on device', (
    tester,
  ) async {
    // Everything that can throw is inside the test body, never in setUp: under
    // some runners a throwing setUp is reported as a pass because the result is
    // only written from inside the test.
    await registerTestEngines();

    final sw = Stopwatch()..start();

    // The path under test: no `file:`, so the registered resolver fetches the
    // manifest and picks the revision-pinned variant itself.
    final install =
        await FlutterEdgeAi.installModel(
              modelType: ModelType.general,
              fileType: ModelFileType.litertlm,
            )
            .fromHuggingFace(_repo, token: _hfToken.isEmpty ? null : _hfToken)
            .install();

    final installMs = sw.elapsedMilliseconds;
    expect(
      install.runtime,
      isNotNull,
      reason:
          'the file-less path must return the manifest runtime defaults; null '
          'means the resolver did not run and this test proved nothing',
    );

    final defaults = install.runtime!;
    // `defaults:` is the whole point of the one-call path — applying them is
    // what the issue means by "did it need a manual override".
    final model = await FlutterEdgeAi.getActiveModel(defaults: defaults);

    try {
      final session = await model.createSession();
      String response;
      try {
        await session.addQueryChunk(
          const Message(text: 'Say hello in one word.', isUser: true),
        );
        response = await session.getResponse();
      } finally {
        await session.close();
      }

      expect(
        response.trim(),
        isNotEmpty,
        reason: 'installed and loaded, but generated nothing',
      );

      // ignore: avoid_print
      print(
        '\n[HF-FILELESS] $_repo / $_platform ${Platform.operatingSystemVersion} / '
        'flutter_gemma 1.7.3 + litertlm 1.6.3 / '
        'backend=${model.activeBackend} (manifest default '
        '${defaults.preferredBackend}) / maxTokens=${defaults.maxTokens} / '
        'install ${installMs}ms / OK, no manual override\n'
        '[HF-FILELESS] reply: "${response.trim()}"\n',
      );
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
