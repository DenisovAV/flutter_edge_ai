/// What the pinned `@litert-lm/core` (litertlm_dart's
/// `liteRtLmWebRuntimeVersion`) does on this page with a Gemma 4 E2B web
/// export, asked through its own JS API, below litertlm_dart: the record the
/// web arm's refusals and wiring are decided from. Measured, never asserted,
/// except that every probe ran (Rule 6b):
/// - a text engine with `benchmarkEnabled`: a reply, `getTokenCount()`,
///   `getBenchmarkInfo()`;
/// - how a stream ends when `conversation.cancel()` stops it after its first
///   chunk (done, or rejected), and whether the next send then answers;
/// - a vision engine (`visionBackend: GPU`) and an image part (`data`);
/// - an audio engine (`audioBackend: CPU`, the Gemma 4 audio encoder's
///   declared backend) and an audio part;
/// - `backendConfig.number_of_threads` on the CPU (WebAssembly) backend;
/// - constrained decoding on (`enableConstrainedDecoding`) through a tool call
///   and the turn after its result (google-ai-edge/LiteRT-LM#2434);
/// - `getHistory()` of a conversation created with a preface (system, user,
///   assistant) after one exchange: is the preface in it;
/// - `cancel()` with nothing in flight, then a send;
/// - a stop at the very end: every chunk read, `cancel()`, then the stream's
///   end, and whether the completed exchange is in `getHistory()`;
/// - `backend: GPU` named explicitly for the web export.
/// The model is fetched once into a Blob and handed to every `Engine.create`.
///
/// Run from packages/flutter_edge_ai/example:
///   chromedriver --port=4444 &
///   flutter drive --driver=test_driver/web_embeddings_driver.dart \
///     --target=integration_test/web_litertlm_runtime_probe_test.dart \
///     -d web-server --browser-name=chrome
/// The record is build/web_litertlm_runtime_probe_response.json.
@TestOn('chrome')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:litertlm_dart/internal.dart' show liteRtLmWebRuntime;

import 'web_embeddings_support.dart';

const _modelUrl = String.fromEnvironment(
  'LLM_MODEL_URL',
  defaultValue:
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/'
      'resolve/main/gemma-4-E2B-it-web.litertlm',
);

