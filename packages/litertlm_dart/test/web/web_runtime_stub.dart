// A stub `@litert-lm/core` LLM runtime for the browser tests, defined on the
// page in plain JS: the module the page hands over, `window.litertLm`, with
// its `Engine` (with the prototype members the release calls) and conversations whose `sendMessageStreaming` returns a real
// `ReadableStream` the test feeds chunk by chunk. It does what 0.19.0 was
// measured to do (2026-11-23, web_litertlm_runtime_probe_test.dart):
// - `cancel()` while a stream is generating rejects it with "Task cancelled",
//   and every later send on that conversation fails the same way;
// - `cancel()` with nothing in flight, or after the last chunk, changes
//   nothing: the stream ends `done` and the conversation keeps working;
// - `getHistory()` holds the completed exchanges only, never the preface; a
//   user message sent as a string comes back with that string as content;
// - `getTokenCount()` runs on the engine's executor mutex: a test can hold
//   it, as a generation that rejected but has not left the module does;
// - an engine's `delete()` is a Promise, a conversation's returns nothing;
// - a send the runtime refuses before it generates ([refuseNextSend]) closes
//   its stream with no chunk, as 0.20.0 does (`sendMessageStreaming` drops
//   the result of `sendMessageAsync`), the message kept at the end of the
//   history with no reply.
// The page sets no other global of the runtime: the module's `Backend` enum
// (`window.litertLm.Backend`) is the pinned release's ([pinnedBackends])
// unless a test installs another layout ([backends019], [backends020]).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

