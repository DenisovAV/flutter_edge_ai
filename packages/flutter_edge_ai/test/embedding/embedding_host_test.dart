// Both embedding hosts (R5 §4.4-4.5, §10.1 "Host"), one suite body: the
// isolate host (native) and the inline host (web, and the VM here). Plus the
// isolate-only cases: close overtaking a queue behind a SYNCHRONOUSLY blocking
// pass (W2) and a worker that dies (W6).
//
// The fake pass is built from a top-level factory over a sendable config, as
// the SPI requires, and writes one line per call to a log file — the only way
// the test can see what a pass did inside the worker. A gated call waits until
// the test creates `<log>.release`, so orderings are fixed by the test, not by
// timing.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_host.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_host_io.dart' as io;
import 'package:flutter_edge_ai/src/embedding/embedding_host_web.dart'
    as inline;
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';
import 'package:flutter_test/flutter_test.dart';

enum _Mode {
  ok,
  imageCapable,
  gatedAsync,
  gatedSync,
  failLoad,
  failLoadGatedClose,
  failLoadThenCloseDies,
  failLoadTyped,
  dieDuringLoad,
  tooLong,
  engineError,
  engineErrorWithCause,
  otherError,
  dieOnEmbed,
  closeThrows,
  failLoadCloseThrows,
}

final class _Config {
  const _Config(this.mode, this.logPath);
  final _Mode mode;
  final String logPath;
}

EmbeddingPass _buildFake(_Config config) => _FakePass(config);

final class _FakePass extends EmbeddingPass {
  _FakePass(this._config);

  final _Config _config;

  void _log(String line) => File(
    _config.logPath,
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);

  File get _release => File('${_config.logPath}.release');

  static const _gateDeadline = Duration(seconds: 30);

  @override
  Future<EmbeddingPassInfo> load() async {
    _log('load');
    switch (_config.mode) {
      case _Mode.failLoad:
      case _Mode.failLoadGatedClose:
      case _Mode.failLoadThenCloseDies:
      case _Mode.failLoadCloseThrows:
        _refuseToLoadInThePass();
      case _Mode.failLoadTyped:
        throw const EmbeddingLoadException(
          'bad model',
          engine: 'FakeNative',
          nativeCode: 5,
        );
      case _Mode.dieDuringLoad:
        // An error nothing catches ends the isolate before it is ready.
        scheduleMicrotask(() => throw StateError('fake died during load'));
        return Completer<EmbeddingPassInfo>().future;
      case _Mode.imageCapable:
        return EmbeddingPassInfo(
          dimension: 2,
          modalities: const {EmbeddingModality.text, EmbeddingModality.image},
          imageFormats: {EncodedMediaFormat.jpeg},
          maxInputTokens: 16,
        );
      default:
        return const EmbeddingPassInfo(dimension: 2, maxInputTokens: 16);
    }
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final label =
        input.text ??
        'image:${utf8.decode(input.images.isEmpty ? input.audio! : input.images.single)}';
    _log('embed:$label');
    if (label == '#gate') {
      final deadline = DateTime.now().add(_gateDeadline);
      while (!_release.existsSync()) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('fake gate was never released');
        }
        if (_config.mode == _Mode.gatedSync) {
          // Blocks this isolate — no events, no microtasks — the way a
          // synchronous native call does. An async fake would leave the event
          // loop free and pass even if the pump forgot to yield (W2).
          sleep(const Duration(milliseconds: 5));
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }
    }
    switch (_config.mode) {
      case _Mode.tooLong:
        throw const EmbeddingInputTooLongException(
          'too long',
          maxInputTokens: 8,
          actualTokens: 9,
        );
      case _Mode.engineError:
        throw const EmbeddingEngineException(
          'boom',
          engine: 'FakeNative',
          nativeCode: 3,
        );
      case _Mode.engineErrorWithCause:
        throw const EmbeddingEngineException(
          'boom',
          engine: 'FakeNative',
          cause: 'native detail',
        );
      case _Mode.otherError:
        _throwKaputFromThePass();
      case _Mode.dieOnEmbed:
        scheduleMicrotask(() => throw StateError('fake died mid-request'));
        return Completer<List<double>>().future;
      default:
        return [taskType.index.toDouble(), label.length.toDouble()];
    }
  }

  @override
  Future<void> close() async {
    if (_config.mode == _Mode.failLoadGatedClose) {
      _log('close-start');
      final deadline = DateTime.now().add(_gateDeadline);
      while (!_release.existsSync()) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    if (_config.mode == _Mode.failLoadThenCloseDies) {
      // The worker dies inside the close, before it can report it.
      scheduleMicrotask(() => throw StateError('fake died while closing'));
      await Completer<void>().future;
    }
    _log('close');
    if (_config.mode == _Mode.closeThrows ||
        _config.mode == _Mode.failLoadCloseThrows) {
      throw StateError('close refused');
    }
  }
}

