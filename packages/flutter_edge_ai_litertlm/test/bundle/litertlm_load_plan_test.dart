import 'package:flutter_edge_ai/engine.dart' show PreferredBackend;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/bundle/litertlm_load_plan.dart';
import 'package:flutter_test/flutter_test.dart';

const npu = PreferredBackend.npu;
const gpu = PreferredBackend.gpu;
const cpu = PreferredBackend.cpu;
const sm8750 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750');

/// A Gemma 4-shaped bundle: text model, vision and audio encoders, optionally
/// a `tf_lite_aux` section. [text], [vision] and [audio] are each a
/// `backend_constraint` and the NPU the section is compiled for.
LiteRtLmBundleInfo bundle({
  (String?, LiteRtLmNpuTarget?) text = (null, null),
  (String?, LiteRtLmNpuTarget?) vision = (null, null),
  (String?, LiteRtLmNpuTarget?) audio = (null, null),
  bool aux = false,
  int? fileLength,
}) {
  var at = 0;
  LiteRtLmSection section(
    String modelType,
    (String?, LiteRtLmNpuTarget?) spec,
  ) {
    final (constraint, target) = spec;
    final begin = at;
    at += 100;
    return LiteRtLmSection(
      dataType: 'TFLiteModel',
      begin: begin,
      end: at,
      items: {'model_type': modelType, 'backend_constraint': ?constraint},
      npuTarget: target,
    );
  }

  final sections = [
    section('tf_lite_prefill_decode', text),
    section('tf_lite_vision_encoder', vision),
    section('tf_lite_audio_encoder_hw', audio),
    if (aux) section('tf_lite_aux', (null, null)),
  ];
  return LiteRtLmBundleInfo(
    majorVersion: 1,
    minorVersion: 5,
    patchVersion: 0,
    systemMetadata: const {},
    sections: sections,
    fileLength: fileLength ?? at,
  );
}

/// The official `…_qualcomm_sm8750`: text and aux compiled, encoders plain,
/// nothing declared (read from the published file).
final officialSm8750 = bundle(text: (null, sm8750), aux: true);

/// Google's all-NPU build: the encoders compiled too.
final allNpu = bundle(
  text: (null, sm8750),
  vision: (null, sm8750),
  audio: (null, sm8750),
  aux: true,
);

/// The generic GPU/CPU Gemma 4: the audio encoder declares cpu.
final generic = bundle(audio: ('cpu', null));

