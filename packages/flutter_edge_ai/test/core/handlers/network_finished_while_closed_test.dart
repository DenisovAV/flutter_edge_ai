// #873: NetworkSourceHandler records a download that finished while the app
// was closed instead of downloading it again — only when there is a stored
// completion of this source and the file is exactly its size. The completion
// itself (live/paused task, source, used once) is held by
// test/mobile/background_completions_test.dart.
import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/handlers/network_source_handler.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/src/services/completed_downloads.dart';
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/src/services/file_system_service.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart';
import 'package:flutter_edge_ai/src/services/remote_size_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Downloads extends Mock implements DownloadService {}

class _Files extends Mock implements FileSystemService {}

class _Repository extends Mock implements ModelRepository {}

/// One stored completion (or none) for one URL and path.
final class _Completed implements CompletedDownloads {
  _Completed(this.completion);

  final ({int? totalBytes})? completion;
  final asked = <(String, String)>[];

  @override
  Future<({int? totalBytes})?> completedWhileAway(
    String url,
    String targetPath,
  ) async {
    asked.add((url, targetPath));
    return completion;
  }
}

final class _Probe implements RemoteSizeProbe {
  _Probe(this.size);

  final int? size;
  var calls = 0;

  @override
  Future<int?> sizeOf(
    String url, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    calls += 1;
    return size;
  }
}

const _url = 'https://example.invalid/model.litertlm';
const _path = '/data/model.litertlm';
final _source = NetworkSource(_url);

void main() {
  setUpAll(() {
    registerFallbackValue(
      ModelInfo(
        id: 'fallback',
        source: _source,
        installedAt: DateTime(2026),
        sizeBytes: 0,
        type: ModelType.inference,
        hasLoraWeights: false,
      ),
    );
  });

  late _Downloads downloads;
  late _Files files;
  late _Repository repository;
  late List<ModelInfo> saved;

  setUp(() {
    downloads = _Downloads();
    files = _Files();
    repository = _Repository();
    saved = [];
    when(() => files.getWriteTargetPath(any())).thenAnswer((_) async => _path);
    when(() => repository.saveModel(any())).thenAnswer((invocation) async {
      saved.add(invocation.positionalArguments.single as ModelInfo);
    });
    when(
      () => downloads.download(
        any(),
        any(),
        token: any(named: 'token'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => downloads.downloadWithProgress(
        any(),
        any(),
        token: any(named: 'token'),
        maxRetries: any(named: 'maxRetries'),
        cancelToken: any(named: 'cancelToken'),
        foreground: any(named: 'foreground'),
      ),
    ).thenAnswer((_) => Stream.fromIterable([40, 100]));
  });

  NetworkSourceHandler handler({
    ({int? totalBytes})? completion,
    int fileSize = 2048,
    RemoteSizeProbe? probe,
    bool withCompletedDownloads = true,
  }) {
    when(() => files.getFileSize(_path)).thenAnswer((_) async => fileSize);
    return NetworkSourceHandler(
      downloadService: downloads,
      fileSystem: files,
      repository: repository,
      completedDownloads: withCompletedDownloads
          ? _Completed(completion)
          : null,
      sizeProbe: probe,
    );
  }

  void expectNoDownload() {
    verifyNever(
      () => downloads.download(
        any(),
        any(),
        token: any(named: 'token'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  }

  void expectDownloaded() {
    verify(
      () => downloads.download(
        _url,
        _path,
        token: any(named: 'token'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
  }

  group('install', () {
    test('a stored completion and a file of its size: recorded, not '
        'downloaded again', () async {
      await handler(completion: (totalBytes: 2048)).install(_source);

      expectNoDownload();
      expect(saved, hasLength(1));
      expect(saved.single.id, 'model.litertlm');
      expect(saved.single.source, _source);
      expect(saved.single.sizeBytes, 2048);
    });

    test('no stored completion: downloaded', () async {
      await handler().install(_source);
      expectDownloaded();
      expect(saved, hasLength(1));
    });

    test('a file of another size (cut short, or another file): downloaded '
        'over it', () async {
      await handler(
        completion: (totalBytes: 4096),
        fileSize: 2048,
      ).install(_source);
      expectDownloaded();
    });

    test('no file at the path: downloaded', () async {
      final subject = handler(completion: (totalBytes: 2048));
      // Nothing there when asked, the downloaded file once it has run.
      var downloaded = false;
      when(
        () => files.getFileSize(_path),
      ).thenAnswer((_) async => downloaded ? 2048 : 0);
      when(
        () => downloads.download(
          any(),
          any(),
          token: any(named: 'token'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => downloaded = true);

      await subject.install(_source);
      expectDownloaded();
      expect(saved.single.sizeBytes, 2048);
    });

    test(
      'a completion that stated no size uses the remote size probe',
      () async {
        final probe = _Probe(2048);
        await handler(
          completion: (totalBytes: null),
          probe: probe,
        ).install(_source);
        expect(probe.calls, 1);
        expectNoDownload();
      },
    );

    test('no size from the response or the probe: downloaded', () async {
      await handler(
        completion: (totalBytes: null),
        probe: _Probe(null),
      ).install(_source);
      expectDownloaded();
    });

    test('no completion source at all (web, desktop, an injected '
        'DownloadService): unchanged', () async {
      await handler(withCompletedDownloads: false).install(_source);
      expectDownloaded();
    });

    test('asks about the exact URL and target path', () async {
      final completed = _Completed(null);
      when(() => files.getFileSize(_path)).thenAnswer((_) async => 2048);
      await NetworkSourceHandler(
        downloadService: downloads,
        fileSystem: files,
        repository: repository,
        completedDownloads: completed,
      ).install(_source);
      expect(completed.asked, [(_url, _path)]);
    });
  });

  group('installWithProgress', () {
    test(
      'recorded without a download, and the stream still ends on 100',
      () async {
        final progress = await handler(
          completion: (totalBytes: 2048),
        ).installWithProgress(_source).toList();

        expect(progress, [100]);
        verifyNever(
          () => downloads.downloadWithProgress(
            any(),
            any(),
            token: any(named: 'token'),
            maxRetries: any(named: 'maxRetries'),
            cancelToken: any(named: 'cancelToken'),
            foreground: any(named: 'foreground'),
          ),
        );
        expect(saved.single.sizeBytes, 2048);
      },
    );

    test('no stored completion: the download\'s own progress', () async {
      final progress = await handler().installWithProgress(_source).toList();
      expect(progress, [40, 100]);
      expect(saved, hasLength(1));
    });

    test('a size mismatch: the download\'s own progress', () async {
      final progress = await handler(
        completion: (totalBytes: 9999),
      ).installWithProgress(_source).toList();
      expect(progress, [40, 100]);
    });
  });
}