/// Named so a test can find the frame in the stack the caller receives.
Never _throwKaputFromThePass() => throw StateError('kaput');

Never _refuseToLoadInThePass() => throw StateError('fake pass refused to load');

typedef _Start =
    Future<EmbeddingHost> Function(
      EmbeddingPassDescriptor<Object> descriptor, {
      required Set<EmbeddingModality> declaredMedia,
      required String label,
    });

final _hosts = <String, _Start>{
  'isolate host': (d, {required declaredMedia, required label}) =>
      io.startEmbeddingHost(d, declaredMedia: declaredMedia, label: label),
  'inline host': (d, {required declaredMedia, required label}) =>
      inline.startEmbeddingHost(d, declaredMedia: declaredMedia, label: label),
};

late Directory _tmp;
var _logCounter = 0;
final _openHosts = <EmbeddingHost>[];
final _releaseFiles = <File>[];

String _newLog() => '${_tmp.path}/pass${_logCounter++}.log';

List<String> _readLog(String path) {
  final file = File(path);
  return file.existsSync()
      ? file.readAsLinesSync().where((l) => l.isNotEmpty).toList()
      : const [];
}

Future<void> _waitForLog(String path, bool Function(List<String>) done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done(_readLog(path))) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out; log was ${_readLog(path)}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void _release(String logPath) {
  final file = File('$logPath.release')..writeAsStringSync('go');
  _releaseFiles.add(file);
}

EmbeddingPassDescriptor<_Config> _descriptor(_Mode mode, String log) =>
    EmbeddingPassDescriptor(
      engineTag: 'Fake',
      factory: _buildFake,
      config: _Config(mode, log),
      activeBackend: PreferredBackend.cpu,
    );

Future<EmbeddingHost> _start(
  _Start start,
  _Mode mode,
  String log, {
  Set<EmbeddingModality> declaredMedia = const {},
}) async {
  final host = await start(
    _descriptor(mode, log),
    declaredMedia: declaredMedia,
    label: '/models/fake.bin',
  );
  _openHosts.add(host);
  return host;
}

EmbeddingInput _image(String label) =>
    EmbeddingInput.image(Uint8List.fromList(utf8.encode(label)));

