/// What the pinned `@litert-lm/core` (litertlm_dart's
/// `liteRtLmWebRuntimeVersion`) does on this page with Gemma 4 E2B's GPU
/// export (the registry's gemma-4-e2b-it/web-gpu), asked through its own JS
/// API, below litertlm_dart: the record the
/// web arm's refusals and wiring are decided from. Measured, never asserted,
/// except that every probe ran (Rule 6b):
/// - a text engine with `benchmarkEnabled`: a reply, `getTokenCount()`,
///   `getBenchmarkInfo()`;
/// - how a stream ends when `conversation.cancel()` stops it after its first
///   chunk (done, or rejected), and whether the next send then answers;
/// - vision engines (`visionBackend` GPU and CPU, with and without
///   `maxNumImages`) and an image part (`data`); a second image in the same
///   conversation; an image as base64 `blob` in a message and in a preface;
///   the history after an image, and a conversation rebuilt from it with the
///   image as base64;
/// - audio engines (`audioBackend` CPU and GPU) and an audio part, and the
///   history after it; vision and audio in one engine;
/// - `backendConfig.number_of_threads` on the CPU (WebAssembly) backend;
/// - constrained decoding on (`enableConstrainedDecoding`) through a tool call
///   and the turn after its result (google-ai-edge/LiteRT-LM#2434);
/// - `getHistory()` of a conversation created with a preface (system, user,
///   assistant) after one exchange: is the preface in it;
/// - `cancel()` with nothing in flight, then a send;
/// - a stop at the very end: every chunk read, `cancel()`, then the stream's
///   end, and whether the completed exchange is in `getHistory()`;
/// - `backend: GPU` and `GPU_ARTISAN` named explicitly.
/// Every backend id is read from the module the page hands over
/// (`window.litertLm.Backend`, recorded as `backendEnum`), never written here:
/// 0.20.0 renumbered it.
/// The model (2.34 GB) is fetched for every `Engine.create` and handed to it
/// as the response's ReadableStream: a Blob of it would need a `blob:` fetch
/// past Chrome's limit. A local copy (LLM_MODEL_URL) keeps that cheap.
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
      'resolve/cccc664ea93091c52eeb7867ad4e5466357e14f3/'
      'gemma-4-E2B-it-gpu.litertlm',
);

