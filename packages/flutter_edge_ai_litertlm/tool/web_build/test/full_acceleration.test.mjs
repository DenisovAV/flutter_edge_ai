// window.getLiteRtEmbeddingFullyAccelerated() through the REAL compile path of
// litert_embeddings_api.js, with @litertjs/core stubbed. Each case imports a
// fresh copy of the module, because its state is module-level.
//
// Run: npm test (from tool/web_build)
import { register } from 'node:module';
import { test } from 'node:test';
import assert from 'node:assert/strict';

register('./loader.mjs', import.meta.url);

globalThis.window = globalThis;
globalThis.fetch = async () => ({ ok: true, arrayBuffer: async () => new ArrayBuffer(1) });
console.log = () => {};
console.warn = () => {};

let instance = 0;

/// Compiles through window.loadLiteRtEmbeddings with [compile] deciding what
/// each requested accelerator yields, and returns the getter's answer.
async function fullyAcceleratedAfter(compile) {
  globalThis.__compile = compile;
  await import(`../litert_embeddings_api.js?case=${instance++}`);
  await window.loadLiteRtEmbeddings('model.tflite', 'tokenizer.model', null);
  return window.getLiteRtEmbeddingFullyAccelerated();
}

const model = (accelerator, isFullyAccelerated) => ({
  options: { accelerator },
  isFullyAccelerated,
  getInputDetails: () => [{ shape: [1, 256] }],
});

test('a webgpu request silently recompiled for wasm is not fully accelerated', async () => {
  // LiteRT.js deletes a webgpu build that is not fully accelerated and returns
  // a wasm one without raising. The graph did not land on the requested
  // accelerator at all, so the answer is false — not "unknown".
  assert.equal(await fullyAcceleratedAfter(() => model('wasm', true)), false);
});

test('a webgpu compile that is fully accelerated says so', async () => {
  assert.equal(await fullyAcceleratedAfter(() => model('webgpu', true)), true);
});

test('a webgpu compile that spilled ops to wasm is not fully accelerated', async () => {
  assert.equal(await fullyAcceleratedAfter(() => model('webgpu', false)), false);
});

test('a wasm compile that was asked for reports nothing', async () => {
  // WebGPU unavailable: the fallback ASKED for wasm, so there is no
  // acceleration question to answer.
  const answer = await fullyAcceleratedAfter((accelerator) => {
    if (accelerator === 'webgpu') throw new Error('no WebGPU');
    return model('wasm', true);
  });
  assert.equal(answer, null);
});