const _stub = r'''
(() => {
  const p = window.__page = {
    createSettings: [], conversationOptions: [], sent: [],
    cancels: 0, conversationDeletes: 0, engineDeletes: 0, streams: [],
    tokenCounts: 0, fences: [], histories: [], conversations: [],
    resolvedBackend: 3, maxNumTokens: 4096,
    createError: null, conversationError: null, conversationErrorAfter: null,
    historyError: null, holdFence: false, holdHistory: false,
    stuckOnCancel: false, deleteError: null, missingMember: null,
    noSettingsBackend: false, noSettingsTokens: false,
    resolvedVisionBackend: null, resolvedAudioBackend: null,
    // What getTokenCount() answers: the tokens a conversation holds.
    tokenCount: 7,
  };
  const open = () => p.streams.find((s) => !s.closed);
  const contextFull = 'Max number of tokens reached, the context window is full.';
  // The image parts of a message.
  const images = (m) => (m && Array.isArray(m.content))
    ? m.content.filter((x) => x.type === 'image').length : 0;
  const conversation = (options, maxImages) => {
    const preface = (options && options.preface && options.preface.messages) || [];
    const c = {dead: false, failed: false, history: [],
               images: preface.reduce((n, m) => n + images(m), 0)};
    c.sendMessageStreaming = (message) => {
      p.sent.push(message);
      // As 0.20.0 for a send `sendMessageAsync` refuses synchronously: the
      // message stays in the history, nothing is generated, the stream
      // closes empty.
      if (p.refuseNextSend) {
        p.refuseNextSend = false;
        if (!p.refusedBeforeHistory) c.history.push(asHistory(message));
        return new ReadableStream({start(ctl) { queueMicrotask(() => ctl.close()); }});
      }
      // A bare iterator (no Symbol.asyncIterator) whose step has no `done`.
      if (p.malformed) return {next: async () => ({value: 1})};
      // A stream whose iterator cannot be read.
      if (p.unreadable) {
        return new Proxy({}, {get() { throw new Error('unreadable stream'); }});
      }
      let controller;
      const stream = new ReadableStream({start(ctl) { controller = ctl; }});
      const entry = {controller, conversation: c, message, closed: false,
                     generated: false, text: ''};
      p.streams.push(entry);
      if (c.dead) {
        entry.closed = true;
        queueMicrotask(() => controller.error(new Error('Task cancelled')));
      } else if (c.full) {
        // As 0.19.0 once the context window is full (N3): every send refused.
        entry.closed = true;
        queueMicrotask(() => controller.error(new Error(contextFull)));
      } else if (c.failed) {
        entry.closed = true;
        queueMicrotask(() => controller.error(new Error('Task failed with state: 7')));
      } else if (c.images + images(message) > maxImages) {
        // As 0.19.0: an image past the reservation fails the turn, the
        // message stays in the history unanswered, and the conversation
        // refuses every later send.
        entry.closed = true;
        c.failed = true;
        c.history.push(asHistory(message));
        queueMicrotask(() => controller.error(
          new Error('Image index ' + maxImages + ' must be less than ' + maxImages + '.')));
      } else {
        c.images += images(message);
      }
      return stream;
    };
    c.cancel = () => {
      p.cancels++;
      const s = p.streams.find((s) => s.conversation === c && !s.closed);
      if (!s) return; // nothing in flight: nothing changes
      if (s.generated) {
        // After the last chunk: the stream ends on its own.
        s.closed = true;
        s.controller.close();
        return;
      }
      c.dead = true;
      if (p.stuckOnCancel) return; // a generation that never ends
      s.closed = true;
      s.controller.error(new Error('Task cancelled'));
    };
    c.getHistory = () => {
      if (p.historyError) return Promise.reject(new Error(p.historyError));
      if (p.oddMediaInHistory) {
        return Promise.resolve([...c.history, {role: 'user', content: [
          {type: 'image', blob: 42}]}, {role: 'assistant', content: 'x'}]);
      }
      if (p.holdHistory) {
        return new Promise((resolve) => p.histories.push(() => resolve(c.history)));
      }
      return Promise.resolve([...c.history, ...(p.historyTail || [])]);
    };
    c.getTokenCount = () => {
      p.tokenCounts++;
      // As 0.19.0 (N5): a conversation counts nothing until something was
      // prefilled on it; a refused message is not counted.
      const n = c.prefilled ? p.tokenCount : 0;
      if (p.holdFence) return new Promise((resolve) => p.fences.push(() => resolve(n)));
      return Promise.resolve(n);
    };
    c.delete = () => {
      p.conversationDeletes++;
      if (p.deleteError) throw new Error(p.deleteError);
    };
    if (p.missingMember) delete c[p.missingMember];
    return c;
  };
  // Every chunk generated, the stream not ended yet.
  // 0.19.0 returns an image or audio part's bytes as {bytes: [...]}.
  const asHistory = (message) => typeof message === 'string'
    ? {role: 'user', content: message}
    : {
        ...message,
        content: message.content.map((p) => typeof p.blob === 'string'
          ? {...p, blob: {bytes: Array.from(atob(p.blob), (c) => c.charCodeAt(0))}}
          : p),
      };
  window.__generated = () => {
    const s = open();
    s.generated = true;
    s.conversation.prefilled = true;
    const reply = {role: 'assistant', content: [{type: 'text', text: s.text}]};
    if (s.toolCalls) reply.tool_calls = s.toolCalls;
    s.conversation.history.push(asHistory(s.message), reply);
  };
  // A reply that ends with no chunk: the model answered nothing, and the
  // history holds the message and an empty assistant entry.
  window.__emptyReply = () => {
    const s = open();
    s.generated = true;
    s.conversation.prefilled = true;
    s.conversation.history.push(asHistory(s.message),
      {role: 'assistant', content: [{type: 'text', text: ''}]});
    s.closed = true;
    s.controller.close();
  };
  window.__step = (text) => {
    const s = open();
    s.conversation.prefilled = true;
    s.text += text;
    s.controller.enqueue({role: 'assistant', content: [{type: 'text', text}]});
  };
  window.__chunk = (json) => {
    const s = open();
    s.conversation.prefilled = true;
    const chunk = JSON.parse(json);
    // A reply's calls stay in the history with it, as the runtime keeps them.
    if (chunk.tool_calls) s.toolCalls = chunk.tool_calls;
    s.controller.enqueue(chunk);
  };
  // A chunk JSON.stringify cannot write.
  window.__unwritable = () => open().controller.enqueue({n: 1n});
  window.__end = () => {
    const s = open();
    if (!s.generated) window.__generated();
    s.closed = true;
    s.controller.close();
  };
  window.__fail = (message) => {
    const s = open();
    s.closed = true;
    // As 0.19.0: a failed turn stays in the history unanswered, and the
    // conversation refuses every later send.
    s.conversation.failed = true;
    s.conversation.history.push(asHistory(s.message));
    s.controller.error(new Error(message));
  };
  // The conversation's context window fills: as 0.19.0 (N3), the send is
  // refused, and so is every later one.
  window.__contextFull = () => {
    const s = open();
    s.closed = true;
    s.conversation.full = true;
    s.controller.error(new Error(contextFull));
  };
  // A message longer than the room the window has left: as 0.19.0 (N5), it
  // is refused, kept at the end of the history, and the conversation refuses
  // every later send.
  // [counts] is "X,Y" as the refusal names them: X the tokens that call
  // would prefill, Y the window.
  window.__tooLong = (counts) => {
    const [x, y] = (counts || '5000,4096').split(',');
    const s = open();
    s.closed = true;
    s.conversation.failed = true;
    s.conversation.history.push(asHistory(s.message));
    s.controller.error(new Error(
      'Input token ids are too long. Exceeding the maximum number of tokens allowed: ' + x + ' >= ' + y));
  };
  window.__releaseFences = () => { for (const f of p.fences.splice(0)) f(); };
  window.__releaseHistories = () => { for (const f of p.histories.splice(0)) f(); };
  window.__releaseConversations = () => { for (const f of p.conversations.splice(0)) f(); };
  const Engine = function Engine() {};
  Engine.prototype.createConversation = function () {};
  Engine.prototype.delete = function () {};
  Engine.create = async (settings) => {
    p.createSettings.push(settings);
    if (p.createError) throw new Error(p.createError);
    const settingsOut = {mainExecutorSettings: {}};
    if (!p.noSettingsBackend) settingsOut.backend = p.resolvedBackend;
    if (!p.noSettingsTokens) settingsOut.mainExecutorSettings.maxNumTokens = p.maxNumTokens;
    if (p.resolvedVisionBackend !== null) settingsOut.visionBackend = p.resolvedVisionBackend;
    if (p.resolvedAudioBackend !== null) settingsOut.audioBackend = p.resolvedAudioBackend;
    return {
      settings: settingsOut,
      createConversation: async (options) => {
        if (p.holdConversation) {
          await new Promise((resolve) => p.conversations.push(resolve));
        }
        p.conversationOptions.push(options);
        if (p.conversationError) throw new Error(p.conversationError);
        if (p.conversationErrorAfter !== null &&
            p.conversationOptions.length > p.conversationErrorAfter) {
          throw new Error('Rebuild refused');
        }
        return conversation(options,
          (settings.mainExecutorSettings && settings.mainExecutorSettings.maxNumImages) || 0);
      },
      delete: async () => {
        p.engineDeletes++;
        if (p.deleteError) throw new Error(p.deleteError);
      },
    };
  };
  // Beside whatever another stub of the same page put in the module.
  window.litertLm = Object.assign(window.litertLm || {}, {Engine});
  window.litertLmReady = Promise.resolve(window.litertLm);
})();
''';