// The GPU engines leave `backend` out (the runtime's default, GPU); the
// explicit forms are probed on their own.
const _probe = r'''
window.__litertlmProbe = async (url, image, audio) => {
  await window.litertLmReady;
  const m = window.litertLm;
  if (!m) {
    throw new Error('window.litertLm is not set: add window.litertLm = m; to '
      + 'the module script of web/index.html');
  }
  const Engine = m.Engine;
  // The module's own Backend ids: 0.20.0 renumbered them (0.19.0: GPU_ARTISAN
  // 2, CPU 3, GPU 4; 0.20.0: 1, 2, 3).
  const B = m.Backend;
  if (!B || ![B.CPU, B.GPU, B.GPU_ARTISAN].every(Number.isInteger)) {
    throw new Error('window.litertLm.Backend is not the module\'s Backend enum');
  }
  const r = {};
  r.backendEnum = {...B};
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
  // A history's media bytes ({bytes: [...]}) as the base64 `blob` a preface
  // takes, as WebConversationHandle._replayable does.
  const toBase64 = (history) => history.map((m) => !Array.isArray(m.content) ? m : {
    ...m,
    content: m.content.map((p) => p.blob && p.blob.bytes
      ? {...p, blob: btoa(String.fromCharCode(...p.blob.bytes))}
      : p),
  });
  const greedy = {sessionConfig: {samplerParams: {type: 2, k: 1, p: 1, temperature: 1, seed: 1}}};
  const stream = async () => (await fetch(url)).body;
  r.modelBytes = Number((await fetch(url, {method: 'HEAD'})).headers.get('content-length'));

  let e;
  await attempt('create_text_benchmark', async () => {
    e = await Engine.create({model: await stream(), benchmarkEnabled: true});
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
    // N2: tool calls in a preface. A stop mid tool call keeps the call
    // (as natively), so a rebuild replays it with or without its response.
    const tools = [{type: 'function', function: {name: 'get_weather', description: 'The weather in a city', parameters: {type: 'object', properties: {city: {type: 'string'}}, required: ['city']}}}];
    const call = {role: 'assistant', tool_calls: [{type: 'function', function: {name: 'get_weather', arguments: {city: 'Paris'}}}]};
    const asked = {role: 'user', content: [{type: 'text', text: 'What is the weather in Paris? Use the tool.'}]};
    const answered = {role: 'tool', content: [{type: 'tool_response', name: 'get_weather', response: {temperature: 21, sky: 'clear'}}]};
    const withPreface = async (messages, next) => {
      const k = await e.createConversation({...greedy, preface: {tools, messages}});
      try { return await text(k, next); } finally { await k.delete(); }
    };
    await attempt('preface_dangling_tool_call', () => withPreface([asked, call], 'Say yes.'));
    await attempt('preface_tool_call_and_response', () => withPreface([asked, call, answered], 'Thanks. Is that warm? One word.'));
    await attempt('preface_from_tool_round_trip_history', async () => {
      const k = await e.createConversation({...greedy, preface: {tools}});
      const first = [];
      for await (const chunk of k.sendMessageStreaming(asked)) first.push(chunk);
      const second = await text(k, answered);
      const h = await k.getHistory();
      await k.delete();
      const answer = await withPreface(h, 'Thanks. Is that warm? One word.');
      return {first: JSON.stringify(first).slice(0, 300), second,
              roles: h.map((m) => m.role), history: JSON.stringify(h).slice(0, 1200), answer};
    });
    await attempt('preface_empty_assistant_text', () => withPreface([
      {role: 'user', content: [{type: 'text', text: 'Why is the sky blue?'}]},
      {role: 'assistant', content: [{type: 'text', text: ''}]}], 'Say yes.'));
    // N3: an empty reply that succeeds, and a reply that fails mid-decode:
    // what each leaves in the history.
    await attempt('history_after_empty_reply', async () => {
      const k = await e.createConversation({...greedy, sessionConfig: {...greedy.sessionConfig, maxOutputTokens: 0}});
      let reply;
      try { reply = 'answered: ' + await text(k, 'Say yes.'); }
      catch (err) { reply = 'rejected: ' + ((err && err.message) || err); }
      const h = await k.getHistory();
      await k.delete();
      return {reply, roles: h.map((m) => m.role), history: JSON.stringify(h).slice(0, 600)};
    });
    await c.delete();
    const deleted = e.delete();
    r.engineDeleteReturnsThenable = !!(deleted && typeof deleted.then === 'function');
    await deleted;
  }

  // N3: a reply that fails mid-decode (the context fills): what the history
  // keeps of it, and whether the conversation answers again.
  await attempt('history_after_failure_mid_decode', async () => {
    const x = await Engine.create({model: await stream(), mainExecutorSettings: {maxNumTokens: 128}});
    try {
      const k = await x.createConversation(greedy);
      let chunks = 0, end;
      try {
        for await (const _ of k.sendMessageStreaming('Count from 1 to 300, one number per line.')) chunks++;
        end = 'done';
      } catch (err) { end = 'rejected: ' + ((err && err.message) || err); }
      const h = await k.getHistory();
      const tokensFull = await k.getTokenCount();
      let next;
      try { next = 'answered: ' + await text(k, 'Say yes.'); }
      catch (err) { next = 'rejected: ' + ((err && err.message) || err); }
      const tokensAfter = await k.getTokenCount();
      const after = await k.getHistory();
      await k.delete();
      // N6: that history, its unanswered tail dropped, as a new
      // conversation's preface: is it refused, and does a send answer?
      const kept = [...after];
      while (kept.length && kept[kept.length - 1].role !== 'assistant') kept.pop();
      let rebuilt, rebuiltTokens;
      try {
        const r = await x.createConversation({...greedy, preface: {messages: kept}});
        rebuiltTokens = await r.getTokenCount();
        try { rebuilt = 'answered: ' + await text(r, 'Say yes.'); }
        catch (err) { rebuilt = 'send rejected: ' + ((err && err.message) || err); }
        await r.delete();
      } catch (err) { rebuilt = 'create rejected: ' + ((err && err.message) || err); }
      return {chunks, end, roles: h.map((m) => m.role), history: JSON.stringify(h).slice(0, 800), next,
              tokensFull, tokensAfter, rolesAfter: after.map((m) => m.role), rebuilt, rebuiltTokens};
    } finally { await x.delete(); }
  });

  // N5: a message longer than the window, after an exchange: is it refused,
  // what does the history keep, and does the conversation rebuilt without it
  // answer a shorter one?
  await attempt('oversized_prompt_then_shorter', async () => {
    const x = await Engine.create({model: await stream(), mainExecutorSettings: {maxNumTokens: 256}});
    try {
      const k = await x.createConversation(greedy);
      const first = await text(k, 'Say yes.');
      const tokensBefore = await k.getTokenCount();
      let oversized;
      try { oversized = 'answered: ' + await text(k, 'Repeat this. ' + 'word '.repeat(600)); }
      catch (err) { oversized = 'rejected: ' + ((err && err.message) || err); }
      const tokensAfter = await k.getTokenCount();
      let same;
      try { same = 'answered: ' + await text(k, 'Say no.'); }
      catch (err) { same = 'rejected: ' + ((err && err.message) || err); }
      const h = await k.getHistory();
      await k.delete();
      const kept = [...h];
      while (kept.length && kept[kept.length - 1].role !== 'assistant') kept.pop();
      let rebuilt, rebuiltTokens, rebuiltTokensAfter;
      try {
        const r = await x.createConversation({...greedy, preface: {messages: kept}});
        rebuiltTokens = await r.getTokenCount();
        try { rebuilt = 'answered: ' + await text(r, 'Say no.'); }
        catch (err) { rebuilt = 'send rejected: ' + ((err && err.message) || err); }
        rebuiltTokensAfter = await r.getTokenCount();
        await r.delete();
      } catch (err) { rebuilt = 'create rejected: ' + ((err && err.message) || err); }
      return {first, tokensBefore, oversized, tokensAfter, same, roles: h.map((m) => m.role),
              kept: kept.length, rebuilt, rebuiltTokens, rebuiltTokensAfter};
    } finally { await x.delete(); }
  });

  // N7: what the count in "Input token ids are too long… X >= Y" holds, and
  // where a one-word message stops fitting behind a long history.
  await attempt('refusal_count_and_room', async () => {
    const x = await Engine.create({model: await stream(), mainExecutorSettings: {maxNumTokens: 128}});
    const counted = (e) => { const m = /(\d+) >= (\d+)/.exec(String((e && e.message) || e)); return m ? [Number(m[1]), Number(m[2])] : String((e && e.message) || e); };
    try {
      const big = 'word '.repeat(200);
      const out = {};
      const a = await x.createConversation(greedy);
      try { await text(a, big); out.fresh = 'answered'; } catch (e) { out.fresh = counted(e); }
      await a.delete();
      const b = await x.createConversation(greedy);
      await text(b, 'Say yes.');
      out.held = await b.getTokenCount();
      try { await text(b, big); out.afterExchange = 'answered'; } catch (e) { out.afterExchange = counted(e); }
      out.heldAfterRefusal = await b.getTokenCount();
      await b.delete();
      // A preface of k words, then 'Hi': accepted or the counts of its refusal.
      out.scan = [];
      for (let k = 90; k <= 130; k += 2) {
        const c = await x.createConversation({...greedy, preface: {messages: [
          {role: 'user', content: [{type: 'text', text: 'word '.repeat(k)}]},
          {role: 'assistant', content: [{type: 'text', text: 'Ok.'}]}]}});
        let r;
        try { await text(c, 'Hi'); r = {k, ok: true, tokens: await c.getTokenCount()}; }
        catch (e) { r = {k, refused: counted(e), tokens: await c.getTokenCount()}; }
        out.scan.push(r);
        await c.delete();
      }
      return out;
    } finally { await x.delete(); }
  });

  // P4: the GPU named explicitly.
  await attempt('explicit_gpu_backend', async () => {
    const x = await Engine.create({model: await stream(), backend: B.GPU});
    const s = {backend: x.settings.backend};
    await x.delete();
    return s;
  });

  await attempt('explicit_gpu_artisan_backend', async () => {
    const x = await Engine.create({model: await stream(), backend: B.GPU_ARTISAN});
    const s = {backend: x.settings.backend};
    await x.delete();
    return s;
  });

  let t;
  await attempt('constrained_decoding_tool_round_trip', async () => {
    t = await Engine.create({model: await stream()});
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

  // Vision: GPU_ARTISAN models reserve image space up front (maxNumImages).
  for (const [name, settings] of [
    ['vision_gpu', {visionBackend: B.GPU, mainExecutorSettings: {maxNumImages: 1}}],
    ['vision_gpu_no_max_images', {visionBackend: B.GPU}],
    ['vision_cpu', {visionBackend: B.CPU, mainExecutorSettings: {maxNumImages: 1}}],
  ]) {
    let v;
    await attempt('create_' + name, async () => {
      v = await Engine.create({model: await stream(), ...settings});
      return JSON.parse(JSON.stringify(v.settings));
    });
    if (v) {
      const c = await v.createConversation(greedy);
      await attempt(name + '_image_and_text', () => text(c, {role: 'user', content: [
        {type: 'image', data: image},
        {type: 'text', text: 'What shape is drawn in this image? Answer in one word.'}]}));
      await attempt(name + '_text_after_image', () => text(c, 'And its colour, in one word?'));
      if (name === 'vision_gpu') {
        let b64 = '';
        for (const x of image) b64 += String.fromCharCode(x);
        b64 = btoa(b64);
        // The native message form: the image as base64 in `blob`.
        await attempt('image_as_base64_blob', async () => {
          const c2 = await v.createConversation(greedy);
          const answer = await text(c2, {role: 'user', content: [
            {type: 'image', blob: b64},
            {type: 'text', text: 'Which shape? One word.'}]});
          await c2.delete();
          return answer;
        });
        await attempt('preface_with_image_blob', async () => {
          const r3 = await v.createConversation({...greedy, preface: {messages: [
            {role: 'user', content: [{type: 'image', blob: b64},
              {type: 'text', text: 'Remember this image.'}]},
            {role: 'assistant', content: [{type: 'text', text: 'Done.'}]}]}});
          const answer = await text(r3, 'What shape was in the image? One word.');
          await r3.delete();
          return answer;
        });
        let history;
        await attempt('history_with_image', async () => {
          history = await c.getHistory();
          return JSON.stringify(history).slice(0, 300);
        });
        // The history's image as its bytes ({bytes: [...]}) turned into the
        // base64 `blob` a message takes.
        await attempt('rebuilt_from_history_with_image_as_base64', async () => {
          const converted = history.map((m) => !Array.isArray(m.content) ? m : {
            ...m,
            content: m.content.map((p) => p.blob && p.blob.bytes
              ? {...p, blob: btoa(String.fromCharCode(...p.blob.bytes))}
              : p),
          });
          const r2 = await v.createConversation({...greedy, preface: {messages: converted}});
          const answer = await text(r2, 'What shape was in the image? One word.');
          await r2.delete();
          return answer;
        });
        // maxNumImages counts the images of a conversation, not of a message.
        await attempt('second_image_same_conversation', () => text(c, {role: 'user', content: [
          {type: 'image', data: image},
          {type: 'text', text: 'And this one, which shape? One word.'}]}));
        // M1: after a runtime error that is not a cancel, is the failed
        // message in the history, and does the conversation still answer?
        let failedHistory;
        await attempt('history_after_failed_turn', async () => {
          failedHistory = await c.getHistory();
          return {length: failedHistory.length,
                  roles: failedHistory.map((m) => m.role),
                  lastUser: JSON.stringify(failedHistory.filter((m) => m.role === 'user').pop()).slice(0, 200)};
        });
        await attempt('send_after_failed_turn', () => text(c, 'Say yes.'));
        // N1: the rebuild as WebConversationHandle does it: the unanswered
        // tail dropped.
        await attempt('rebuilt_after_failed_turn_trimmed', async () => {
          const trimmed = [...failedHistory];
          while (trimmed.length && trimmed[trimmed.length - 1].role !== 'assistant') trimmed.pop();
          const r6 = await v.createConversation({...greedy, preface: {messages: toBase64(trimmed)}});
          const answer = await text(r6, 'Say yes.');
          await r6.delete();
          return {messages: trimmed.length, answer};
        });
        await attempt('rebuilt_after_failed_turn', async () => {
          const r4 = await v.createConversation({...greedy, preface: {messages: toBase64(failedHistory)}});
          const answer = await text(r4, 'Say yes.');
          await r4.delete();
          return answer;
        });
      }
      await c.delete();
      await v.delete();
    }
  }

  for (const [name, settings] of [
    ['audio_cpu', {audioBackend: B.CPU}],
    ['audio_gpu', {audioBackend: B.GPU}],
  ]) {
    let a;
    await attempt('create_' + name, async () => {
      a = await Engine.create({model: await stream(), ...settings});
      return JSON.parse(JSON.stringify(a.settings));
    });
    if (a) {
      const c = await a.createConversation(greedy);
      await attempt(name + '_and_text', () => text(c, {role: 'user', content: [
        {type: 'audio', data: audio},
        {type: 'text', text: 'Transcribe this audio.'}]}));
      if (name === 'audio_cpu') {
        let audioHistory;
        await attempt('history_with_audio', async () => {
          audioHistory = await c.getHistory();
          return JSON.stringify(audioHistory).slice(0, 200);
        });
        // M2: a conversation rebuilt from a history that holds audio, its
        // bytes turned into base64 as a rebuild does.
        await attempt('rebuilt_from_history_with_audio_as_base64', async () => {
          const r5 = await a.createConversation({...greedy, preface: {messages: toBase64(audioHistory)}});
          const answer = await text(r5, 'What did the audio ask for? A few words.');
          await r5.delete();
          return answer;
        });
      }
      await c.delete();
      await a.delete();
    }
  }

  // Vision and audio in one engine, as a native multimodal load.
  let va;
  await attempt('create_vision_and_audio', async () => {
    va = await Engine.create({model: await stream(), visionBackend: B.GPU,
      audioBackend: B.CPU, mainExecutorSettings: {maxNumImages: 1}});
    return JSON.parse(JSON.stringify(va.settings));
  });
  if (va) {
    const c = await va.createConversation(greedy);
    await attempt('vision_and_audio_both', () => text(c, {role: 'user', content: [
      {type: 'image', data: image}, {type: 'audio', data: audio},
      {type: 'text', text: 'Describe the image and transcribe the audio.'}]}));
    await c.delete();
    await va.delete();
  }

  await attempt('cpu_default', async () => {
    const x = await Engine.create({model: await stream(), backend: B.CPU});
    const c = await x.createConversation(greedy);
    const s = {backend: x.settings.backend, reply: await text(c, 'Say hi.')};
    await c.delete();
    await x.delete();
    return s;
  });
  await attempt('cpu_number_of_threads', async () => {
    const x = await Engine.create({model: await stream(), backend: B.CPU,
      mainExecutorSettings: {backendConfig: {number_of_threads: 2}}});
    const s = {backend: x.settings.backend,
               backendConfig: JSON.parse(JSON.stringify(x.settings.mainExecutorSettings.backendConfig))};
    const c = await x.createConversation(greedy);
    s.reply = await text(c, 'Say hi.');
    await c.delete();
    await x.delete();
    return s;
  });
  // N4: the model as a `blob:` URL of more than 2 GiB, as a cacheApi install
  // hands it over: what Engine.create says.
  await attempt('create_from_blob_url_over_2gib', async () => {
    const blob = await (await fetch(url)).blob();
    const blobUrl = URL.createObjectURL(blob);
    try {
      const x = await Engine.create({model: blobUrl});
      await x.delete();
      return {bytes: blob.size, created: true};
    } finally { URL.revokeObjectURL(blobUrl); }
  });
  // Not probed: replaying the history as the runtime returns it, its image
  // as {bytes: [...]}, aborted the module on 0.19.0 ("Aborted()", 2026-11-23),
  // and the CPU probes above end the page's module too.
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
      'explicit_gpu_artisan_backend',
      'constrained_decoding_tool_round_trip',
      'create_vision_gpu',
      'create_vision_gpu_no_max_images',
      'create_vision_cpu',
      'create_audio_cpu',
      'create_audio_gpu',
      'create_vision_and_audio',
      'history_with_image',
      'image_as_base64_blob',
      'preface_with_image_blob',
      'second_image_same_conversation',
      'rebuilt_from_history_with_image_as_base64',
      'history_after_failed_turn',
      'send_after_failed_turn',
      'rebuilt_after_failed_turn',
      'rebuilt_after_failed_turn_trimmed',
      'preface_dangling_tool_call',
      'preface_tool_call_and_response',
      'preface_from_tool_round_trip_history',
      'preface_empty_assistant_text',
      'history_after_empty_reply',
      'history_after_failure_mid_decode',
      'oversized_prompt_then_shorter',
      'refusal_count_and_room',
      'create_from_blob_url_over_2gib',
      'history_with_audio',
      'rebuilt_from_history_with_audio_as_base64',
      'cpu_default',
      'cpu_number_of_threads',
    ]) {
      expect(record, contains(probe), reason: '$probe never ran');
    }
    // What the docs and the web arm rely on must have worked, not only run.
    for (final probe in [
      'send_text',
      'create_vision_gpu',
      'vision_gpu_image_and_text',
      'create_audio_cpu',
      'audio_cpu_and_text',
      'create_vision_and_audio',
      'vision_and_audio_both',
      'image_as_base64_blob',
      'preface_with_image_blob',
      'rebuilt_from_history_with_image_as_base64',
      'rebuilt_from_history_with_audio_as_base64',
      'history_with_preface',
      'idle_cancel_then_send',
      'cancel_at_end',
      'explicit_gpu_backend',
      'rebuilt_from_history',
      'rebuilt_after_failed_turn_trimmed',
      'preface_dangling_tool_call',
      'preface_tool_call_and_response',
      'preface_from_tool_round_trip_history',
      'preface_empty_assistant_text',
    ]) {
      expect(
        (record[probe]! as Map)['ok'],
        isTrue,
        reason: '$probe failed: ${record[probe]}',
      );
    }
    // N5: an oversized message is refused and kept in the history; the
    // conversation rebuilt without it answers a shorter one. N6: a history
    // that filled the window is refused again when replayed.
    final oversized =
        (record['oversized_prompt_then_shorter']! as Map)['value'] as Map;
    expect(oversized['oversized'], startsWith('rejected: Input token ids'));
    expect(oversized['rebuilt'], startsWith('answered:'));
    final full =
        (record['history_after_failure_mid_decode']! as Map)['value'] as Map;
    expect(full['tokensFull'], full['tokensAfter']);
    expect(full['rebuilt'], startsWith('send rejected: Input token ids'));
    // N7: a refusal's count is what that call would prefill: the message
    // alone once the conversation has prefilled (not its 15 held tokens),
    // the preface with the message on a conversation's first call; a call
    // of the whole window is refused.
    final room = (record['refusal_count_and_room']! as Map)['value'] as Map;
    final fresh = (room['fresh']! as List).cast<num>();
    final after = (room['afterExchange']! as List).cast<num>();
    expect(after[0], lessThan(fresh[0] + (room['held']! as num)));
    expect(
      (room['scan']! as List).cast<Map>().where(
        (r) => '${r['refused']}' == '[128, 128]',
      ),
      hasLength(1),
    );
    // M1/N1: the failed message stays at the end of the history with no
    // reply, a rebuild with it fails again, and one without it answers.
    final failed =
        (record['history_after_failed_turn']! as Map)['value'] as Map;
    final roles = (failed['roles']! as List).cast<String>();
    expect(roles.sublist(roles.length - 2), ['assistant', 'user']);
    expect(
      (record['rebuilt_after_failed_turn']! as Map)['ok'],
      isFalse,
      reason: 'a rebuild that replays the failed message answered',
    );
  }, timeout: const Timeout(Duration(minutes: 60)));
}
