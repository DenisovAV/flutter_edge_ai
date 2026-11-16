// Where an EmbeddingEngineConfig runs: the bundle's own NPU stamp decides,
// and nothing moves to another backend on its own.
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import '../litertlm_container_fixture.dart';

/// The host [abi], for the NPU placements.
class _Host extends EngineHost {
  const _Host(this.abiName);
  final String abiName;
  @override
  String get abi => abiName;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('eg2_config'));
  tearDown(() {
    debugEngineHost = null;
    dir.deleteSync(recursive: true);
  });

  String write(String name, Uint8List bytes) =>
      (File('${dir.path}/$name')..writeAsBytesSync(bytes)).path;

  EmbeddingEngineConfig config(
    String path, {
    Backend? backend,
    Backend? vision,
    Backend? audio,
  }) => EmbeddingEngineConfig(
    modelPath: path,
    cacheDir: dir.path,
    backend: backend,
    visionBackend: vision,
    audioBackend: audio,
  );

  test(
    'the generic bundle runs on the CPU; on the NPU it is refused',
    () async {
      final path = write('g.litertlm', eg2Container(vision: true, audio: true));
      final placed = await embedderConfigFor(
        config(path, vision: const Backend.cpu(), audio: const Backend.cpu()),
      );
      expect(placed.npuTarget, isNull);
      expect(placed.gpu, isFalse);
      expect(placed.declaredMedia, {
        EmbedderModality.image,
        EmbedderModality.audio,
      });
      // Beside a CPU text tower every tower is on the CPU already.
      expect(placed.audioTowerOnCpu, isFalse);
      expect(
        placed.visionTowerOnCpu,
        isFalse,
        reason: 'beside a CPU text tower',
      );
      await expectLater(
        embedderConfigFor(config(path, backend: Backend.npu())),
        throwsA(isA<EmbedderLoadException>()),
      );
    },
  );

  test('the GPU: taken for a bundle measured on this host, refused for any '
      'other and off the measured hosts; never moved to the CPU', () async {
    final abi = '${Abi.current()}';
    final measured = liteRtLmEmbeddingGpuMeasured[abi] ?? const {};
    for (final (bundle, bytes) in [
      (LiteRtLmEg2Bundle.text270m, eg2Container()),
      (LiteRtLmEg2Bundle.textVision440m, eg2Container(vision: true)),
      (
        LiteRtLmEg2Bundle.textVisionAudio740m,
        eg2Container(vision: true, audio: true),
      ),
    ]) {
      final path = write('${bundle.name}.litertlm', bytes);
      final placing = embedderConfigFor(
        config(path, backend: const Backend.gpu()),
      );
      if (liteRtLmEmbeddingGpuAbis.contains(abi) &&
          !liteRtLmEmbeddingGpuRefusedAbis.contains(abi) &&
          measured.contains(bundle)) {
        final placed = await placing;
        expect(placed.gpu, isTrue, reason: bundle.label);
        expect(placed.visionTowerOnCpu, bundle != LiteRtLmEg2Bundle.text270m);
      } else {
        await expectLater(
          placing,
          throwsA(isA<EmbedderLoadException>()),
          reason: '${bundle.label} on $abi',
        );
      }
    }
  });

  test(
    'images on a bundle without a vision tower are refused on the GPU',
    () async {
      final abi = '${Abi.current()}';
      if (!(liteRtLmEmbeddingGpuMeasured[abi] ?? const {}).contains(
        LiteRtLmEg2Bundle.text270m,
      )) {
        return;
      }
      final path = write('t.litertlm', eg2Container());
      await expectLater(
        embedderConfigFor(
          config(
            path,
            backend: const Backend.gpu(),
            vision: const Backend.cpu(),
          ),
        ),
        throwsA(isA<EmbedderLoadException>()),
      );
    },
  );

  test('an unreadable file is a load failure', () async {
    final path = write('junk.litertlm', Uint8List.fromList([1, 2, 3]));
    await expectLater(
      embedderConfigFor(config(path)),
      throwsA(isA<EmbedderLoadException>()),
    );
  });

  test('an NPU bundle of a vendor this host does not run is refused, a '
      'prepared directory notwithstanding', () async {
    final path = write(
      'intel.litertlm',
      eg2Container(textStamp: ('IntelOpenVINO', 'PTL')),
    );
    debugEngineHost = const _Host('android_arm64');
    await expectLater(
      embedderConfigFor(config(path, backend: Backend.npu(dispatchDir: '/x'))),
      throwsA(isA<EmbedderLoadException>()),
    );
  });

  test('a per-SoC bundle runs on its NPU only, with a prepared directory '
      'used as it is', () async {
    debugEngineHost = const _Host('android_arm64');
    final path = write(
      'q.litertlm',
      eg2Container(textStamp: ('Qualcomm', 'SM8650')),
    );
    await expectLater(
      embedderConfigFor(config(path)),
      throwsA(isA<EmbedderLoadException>()),
    );
    final placed = await embedderConfigFor(
      config(path, backend: Backend.npu(dispatchDir: '/ready')),
    );
    expect(placed.npuTarget?.soc, 'SM8650');
    expect(placed.npuDispatchDir, '/ready');
    expect(placed.declaredMedia, isEmpty);
  });

  test('a CPU thread count reaches the embedder', () async {
    final path = write('g.litertlm', eg2Container());
    final placed = await embedderConfigFor(
      config(path, backend: const Backend.cpu(threadCount: 2)),
    );
    expect(placed.numThreads, 2);
  });

  test('beside an NPU text tower the audio tower is named cpu; the vision '
      'tower runs with the text', () async {
    debugEngineHost = const _Host('android_arm64');
    final path = write(
      'q.litertlm',
      eg2Container(
        textStamp: ('Qualcomm', 'SM8850'),
        vision: true,
        visionStamp: ('Qualcomm', 'SM8850'),
        audio: true,
      ),
    );
    final placed = await embedderConfigFor(
      config(
        path,
        backend: Backend.npu(dispatchDir: '/ready'),
        vision: Backend.npu(),
        audio: const Backend.cpu(),
      ),
    );
    expect(placed.audioTowerOnCpu, isTrue);
    expect(placed.visionTowerOnCpu, isFalse);
  });
}
