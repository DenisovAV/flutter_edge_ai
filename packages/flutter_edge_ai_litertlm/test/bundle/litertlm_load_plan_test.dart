import 'package:flutter_edge_ai/engine.dart' show PreferredBackend;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/bundle/litertlm_load_plan.dart';
import 'package:flutter_test/flutter_test.dart';

const npu = PreferredBackend.npu;
const gpu = PreferredBackend.gpu;
const cpu = PreferredBackend.cpu;
const sm8750 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8750');

/// A Gemma 4-shaped bundle: text model, vision and audio encoders, optionally
/// a `tf_lite_aux` section ([aux], or [auxTarget] for one compiled for that
/// NPU). [text], [vision] and [audio] are each a `backend_constraint` and the
/// NPU the section is compiled for.
LiteRtLmBundleInfo bundle({
  (String?, LiteRtLmNpuTarget?) text = (null, null),
  (String?, LiteRtLmNpuTarget?) vision = (null, null),
  (String?, LiteRtLmNpuTarget?) audio = (null, null),
  bool aux = false,
  LiteRtLmNpuTarget? auxTarget,
  bool withEncoders = true,
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
    if (withEncoders) ...[
      section('tf_lite_vision_encoder', vision),
      section('tf_lite_audio_encoder_hw', audio),
    ],
    if (aux || auxTarget != null) section('tf_lite_aux', (null, auxTarget)),
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

/// Gemma 3n: the text model declares cpu,gpu, the vision encoder gpu, the
/// audio encoder cpu.
final gemma3n = bundle(
  text: ('cpu,gpu', null),
  vision: ('gpu', null),
  audio: ('cpu', null),
);

/// A text-only bundle (FunctionGemma): no encoder sections.
final textOnly = bundle(withEncoders: false);

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

  Matcher refusedWith(LiteRtLmBundleProblem problem, String message) => throwsA(
    isA<LiteRtLmBundleException>()
        .having((e) => e.problem, 'problem', problem)
        .having((e) => e.message, 'message', message),
  );

  /// Why a text model compiled for no NPU is not tried on one.
  const noNpuGraph =
      'model.litertlm is not compiled for an NPU (its text model carries no '
      'LiteRtStamp and there is no tf_lite_aux), so it cannot run on one: '
      'LiteRT would try to compile it on the device with a compiler plugin, '
      'which no NPU stack here ships, and run it on the CPU';

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
        expect(plan(info: info, preferred: gpu).textBackends, [gpu, cpu]);
        expect(plan(info: info, preferred: cpu).textBackends, [cpu]);
      });

      test('$name, strict: exactly one attempt, the GPU when none asked', () {
        expect(plan(info: info, fallback: false).textBackends, [gpu]);
        for (final backend in [gpu, cpu]) {
          expect(
            plan(info: info, preferred: backend, fallback: false).textBackends,
            [backend],
          );
        }
      });
    }

    test('generic: never the NPU, for it has no NPU graph — dropped with the '
        "file's reason, and nothing asked", () {
      // Measured 2026-10-18 on a DDP Galaxy S24: on npu LiteRT-LM compiled
      // nothing ("No compiler plugin found"), ran on the CPU and the engine
      // reported npu.
      final npuOnGeneric = plan(info: generic, preferred: npu);
      expect(npuOnGeneric.textBackends, [gpu, cpu]);
      expect(npuOnGeneric.dropped[npu], noNpuGraph);
      expect(npuAsked, 0, reason: 'not a candidate, so not unreachable');
    });

    test('generic, strict: npu is refused before any engine, naming what to '
        'install', () {
      expect(
        () => plan(info: generic, preferred: npu, fallback: false),
        refusedWith(
          LiteRtLmBundleProblem.wrongBackend,
          '$noNpuGraph. Load it with PreferredBackend.gpu or .cpu, or omit '
          'preferredBackend; to run on the NPU, install the bundle compiled '
          "for this device's NPU.",
        ),
      );
      expect(npuAsked, 0);
    });

    test('unread: the NPU stays a candidate, as before', () {
      expect(plan(info: null, preferred: npu).textBackends, [npu, gpu, cpu]);
      expect(plan(info: null, preferred: npu, fallback: false).textBackends, [
        npu,
      ]);
    });

    test('an NPU this device cannot reach is dropped with a fallback', () {
      expect(plan(info: null, preferred: npu, npuHere: false).textBackends, [
        gpu,
        cpu,
      ]);
    });

    test('and refused at once without one: no engine is created', () {
      expect(
        () => plan(info: null, preferred: npu, fallback: false, npuHere: false),
        npuUnreachable('no Qualcomm FastRPC'),
      );
    });

    test('the NPU is asked about only when it is one of the backends', () {
      plan(info: null);
      plan(info: null, preferred: gpu);
      plan(info: null, preferred: cpu);
      plan(info: generic, preferred: npu);
      expect(npuAsked, 0);
      plan(info: null, preferred: npu);
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

    test('a backend the file rules out is reported with the declared '
        'constraint, for the notice', () {
      final npuOn3n = plan(info: gemma3n, preferred: npu);
      expect(npuOn3n.textBackends, [gpu, cpu]);
      expect(npuOn3n.dropped.keys, [npu]);
      expect(
        npuOn3n.dropped[npu],
        'model.litertlm declares that its text model runs on cpu, gpu '
        '(backend_constraint)',
      );
      expect(
        npuAsked,
        0,
        reason: 'the NPU is not a candidate, not unreachable',
      );

      final gpuOnCpu = plan(info: cpuOnly, preferred: gpu);
      expect(gpuOnCpu.textBackends, [cpu]);
      expect(
        gpuOnCpu.dropped[gpu],
        contains('runs on cpu (backend_constraint)'),
      );
    });

    test('nothing is reported when nothing the caller asked for is ruled '
        'out', () {
      expect(plan(info: null, preferred: npu).dropped, isEmpty);
      expect(plan(info: cpuOnly).dropped, isEmpty);
      expect(
        plan(info: null, preferred: npu, npuHere: false).dropped,
        isEmpty,
        reason:
            'an unreachable NPU is the host\'s reason, worded by the caller',
      );
    });

    test(
      'a text model that declares only the NPU but is compiled for none '
      'has nothing to run on: refused for every request, the NPU not asked',
      () {
        // No published bundle has this shape (14 read 2026-10-18): each that
        // declares npu also carries a stamp and tf_lite_aux. On npu it would
        // take LiteRT-LM's compiler-plugin path, as a generic bundle does.
        final npuDeclared = bundle(text: ('npu', null));
        expect(npuDeclared.isCompiledForNpu, isFalse);
        final nothing = refusedWith(
          LiteRtLmBundleProblem.wrongBackend,
          'model.litertlm declares that its text model runs on npu '
          '(backend_constraint) but is not compiled for an NPU (its text model '
          'carries no LiteRtStamp and there is no tf_lite_aux), so no backend '
          'here can run it: on the NPU LiteRT would try to compile it on the '
          'device with a compiler plugin, which no NPU stack here ships, and run '
          "it on the CPU. Install the bundle compiled for this device's NPU.",
        );
        for (final preferred in [null, npu, gpu, cpu]) {
          for (final fallback in [true, false]) {
            expect(
              () => plan(
                info: npuDeclared,
                preferred: preferred,
                fallback: fallback,
              ),
              nothing,
              reason: '$preferred, fallback $fallback',
            );
          }
        }
        expect(
          () => liteRtLmTextCandidates(
            path: 'model.litertlm',
            bundle: npuDeclared,
            preferredBackend: null,
            backendFallback: true,
            abi: 'android_arm64',
          ),
          nothing,
        );
        expect(npuAsked, 0);
      },
    );

    test('one that declares the NPU and the CPU runs on the CPU, the NPU '
        'dropped for its missing NPU graph', () {
      final npuOrCpu = bundle(text: ('npu,cpu', null));
      expect(plan(info: npuOrCpu).textBackends, [cpu]);
      final onNpu = plan(info: npuOrCpu, preferred: npu);
      expect(onNpu.textBackends, [cpu]);
      expect(onNpu.dropped, {
        npu: noNpuGraph,
        gpu:
            'model.litertlm declares that its text model runs on npu, cpu '
            '(backend_constraint)',
      });
      expect(
        () => plan(info: npuOrCpu, preferred: npu, fallback: false),
        refusedWith(
          LiteRtLmBundleProblem.wrongBackend,
          '$noNpuGraph. Load it with PreferredBackend.cpu, or omit '
          'preferredBackend; to run on the NPU, install the bundle compiled '
          "for this device's NPU.",
        ),
      );
      expect(
        () => plan(info: npuOrCpu, preferred: gpu, fallback: false),
        refusedWith(
          LiteRtLmBundleProblem.wrongBackend,
          'model.litertlm declares that its text model runs on npu, cpu '
          '(backend_constraint), not on gpu. Load it with '
          'PreferredBackend.cpu, or omit preferredBackend.',
        ),
      );
      expect(npuAsked, 0);
    });

    test("liteRtLmTextCandidates is the plan's text order, which the engine "
        'reads to know whether to look for an NPU stack', () {
      List<PreferredBackend> candidates(
        LiteRtLmBundleInfo? info, [
        PreferredBackend? preferred,
      ]) => liteRtLmTextCandidates(
        path: 'model.litertlm',
        bundle: info,
        preferredBackend: preferred,
        backendFallback: true,
        abi: 'android_arm64',
      ).backends;
      expect(candidates(officialSm8750), [npu]);
      expect(candidates(generic), [gpu, cpu]);
      expect(candidates(generic, npu), [gpu, cpu]);
      expect(candidates(null, npu), [npu, gpu, cpu]);
      expect(candidates(null), [gpu, cpu]);
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

    test("the text model's NPU is its own stamp, else the tf_lite_aux "
        "section's", () {
      final auxOnly = bundle(auxTarget: sm8750);
      expect(plan(info: auxOnly).npuTarget, sm8750);
      expect(
        () => plan(info: auxOnly, abi: 'macos_arm64'),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          'model.litertlm is compiled for the Qualcomm SM8750 NPU, which runs '
          'on android_arm64 and linux_arm64 only, and this is macos_arm64',
        ),
      );
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
      final mediaTek = bundle(
        text: (
          null,
          const LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'MT6991'),
        ),
        aux: true,
      );
      expect(
        () => plan(info: mediaTek),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          'Qualcomm, Google Tensor and Intel',
        ),
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

    test(
      'sections compiled for different vendors are explicitly ambiguous',
      () {
        final tensorAudio = bundle(
          text: (null, sm8750),
          audio: (
            null,
            const LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G5'),
          ),
          aux: true,
        );
        expect(
          () => plan(info: tensorAudio, audio: true, npuHere: false),
          refused(
            LiteRtLmBundleProblem.malformed,
            'active sections compiled for different NPUs '
            '(Qualcomm SM8750, Google Tensor_G5); one load can expose only one '
            "vendor's dispatch, so the request is ambiguous",
          ),
        );
        expect(npuAsked, 0);
      },
    );
  });

  group('encoders', () {
    test('the official SM8750: plain encoders run on the CPU', () {
      final p = plan(info: officialSm8750, image: true, audio: true);
      expect((p.visionBackend, p.audioBackend), (cpu, cpu));
    });

    test("Google's all-NPU build: compiled encoders run on the NPU", () {
      final p = plan(info: allNpu, image: true, audio: true);
      expect((p.visionBackend, p.audioBackend), (npu, npu));
      expect(npuAsked, 1, reason: 'the NPU is asked about once per load');
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

    test("a backend the encoder's backend_constraint excludes is refused: "
        'audio', () {
      expect(
        () => plan(info: generic, audio: true, audioBackend: gpu),
        refused(
          LiteRtLmBundleProblem.wrongBackend,
          "model.litertlm's audio encoder declares that it runs on cpu "
          '(backend_constraint), not on gpu',
        ),
      );
      expect(npuAsked, 0);
    });

    test("a backend the encoder's backend_constraint excludes is refused: "
        'vision', () {
      expect(
        () => plan(info: gemma3n, image: true, visionBackend: cpu),
        refused(
          LiteRtLmBundleProblem.wrongBackend,
          "model.litertlm's vision encoder declares that it runs on gpu "
          '(backend_constraint), not on cpu',
        ),
      );
      expect(
        plan(
          info: bundle(vision: ('gpu,cpu', null)),
          image: true,
          visionBackend: gpu,
        ).visionBackend,
        gpu,
        reason: 'a backend the constraint names is kept',
      );
      expect(
        plan(info: gemma3n, audio: true, audioBackend: cpu).audioBackend,
        cpu,
      );
    });

    test('a bundle without the encoder reports no encoder backend; an unread '
        'file keeps the CPU', () {
      final p = plan(info: textOnly, image: true, audio: true);
      expect((p.visionBackend, p.audioBackend), (null, null));
      expect(
        plan(info: textOnly, image: true, visionBackend: gpu).visionBackend,
        isNull,
      );
      final unread = plan(image: true, audio: true, audioBackend: gpu);
      expect((unread.visionBackend, unread.audioBackend), (cpu, gpu));
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

  group('a generic text model with one encoder compiled for an NPU', () {
    // A generic text model with one encoder compiled for the SM8750: only that
    // encoder is NPU-only, so only a load that turns it on needs the NPU.
    final visionSm8750 = bundle(vision: (null, sm8750));
    final audioSm8750 = bundle(audio: (null, sm8750));

    test('a text-only load runs as on a generic bundle', () {
      for (final info in [visionSm8750, audioSm8750]) {
        expect(info.isCompiledForNpu, isFalse);
        final p = plan(info: info, abi: 'macos_arm64');
        expect(p.textBackends, [gpu, cpu]);
        expect((p.visionBackend, p.audioBackend), (null, null));
        expect(p.npuTarget, isNull, reason: 'no NPU section is on');
        expect(
          plan(info: info, preferred: cpu, abi: 'macos_arm64').textBackends,
          [cpu],
        );
        expect(
          liteRtLmTextCandidates(
            path: 'model.litertlm',
            bundle: info,
            preferredBackend: null,
            backendFallback: true,
            abi: 'macos_arm64',
          ).backends,
          [gpu, cpu],
          reason: 'the engine asks for the text candidates first',
        );
      }
      expect(
        plan(info: visionSm8750, audio: true, abi: 'macos_arm64').audioBackend,
        cpu,
        reason: 'the other, plain encoder is not affected',
      );
    });

    test('turning that encoder on is refused, naming its vendor and SoC', () {
      expect(
        () => plan(info: visionSm8750, image: true, abi: 'macos_arm64'),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          "model.litertlm's vision encoder is compiled for the Qualcomm SM8750 "
          'NPU, which runs on android_arm64 and linux_arm64 only, and this is '
          'macos_arm64; load it without supportImage, or install the generic '
          'bundle of this model to run it here.',
        ),
      );
      expect(
        () => plan(info: audioSm8750, audio: true, abi: 'windows_x64'),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          "model.litertlm's audio encoder is compiled for the Qualcomm SM8750 "
          'NPU, which runs on android_arm64 and linux_arm64 only, and this is '
          'windows_x64; load it without supportAudio',
        ),
      );
      for (final backend in PreferredBackend.values) {
        expect(
          () => plan(
            info: visionSm8750,
            image: true,
            visionBackend: backend,
            abi: 'macos_arm64',
          ),
          refused(LiteRtLmBundleProblem.unsupportedNpu, 'Qualcomm SM8750'),
          reason: 'the host cannot run it, whatever backend is asked',
        );
      }
      expect(npuAsked, 0);
    });

    test('a vendor this package has no dispatch for: the same, on every '
        'host', () {
      final mediaTekAudio = bundle(
        audio: (
          null,
          const LiteRtLmNpuTarget(vendor: 'MediaTek', soc: 'MT6991'),
        ),
      );
      expect(plan(info: mediaTekAudio).textBackends, [gpu, cpu]);
      expect(plan(info: mediaTekAudio, image: true).visionBackend, cpu);
      expect(
        () => plan(info: mediaTekAudio, audio: true),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          "model.litertlm's audio encoder is compiled for the MediaTek MT6991 "
          'NPU. flutter_edge_ai_litertlm runs Qualcomm, Google Tensor and Intel '
          'NPU bundles only; load it without supportAudio, or install',
        ),
      );
    });

    test('on a host that has the dispatch, turning it on is refused: an '
        'encoder runs on the NPU only with a text model on the NPU', () {
      expect(
        () => plan(info: visionSm8750, image: true),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          "model.litertlm's vision encoder is compiled for the Qualcomm SM8750 "
          'NPU and runs only there, and its text model would be tried on gpu, '
          'then cpu, not on the NPU alone. flutter_edge_ai_litertlm runs an '
          'encoder on the NPU only together with a text model on the NPU (a '
          'bundle compiled for the NPU throughout). Load it without '
          'supportImage to run the text model alone, or install the generic '
          'bundle of this model.',
        ),
      );
      expect(
        () => plan(info: audioSm8750, audio: true, abi: 'linux_arm64'),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          "model.litertlm's audio encoder is compiled for the Qualcomm SM8750 "
          'NPU and runs only there, and its text model would be tried on gpu, '
          'then cpu',
        ),
      );
      expect(
        () => plan(info: visionSm8750, image: true, preferred: npu),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          'would be tried on gpu, then cpu, not on the NPU alone',
        ),
        reason: 'a generic text model never runs on the NPU',
      );
      expect(
        () => plan(info: visionSm8750, image: true, visionBackend: npu),
        refused(LiteRtLmBundleProblem.unsupportedNpu, 'not on the NPU alone'),
      );
      expect(
        () => plan(info: bundle(vision: ('npu', null)), image: true),
        refused(
          LiteRtLmBundleProblem.unsupportedNpu,
          "model.litertlm's vision encoder runs only on the NPU, and its text "
          'model would be tried on gpu, then cpu',
        ),
        reason: 'an encoder that declares only the NPU, with no stamp',
      );
    });

    test('nor with the text model asked onto the NPU alone: a generic text '
        'model has no NPU graph, so it is refused for that', () {
      expect(
        () => plan(
          info: visionSm8750,
          image: true,
          preferred: npu,
          fallback: false,
        ),
        // Exact: its vision section does carry a stamp, so the reason has
        // to be about the text model.
        refusedWith(
          LiteRtLmBundleProblem.wrongBackend,
          '$noNpuGraph. Load it with PreferredBackend.gpu or .cpu, or omit '
          'preferredBackend; to run on the NPU, install the bundle compiled '
          "for this device's NPU.",
        ),
      );
    });

    test('an NPU this device cannot reach is refused with its reason, before '
        'any engine', () {
      expect(
        () => plan(info: visionSm8750, image: true, npuHere: false),
        npuUnreachable(
          "model.litertlm's vision encoder is compiled for the Qualcomm SM8750 "
          'NPU and runs only there, and this device has no Qualcomm FastRPC',
        ),
      );
      expect(npuAsked, 1);
      expect(
        () => plan(
          info: visionSm8750,
          image: true,
          preferred: npu,
          npuHere: false,
        ),
        npuUnreachable("vision encoder is compiled for the Qualcomm SM8750"),
        reason: 'the text model falls back from the NPU, the encoder cannot',
      );
    });

    test('the engine is told to look for the NPU stack only when an encoder '
        'that is on runs on the NPU', () {
      bool onNpu(
        LiteRtLmBundleInfo? info, {
        bool image = false,
        bool audio = false,
        PreferredBackend? visionBackend,
      }) => liteRtLmEncoderOnNpu(
        bundle: info,
        supportImage: image,
        supportAudio: audio,
        preferredVisionBackend: visionBackend,
      );
      expect(onNpu(visionSm8750, image: true), isTrue);
      expect(onNpu(audioSm8750, audio: true), isTrue);
      expect(onNpu(allNpu, image: true, audio: true), isTrue);
      expect(onNpu(visionSm8750), isFalse, reason: 'the encoder is off');
      expect(onNpu(visionSm8750, audio: true), isFalse);
      expect(onNpu(officialSm8750, image: true, audio: true), isFalse);
      expect(onNpu(generic, image: true, visionBackend: npu), isTrue);
      expect(
        onNpu(null, image: true, visionBackend: npu),
        isFalse,
        reason: 'a file that could not be read keeps the old rules',
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