// The GPU engines leave `backend` out (the runtime's default): 0.18.0
// refuses the web export asked for `backend: GPU` ("Unsupported backend: 2").
const _probe = r'''
window.__litertlmProbe = async (url, image, audio) => {
  await window.litertLmReady;
  const Engine = window.Engine;
  const r = {};
  const attempt = async (name, fn) => {
    try { r[name] = {ok: true, value: await fn()}; }
    catch (e) { r[name] = {ok: false, error: String((e && e.message) || e)}; }
  };
  const text = async (c, message) => {
    let t = '';
    for await (const chunk of c.sendMessageStreaming(message)) {
      t += JSON.stringify(chunk.content);
    }
    return t.slice(0, 400);
  };
  const greedy = {sessionConfig: {samplerParams: {type: 2, k: 1, p: 1, temperature: 1, seed: 1}}};
  const model = await (await fetch(url)).blob();
  r.modelBytes = model.size;

  let e;
  await attempt('create_text_benchmark', async () => {
    e = await Engine.create({model, benchmarkEnabled: true});
    return {backend: e.settings.backend,
            maxNumTokens: e.settings.mainExecutorSettings.maxNumTokens,
            deleteIsPromise: typeof Engine.prototype.delete === 'function'};
  });
  if (e) {
    const c = await e.createConversation(greedy);
    await attempt('send_text', () => text(c, 'Say hello in five words.'));
    await attempt('token_count', () => c.getTokenCount());
    await attempt('benchmark_info', async () => JSON.parse(JSON.stringify(await c.getBenchmarkInfo())));
    await attempt('cancel_after_first_chunk', async () => {
      const it = c.sendMessageStreaming('Count from 1 to 300, one number per line.')[Symbol.asyncIterator]();
      await it.next();
      c.cancel();
      let n = 0;
      try { while (!(await it.next()).done) n++; return 'done after ' + n + ' more chunks'; }
      catch (err) { return 'rejected: ' + ((err && err.message) || err); }
    });
    await attempt('send_after_cancel', () => text(c, 'Say yes.'));
    await attempt('second_send_after_cancel', () => text(c, 'Say no.'));
    // The way back: the cancelled conversation's history, replayed as the
    // preface of a new one.
    let history;
    await attempt('history_after_cancel', async () => {
      history = await c.getHistory();
      return JSON.stringify(history).slice(0, 1500);
    });
    await attempt('rebuilt_from_history', async () => {
      const r2 = await e.createConversation({...greedy, preface: {messages: history}});
      const answer = await text(r2, 'What was the first thing I asked you? Answer in a few words.');
      const count = await r2.getTokenCount();
      await r2.delete();
      return {answer, tokenCount: count};
    });
    await attempt('token_count_after', () => c.getTokenCount());
    // A stream cancelled by its reader (the ReadableStream's own cancel),
    // in a fresh conversation, then the next send.
    const d = await e.createConversation(greedy);
    await attempt('reader_cancel_then_send', async () => {
      const reader = d.sendMessageStreaming('Count from 1 to 300, one number per line.').getReader();
      await reader.read();
      await reader.cancel();
      await new Promise((r) => setTimeout(r, 500));
      return text(d, 'Say yes.');
    });
    await d.delete();
    // A fresh conversation on the same engine after the cancelled one.
    const f = await e.createConversation(greedy);
    await attempt('fresh_conversation_after_cancel', () => text(f, 'Say yes.'));
    await f.delete();
    // P1: a preface and getHistory().
    await attempt('history_with_preface', async () => {
      const p = await e.createConversation({...greedy, preface: {messages: [
        {role: 'system', content: [{type: 'text', text: 'Answer in one word.'}]},
        {role: 'user', content: [{type: 'text', text: 'Say red.'}]},
        {role: 'assistant', content: [{type: 'text', text: 'Red.'}]}]}});
      await text(p, 'Say blue.');
      const h = await p.getHistory();
      await p.delete();
      return {length: h.length, roles: h.map((m) => m.role), history: JSON.stringify(h).slice(0, 1500)};
    });
    // P2: cancel with nothing in flight, then a send.
    await attempt('idle_cancel_then_send', async () => {
      const q = await e.createConversation(greedy);
      q.cancel();
      try { return 'answered: ' + await text(q, 'Say yes.'); }
      catch (err) { return 'rejected: ' + ((err && err.message) || err); }
      finally { await q.delete(); }
    });
    // P3: a stop after the last chunk, before the stream's end is read. The
    // reply is greedy, so a first run counts its chunks.
    await attempt('cancel_at_end', async () => {
      const prompt = 'Say hello.';
      const g = await e.createConversation(greedy);
      let n = 0;
      for await (const _ of g.sendMessageStreaming(prompt)) n++;
      await g.delete();
      const h = await e.createConversation(greedy);
      const it = h.sendMessageStreaming(prompt)[Symbol.asyncIterator]();
      for (let i = 0; i < n; i++) await it.next();
      h.cancel();
      let end;
      try { const last = await it.next(); end = last.done ? 'done' : 'one more chunk'; }
      catch (err) { end = 'rejected: ' + ((err && err.message) || err); }
      let history;
      try { history = JSON.stringify(await h.getHistory()).slice(0, 800); }
      catch (err) { history = 'getHistory rejected: ' + ((err && err.message) || err); }
      let next;
      try { next = 'answered: ' + await text(h, 'Say yes.'); }
      catch (err) { next = 'rejected: ' + ((err && err.message) || err); }
      await h.delete();
      return {chunks: n, end, history, next};
    });
    await c.delete();
    const deleted = e.delete();
    r.engineDeleteReturnsThenable = !!(deleted && typeof deleted.then === 'function');
    await deleted;
  }

  // P4: the GPU named explicitly for the web export.
  await attempt('explicit_gpu_backend', async () => {
    const x = await Engine.create({model, backend: 4});
    const s = {backend: x.settings.backend};
    await x.delete();
    return s;
  });

  let t;
  await attempt('constrained_decoding_tool_round_trip', async () => {
    t = await Engine.create({model});
    const c = await t.createConversation({
      ...greedy,
      enableConstrainedDecoding: true,
      preface: {tools: [{type: 'function', function: {name: 'get_weather', description: 'The weather in a city', parameters: {type: 'object', properties: {city: {type: 'string'}}, required: ['city']}}}]},
    });
    const first = [];
    for await (const chunk of c.sendMessageStreaming('What is the weather in Paris? Use the tool.')) first.push(chunk);
    const second = await text(c, {role: 'tool', content: [{type: 'tool_response', name: 'get_weather', response: {temperature: 21, sky: 'clear'}}]});
    let third = '';
    for await (const chunk of c.sendMessageStreaming('Thanks. And in one word, is that warm?')) third += JSON.stringify(chunk);
    third = third.slice(0, 400);
    await c.delete();
    return {first: JSON.stringify(first).slice(0, 400), second, third};
  });
  if (t) await t.delete();

  let v;
  await attempt('create_vision', async () => {
    v = await Engine.create({model, visionBackend: 4, maxNumImages: 1});
    return {visionBackend: v.settings.visionBackend};
  });
  if (v) {
    const c = await v.createConversation(greedy);
    await attempt('image_and_text', () => text(c, {role: 'user', content: [
      {type: 'image', data: image},
      {type: 'text', text: 'What shape is drawn in this image? Answer in one word.'}]}));
    await c.delete();
    await v.delete();
  }

  let a;
  await attempt('create_audio', async () => {
    a = await Engine.create({model, audioBackend: 3});
    return {audioBackend: a.settings.audioBackend};
  });
  if (a) {
    const c = await a.createConversation(greedy);
    await attempt('audio_and_text', () => text(c, {role: 'user', content: [
      {type: 'audio', data: audio},
      {type: 'text', text: 'Transcribe this audio.'}]}));
    await c.delete();
    await a.delete();
  }

  await attempt('cpu_default', async () => {
    const x = await Engine.create({model, backend: 3});
    const c = await x.createConversation(greedy);
    const s = {backend: x.settings.backend, reply: await text(c, 'Say hi.')};
    await c.delete();
    await x.delete();
    return s;
  });
  await attempt('cpu_number_of_threads', async () => {
    const x = await Engine.create({model, backend: 3,
      mainExecutorSettings: {backendConfig: {number_of_threads: 2}}});
    const s = {backend: x.settings.backend,
               backendConfig: JSON.parse(JSON.stringify(x.settings.mainExecutorSettings.backendConfig))};
    const c = await x.createConversation(greedy);
    s.reply = await text(c, 'Say hi.');
    await c.delete();
    await x.delete();
    return s;
  });
  return JSON.stringify(r);
};
''';

