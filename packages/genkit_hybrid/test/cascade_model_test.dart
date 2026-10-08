import 'dart:async';

import 'package:genkit/genkit.dart';
import 'package:genkit_hybrid/src/cascade_model.dart';
import 'package:test/test.dart';

// A real Model that returns [text], optionally throwing (transient) first.
Model _model(String name, {String text = 'ok', bool throwFirst = false}) =>
    Model(
      name: name,
      fn: (request, context) async {
        if (throwFirst) throw Exception('$name unavailable');
        return ModelResponse(
          finishReason: FinishReason.stop,
          message: Message(
            role: Role.model,
            content: [TextPart(text: text)],
          ),
        );
      },
    );

ModelRequest _req() => ModelRequest(messages: []);

void main() {
  test('accept on first -> no escalation', () async {
    final m = cascadeModel(
      branches: {
        'a': _model('a', text: 'A'),
        'b': _model('b', text: 'B'),
      },
      order: ['a', 'b'],
      accept: (r) => true,
    );
    final resp = await m(_req());
    expect(resp.text, 'A');
  });

  test('reject first -> escalate and return second', () async {
    final m = cascadeModel(
      branches: {
        'a': _model('a', text: 'A'),
        'b': _model('b', text: 'B'),
      },
      order: ['a', 'b'],
      accept: (r) => r.text == 'B',
    );
    final resp = await m(_req());
    expect(resp.text, 'B');
  });

  test('reject all -> last response returned anyway', () async {
    final m = cascadeModel(
      branches: {
        'a': _model('a', text: 'A'),
        'b': _model('b', text: 'B'),
      },
      order: ['a', 'b'],
      accept: (r) => false,
    );
    final resp = await m(_req());
    expect(resp.text, 'B');
  });

  test('transient error mid-cascade -> next branch', () async {
    final m = cascadeModel(
      branches: {
        'a': _model('a', throwFirst: true),
        'b': _model('b', text: 'B'),
      },
      order: ['a', 'b'],
      accept: (r) => true,
    );
    final resp = await m(_req());
    expect(resp.text, 'B');
  });

  test('async accept is awaited', () async {
    final m = cascadeModel(
      branches: {
        'a': _model('a', text: 'A'),
        'b': _model('b', text: 'B'),
      },
      order: ['a', 'b'],
      accept: (r) async {
        await Future<void>.delayed(Duration.zero);
        return r.text == 'B';
      },
    );
    final resp = await m(_req());
    expect(resp.text, 'B');
  });

  test('construction validation throws ArgumentError', () {
    expect(
      () => cascadeModel(branches: {}, order: ['a'], accept: (_) => true),
      throwsArgumentError,
    );
    expect(
      () => cascadeModel(
        branches: {'a': _model('a')},
        order: [],
        accept: (_) => true,
      ),
      throwsArgumentError,
    );
    expect(
      () => cascadeModel(
        branches: {'a': _model('a')},
        order: ['x'],
        accept: (_) => true,
      ),
      throwsArgumentError,
    );
  });

  test(
    'a throwing accept propagates — not treated as a transient branch failure',
    () async {
      var bCalls = 0;
      final m = cascadeModel(
        branches: {
          'a': _model('a', text: 'A'),
          'b': Model(
            name: 'b',
            fn: (req, ctx) async {
              bCalls++;
              return ModelResponse(
                finishReason: FinishReason.stop,
                message: Message(
                  role: Role.model,
                  content: [TextPart(text: 'B')],
                ),
              );
            },
          ),
        },
        order: ['a', 'b'],
        accept: (r) => throw StateError('judge bug'),
      );
      await expectLater(m(_req()), throwsA(isA<StateError>()));
      expect(bCalls, 0); // did NOT silently escalate to b
    },
  );

  test('streaming caller gets one final chunk (non-streaming v1)', () async {
    final received = <String>[];
    final m = cascadeModel(
      branches: {'a': _model('a', text: 'A')},
      order: ['a'],
      accept: (r) => true,
    );
    final resp = await m(
      _req(),
      onChunk: (c) => received.add(c.content.first.text ?? ''),
    );
    expect(resp.text, 'A');
    expect(received, ['A']); // exactly one chunk = the final response
  });

  test("a branch gets the caller's context and cancellation token", () async {
    Map<String, dynamic>? seenContext;
    CancellationToken? seenCancel;
    final m = cascadeModel(
      branches: {
        'a': Model(
          name: 'a',
          fn: (request, context) async {
            seenContext = context.context;
            seenCancel = context.cancel;
            return ModelResponse(
              finishReason: FinishReason.stop,
              message: Message(
                role: Role.model,
                content: [TextPart(text: 'A')],
              ),
            );
          },
        ),
      },
      order: ['a'],
      accept: (r) => true,
    );
    final controller = CancellationController();

    await m(_req(), context: {'user': 'u1'}, cancel: controller.token);

    expect(seenContext?['user'], 'u1');
    expect(seenCancel, same(controller.token));
  });
}
