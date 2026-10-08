import 'package:genkit/genkit.dart';
import 'package:genkit/plugin.dart';
import 'package:genkit_hybrid/src/hybrid_model.dart';
import 'package:genkit_hybrid/src/routing_context.dart';
import 'package:genkit_hybrid/src/routing_strategy.dart';
import 'package:test/test.dart';
import 'fakes.dart';

class _Pick implements RoutingStrategy {
  _Pick(this.keys);
  final List<String> keys;
  @override
  List<String> route(RoutingContext c) => keys;
}

ModelRequest _req() => ModelRequest(messages: []);

({List<String> received, void Function(ModelResponseChunk) onChunk})
_streamingCtx() {
  final received = <String>[];
  return (
    received: received,
    onChunk: (ModelResponseChunk chunk) {
      received.add(chunk.content.first.text ?? '');
    },
  );
}

void main() {
  test('pre-routing: only the chosen branch is called', () async {
    var deviceCalls = 0, cloudCalls = 0;
    final model = hybridModel(
      branches: {
        'onDevice': fakeModel(
          name: 'd',
          text: 'from-device',
          onCall: () => deviceCalls++,
        ),
        'cloud': fakeModel(
          name: 'c',
          text: 'from-cloud',
          onCall: () => cloudCalls++,
        ),
      },
      strategy: _Pick(['cloud']),
    );
    final res = await model(_req());
    expect(cloudCalls, 1);
    expect(deviceCalls, 0);
    expect(res.message!.content.first.text, 'from-cloud');
  });

  test('fallback: primary throws -> secondary returns', () async {
    var cloudCalls = 0;
    final model = hybridModel(
      branches: {
        'onDevice': fakeModel(name: 'd', throwBeforeToken: true),
        'cloud': fakeModel(
          name: 'c',
          text: 'recovered',
          onCall: () => cloudCalls++,
        ),
      },
      strategy: _Pick(['onDevice', 'cloud']),
    );
    final res = await model(_req());
    expect(cloudCalls, 1);
    expect(res.message!.content.first.text, 'recovered');
  });

  test('fallback: last branch throws -> error propagates', () async {
    final model = hybridModel(
      branches: {
        'onDevice': fakeModel(name: 'd', throwBeforeToken: true),
        'cloud': fakeModel(name: 'c2', throwBeforeToken: true),
      },
      strategy: _Pick(['onDevice', 'cloud']),
    );
    expect(
      () => model(_req()),
      throwsA(
        predicate<StateError>(
          (e) => e.message.contains('fail-before-token:c2'),
        ),
      ),
    );
  });

  test('empty route at top level throws config error', () async {
    final model = hybridModel(
      branches: {'cloud': fakeModel(name: 'c')},
      strategy: _Pick([]),
    );
    expect(() => model(_req()), throwsA(isA<GenkitException>()));
  });

  test('unknown branch key throws config error', () async {
    final model = hybridModel(
      branches: {'cloud': fakeModel(name: 'c')},
      strategy: _Pick(['nope']),
    );
    expect(() => model(_req()), throwsA(isA<GenkitException>()));
  });

  test(
    'permanent GenkitException (e.g. bad auth) does NOT fall back',
    () async {
      var cloudCalls = 0;
      final authFailModel = Model(
        name: 'auth-fail',
        fn: (request, context) async => throw GenkitException(
          'bad key',
          status: StatusCode.permissionDenied,
        ),
      );
      final model = hybridModel(
        branches: {
          'cloud': authFailModel,
          'onDevice': fakeModel(
            name: 'd',
            text: 'should-not-run',
            onCall: () => cloudCalls++,
          ),
        },
        strategy: _Pick(['cloud', 'onDevice']),
      );
      expect(() => model(_req()), throwsA(isA<GenkitException>()));
      expect(
        cloudCalls,
        0,
      ); // permanent error propagated; second branch NOT tried
    },
  );

  test('transient GenkitException (UNAVAILABLE) DOES fall back', () async {
    var deviceCalls = 0;
    final unavailable = Model(
      name: 'down',
      fn: (request, context) async =>
          throw GenkitException('offline', status: StatusCode.unavailable),
    );
    final model = hybridModel(
      branches: {
        'cloud': unavailable,
        'onDevice': fakeModel(
          name: 'd',
          text: 'recovered',
          onCall: () => deviceCalls++,
        ),
      },
      strategy: _Pick(['cloud', 'onDevice']),
    );
    final res = await model(_req());
    expect(deviceCalls, 1);
    expect(res.message!.content.first.text, 'recovered');
  });

  test(
    'streaming: branch fails before first token -> next branch used',
    () async {
      final s = _streamingCtx();
      final model = hybridModel(
        branches: {
          'onDevice': fakeModel(name: 'd', throwBeforeToken: true),
          'cloud': fakeModel(name: 'c', text: 'done', chunks: ['he', 'llo']),
        },
        strategy: _Pick(['onDevice', 'cloud']),
      );
      final res = await model(_req(), onChunk: s.onChunk);
      expect(s.received, ['he', 'llo']);
      expect(res.message!.content.first.text, 'done');
    },
  );

  test(
    'streaming: branch fails AFTER first token -> propagates, no re-route',
    () async {
      final s = _streamingCtx();
      var cloudCalls = 0;
      final model = hybridModel(
        branches: {
          'onDevice': fakeModel(
            name: 'd',
            chunks: ['partial'],
            throwAfterToken: true,
          ),
          'cloud': fakeModel(
            name: 'c',
            text: 'should-not-run',
            onCall: () => cloudCalls++,
          ),
        },
        strategy: _Pick(['onDevice', 'cloud']),
      );
      await expectLater(
        () => model(_req(), onChunk: s.onChunk),
        throwsA(isA<StateError>()),
      );
      expect(s.received, ['partial']); // first token already delivered
      expect(cloudCalls, 0); // NOT re-routed mid-stream
    },
  );

  test(
    'hybridModel uses a custom name when provided, defaults to "hybrid"',
    () {
      final a = hybridModel(
        branches: {'cloud': fakeModel(name: 'c')},
        strategy: _Pick(['cloud']),
      );
      final b = hybridModel(
        branches: {'cloud': fakeModel(name: 'c')},
        strategy: _Pick(['cloud']),
        name: 'router-A',
      );
      expect(a.name, 'hybrid');
      expect(b.name, 'router-A');
    },
  );
}
