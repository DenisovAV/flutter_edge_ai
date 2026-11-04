// Which open sessions are native conversations (core 2.6.0 design §1.1): only
// where several live conversations on one engine were verified, virtual (text
// replay, no media) everywhere else; and what the model does with each.
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

const _abis = [
  'macos_arm64',
  'ios_arm64',
  'android_arm64',
  'linux_x64',
  'linux_arm64',
  'windows_x64',
  'windows_arm64',
];

void main() {
  group('liteRtLmOpenSessionBacking', () {
    OpenSessionBacking backing(
      String abi,
      PreferredBackend? backend, {
      NpuStack? npu,
      AndroidGpuFamily? gpu,
    }) => liteRtLmOpenSessionBacking(
      abi: abi,
      backend: backend,
      npuVendor: npu,
      androidGpu: gpu,
    );

    test('CPU: native on the four desktop hosts the probe ran, virtual on '
        'Android and iOS', () {
      final native = {
        for (final abi in _abis)
          if (backing(abi, PreferredBackend.cpu) == OpenSessionBacking.native)
            abi,
      };
      expect(native, {
        'macos_arm64',
        'linux_x64',
        'linux_arm64',
        'windows_x64',
      });
    });

    test('GPU: Metal on macOS, Linux x86_64 and Windows x86_64; not iOS, not '
        'Linux arm64', () {
      final native = {
        for (final abi in _abis)
          if (abi != 'android_arm64' &&
              backing(abi, PreferredBackend.gpu) == OpenSessionBacking.native)
            abi,
      };
      expect(native, {'macos_arm64', 'linux_x64', 'windows_x64'});
    });

    test('Android GPU: Adreno and Mali only; any other family or an unread '
        'one is virtual', () {
      expect(
        backing(
          'android_arm64',
          PreferredBackend.gpu,
          gpu: AndroidGpuFamily.adreno,
        ),
        OpenSessionBacking.native,
      );
      expect(
        backing(
          'android_arm64',
          PreferredBackend.gpu,
          gpu: AndroidGpuFamily.mali,
        ),
        OpenSessionBacking.native,
      );
      expect(
        backing(
          'android_arm64',
          PreferredBackend.gpu,
          gpu: AndroidGpuFamily.other,
        ),
        OpenSessionBacking.virtual,
      );
      expect(
        backing('android_arm64', PreferredBackend.gpu),
        OpenSessionBacking.virtual,
      );
    });

    test('NPU: Qualcomm and Tensor on Android, Intel on Windows; Qualcomm on '
        'Linux arm64, MediaTek and an unknown vendor are virtual', () {
      final native = <(NpuStack, String)>{
        for (final npu in NpuStack.values)
          for (final abi in _abis)
            if (backing(abi, PreferredBackend.npu, npu: npu) ==
                OpenSessionBacking.native)
              (npu, abi),
      };
      expect(native, {
        (NpuStack.qualcomm, 'android_arm64'),
        (NpuStack.googleTensor, 'android_arm64'),
        (NpuStack.intel, 'windows_x64'),
      });
      expect(
        backing('android_arm64', PreferredBackend.npu),
        OpenSessionBacking.virtual,
      );
    });

    test('an unknown backend is virtual', () {
      for (final abi in _abis) {
        expect(backing(abi, null), OpenSessionBacking.virtual, reason: abi);
      }
    });
  });

  group('FfiInferenceModel.openSession', () {
    FfiInferenceModel model(OpenSessionBacking backing, {int? cap}) =>
        FfiInferenceModel(
          // Uninitialized: any native call it is asked for fails.
          ffiClient: LiteRtLmFfiClient(),
          maxTokens: 1024,
          modelType: ModelType.gemmaIt,
          activeBackend: PreferredBackend.cpu,
          supportImage: true,
          maxConcurrentSessions: cap,
          openSessionBacking: backing,
          onClose: () {},
        );

    test('virtual: opens without a native call and refuses an image at the '
        'send', () async {
      final m = model(OpenSessionBacking.virtual);
      final session = await m.openSession();
      await session.addQueryChunk(
        Message(
          text: 'What is this?',
          isUser: true,
          imageBytes: Uint8List.fromList([1, 2, 3]),
        ),
      );
      await expectLater(session.getResponse(), throwsUnsupportedError);
      await session.close();
    });

    /// The uninitialized client's refusal: the open reached the engine.
    final reachedEngine = throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('Engine not initialized'),
      ),
    );

    test('native: each session asks the engine for its own conversation at '
        'open', () async {
      final m = model(OpenSessionBacking.native);
      await expectLater(m.openSession(), reachedEngine);
      expect(m.sessions, isEmpty, reason: 'a failed open adds no session');
    });

    test('native: a failed open frees its place under the cap', () async {
      final m = model(OpenSessionBacking.native, cap: 1);
      await expectLater(m.openSession(), reachedEngine);
      // Still one free place: the second open fails at the engine again,
      // not at the cap.
      await expectLater(m.openSession(), reachedEngine);
    });

    test('native: opens running at once share the cap', () async {
      final m = model(OpenSessionBacking.native, cap: 1);
      final a = expectLater(m.openSession(), reachedEngine);
      final b = expectLater(
        m.openSession(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Max concurrent sessions (1)'),
          ),
        ),
      );
      await a;
      await b;
    });
  });

  test('conversations rewind on the CPU and GPU, never on the NPU or a model '
      'with linear attention state', () {
    String? reason(PreferredBackend? backend, {bool linear = false}) =>
        FfiInferenceModel(
          ffiClient: LiteRtLmFfiClient(),
          maxTokens: 1024,
          modelType: ModelType.gemmaIt,
          activeBackend: backend,
          linearAttentionState: linear,
          onClose: () {},
        ).noRewindReason;
    expect(reason(PreferredBackend.cpu), isNull);
    expect(reason(PreferredBackend.gpu), isNull);
    expect(reason(PreferredBackend.npu), contains('NPU'));
    expect(reason(PreferredBackend.cpu, linear: true), contains('linear'));
    expect(reason(PreferredBackend.gpu, linear: true), contains('linear'));
  });
}
