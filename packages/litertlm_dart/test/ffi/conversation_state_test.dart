// The calls that read a conversation's own state (Kotlin's and Swift's
// getTokenCount, renderMessageIntoString, renderPrefaceIntoString, clone),
// down to the C API through fake bindings, and through the recovering and
// virtual handles above it.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:litertlm_dart/bindings.dart'
    show LiteRtLmBindings, LiteRtLmConversation;
import 'package:litertlm_dart/internal_io.dart';
import 'package:test/test.dart';

/// A client with an engine and fake conversation calls: the token count is
/// the conversation's address, rendering echoes what it was given, and a
/// clone is the address plus 0x100.
({LiteRtLmFfiClient client, List<String> calls}) _client() {
  final calls = <String>[];
  final keep = <Pointer<Utf8>>[];
  final callables = <NativeCallable<Function>>[];
  final symbols = <String, Pointer<Void>>{};
  void add<T extends Function>(String name, NativeCallable<T> callable) {
    callables.add(callable);
    symbols[name] = callable.nativeFunction.cast();
  }

  Pointer<Char> text(String s) {
    final p = s.toNativeUtf8();
    keep.add(p);
    return p.cast();
  }

  add(
    'litert_lm_conversation_get_token_count',
    NativeCallable<
      UnsignedInt Function(Pointer<LiteRtLmConversation>, Pointer<Size>)
    >.isolateLocal((Pointer<LiteRtLmConversation> c, Pointer<Size> out) {
      calls.add('count(${c.address})');
      out.value = c.address;
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_conversation_render_message_to_string',
    NativeCallable<
      UnsignedInt Function(
        Pointer<LiteRtLmConversation>,
        Pointer<Char>,
        Pointer<Pointer<Char>>,
      )
    >.isolateLocal((
      Pointer<LiteRtLmConversation> c,
      Pointer<Char> json,
      Pointer<Pointer<Char>> out,
    ) {
      final message = json.cast<Utf8>().toDartString();
      calls.add('render(${c.address}, $message)');
      out.value = text('<turn>$message');
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_conversation_render_preface_to_string',
    NativeCallable<
      UnsignedInt Function(
        Pointer<LiteRtLmConversation>,
        Pointer<Pointer<Char>>,
      )
    >.isolateLocal((
      Pointer<LiteRtLmConversation> c,
      Pointer<Pointer<Char>> out,
    ) {
      calls.add('preface(${c.address})');
      out.value = text('<preface>');
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_conversation_clone',
    NativeCallable<
      UnsignedInt Function(
        Pointer<LiteRtLmConversation>,
        Pointer<Pointer<LiteRtLmConversation>>,
      )
    >.isolateLocal((
      Pointer<LiteRtLmConversation> c,
      Pointer<Pointer<LiteRtLmConversation>> out,
    ) {
      calls.add('clone(${c.address})');
      out.value = Pointer.fromAddress(c.address + 0x100);
      return 0;
    }, exceptionalReturn: 1),
  );
  add(
    'litert_lm_conversation_delete',
    NativeCallable<Void Function(Pointer<LiteRtLmConversation>)>.isolateLocal(
      (Pointer<LiteRtLmConversation> c) => calls.add('delete(${c.address})'),
    ),
  );
  add(
    'litert_lm_clear_last_error',
    NativeCallable<Void Function()>.isolateLocal(() {}),
  );
  add(
    'litert_lm_get_last_error_message',
    NativeCallable<Pointer<Char> Function()>.isolateLocal(() => nullptr),
  );
  addTearDown(() {
    for (final c in callables) {
      c.close();
    }
    keep.forEach(malloc.free);
  });
  final client = LiteRtLmFfiClient()
    ..streamForTest(
      createProxy: (_, _, _, _, _, _) => nullptr,
      freeString: (_) {},
      destroyProxy: (_) {},
    )
    ..bindingsForTest = LiteRtLmBindings.fromLookup(
      <T extends NativeType>(String name) => symbols[name]!.cast<T>(),
    );
  return (client: client, calls: calls);
}

/// A live conversation whose state calls answer at once, and whose turn the
/// test ends.
class _Live implements ConversationHandle, ConversationStateAccess {
  _Live(this.id);

  final int id;
  final turnEnd = Completer<void>();
  final clones = <_Live>[];

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) async* {
    await turnEnd.future;
    yield '{"role":"assistant","content":[{"type":"text","text":"ok"}]}';
  }

  @override
  Future<int> kvTokenCount() async => id;

  @override
  Future<String> renderMessage(String messageJson) async => 'r$id';

  @override
  Future<String> renderPreface() async => 'p$id';

  @override
  Future<ConversationHandle> cloneHandle() async {
    final clone = _Live(id + 1);
    clones.add(clone);
    return clone;
  }

  @override
  NativeLastTurnEnd? get lastTurnEnd => NativeLastTurnEnd.completed;

  @override
  int? get lastTurnCode => 0;

  @override
  void cancelGeneration() {}

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a native conversation counts, renders and clones through the C '
      'API; the clone is a conversation of the client', () async {
    final (:client, :calls) = _client();
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x7000);
    client.registerLiveForTest(conv);
    final handle = LiteRtLmConversationHandle.forTest(
      client,
      conversation: conv,
    );
    expect(await handle.kvTokenCount(), 0x7000);
    expect(await handle.renderPreface(), '<preface>');
    expect(
      await handle.renderMessage('{"role":"user"}'),
      '<turn>{"role":"user"}',
    );
    final clone = await handle.cloneHandle();
    expect(await clone.kvTokenCount(), 0x7100);
    expect(calls, [
      'count(${0x7000})',
      'preface(${0x7000})',
      'render(${0x7000}, {"role":"user"})',
      'clone(${0x7000})',
      'count(${0x7100})',
    ]);
    // A conversation the client no longer holds is refused before native.
    client.deleteConversationForTest(conv);
    expect(handle.kvTokenCount(), throwsStateError);
  });

  test('a recovering handle reads its state after the turn in flight, and '
      'its clone records the same history over the native clone', () async {
    final live = _Live(1);
    final handle = RecoveringConversationHandle(
      live,
      reopen: (_) async => _Live(99),
      toolCallsOf: nativeToolCalls,
    );
    final turn = handle.chatRawMessage('{"role":"user","content":[]}').toList();
    // The turn has taken the conversation.
    await pumpEventQueue();
    var counted = false;
    final count = handle.kvTokenCount().then((n) {
      counted = true;
      return n;
    });
    await pumpEventQueue();
    expect(counted, isFalse, reason: 'the turn has not ended');
    live.turnEnd.complete();
    await turn;
    expect(await count, 1);
    expect(await handle.renderPreface(), 'p1');
    final clone = await handle.cloneHandle();
    expect(clone, isA<RecoveringConversationHandle>());
    expect(await (clone as ConversationStateAccess).kvTokenCount(), 2);
    expect(live.clones, hasLength(1));
  });

  test('a virtual session clones as a new session with its history, and '
      'has no state of its own to count or render', () async {
    final history = [
      {'role': 'user', 'content': 'hi'},
      {'role': 'assistant', 'content': 'hello'},
    ];
    final handle = VirtualConversationHandle(
      client: LiteRtLmFfiClient(),
      systemMessage: 'be brief',
      toolsJson: null,
      sampling: const Sampler(temperature: 1, topK: 1, topP: 1, randomSeed: 0),
      samplingExplicit: false,
      multimodalOrder: MediaOrder.imagesAudioText,
      filterChannelContent: true,
      toolCallsOf: nativeToolCalls,
      extras: const ConversationExtras(chatTemplate: 't'),
      initialHistory: history,
    );
    final clone = await handle.cloneHandle() as VirtualConversationHandle;
    expect(virtualConversationHistoryForTest(clone), history);
    expect(clone.systemMessage, 'be brief');
    expect(clone.extras.chatTemplate, 't');
    expect(
      identical(
        virtualConversationTokenForTest(clone),
        virtualConversationTokenForTest(handle),
      ),
      isFalse,
    );
    expect(handle.kvTokenCount(), throwsUnsupportedError);
    expect(handle.renderPreface(), throwsUnsupportedError);
  });
}
