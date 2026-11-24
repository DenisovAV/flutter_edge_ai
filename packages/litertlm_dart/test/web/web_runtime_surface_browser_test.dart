// What the web Engine requires of the page's @litert-lm/core and what it
// reads back from it, over the stub runtime (web_runtime_stub.dart): the
// members it calls, the loader's failure, the resolved settings, and the
// sampler default the Flutter adapter passes.
//
// Run: dart test -p chrome test/web/web_runtime_surface_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_runtime_surface_browser_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

Matcher _incomplete(String member) => throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    allOf(contains(member), contains(web.liteRtLmWebModuleUrl)),
  ),
);

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);

  group('an Engine lacking a member the release calls is refused before '
      'the runtime creates anything', () {
    for (final member in ['createConversation', 'delete']) {
      test(member, () async {
        ((globalContext['Engine']! as JSObject)['prototype']! as JSObject)
            .delete(member.toJS);

        await expectLater(Engine.create(webConfig()), _incomplete(member));

        expect(list('createSettings'), isEmpty);
      });
    }

    test('create', () async {
      (globalContext['Engine']! as JSObject).delete('create'.toJS);

      await expectLater(Engine.create(webConfig()), _incomplete('create'));
    });
  });

  group('a conversation lacking a member the release calls is refused, and '
      'deleted', () {
    for (final member in web.webConversationMembers) {
      test(member, () async {
        final engine = await webEngine();
        setOnPage('missingMember', member);

        await expectLater(engine.createConversation(), _incomplete(member));

        // `delete` itself is the member missing: there is nothing to call.
        expect(count('conversationDeletes'), member == 'delete' ? 0 : 1);
        await engine.close();
      });
    }
  });

  test(
    'a loader that rejected is a StateError naming the module script',
    () async {
      globalContext.callMethod(
        'eval'.toJS,
        '''window.litertLmReady = Promise.reject(new Error('CDN down'));
         window.litertLmReady.catch(() => {});'''
            .toJS,
      );

      await expectLater(
        Engine.create(webConfig()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('CDN down'), contains(web.liteRtLmWebModuleUrl)),
          ),
        ),
      );
    },
  );

  group('the resolved settings', () {
    test('backend 4 (GPU) is Backend.gpu', () async {
      setOnPage('resolvedBackend', 4);

      final engine = await Engine.create(webConfig());

      expect(engine.backend, const Backend.gpu());
      await engine.close();
    });

    test(
      'an unknown backend is a StateError, and the engine is deleted',
      () async {
        setOnPage('resolvedBackend', 6);

        await expectLater(
          Engine.create(webConfig()),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('backend 6'),
            ),
          ),
        );

        expect(count('engineDeletes'), 1);
      },
    );

    test(
      'no backend reported is a StateError, and the engine is deleted',
      () async {
        setOnPage('noSettingsBackend', true);

        await expectLater(
          Engine.create(webConfig()),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('reported no backend'),
            ),
          ),
        );

        expect(count('engineDeletes'), 1);
      },
    );

    test('no context reported is the one asked for', () async {
      setOnPage('noSettingsTokens', true);

      final engine = await Engine.create(webConfig(tokens: 2048));

      expect(engine.maxNumTokens, 2048);
      await engine.close();
    });

    test('no context reported and none asked for is 0', () async {
      setOnPage('noSettingsTokens', true);

      final engine = await Engine.create(webConfig());

      expect(engine.maxNumTokens, 0);
      await engine.close();
    });
  });

  group('createConversationWithDefault', () {
    late web.Engine engine;
    setUp(() async => engine = await webEngine());
    tearDown(() => engine.close());

    final modelDefault = SamplerConfig(topK: 64, topP: 0.95, temperature: 1);

    test('samples with the default it is given', () async {
      await web.createConversationWithDefault(
        engine,
        ConversationConfig(),
        modelDefault,
      );

      expect(
        asMap(
          asMap(list('conversationOptions').single)['sessionConfig'],
        )['samplerParams'],
        {'type': 2, 'temperature': 1.0, 'k': 64, 'p': 0.95, 'seed': 0},
      );
    });

    test('does not say the sampler cannot be read', () async {
      final printed = await printsOf(
        () => web.createConversationWithDefault(
          engine,
          ConversationConfig(),
          modelDefault,
        ),
      );

      expect(printed.where((l) => l.contains('cannot be read')), isEmpty);
    });

    test('a second default with other values is not warned about: neither '
        'sampler is the caller\'s (LiteRT-LM#2080)', () async {
      final printed = await printsOf(() async {
        final first = await web.createConversationWithDefault(
          engine,
          ConversationConfig(),
          modelDefault,
        );
        await exchange(first, 'x', 'y');
        final second = await web.createConversationWithDefault(
          engine,
          ConversationConfig(),
          SamplerConfig(topK: 20, topP: 0.8, temperature: 0.7),
        );
        await exchange(second, 'x', 'y');
      });

      expect(printed.where((l) => l.contains('LiteRT-LM#2080')), isEmpty);
    });

    test('a caller\'s sampler after a default is warned about once, as '
        'natively: it is not applied (LiteRT-LM#2080)', () async {
      final printed = await printsOf(() async {
        final first = await web.createConversationWithDefault(
          engine,
          ConversationConfig(),
          modelDefault,
        );
        await exchange(first, 'x', 'y');
        final second = await engine.createConversation(
          ConversationConfig(
            samplerConfig: SamplerConfig(topK: 1, topP: 1, temperature: 1),
          ),
        );
        await exchange(second, 'x', 'y');
      });

      expect(printed.where((l) => l.contains('LiteRT-LM#2080')), hasLength(1));
    });
  });
}