void main() {
  setUpAll(() => _tmp = Directory.systemTemp.createTempSync('emb_host_test'));
  tearDown(() async {
    // Every gate opens, so a failed test never leaves a pass blocked.
    for (final path in Directory(_tmp.path).listSync().whereType<File>()) {
      if (path.path.endsWith('.log')) _release(path.path);
    }
    for (final host in _openHosts) {
      await host.close();
    }
    _openHosts.clear();
  });
  tearDownAll(() => _tmp.deleteSync(recursive: true));

  _hosts.forEach((name, start) {
    group(name, () {
      test('loads, reports the pass, serves a request', () async {
        final log = _newLog();
        final host = await _start(start, _Mode.ok, log);

        expect(host.info.dimension, 2);
        expect(host.info.maxInputTokens, 16);
        expect(host.modalities, {EmbeddingModality.text});
        expect(
          await host.embed(EmbeddingInput.text('abc'), TaskType.clustering),
          [TaskType.clustering.index.toDouble(), 3.0],
        );
        expect(_readLog(log), ['load', 'embed:abc']);
      });

      test('declared media the pass serves become modalities', () async {
        final host = await _start(
          start,
          _Mode.imageCapable,
          _newLog(),
          declaredMedia: const {EmbeddingModality.image},
        );
        expect(host.modalities, {
          EmbeddingModality.text,
          EmbeddingModality.image,
        });
      });

      test('text before media, FIFO within each lane, one at a time', () async {
        final log = _newLog();
        final host = await _start(start, _Mode.gatedAsync, log);

        final first = host.embed(EmbeddingInput.text('#gate'), TaskType.none);
        await _waitForLog(log, (l) => l.contains('embed:#gate'));
        final rest = [
          host.embed(_image('A'), TaskType.none),
          host.embed(EmbeddingInput.text('B'), TaskType.none),
          host.embed(_image('C'), TaskType.none),
          host.embed(EmbeddingInput.text('D'), TaskType.none),
        ];
        await Future<void>.delayed(const Duration(milliseconds: 50));
        _release(log);
        await first;
        await Future.wait(rest);

        expect(_readLog(log).where((l) => l.startsWith('embed:')), [
          'embed:#gate',
          'embed:B',
          'embed:D',
          'embed:image:A',
          'embed:image:C',
        ]);
      });

      test('close fails what has not started, finishes the request in '
          'flight, closes the pass once', () async {
        final log = _newLog();
        final host = await _start(start, _Mode.gatedAsync, log);

        final inFlight = host.embed(
          EmbeddingInput.text('#gate'),
          TaskType.none,
        );
        await _waitForLog(log, (l) => l.contains('embed:#gate'));
        final queued = [
          host.embed(EmbeddingInput.text('q1'), TaskType.none),
          host.embed(_image('q2'), TaskType.none),
        ];
        for (final q in queued) {
          unawaited(q.then((_) {}, onError: (_) {}));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final closing = host.close();
        final again = host.close();
        _release(log);

        expect(await inFlight, isNotEmpty);
        for (final q in queued) {
          await expectLater(q, throwsA(isA<EmbedderClosedException>()));
        }
        await closing;
        await again;
        expect(_readLog(log), ['load', 'embed:#gate', 'close']);
        await expectLater(
          host.embed(EmbeddingInput.text('late'), TaskType.none),
          throwsA(isA<EmbedderClosedException>()),
        );
      });

      test(
        'a load failure is reported typed and still closes the pass',
        () async {
          final log = _newLog();
          await expectLater(
            _start(start, _Mode.failLoad, log),
            throwsA(
              isA<EmbeddingLoadException>()
                  .having((e) => e.engine, 'engine', 'Fake')
                  .having((e) => e.message, 'message', contains('refused')),
            ),
          );
          await _waitForLog(log, (l) => l.contains('close'));
          expect(_readLog(log), ['load', 'close']);
        },
      );

      test('an engine load error keeps its engine and native code', () async {
        await expectLater(
          _start(start, _Mode.failLoadTyped, _newLog()),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.engine, 'engine', 'FakeNative')
                .having((e) => e.nativeCode, 'code', 5),
          ),
        );
      });

      test('a declared modality the pass lacks is refused at load and the '
          'pass is closed', () async {
        final log = _newLog();
        await expectLater(
          _start(
            start,
            _Mode.ok,
            log,
            declaredMedia: const {EmbeddingModality.image},
          ),
          throwsA(
            isA<EmbeddingLoadException>().having(
              (e) => e.message,
              'message',
              contains('images'),
            ),
          ),
        );
        await _waitForLog(log, (l) => l.contains('close'));
        expect(_readLog(log), ['load', 'close']);
      });

      test('a too-long failure crosses typed, with both counts', () async {
        final host = await _start(start, _Mode.tooLong, _newLog());
        await expectLater(
          host.embed(EmbeddingInput.text('x'), TaskType.none),
          throwsA(
            isA<EmbeddingInputTooLongException>()
                .having((e) => e.maxInputTokens, 'max', 8)
                .having((e) => e.actualTokens, 'actual', 9),
          ),
        );
        // And the host keeps serving.
        await expectLater(
          host.embed(EmbeddingInput.text('y'), TaskType.none),
          throwsA(isA<EmbeddingInputTooLongException>()),
        );
      });

      test('an engine failure keeps its engine and native code', () async {
        final host = await _start(start, _Mode.engineError, _newLog());
        await expectLater(
          host.embed(EmbeddingInput.text('x'), TaskType.none),
          throwsA(
            isA<EmbeddingEngineException>()
                .having((e) => e.engine, 'engine', 'FakeNative')
                .having((e) => e.nativeCode, 'code', 3),
          ),
        );
      });

      test(
        'a cause reaches the caller, and both hosts print the same line',
        () async {
          final host = await _start(
            start,
            _Mode.engineErrorWithCause,
            _newLog(),
          );
          await expectLater(
            host.embed(EmbeddingInput.text('x'), TaskType.none),
            throwsA(
              isA<EmbeddingEngineException>().having(
                (e) => e.toString(),
                'toString',
                'EmbeddingEngineException: boom (cause: native detail)',
              ),
            ),
          );
          final plain = await _start(start, _Mode.otherError, _newLog());
          await expectLater(
            plain.embed(EmbeddingInput.text('x'), TaskType.none),
            throwsA(
              isA<EmbeddingEngineException>().having(
                (e) => e.toString(),
                'toString',
                'EmbeddingEngineException: Bad state: kaput',
              ),
            ),
          );
        },
      );

      test('a failure keeps the stack of the pass that threw', () async {
        final host = await _start(start, _Mode.otherError, _newLog());
        StackTrace? stack;
        try {
          await host.embed(EmbeddingInput.text('x'), TaskType.none);
        } on EmbeddingEngineException catch (_, st) {
          stack = st;
        }
        expect('$stack', contains('_throwKaputFromThePass'));

        StackTrace? loadStack;
        try {
          await _start(start, _Mode.failLoad, _newLog());
        } on EmbeddingLoadException catch (_, st) {
          loadStack = st;
        }
        expect('$loadStack', contains('_refuseToLoadInThePass'));
      });

      test('any other error becomes an EmbeddingEngineException', () async {
        final host = await _start(start, _Mode.otherError, _newLog());
        await expectLater(
          host.embed(EmbeddingInput.text('x'), TaskType.none),
          throwsA(
            isA<EmbeddingEngineException>()
                .having((e) => e.engine, 'engine', 'Fake')
                .having((e) => e.message, 'message', 'Bad state: kaput'),
          ),
        );
      });

      test('a pass whose close throws still closes the host', () async {
        final log = _newLog();
        final host = await _start(start, _Mode.closeThrows, log);
        await host.close();
        expect(_readLog(log), ['load', 'close']);
      });
    });
  });

  group('a pass close that throws is reported once (inline host)', () {
    /// Every diagnostic line the host emits — `print` (release-visible) and
    /// `debugPrint` (what `edgeAiLog` uses) alike — while [body] runs.
    Future<List<String>> reports(Future<void> Function() body) async {
      final lines = <String>[];
      final savedDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
      try {
        await runZoned(
          body,
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => lines.add(line),
          ),
        );
      } finally {
        debugPrint = savedDebugPrint;
      }
      return lines;
    }

    void expectOneWarning(List<String> lines) {
      final aboutIt = lines.where((l) => l.contains('close refused')).toList();
      expect(aboutIt, hasLength(1), reason: 'one failure, one report');
      expect(
        aboutIt.single,
        startsWith('[flutter_edge_ai] WARNING:'),
        reason: 'the report kept is the one a release build prints',
      );
    }

    test('when the host closes it', () async {
      final log = _newLog();
      final lines = await reports(() async {
        final host = await inline.startEmbeddingHost(
          _descriptor(_Mode.closeThrows, log),
          declaredMedia: const {},
          label: '/models/fake.bin',
        );
        await host.close();
      });
      expectOneWarning(lines);
    });

    test('when it is closed after a failed load', () async {
      final log = _newLog();
      final lines = await reports(() async {
        Future<void>? cleanup;
        await expectLater(
          inline.startEmbeddingHost(
            _descriptor(_Mode.failLoadCloseThrows, log),
            declaredMedia: const {},
            label: '/models/fake.bin',
            onFailedLoadCleanup: (c) => cleanup = c,
          ),
          throwsA(isA<EmbeddingLoadException>()),
        );
        await cleanup;
      });
      expect(_readLog(log), ['load', 'close']);
      expectOneWarning(lines);
    });
  });

  group(
    'a failed load is closed behind its error, and the caller can wait',
    () {
      final starters = <String, Function>{
        'isolate host': io.startEmbeddingHost,
        'inline host': inline.startEmbeddingHost,
      };
      starters.forEach((name, start) {
        test('$name: the error comes first; the cleanup future ends when the '
            'pass has closed, and a slow close says so', () async {
          final log = _newLog();
          Future<void>? cleanup;
          final printed = <String>[];
          await runZoned(
            () async {
              await expectLater(
                Function.apply(
                      start,
                      [_descriptor(_Mode.failLoadGatedClose, log)],
                      {
                        #declaredMedia: const <EmbeddingModality>{},
                        #label: '/models/fake.bin',
                        #slowCloseNotice: const Duration(milliseconds: 100),
                        #onFailedLoadCleanup: (Future<void> c) => cleanup = c,
                      },
                    )
                    as Future<EmbeddingHost>,
                throwsA(isA<EmbeddingLoadException>()),
              );
              expect(
                cleanup,
                isNotNull,
                reason: 'handed over before the error',
              );
              await _waitForLog(log, (l) => l.contains('close-start'));
              var done = false;
              unawaited(cleanup!.then((_) => done = true));
              await Future<void>.delayed(const Duration(milliseconds: 300));
              expect(done, isFalse, reason: 'the pass is still closing');
              expect(
                printed.join('\n'),
                contains('after its load failed'),
                reason: 'a slow cleanup is reported, not silent',
              );
              _release(log);
              await cleanup!.timeout(const Duration(seconds: 10));
            },
            zoneSpecification: ZoneSpecification(
              print: (self, parent, zone, line) => printed.add(line),
            ),
          );
          expect(_readLog(log), ['load', 'close-start', 'close']);
        });
      });

      test('isolate host: a worker that dies while closing after a failed load '
          'is reported, and the cleanup still ends', () async {
        Future<void>? cleanup;
        final printed = <String>[];
        await runZoned(
          () async {
            await expectLater(
              io.startEmbeddingHost(
                _descriptor(_Mode.failLoadThenCloseDies, _newLog()),
                declaredMedia: const {},
                label: '/models/fake.bin',
                onFailedLoadCleanup: (c) => cleanup = c,
              ),
              throwsA(isA<EmbeddingLoadException>()),
            );
            await cleanup!.timeout(const Duration(seconds: 10));
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => printed.add(line),
          ),
        );
        final out = printed.join('\n');
        expect(out, contains('fake died while closing'));
        expect(out, contains('without reporting'));
        expect(out, contains('may still be resident'));
      });

      test('isolate host: a worker that dies during load says the native model '
          'may still be resident', () async {
        final printed = <String>[];
        await runZoned(
          () async {
            await expectLater(
              _start(io.startEmbeddingHost, _Mode.dieDuringLoad, _newLog()),
              throwsA(isA<EmbeddingLoadException>()),
            );
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => printed.add(line),
          ),
        );
        expect(
          printed.join('\n'),
          allOf(
            contains('died during load'),
            contains('may still be resident'),
          ),
        );
      });
    },
  );

  group('isolate host only', () {
    test(
      'W2: close overtakes a queue behind a synchronously blocking pass, and '
      'the worker closes its own pass (W4: no kill)',
      () async {
        final log = _newLog();
        final host = await _start(io.startEmbeddingHost, _Mode.gatedSync, log);

        final inFlight = host.embed(
          EmbeddingInput.text('#gate'),
          TaskType.none,
        );
        await _waitForLog(log, (l) => l.contains('embed:#gate'));
        // The worker's event loop is blocked now: these and the close sit in
        // its message queue until the call returns.
        final queued = [
          for (var i = 0; i < 3; i++)
            host.embed(EmbeddingInput.text('q$i'), TaskType.none),
        ];
        for (final q in queued) {
          unawaited(q.then((_) {}, onError: (_) {}));
        }
        final closing = host.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        _release(log);

        expect(await inFlight, isNotEmpty);
        for (final q in queued) {
          await expectLater(q, throwsA(isA<EmbedderClosedException>()));
        }
        await closing;
        // Not one queued request ran, and the pass was closed BY THE WORKER —
        // a killed isolate runs no more Dart code and could not have written
        // this line.
        expect(_readLog(log), ['load', 'embed:#gate', 'close']);
      },
    );

    test('W6: a worker that dies fails what is pending and says so', () async {
      final host = await _start(
        io.startEmbeddingHost,
        _Mode.dieOnEmbed,
        _newLog(),
      );
      final died = host.unexpectedExit;

      await expectLater(
        host.embed(EmbeddingInput.text('x'), TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>().having(
            (e) => e.message,
            'message',
            allOf(contains('exited unexpectedly'), contains('fake died')),
          ),
        ),
      );
      expect(await died, contains('fake died mid-request'));
      await expectLater(
        host.embed(EmbeddingInput.text('y'), TaskType.none),
        throwsA(isA<EmbedderClosedException>()),
      );
      await host.close();
    });

    test('a worker that dies during load fails the start typed', () async {
      await expectLater(
        _start(io.startEmbeddingHost, _Mode.dieDuringLoad, _newLog()),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            allOf(contains('exited during load'), contains('fake died')),
          ),
        ),
      );
    });

    test('a clean close never reports an unexpected exit', () async {
      final host = await _start(io.startEmbeddingHost, _Mode.ok, _newLog());
      var died = false;
      unawaited(host.unexpectedExit.then((_) => died = true));
      await host.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(died, isFalse);
    });
  });
}
