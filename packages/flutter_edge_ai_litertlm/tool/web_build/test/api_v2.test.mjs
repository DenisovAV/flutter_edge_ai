// Bundle API v2 (R5 §7) through the REAL litert_embeddings_api.js, with
// @litertjs/core and the SentencePiece processor stubbed: the bundle knows no
// prefix, reports the model's dimension and input length, never truncates,
// and tokenizes empty text like native. Each case imports a fresh copy of the
// module, because its state is module-level.
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

/// One id per code point (+100, so no id collides with BOS 2 / EOS 1 / PAD 0),
/// and every text the bundle tokenized, in order.
const encoded = [];
const encodeIds = (text) => {
  encoded.push(text);
  return Array.from(text, (c) => c.codePointAt(0) + 100);
};

/// An output tensor on [accelerator] holding `[0, 0.1, …]`; `moveTo` makes a
/// copy that is itself an output tensor, and `made` collects every one made.
function fakeOutput({ dim = 4, accelerator = 'wasm', made = [] } = {}) {
  const tensor = {
    accelerator,
    deleted: false,
    toTypedArray: () => Float32Array.from({ length: dim }, (_, i) => i / 10),
    moveTo: async (target) => fakeOutput({ dim, accelerator: target, made }),
    delete() { this.deleted = true; },
  };
  made.push(tensor);
  return tensor;
}

/// A compiled model with input `[1, seq]` and output `[1, dim]` unless the
/// shapes are given. `runs` holds the ids of every forward run; `outputs`
/// builds what each run returns (one wasm tensor by default).
function fakeModel({ seq = 8, dim = 4, inputShape, outputShape, inputs, outputs } = {}) {
  const runs = [];
  return {
    runs,
    options: { accelerator: 'webgpu' },
    isFullyAccelerated: true,
    getInputDetails: () => inputs ?? [{ shape: Int32Array.from(inputShape ?? [1, seq]) }],
    getOutputDetails: () => [{ shape: Int32Array.from(outputShape ?? [1, dim]) }],
    run: async (tensor) => {
      runs.push(Array.from(tensor.data));
      return outputs ? outputs() : [fakeOutput({ dim })];
    },
    delete() {},
  };
}

/// Imports a fresh bundle and loads [model] through its window API.
async function loadFresh(model) {
  globalThis.__compile = () => model;
  globalThis.__encodeIds = encodeIds;
  globalThis.__tensors = [];
  encoded.length = 0;
  await import(`../litert_embeddings_api.js?v2=${instance++}`);
  return window.loadLiteRtEmbeddings('model.tflite', 'tokenizer.model', null);
}

test('the bundle announces API version 2, and the v1 prompt functions are gone', async () => {
  await loadFresh(fakeModel());
  assert.equal(window.liteRtEmbeddingsApiVersion, 2);
  for (const v1 of ['generateEmbedding', 'generateDocumentEmbedding', 'generateEmbeddings']) {
    assert.equal(window[v1], undefined, `${v1} still exists`);
  }
});

test('load reports the dimension and input length read from the model', async () => {
  assert.deepEqual(await loadFresh(fakeModel({ seq: 8, dim: 4 })), { dimension: 4, maxInputTokens: 8 });
  assert.deepEqual(
    await loadFresh(fakeModel({ seq: 256, dim: 768 })),
    { dimension: 768, maxInputTokens: 256 },
  );
  assert.equal(window.getLiteRtEmbeddingDimension(), 768, 'the model\'s, not a constant');
});

test('a model whose input length or dimension cannot be read fails the load', async () => {
  await assert.rejects(loadFresh(fakeModel({ inputShape: [1] })), /sequence length/);
  await assert.rejects(loadFresh(fakeModel({ inputShape: [1, -1] })), /sequence length/);
  await assert.rejects(loadFresh(fakeModel({ outputShape: [1, -1] })), /dimension/);
  await assert.rejects(loadFresh(fakeModel({ outputShape: [] })), /dimension/);
});

test('embedLiteRtText tokenizes the text exactly as given — no prefix, no "▁" — '
  + 'between BOS 2 and EOS 1, padded with 0', async () => {
  const model = fakeModel({ seq: 8, dim: 4 });
  await loadFresh(model);
  const result = await window.embedLiteRtText('ab');

  assert.deepEqual(encoded, ['ab']);
  assert.deepEqual(model.runs, [[2, 197, 198, 1, 0, 0, 0, 0]]);
  assert.equal(result.status, 'ok');
  assert.ok(result.values instanceof Float32Array);
  assert.deepEqual(Array.from(result.values), [0, 0.1, 0.2, 0.3].map(Math.fround));
  assert.ok(globalThis.__tensors.every((t) => t.deleted), 'the input tensor was freed');
});

test('exactly maxInputTokens ids run; one more is too_long, untruncated and never run', async () => {
  const model = fakeModel({ seq: 8 });
  await loadFresh(model);

  // 6 code points + BOS + EOS = 8 ids.
  assert.equal((await window.embedLiteRtText('abcdef')).status, 'ok');
  assert.deepEqual(
    await window.embedLiteRtText('abcdefg'),
    { status: 'too_long', actualTokens: 9, maxInputTokens: 8 },
  );
  assert.equal(model.runs.length, 1, 'the over-long input reached the model');
});

test('empty and whitespace-only text embed like native: [2, ...encodeIds(text), 1]', async () => {
  const model = fakeModel({ seq: 8 });
  await loadFresh(model);

  assert.equal((await window.embedLiteRtText('')).status, 'ok');
  assert.equal((await window.embedLiteRtText('  ')).status, 'ok');
  assert.deepEqual(model.runs, [
    [2, 1, 0, 0, 0, 0, 0, 0],
    [2, 132, 132, 1, 0, 0, 0, 0],
  ]);
});

