// The seams the runtime side (lib/src/ffi and the EmbeddingGemma 2
// placement) takes its Flutter-bound answers through: the
// NativeAssetsManifest.json reader, the Android dispatch directory, the
// executable's directory and the cache directories. Each injected value must
// be the one used, and each default must be what the code used before.

import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/embedding/embedding_cache_dir.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart'
    show NpuDispatchUnavailableException;
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_vendor_host.dart';
import 'package:flutter_edge_ai_litertlm/src/flutter_npu_platform.dart';
import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine_host.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the NPU platform bindings', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('npu_seams_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('the Flutter bindings look beside the running executable', () {
      expect(
        const FlutterNpuPlatform().executableDir,
        File(Platform.resolvedExecutable).parent.path,
      );
      expect(executableDirOf(), File(Platform.resolvedExecutable).parent.path);
    });

    test('Intel\'s stack check and dispatch directory are the injected '
        'executable directory', () async {
      final platform = _FakePlatform(executableDir: dir.path);
      final missing = await npuStackOf(NpuStack.intel, platform);
      expect(missing.bundled, isFalse);
      expect(missing.reason, contains('(${dir.path})'));

      File(
        '${dir.path}${Platform.pathSeparator}LiteRtDispatch.dll',
      ).writeAsBytesSync(const [0]);
      expect((await npuStackOf(NpuStack.intel, platform)).bundled, isTrue);
      expect(
        await prepareNpuDispatchDir(
          NpuStack.intel,
          platform,
          operatingSystem: 'windows',
        ),
        dir.path,
      );
      expect(platform.manifestReads, 0);
    });

    test('Linux looks for the Qualcomm stack in the injected executable '
        'directory\'s lib/', () async {
      await expectLater(
        prepareNpuDispatchDir(
          NpuStack.qualcomm,
          _FakePlatform(executableDir: dir.path),
          operatingSystem: 'linux',
        ),
        throwsA(
          isA<NpuDispatchUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('is not in ${dir.path}/lib'),
          ),
        ),
      );
    });

    test(
      'Android asks the injected bindings with the vendor\'s file names',
      () async {
        final platform = _FakePlatform(androidDir: '/prepared');
        expect(
          await prepareNpuDispatchDir(
            NpuStack.googleTensor,
            platform,
            operatingSystem: 'android',
          ),
          '/prepared',
        );
        expect(platform.androidAsked, hasLength(1));
        final (names, vendor) = platform.androidAsked.single;
        expect(names, [
          for (final n in googleTensorNpuLibs) androidLibFileName(n),
        ]);
        expect(vendor, NpuStack.googleTensor);
      },
    );

    test(
      'Android: no directory from the native side is still refused',
      () async {
        await expectLater(
          prepareNpuDispatchDir(
            NpuStack.qualcomm,
            _FakePlatform(),
            operatingSystem: 'android',
          ),
          throwsA(
            isA<NpuDispatchUnavailableException>().having(
              (e) => e.message,
              'message',
              'prepareNpuDispatchDir returned no directory',
            ),
          ),
        );
      },
    );

    test('the host\'s manifest read is the injected reader, and its answer '
        'is cached; a test read is not', () async {
      var reads = 0;
      Future<String> read() async {
        reads++;
        return '{"native-assets": {"android_arm64": {}}}';
      }

      for (var i = 0; i < 2; i++) {
        final r = await checkNpuStackInManifest(
          NpuStack.mediatek,
          read: read,
          abi: 'android_arm64',
          operatingSystem: 'android',
        );
        expect(r.bundled, isFalse);
      }
      expect(reads, 2, reason: 'uncached unless asked');

      for (var i = 0; i < 2; i++) {
        final r = await checkNpuStackInManifest(
          NpuStack.mediatek,
          read: read,
          cache: true,
          abi: 'android_arm64',
          operatingSystem: 'android',
        );
        expect(r.bundled, isFalse);
      }
      expect(reads, 3, reason: 'the second cached read reuses the first');
    });

    test('a failed cached read is not cached', () async {
      var reads = 0;
      for (var i = 0; i < 2; i++) {
        final r = await checkNpuStackInManifest(
          NpuStack.googleTensor,
          read: () async {
            reads++;
            throw StateError('Binding has not yet been initialized');
          },
          cache: true,
          abi: 'android_arm64',
          operatingSystem: 'android',
        );
        expect(r.known, isFalse);
      }
      expect(reads, 2);
    });
  });

  group('the LLM engine host', () {
    test('cacheDir is the injected directory', () async {
      final host = LiteRtLmEngineHost(cacheDirectory: () async => '/injected');
      expect(await host.cacheDir(), '/injected');
    });

    test('a cache directory that throws fails the future, as path_provider '
        'did', () async {
      final host = LiteRtLmEngineHost(
        cacheDirectory: () => throw StateError('no directory'),
      );
      final future = host.cacheDir();
      await expectLater(future, throwsStateError);
    });

    test('by default the app support directory and the Flutter NPU host', () {
      const host = LiteRtLmEngineHost();
      expect(host.cacheDirectory, applicationSupportDirectoryPath);
      expect(identical(host.npu, flutterNpuHost), isTrue);
    });

    test('NPU questions go to the injected host', () async {
      final npu = _FakeNpuHost();
      final host = LiteRtLmEngineHost(npu: npu);
      expect((await host.stack(NpuStack.intel)).bundled, isTrue);
      expect(host.unreachable(NpuStack.intel), 'fake');
      expect(await host.prepareDispatchDir(NpuStack.intel), '/fake/intel');
      expect(npu.asked, ['stack:intel', 'probe:intel', 'prepare:intel']);
    });
  });

  test('the embedding cache directory defaults to path_provider\'s cache '
      'directory', () {
    expect(liteRtEmbeddingCacheDirectory, applicationCacheDirectoryPath);
  });
}

final class _FakePlatform implements NpuPlatformBindings {
  _FakePlatform({this.executableDir = '/nowhere', this.androidDir});

  @override
  final String executableDir;

  final String? androidDir;
  final androidAsked = <(List<String>, NpuStack)>[];
  int manifestReads = 0;

  @override
  Future<String> readNativeAssetsManifest() async {
    manifestReads++;
    return '{}';
  }

  @override
  Future<String?> prepareAndroidDispatchDir(
    List<String> libFileNames,
    NpuStack vendor,
  ) async {
    androidAsked.add((libFileNames, vendor));
    return androidDir;
  }
}

final class _FakeNpuHost implements LiteRtLmNpuHost {
  final asked = <String>[];

  @override
  String get abi => 'windows_x64';

  @override
  String get operatingSystem => 'windows';

  @override
  Future<NpuStackCheck> stack(NpuStack vendor) async {
    asked.add('stack:${vendor.name}');
    return const NpuStackCheck.bundled();
  }

  @override
  String? unreachable(NpuStack vendor) {
    asked.add('probe:${vendor.name}');
    return 'fake';
  }

  @override
  Future<String> prepareDispatchDir(NpuStack vendor) async {
    asked.add('prepare:${vendor.name}');
    return '/fake/${vendor.name}';
  }
}