JSObject get page => globalContext['__page']! as JSObject;
int count(String key) => (page[key]! as JSNumber).toDartInt;
List<Object?> list(String key) =>
    (page[key]! as JSArray<JSAny?>).toDart.map((v) => v.dartify()).toList();
void setOnPage(String key, Object? value) => page[key] = value.jsify();
void js(String name, [String? arg]) => arg == null
    ? globalContext.callMethod(name.toJS)
    : globalContext.callMethod(name.toJS, arg.toJS);

/// `Backend` of `@litert-lm/core` 0.19.0 (`wasm_binding_types.js`).
const backends019 = {
  'UNSPECIFIED': 0,
  'CPU_ARTISAN': 1,
  'GPU_ARTISAN': 2,
  'CPU': 3,
  'GPU': 4,
  'GOOGLE_TENSOR_ARTISAN': 5,
  'NPU': 6,
};

/// `Backend` of `@litert-lm/core` 0.20.0: CPU_ARTISAN removed, the rest
/// renumbered.
const backends020 = {
  'UNSPECIFIED': 0,
  'GPU_ARTISAN': 1,
  'CPU': 2,
  'GPU': 3,
  'GOOGLE_TENSOR_ARTISAN': 4,
  'NPU': 5,
};

/// `Backend` of the release litertlm_dart pins
/// (`liteRtLmWebRuntimeVersion`), the stub's unless a test installs another.
const pinnedBackends = backends020;