test('tokenizeLiteRtText returns the ids embedLiteRtText would run, unpadded', async () => {
  const model = fakeModel({ seq: 8 });
  await loadFresh(model);
  const ids = window.tokenizeLiteRtText('task: x');

  assert.ok(ids instanceof Int32Array);
  assert.deepEqual(Array.from(ids), [2, ...Array.from('task: x', (c) => c.codePointAt(0) + 100), 1]);
  // It counts past the model's limit instead of cutting there.
  assert.equal(window.tokenizeLiteRtText('0123456789').length, 12);
  assert.equal(model.runs.length, 0, 'tokenizing runs nothing');
});

test('a non-string input is refused, not coerced', async () => {
  await loadFresh(fakeModel());
  await assert.rejects(window.embedLiteRtText(undefined), /string/);
  assert.throws(() => window.tokenizeLiteRtText(42), /string/);
});

test('cleanup forgets the model: embed and tokenize throw until the next load', async () => {
  await loadFresh(fakeModel({ seq: 8, dim: 4 }));
  await window.cleanupLiteRtEmbeddings();

  assert.equal(window.getLiteRtEmbeddingDimension(), null);
  await assert.rejects(window.embedLiteRtText('a'), /not initialized/);
  assert.throws(() => window.tokenizeLiteRtText('a'), /not initialized/);

  // The next load reads its own model's shapes.
  globalThis.__compile = () => fakeModel({ seq: 16, dim: 2 });
  assert.deepEqual(
    await window.loadLiteRtEmbeddings('m', 't', null),
    { dimension: 2, maxInputTokens: 16 },
  );
});

test('a graph with more than one input is refused at load, naming the inputs '
  + '— the bundle feeds only the token ids', async () => {
  const bert = (name) => ({ name, shape: Int32Array.from([1, 8]) });
  await assert.rejects(
    loadFresh(fakeModel({ inputs: [bert('input_ids'), bert('attention_mask'), bert('token_type_ids')] })),
    (error) => {
      assert.match(error.message, /declares 3 inputs \(input_ids, attention_mask, token_type_ids\)/);
      assert.match(error.message, /exactly one: the token ids/);
      assert.match(error.message, /OnnxEmbeddingBackend/);
      return true;
    },
  );
  assert.equal(window.isLiteRtEmbeddingsInitialized(), false);
  assert.equal(window.getLiteRtEmbeddingDimension(), null, 'nothing read off a refused graph');
  await assert.rejects(loadFresh(fakeModel({ inputs: [] })), /declares 0 inputs/);
  // The single-input graph every litert-community embedder is still loads.
  assert.deepEqual(await loadFresh(fakeModel({ seq: 8, dim: 4 })), { dimension: 4, maxInputTokens: 8 });
});

test('every output tensor a run returns is freed, not only the first', async () => {
  const made = [];
  const model = fakeModel({ outputs: () => [fakeOutput({ made }), fakeOutput({ made })] });
  await loadFresh(model);

  const result = await window.embedLiteRtText('ab');
  assert.equal(result.status, 'ok');
  assert.equal(made.length, 2);
  assert.ok(made.every((t) => t.deleted), 'an output tensor leaked');
  assert.ok(globalThis.__tensors.every((t) => t.deleted), 'the input tensor leaked');
});

test('a webgpu output is copied to wasm, and both, the second output and the '
  + 'input are freed', async () => {
  const made = [];
  const model = fakeModel({
    outputs: () => [fakeOutput({ accelerator: 'webgpu', made }), fakeOutput({ made })],
  });
  await loadFresh(model);

  assert.equal((await window.embedLiteRtText('ab')).status, 'ok');
  assert.equal(made.length, 3, 'two outputs and the wasm copy');
  assert.ok(made.every((t) => t.deleted), 'a tensor leaked');
  assert.ok(globalThis.__tensors.every((t) => t.deleted), 'the input tensor leaked');
});

test('when reading the first output throws, every output and the input are '
  + 'still freed and the error reaches the caller', async () => {
  const made = [];
  const throwing = () => {
    const tensor = fakeOutput({ made });
    Object.defineProperty(tensor, 'accelerator', {
      get() { throw new Error('tensor accelerator unavailable'); },
    });
    return tensor;
  };
  const model = fakeModel({ outputs: () => [throwing(), fakeOutput({ made })] });
  await loadFresh(model);

  await assert.rejects(window.embedLiteRtText('ab'), /tensor accelerator unavailable/);
  assert.equal(made.length, 2);
  assert.ok(made.every((t) => t.deleted), 'an output tensor leaked');
  assert.ok(globalThis.__tensors.every((t) => t.deleted), 'the input tensor leaked');
});

test('a run that returns no output fails by name and frees the input', async () => {
  await loadFresh(fakeModel({ outputs: () => [] }));
  await assert.rejects(window.embedLiteRtText('ab'), /no output tensor/);
  assert.ok(globalThis.__tensors.every((t) => t.deleted), 'the input tensor leaked');
});

test('a delete that throws does not stop the other tensors from being freed '
  + 'nor replace the result', async () => {
  const made = [];
  const brittle = () => {
    const tensor = fakeOutput({ made });
    tensor.delete = () => { throw new Error('delete failed'); };
    return tensor;
  };
  await loadFresh(fakeModel({ outputs: () => [fakeOutput({ made }), brittle(), fakeOutput({ made })] }));

  assert.equal((await window.embedLiteRtText('ab')).status, 'ok');
  assert.equal(made.filter((t) => t.deleted).length, 2, 'the tensors after the failing one were not freed');
  assert.ok(globalThis.__tensors.every((t) => t.deleted), 'the input tensor leaked');
});