void main() {
  var npuAsked = 0;

  LiteRtLmLoadPlan plan({
    LiteRtLmBundleInfo? info,
    PreferredBackend? preferred,
    bool fallback = true,
    bool image = false,
    bool audio = false,
    PreferredBackend? visionBackend,
    PreferredBackend? audioBackend,
    bool npuHere = true,
    String abi = 'android_arm64',
  }) => planLiteRtLmLoad(
    path: 'model.litertlm',
    bundle: info,
    preferredBackend: preferred,
    backendFallback: fallback,
    supportImage: image,
    supportAudio: audio,
    preferredVisionBackend: visionBackend,
    preferredAudioBackend: audioBackend,
    npuAvailable: () {
      npuAsked++;
      return npuHere;
    },
    npuUnavailableReason: () => 'this device has no Qualcomm FastRPC',
    abi: abi,
  );

  setUp(() => npuAsked = 0);

  Matcher refused(LiteRtLmBundleProblem problem, [Pattern? says]) => throwsA(
    isA<LiteRtLmBundleException>()
        .having((e) => e.problem, 'problem', problem)
        .having((e) => e.message, 'message', contains(says ?? '')),
  );

  Matcher npuUnreachable(Pattern says) => throwsA(
    isA<BackendInitException>()
        .having((e) => e.attempts.length, 'attempts', 1)
        .having((e) => e.lastAttempt.backend, 'backend', npu)
        .having(
          (e) => e.lastAttempt.error,
          'error',
          isA<NpuDispatchUnavailableException>().having(
            (e) => e.message,
            'message',
            contains(says),
          ),
        ),
  );

  group('a generic bundle (or one the reader could not read)', () {
    for (final info in [generic, null]) {
      final name = info == null ? 'unread' : 'generic';

      test('$name: the fallback order as before', () {
        expect(plan(info: info).textBackends, [gpu, cpu]);
        expect(plan(info: info, preferred: npu).textBackends, [npu, gpu, cpu]);
        expect(plan(info: info, preferred: gpu).textBackends, [gpu, cpu]);
        expect(plan(info: info, preferred: cpu).textBackends, [cpu]);
      });

      test('$name, strict: exactly one attempt, the GPU when none asked', () {
        expect(plan(info: info, fallback: false).textBackends, [gpu]);
        for (final backend in PreferredBackend.values) {
          expect(
            plan(info: info, preferred: backend, fallback: false).textBackends,
            [backend],
          );
        }
      });
    }

    test('an NPU this device cannot reach is dropped with a fallback', () {
      expect(plan(info: generic, preferred: npu, npuHere: false).textBackends, [
        gpu,
        cpu,
      ]);
    });

    test('and refused at once without one: no engine is created', () {
      expect(
        () => plan(
          info: generic,
          preferred: npu,
          fallback: false,
          npuHere: false,
        ),
        npuUnreachable('no Qualcomm FastRPC'),
      );
    });

    test('the NPU is asked about only when it is one of the backends', () {
      plan(info: generic);
      plan(info: generic, preferred: gpu);
      plan(info: generic, preferred: cpu);
      expect(npuAsked, 0);
      plan(info: generic, preferred: npu);
      expect(npuAsked, 1);
    });
  });

  group('a text model that declares its backends', () {
    final cpuOnly = bundle(text: ('cpu', null));

    test('the fallback order keeps only what it declares', () {
      expect(plan(info: cpuOnly).textBackends, [cpu]);
      expect(plan(info: cpuOnly, preferred: gpu).textBackends, [cpu]);
      expect(
        plan(
          info: bundle(text: ('gpu,cpu', null)),
          preferred: npu,
        ).textBackends,
        [gpu, cpu],
      );
    });

    test('strict: another backend is refused, naming the declared ones', () {
      expect(
        () => plan(info: cpuOnly, preferred: gpu, fallback: false),
        refused(LiteRtLmBundleProblem.wrongBackend, 'runs on cpu'),
      );
      expect(plan(info: cpuOnly, fallback: false).textBackends, [cpu]);
    });
  });

  group('a bundle compiled for an NPU', () {
    test('runs on the NPU, also when no backend is given', () {
      expect(plan(info: officialSm8750).textBackends, [npu]);
      expect(plan(info: officialSm8750, preferred: npu).textBackends, [npu]);
      expect(plan(info: officialSm8750, fallback: false).textBackends, [npu]);
    });

    test('a tf_lite_aux section alone is enough', () {
      expect(plan(info: bundle(aux: true)).textBackends, [npu]);
    });

    test('the GPU or the CPU is refused before any engine, with or without '
        'a fallback', () {
      for (final fallback in [true, false]) {
        for (final backend in [gpu, cpu]) {
          expect(
            () => plan(
              info: officialSm8750,
              preferred: backend,
              fallback: fallback,
            ),
            refused(
              LiteRtLmBundleProblem.wrongBackend,
              'compiled for the Qualcomm SM8750 NPU and runs only there, '
              'not on ${backend.name}',
            ),
          );
        }
      }
      expect(npuAsked, 0);
    });

    test('an unreachable NPU is refused, never tried on the GPU', () {
      expect(
        () => plan(info: officialSm8750, npuHere: false),
        npuUnreachable(
          'compiled for the Qualcomm SM8750 NPU and runs only there, and this '
          'device has no Qualcomm FastRPC',
        ),
      );
    });

    test('an NPU this package has no dispatch for is refused', () {
      final tensor = bundle(
        text: (
          null,
          const LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
        ),
        aux: true,
      );
      expect(
        () => plan(info: tensor),
        refused(LiteRtLmBundleProblem.unsupportedNpu, 'Qualcomm and Intel'),
      );
      expect(
        () => plan(info: officialSm8750, abi: 'windows_x64'),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          'android_arm64 and linux_arm64 only, and this is windows_x64',
        ),
      );
      final intel = bundle(
        text: (
          null,
          const LiteRtLmNpuTarget(vendor: 'IntelOpenVINO', soc: 'PTL'),
        ),
      );
      expect(plan(info: intel, abi: 'windows_x64').textBackends, [npu]);
      expect(plan(info: officialSm8750, abi: 'linux_arm64').textBackends, [
        npu,
      ]);
    });
  });

  group('encoders', () {
    test('the official SM8750: plain encoders run on the CPU', () {
      final p = plan(info: officialSm8750, image: true, audio: true);
      expect((p.visionBackend, p.audioBackend), (cpu, cpu));
    });

    test("Google's all-NPU build: compiled encoders run on the NPU", () {
      final p = plan(info: allNpu, image: true, audio: true);
      expect((p.visionBackend, p.audioBackend), (npu, npu));
    });

    test('the generic Gemma 4: CPU, as before', () {
      final p = plan(info: generic, image: true, audio: true);
      expect((p.visionBackend, p.audioBackend), (cpu, cpu));
      expect(plan(image: true, audio: true).visionBackend, cpu);
    });

    test('a declared constraint decides: the CPU when it allows it', () {
      expect(
        plan(info: bundle(vision: ('gpu', null)), image: true).visionBackend,
        gpu,
      );
      expect(
        plan(
          info: bundle(vision: ('gpu,cpu', null)),
          image: true,
        ).visionBackend,
        cpu,
      );
    });

    test('an encoder that is off has no backend', () {
      final p = plan(info: allNpu, visionBackend: cpu);
      expect((p.visionBackend, p.audioBackend), (null, null));
    });

    test('an explicit backend is kept', () {
      expect(
        plan(info: generic, image: true, visionBackend: gpu).visionBackend,
        gpu,
      );
      expect(
        plan(info: allNpu, audio: true, audioBackend: npu).audioBackend,
        npu,
      );
    });

    test('the NPU for a plain encoder is refused', () {
      expect(
        () => plan(info: officialSm8750, image: true, visionBackend: npu),
        refused(
          LiteRtLmBundleProblem.wrongBackend,
          "vision encoder is not compiled for an NPU",
        ),
      );
    });

    test('another backend for a compiled encoder is refused', () {
      expect(
        () => plan(info: allNpu, audio: true, audioBackend: cpu),
        refused(
          LiteRtLmBundleProblem.wrongBackend,
          'audio encoder is compiled for the Qualcomm SM8750 NPU and runs only '
          'there, not on cpu',
        ),
      );
    });
  });

  test('an incomplete file is refused before anything else', () {
    expect(
      () => plan(info: bundle(text: (null, sm8750), fileLength: 250)),
      refused(
        LiteRtLmBundleProblem.incomplete,
        'is 250 bytes, and its sections end at 300',
      ),
    );
    expect(npuAsked, 0);
  });
}