/// The pinned release's id for [name] (`CPU`, `GPU`, `GPU_ARTISAN`, …).
int backendId(String name) => pinnedBackends[name]!;

/// Installs the stub with [backends] as the module's `Backend` (none when
/// null); the engine resolves to its `GPU`.
void installRuntime({Map<String, int>? backends = pinnedBackends}) {
  globalContext.callMethod('eval'.toJS, _stub.toJS);
  if (backends != null) {
    stubModule['Backend'] = backends.jsify();
    setOnPage('resolvedBackend', backends['GPU']);
  } else {
    stubModule.delete('Backend'.toJS);
  }
}

/// The page's `window.litertLm`, as the stub sets it.
JSObject get stubModule => globalContext['litertLm']! as JSObject;

void removeRuntime() {
  for (final key in ['litertLmReady', 'litertLm', '__page']) {
    globalContext.delete(key.toJS);
  }
}

/// Lets the microtasks and the stream's own callbacks run.
Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

EngineConfig webConfig({Backend backend = const Backend.gpu(), int? tokens}) =>
    EngineConfig(
      modelPath: 'blob:https://example.com/model',
      backend: backend,
      maxNumTokens: tokens,
    );

/// An engine on a page lock of its own, so a poisoned lock stays in its test.
Future<web.Engine> webEngine({web.LiteRtLmPageLock? lock}) =>
    web.createWebEngine(webConfig(), pageLock: lock ?? web.LiteRtLmPageLock());

Map<String, Object?> asMap(Object? value) =>
    (value! as Map).cast<String, Object?>();

/// The preface messages of the [index]th conversation the runtime created.
List<Object?>? prefaceMessages(int index) =>
    asMap(asMap(list('conversationOptions')[index])['preface'])['messages']
        as List<Object?>?;

/// A user message of [text] as the preface holds it.
Map<String, Object?> userPart(String text) => {
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
};

/// A reply of [text] as the preface holds it.
Map<String, Object?> assistantPart(String text) => {
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': text},
  ],
};

/// Sends [text] on [conversation], streams [reply] and ends the turn.
Future<void> exchange(
  Conversation conversation,
  String text,
  String reply,
) async {
  final done = conversation.sendMessageStream(Message.user(text)).drain<void>();
  await settle();
  js('__step', reply);
  js('__end');
  await done;
}

/// Sends [text], streams [partial] and stops the turn mid-reply.
Future<void> stoppedExchange(
  Conversation conversation,
  String text,
  String partial,
) async {
  final done = conversation.sendMessageStream(Message.user(text)).drain<void>();
  await settle();
  if (partial.isNotEmpty) js('__step', partial);
  await settle();
  conversation.cancel();
  await done;
}

/// An error of type [T] whose message contains [message].
TypeMatcher<T> errorWith<T>(String message) =>
    isA<T>().having((e) => '$e', 'message', contains(message));

/// Throws an error of type [T] whose message contains [message].
Matcher throwsWith<T>(String message) => throwsA(errorWith<T>(message));

/// Collects what [body] prints.
Future<List<String>> printsOf(Future<void> Function() body) async {
  final printed = <String>[];
  await runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => printed.add(line),
    ),
  );
  return printed;
}