Future<JSUint8Array> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes).toJS;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reportTo('web_litertlm_runtime_probe_response');

  testWidgets('$liteRtLmWebRuntime with Gemma 4 E2B: what it does when asked '
      'directly', (tester) async {
    globalContext.callMethod('eval'.toJS, _probe.toJS);
    final result = await tester.runAsync(() async {
      final image = await _asset('assets/eg2_vision/circle.png');
      final audio = await _asset('assets/eg2_audio/kitchen_lights.wav');
      return globalContext
          .callMethod<JSPromise<JSString>>(
            '__litertlmProbe'.toJS,
            _modelUrl.toJS,
            image,
            audio,
          )
          .toDart;
    });
    final record = jsonDecode(result!.toDart) as Map<String, Object?>;
    report('runtime', liteRtLmWebRuntime);
    record.forEach(report);
    // ignore: avoid_print
    print('PROBE ${jsonEncode(record)}');
    for (final probe in [
      'create_text_benchmark',
      'cancel_after_first_chunk',
      'send_after_cancel',
      'history_after_cancel',
      'rebuilt_from_history',
      'history_with_preface',
      'idle_cancel_then_send',
      'cancel_at_end',
      'explicit_gpu_backend',
      'constrained_decoding_tool_round_trip',
      'create_vision',
      'create_audio',
      'cpu_default',
      'cpu_number_of_threads',
    ]) {
      expect(record, contains(probe), reason: '$probe never ran');
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
