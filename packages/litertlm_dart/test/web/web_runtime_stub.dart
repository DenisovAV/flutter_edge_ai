// A stub `@litert-lm/core` LLM runtime for the browser tests, defined on the
// page in plain JS: `window.Engine` (with the prototype members the release
// calls) and conversations whose `sendMessageStreaming` returns a real
// `ReadableStream` the test feeds chunk by chunk. It does what 0.18.0 was
// measured to do (2026-11-23, web_litertlm_runtime_probe_test.dart):
// - `cancel()` while a stream is generating rejects it with "Task cancelled",
//   and every later send on that conversation fails the same way;
// - `cancel()` with nothing in flight, or after the last chunk, changes
//   nothing: the stream ends `done` and the conversation keeps working;
// - `getHistory()` holds the completed exchanges only, never the preface; a
//   user message sent as a string comes back with that string as content;
// - `getTokenCount()` runs on the engine's executor mutex: a test can hold
//   it, as a generation that rejected but has not left the module does;
// - an engine's `delete()` is a Promise, a conversation's returns nothing.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';

const _stub = r'''
(() => {
  const p = window.__page = {
    createSettings: [], conversationOptions: [], sent: [],
    cancels: 0, conversationDeletes: 0, engineDeletes: 0, streams: [],
    tokenCounts: 0, fences: [], histories: [],
    resolvedBackend: 4, maxNumTokens: 4096,
    createError: null, conversationError: null, conversationErrorAfter: null,
    historyError: null, holdFence: false, holdHistory: false,
    stuckOnCancel: false, deleteError: null, missingMember: null,
    noSettingsBackend: false, noSettingsTokens: false,
    resolvedVisionBackend: null, resolvedAudioBackend: null,
  };
  const open = () => p.streams.find((s) => !s.closed);
  // The image parts of a message.
  const images = (m) => (m && Array.isArray(m.content))
    ? m.content.filter((x) => x.type === 'image').length : 0;
  const conversation = (options, maxImages) => {
    const preface = (options && options.preface && options.preface.messages) || [];
    const c = {dead: false, failed: false, history: [],
               images: preface.reduce((n, m) => n + images(m), 0)};
    c.sendMessageStreaming = (message) => {
      p.sent.push(message);
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
      return Promise.resolve(c.history);
    };
    c.getTokenCount = () => {
      p.tokenCounts++;
      if (p.holdFence) return new Promise((resolve) => p.fences.push(() => resolve(7)));
      return Promise.resolve(7);
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
    s.conversation.history.push(
      asHistory(s.message),
      {role: 'assistant', content: [{type: 'text', text: s.text}]});
  };
  window.__step = (text) => {
    const s = open();
    s.text += text;
    s.controller.enqueue({role: 'assistant', content: [{type: 'text', text}]});
  };
  window.__chunk = (json) => open().controller.enqueue(JSON.parse(json));
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
  window.__releaseFences = () => { for (const f of p.fences.splice(0)) f(); };
  window.__releaseHistories = () => { for (const f of p.histories.splice(0)) f(); };
  window.Engine = function Engine() {};
  window.Engine.prototype.createConversation = function () {};
  window.Engine.prototype.delete = function () {};
  window.Engine.create = async (settings) => {
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
  window.litertLmReady = Promise.resolve(window.Engine);
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

void installRuntime() => globalContext.callMethod('eval'.toJS, _stub.toJS);

void removeRuntime() {
  for (final key in ['litertLmReady', 'Engine', '__page']) {
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
