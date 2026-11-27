// #873: NetworkSourceHandler records a download that finished while the app
// was closed instead of downloading it again — only when there is a stored
// completion of this source and the file is exactly the size its response
// stated. The completion itself (live/paused task, source, used once) is held
// by test/mobile/background_completions_test.dart.
import 'dart:async';

import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/handlers/network_source_handler.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/src/services/completed_downloads.dart';
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/src/services/file_system_service.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Downloads extends Mock implements DownloadService {}

class _Files extends Mock implements FileSystemService {}

class _Repository extends Mock implements ModelRepository {}

typedef _Completion = ({int totalBytes, String statedBy});

/// One stored completion (or none) for one URL and path.
final class _Completed implements CompletedDownloads {
  _Completed(this.completion, {this.whileAsked});

  final _Completion? completion;

  /// Runs while the lookup is in progress.
  final void Function()? whileAsked;
  final asked = <(String, String)>[];

  @override
  Future<_Completion?> completedWhileAway(String url, String targetPath) async {
    asked.add((url, targetPath));
    whileAsked?.call();
    return completion;
  }
}

const _url = 'https://example.invalid/model.litertlm';
const _path = '/data/model.litertlm';
final _source = NetworkSource(_url);
const _stated = (totalBytes: 2048, statedBy: 'Content-Length');

/// The lines [body] prints.
Future<List<String>> _printed(Future<void> Function() body) async {
  final lines = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => lines.add(line),
    ),
  );
  return lines;
}

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
    _Completion? completion,
    int fileSize = 2048,
    bool withCompletedDownloads = true,
    void Function()? whileAsked,
  }) {
    when(() => files.getFileSize(_path)).thenAnswer((_) async => fileSize);
    return NetworkSourceHandler(
      downloadService: downloads,
      fileSystem: files,
      repository: repository,
      completedDownloads: withCompletedDownloads
          ? _Completed(completion, whileAsked: whileAsked)
          : null,
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
      await handler(completion: _stated).install(_source);

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
        completion: (totalBytes: 4096, statedBy: 'Content-Length'),
        fileSize: 2048,
      ).install(_source);
      expectDownloaded();
    });

    test('no file at the path: downloaded', () async {
      final subject = handler(completion: _stated);
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

  group('the decision is printed in release builds too', () {
    test('recorded: path, source, both sizes and the header', () async {
      final lines = await _printed(
        () => handler(completion: _stated).install(_source),
      );
      expect(lines, hasLength(1));
      expect(lines.single, startsWith('[flutter_edge_ai] '));
      expect(
        lines.single,
        allOf(
          contains(_path),
          contains(_url),
          contains('2048 bytes'),
          contains('Content-Length'),
          contains('recording it instead of downloading again'),
        ),
      );
    });

    test('downloaded again on a size mismatch', () async {
      final lines = await _printed(
        () => handler(
          completion: (totalBytes: 4096, statedBy: 'X-Linked-Size'),
        ).install(_source),
      );
      expect(lines.single, allOf(contains('4096'), contains('X-Linked-Size')));
      expect(lines.single, contains('downloading it again'));
    });

    test('a signed URL is printed without its signature', () async {
      const signed = '$_url?X-Amz-Signature=secret&X-Amz-Credential=key';
      final lines = await _printed(
        () => handler(completion: _stated).install(NetworkSource(signed)),
      );
      expect(lines.single, isNot(contains('secret')));
      expect(lines.single, isNot(contains('key')));
    });

    test('nothing is printed without a completion', () async {
      expect(await _printed(() => handler().install(_source)), isEmpty);
    });
  });

  group('cancellation', () {
    test('cancelled before the install: not recorded', () async {
      final token = CancelToken()..cancel('user');
      await expectLater(
        handler(completion: _stated).install(_source, cancelToken: token),
        throwsA(isA<DownloadCancelledException>()),
      );
      expect(saved, isEmpty);
      expectNoDownload();
    });

    test('cancelled during the lookup: not recorded', () async {
      final token = CancelToken();
      await expectLater(
        handler(
          completion: _stated,
          whileAsked: () => token.cancel('user'),
        ).install(_source, cancelToken: token),
        throwsA(isA<DownloadCancelledException>()),
      );
      expect(saved, isEmpty);
      expectNoDownload();
    });

    test('installWithProgress cancelled during the lookup: an error, no 100, '
        'not recorded', () async {
      final token = CancelToken();
      final progress = <int>[];
      await expectLater(
        handler(completion: _stated, whileAsked: () => token.cancel('user'))
            .installWithProgress(_source, cancelToken: token)
            .forEach(progress.add),
        throwsA(isA<DownloadCancelledException>()),
      );
      expect(progress, isEmpty);
      expect(saved, isEmpty);
    });
  });

  group('installWithProgress', () {
    test(
      'recorded without a download, and the stream still ends on 100',
      () async {
        final progress = await handler(
          completion: _stated,
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
        completion: (totalBytes: 9999, statedBy: 'Content-Length'),
      ).installWithProgress(_source).toList();
      expect(progress, [40, 100]);
    });
  });
}
