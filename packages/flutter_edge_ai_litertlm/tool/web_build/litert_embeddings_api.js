/**
 * LiteRT.js embeddings for flutter_edge_ai_litertlm — bundle API v2.
 *
 * Window-scoped functions the Dart side (`LiteRtJsEmbeddingPass`, through
 * `lib/src/embedding/web/litert_web_embeddings.dart`) calls:
 *
 *   liteRtEmbeddingsApiVersion = 2
 *   loadLiteRtEmbeddings(modelPath, tokenizerPath, wasmPath)
 *       → {dimension, maxInputTokens}, both read from the compiled model
 *   embedLiteRtText(prefixedText)
 *       → {status: 'ok', values: Float32Array}
 *       | {status: 'too_long', actualTokens, maxInputTokens}
 *   tokenizeLiteRtText(prefixedText) → Int32Array   (the W1 parity check)
 *   cleanupLiteRtEmbeddings(), getLiteRtEmbeddingAccelerator(),
 *   getLiteRtEmbeddingFullyAccelerated()
 *
 * This file knows NO task prefix. Dart builds `taskType.prefix + text` with
 * the one prefix function every engine uses, so all nine TaskType values mean
 * on web what they mean on native. The ids are `[2, ...encodeIds(text), 1]` —
 * what the native Dart tokenizer produces for the same string — padded with 0
 * to the model's input length and NEVER truncated: a longer input comes back
 * as `too_long`, which Dart turns into EmbeddingInputTooLongException.
 *
 * API v1 (flutter_edge_ai_litertlm ≤ 1.12.x) had `generateEmbedding`,
 * `generateDocumentEmbedding` and `generateEmbeddings`, prepended one of two
 * hard-coded prefixes itself (every task type but a document got the query
 * prompt), tokenized prefix and text separately with a "▁" before the text,
 * cut the ids to the sequence length (EOS included) without a word, and
 * refused empty text. It set no `liteRtEmbeddingsApiVersion`; the Dart side
 * refuses a page whose copy does not announce version 2.
 */

// ============================================================================
// Imports
// ============================================================================

import * as tf from '@tensorflow/tfjs-core';
import '@tensorflow/tfjs-backend-webgl';
import { loadLiteRt, loadAndCompile, Tensor } from '@litertjs/core';
import { SentencePieceProcessor } from '@sctg/sentencepiece-js';

// ============================================================================
// Constants
// ============================================================================

/** The window API this file implements. Dart refuses any other value. */
const API_VERSION = 2;
const BOS_TOKEN = 2;
const EOS_TOKEN = 1;
const PAD_TOKEN = 0;

// ============================================================================
// Global State
// ============================================================================

let tfliteModel = null;
let tokenizer = null;
let isInitialized = false;
let liteRtWasmLoaded = false;  // Track if LiteRT WASM runtime is loaded

// Read from the compiled model at load: the input's sequence length and the
// output's last dimension. Null while nothing is loaded; never a default.
let maxSequenceLength = null;
let embeddingDimension = null;

// Where the OUTPUT BUFFER lived after a run, as reported by the first output
// tensor. Null until the first run. Buffer residency, not execution: an op that
// spilled to WASM inside a webgpu build still leaves WebGPU buffers, which is
// why `fullyAccelerated` below exists rather than this answering alone.
let actualAccelerator = null;
// What we ASKED for. Never overwritten after the compile, because it is the
// only thing a mismatch can be measured against.
let askedAccelerator = null;
// What the model was actually COMPILED for — read from `model.options` right
// after compiling, so it survives LiteRT.js silently recompiling for WASM.
let compiledAccelerator = null;
// Null until the model is compiled; false when LiteRT had to spill ops to WASM.
let fullyAccelerated = null;

// ============================================================================
// SentencePiece Tokenizer Loading
// ============================================================================

async function loadSentencePieceTokenizer(tokenizerPath) {
  try {
    const response = await fetch(tokenizerPath);
    if (!response.ok) {
      throw new Error(`Failed to fetch tokenizer: ${response.status} ${response.statusText}`);
    }

    const arrayBuffer = await response.arrayBuffer();
    const processor = new SentencePieceProcessor();

    // Try loadFromBuffer first, fallback to base64
    if (typeof processor.loadFromBuffer === 'function') {
      await processor.loadFromBuffer(new Uint8Array(arrayBuffer));
    } else {
      const uint8Array = new Uint8Array(arrayBuffer);
      let binary = '';
      for (let i = 0; i < uint8Array.length; i++) {
        binary += String.fromCharCode(uint8Array[i]);
      }
      const base64Model = btoa(binary);
      await processor.loadFromB64StringModel(base64Model);
    }

    tokenizer = {
      encode: (text, addBosEos = false) => {
        const tokens = processor.encodeIds(text);
        return addBosEos ? [BOS_TOKEN, ...tokens, EOS_TOKEN] : tokens;
      },
      decode: (ids) => processor.decodeIds(ids),
      processor: processor
    };

    return tokenizer;
  } catch (error) {
    throw new Error('Failed to load SentencePiece tokenizer: ' + error.message);
  }
}

// ============================================================================
// LiteRT Model Loading
// ============================================================================

async function loadLiteRTModel(modelPath, wasmPath = '/node_modules/@litertjs/core/wasm/') {
  try {
    console.log(`[LiteRT] Loading model from: ${modelPath}`);
    console.log(`[LiteRT] WASM loaded flag: ${liteRtWasmLoaded}`);

    // Initialize TensorFlow.js backend
    await tf.setBackend('webgl');
    await tf.ready();

    // Load LiteRT WASM runtime only once
    if (!liteRtWasmLoaded) {
      console.log(`[LiteRT] Loading WASM runtime from: ${wasmPath}`);
      await loadLiteRt(wasmPath);
      liteRtWasmLoaded = true;
      console.log('[LiteRT] WASM runtime loaded successfully');
    } else {
      console.log('[LiteRT] WASM runtime already loaded, reusing');
    }

    // Load and compile model with WebGPU (fallback to WASM)
    // Pass modelPath directly - LiteRT.js handles blob URLs internally
    try {
      console.log('[LiteRT] Attempting to compile model with WebGPU...');
      askedAccelerator = 'webgpu';
      tfliteModel = await loadAndCompile(modelPath, {
        accelerator: 'webgpu',
      });
      // Deliberately NOT "compiled with WebGPU successfully". LiteRT.js can
      // hand back a model it quietly recompiled for WASM: when a webgpu build
      // is not fully accelerated it either partially delegates to WASM (JSPI
      // browsers) or deletes the model and re-runs loadAndCompile with
      // accelerator 'wasm' (everywhere else). It throws in NEITHER case, so
      // this line is reached either way and the old wording was a guess.
      console.log('[LiteRT] Model compiled, accelerator confirmed on first run');
    } catch (error) {
      console.warn('[LiteRT] WebGPU not available, falling back to WASM:', error.message);
      askedAccelerator = 'wasm';
      tfliteModel = await loadAndCompile(modelPath, {
        accelerator: 'wasm',
      });
      console.log('[LiteRT] Model compiled with WASM successfully');
    }

    // Two questions, two sources. WHETHER the graph is fully on the accelerator
    // is answerable here, at compile time — isFullyAccelerated is the flag
    // LiteRT itself branches on, and the only way to see the JSPI partial case,
    // which keeps WebGPU buffers and so looks like a clean webgpu run to every
    // later check. WHICH accelerator ran is answerable only from an output
    // tensor, after the first embedding.
    //
    // Below the try/catch so it runs on BOTH arms. Inside the try it was
    // unreachable on the WASM fallback, which left the getter null after a
    // SUCCESSFUL compile — indistinguishable from "not compiled yet", and on
    // exactly the browsers the fallback exists for.
    //
    // Read off the model rather than taken from what we asked for: LiteRT.js can
    // delete a webgpu build and return a wasm one without throwing. Kept in a
    // SEPARATE variable — folding it into the asked-for value silenced the one
    // warning below that this whole block exists to produce, because the
    // comparison then had nothing left to disagree with.
    compiledAccelerator = tfliteModel.options?.accelerator ?? null;
    if (compiledAccelerator && compiledAccelerator !== askedAccelerator) {
      console.warn(
        `[LiteRT] Compiled for ${compiledAccelerator}, not the requested ` +
        `${askedAccelerator}. LiteRT recompiled without raising.`,
      );
    }
    reportFullAcceleration(tfliteModel);

    // What Dart reports as EmbeddingPassInfo: read from the model, never
    // assumed. A model this file cannot feed, or whose shapes cannot be read,
    // fails the load here rather than every embed after it.
    refuseMultiInputGraph(tfliteModel);
    maxSequenceLength = readSequenceLength(tfliteModel);
    embeddingDimension = readDimension(tfliteModel);
    console.log(
      `[LiteRT] Model input length ${maxSequenceLength}, ` +
      `dimension ${embeddingDimension}`,
    );

    return tfliteModel;
  } catch (error) {
    throw new Error('Failed to load LiteRT model: ' + error.message);
  }
}

/**
 * Throws unless the graph has exactly one input. `runIds` builds one tensor —
 * the token ids — so a BERT-style export that also takes `attention_mask` and
 * `token_type_ids` would load here and then fail every embed. The native
 * LiteRT pass refuses the same graphs at load.
 */
function refuseMultiInputGraph(model) {
  const inputs = model.getInputDetails() ?? [];
  if (inputs.length === 1) return;
  const names = Array.from(inputs, (input) => input?.name).filter(Boolean);
  throw new Error(
    `the model declares ${inputs.length} inputs` +
    (names.length ? ` (${names.join(', ')})` : '') +
    ' but LiteRT.js embeddings feed exactly one: the token ids. A graph that ' +
    'also takes attention_mask or token_type_ids (a BERT / MiniLM export) ' +
    'cannot run here; register flutter_edge_ai_onnx\'s OnnxEmbeddingBackend ' +
    'and install the .onnx export of the same model instead.',
  );
}

/** The compiled input `[1, seq]`'s sequence length, or a thrown Error. */
function readSequenceLength(model) {
  const shape = model.getInputDetails()?.[0]?.shape;
  const length = shape && shape.length >= 2 ? shape[1] : undefined;
  if (!Number.isInteger(length) || length <= 0) {
    throw new Error(
      'cannot read the input sequence length from the model ' +
      `(input 0 shape: ${describeShape(shape)})`,
    );
  }
  return length;
}

/** The output's last dimension — the embedding's length — or a thrown Error. */
function readDimension(model) {
  const shape = model.getOutputDetails()?.[0]?.shape;
  const dimension = shape && shape.length >= 1 ? shape[shape.length - 1] : undefined;
  if (!Number.isInteger(dimension) || dimension <= 0) {
    throw new Error(
      'cannot read the embedding dimension from the model ' +
      `(output 0 shape: ${describeShape(shape)})`,
    );
  }
  return dimension;
}

function describeShape(shape) {
  return shape ? `[${Array.from(shape).join(', ')}]` : 'none';
}

// ============================================================================
// Tokenization and the forward run
// ============================================================================

/**
 * `[BOS, ...encodeIds(prefixedText), EOS]`, unpadded and uncut — what the
 * native Dart tokenizer produces for the same string. Tokenized as ONE
 * string, exactly as given: Dart has already prepended the task prefix.
 */
function idsFor(prefixedText) {
  if (!isInitialized || !tokenizer) {
    throw new Error('LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.');
  }
  if (typeof prefixedText !== 'string') {
    throw new Error(`The text must be a string, got ${typeof prefixedText}`);
  }
  return [BOS_TOKEN, ...tokenizer.processor.encodeIds(prefixedText), EOS_TOKEN];
}

/** One forward run over [ids] (at most maxSequenceLength), padded with 0. */
async function runIds(ids) {
  const padded = new Int32Array(maxSequenceLength).fill(PAD_TOKEN);
  padded.set(ids);
  // Input placement: 2.x run() places inputs itself. 0.2.x exposed
  // CompiledModel.accelerator and the input was moved to the GPU by hand; 2.x
  // has no such field, and the measured no-move path gives identical vectors
  // with WebGPU still selected.
  const inputTensor = new Tensor(padded, [1, maxSequenceLength]);
  let outputTensors = [];
  let cpuTensor = null;
  try {
    // @litertjs/core 2.x returns a promise here; 0.2.x returned the tensors
    // directly.
    outputTensors = await tfliteModel.run(inputTensor);
    // Read only once every output is in `outputTensors`, so a getter that
    // throws still leaves them all to the finally below.
    const outputTensor = outputTensors[0];
    if (!outputTensor) throw new Error('the model returned no output tensor');
    // Every run reports it: the first embedding an app makes is usually a
    // document during a RAG ingest.
    reportAccelerator(outputTensor.accelerator);
    cpuTensor = outputTensor.accelerator === 'webgpu'
      ? await outputTensor.moveTo('wasm')
      : outputTensor;
    // A copy: the typed array may be a view that delete() frees.
    return Float32Array.from(cpuTensor.toTypedArray());
  } finally {
    // EVERY tensor the run handed back is ours to free, not only the one we
    // read: a graph with a second output (pooled and per-token, say) would
    // otherwise leak it on every call. Then the CPU copy, then the input.
    for (const tensor of Array.isArray(outputTensors) ? outputTensors : []) {
      freeTensor(tensor);
    }
    freeTensor(cpuTensor);
    freeTensor(inputTensor);
  }
}

/**
 * Deletes [tensor] unless it is null or already deleted. A failing delete is
 * logged, not thrown: it must not stop the other tensors from being freed, nor
 * replace the error that brought us here.
 */
function freeTensor(tensor) {
  if (!tensor || tensor.deleted) return;
  try {
    tensor.delete();
  } catch (error) {
    console.warn('[LiteRT] Could not free a tensor:', error);
  }
}

// ============================================================================
// Public API (window-scoped for Dart/JS interop)
// ============================================================================

/**
 * Says once, at compile time, when the graph did NOT land entirely on the
 * requested accelerator.
 *
 * This is the case `reportAccelerator` structurally cannot see: on a browser
 * with JSPI, LiteRT keeps the WebGPU compile and delegates the unsupported ops
 * to WASM, so the output tensor still lives in a WebGPU buffer and reports
 * 'webgpu'. `isFullyAccelerated` is the flag LiteRT itself branches on to take
 * that path.
 */
function reportFullAcceleration(model) {
  // Checked before anything is read off the model: a compile that is not the
  // one we asked for already answers the getter's question. LiteRT.js deletes a
  // webgpu build that is not fully accelerated and returns a wasm one without
  // raising, so the graph did not land on the requested accelerator at all —
  // and the wasm guard below used to turn that into "unknown" (null), on
  // exactly the path this getter exists for.
  if (compiledAccelerator && compiledAccelerator !== askedAccelerator) {
    fullyAccelerated = false;
    return;
  }
  let full;
  try {
    full = model.isFullyAccelerated;
  } catch (_) {
    // Not "a runtime without the flag": an absent property reads as undefined,
    // which the triple state below already handles by saying nothing. This is
    // only the getter itself throwing (a deleted model), and there is nothing
    // truthful to report about one.
    return;
  }
  // A wasm compile that was ASKED for is not a question about acceleration:
  // every op runs in WASM by construction, there is no buffer-vs-execution
  // distinction to report, and LiteRT itself only consults this flag for
  // webgpu/webnn — so whatever it answers for wasm is unspecified and we say
  // nothing rather than guess.
  const target = compiledAccelerator ?? askedAccelerator;
  if (target === 'wasm') return;

  if (full === false) {
    fullyAccelerated = false;
    console.warn(
      `[LiteRT] Model is not fully accelerated on ${target}. ` +
      `Unsupported ops run in WASM, so the accelerator reported after the ` +
      `first embedding is where the output buffer lives, not where every op ran.`,
    );
  } else if (full === true) {
    // The compile matches the request (checked above), so this is the answer.
    fullyAccelerated = true;
  }
}

/**
 * Records what the model actually ran on, and says so once.
 *
 * Called with the first output tensor's accelerator. When it disagrees with
 * what was requested, LiteRT.js fell back without throwing — the case the old
 * unconditional "compiled with WebGPU successfully" line hid. `window.getLiteRtEmbeddingAccelerator()`
 * exposes the same value to Dart.
 */
function reportAccelerator(accelerator) {
  if (actualAccelerator !== null || !accelerator) return;
  actualAccelerator = accelerator;
  if (askedAccelerator && accelerator !== askedAccelerator) {
    console.warn(
      `[LiteRT] Running on ${accelerator}, not the requested ${askedAccelerator}. ` +
      `LiteRT fell back without raising — the model was not fully accelerated.`,
    );
  } else {
    console.log(`[LiteRT] Running on ${accelerator}`);
  }
}

/**
 * The window API version, which the Dart side checks before it loads
 * anything. API v1 set none.
 */
window.liteRtEmbeddingsApiVersion = API_VERSION;

/**
 * Loads the tokenizer, then compiles the model. Replaces whatever was loaded.
 * @param {string} modelPath - URL of the .tflite model
 * @param {string} tokenizerPath - URL of the sentencepiece.model file
 * @param {string|null|undefined} wasmPath - Optional prefix of the WASM files
 * @returns {Promise<{dimension: number, maxInputTokens: number}>} read from
 *     the model: its output's last dimension and its input's sequence length,
 *     which the task prefix, BOS and EOS count towards
 * @throws when the graph does not take exactly one input (the token ids) or
 *     its input length or output dimension cannot be read
 */
window.loadLiteRtEmbeddings = async function(modelPath, tokenizerPath, wasmPath) {
  try {
    // Cleanup old model before loading new one (important for hot restart)
    // This prevents memory leaks and "memory access out of bounds" errors
    if (isInitialized) {
      console.log('[LiteRT] Cleaning up previous model before reinitialization (hot restart detected)');
      try {
        await window.cleanupLiteRtEmbeddings();
      } catch (cleanupError) {
        // Cleanup errors should not block reinitialization
        // Old instances may be invalid after hot restart
        console.warn('[LiteRT] Non-fatal cleanup error (will reinitialize anyway):', cleanupError);
        // Force reset all state even if cleanup failed
        tfliteModel = null;
        tokenizer = null;
        liteRtWasmLoaded = false;
        isInitialized = false;
        maxSequenceLength = null;
        embeddingDimension = null;
      }
    }

    // IMPORTANT: Check for null and convert to undefined to trigger default parameter
    // Dart's null becomes JavaScript null (not undefined), which bypasses default parameters
    const effectiveWasmPath = (wasmPath === null || wasmPath === undefined)
      ? '/node_modules/@litertjs/core/wasm/'
      : wasmPath;

    // Load tokenizer
    await loadSentencePieceTokenizer(tokenizerPath);

    // Load model (reads its input length and dimension)
    await loadLiteRTModel(modelPath, effectiveWasmPath);

    isInitialized = true;
    return { dimension: embeddingDimension, maxInputTokens: maxSequenceLength };
  } catch (error) {
    isInitialized = false;
    throw new Error('Failed to initialize LiteRT embeddings: ' + error.message);
  }
};

/**
 * Embeds one string exactly as given — Dart has prepended the task prefix.
 * @param {string} prefixedText - may be empty: like native, that embeds the
 *     BOS and EOS ids alone
 * @returns {Promise<{status: 'ok', values: Float32Array}
 *     | {status: 'too_long', actualTokens: number, maxInputTokens: number}>}
 *     `too_long` when the ids, BOS and EOS included, are longer than the
 *     model's input; nothing runs then, and nothing is ever truncated
 */
window.embedLiteRtText = async function(prefixedText) {
  const ids = idsFor(prefixedText);
  if (ids.length > maxSequenceLength) {
    return {
      status: 'too_long',
      actualTokens: ids.length,
      maxInputTokens: maxSequenceLength,
    };
  }
  return { status: 'ok', values: await runIds(ids) };
};

/**
 * The ids embedLiteRtText would run for [prefixedText], unpadded and uncut.
 * For the W1 parity check against the native Dart tokenizer; embedding never
 * calls it.
 * @param {string} prefixedText
 * @returns {Int32Array}
 */
window.tokenizeLiteRtText = function(prefixedText) {
  return Int32Array.from(idsFor(prefixedText));
};

/**
 * The accelerator the model actually ran on: 'webgpu', 'wasm', or null before
 * the first embedding. Null is "not yet known", never "none".
 */
window.getLiteRtEmbeddingAccelerator = function() {
  return actualAccelerator;
};

/**
 * False when the graph did not land entirely on the REQUESTED accelerator, true
 * when it did. Separate from the accelerator because a partially delegated model
 * still reports WebGPU buffers.
 *
 * Null both before a compile and after a plain WASM one: on wasm there is no
 * acceleration question to answer, and LiteRT only consults the underlying flag
 * for webgpu/webnn, so its value there is unspecified.
 */
window.getLiteRtEmbeddingFullyAccelerated = function() {
  return fullyAccelerated;
};

/**
 * The loaded model's embedding dimension, read from its output shape; null
 * while nothing is loaded. (API v1 returned a constant 768.)
 * @returns {number|null}
 */
window.getLiteRtEmbeddingDimension = function() {
  return embeddingDimension;
};

/**
 * Cleanup and release resources
 *
 * CRITICAL for hot restart: Cleans up all LiteRT state including:
 * - TFLite model instances
 * - SentencePiece tokenizer
 * - TensorFlow.js tensors and backend
 * - WASM runtime flag (forces reload on next init)
 */
window.cleanupLiteRtEmbeddings = async function() {
  actualAccelerator = null;
  askedAccelerator = null;
  compiledAccelerator = null;
  fullyAccelerated = null;
  console.log('[LiteRT] ========================================');
  console.log('[LiteRT] Starting cleanup...');
  console.log('[LiteRT] ========================================');

  // 1. Dispose TFLite model
  if (tfliteModel) {
    try {
      if (typeof tfliteModel.delete === 'function' && !tfliteModel.deleted) {
        tfliteModel.delete();
        console.log('[LiteRT] ✅ Model deleted');
      }
    } catch (e) {
      console.warn('[LiteRT] ⚠️  Error deleting model (non-fatal):', e);
    }
  }
  tfliteModel = null;

  // 2. Dispose tokenizer
  if (tokenizer) {
    try {
      if (tokenizer.processor && typeof tokenizer.processor.delete === 'function') {
        tokenizer.processor.delete();
        console.log('[LiteRT] ✅ Tokenizer deleted');
      }
    } catch (e) {
      console.warn('[LiteRT] ⚠️  Error deleting tokenizer (non-fatal):', e);
    }
  }
  tokenizer = null;

  // 3. Dispose TensorFlow.js tensors
  try {
    const memory = tf.memory();
    const numTensors = memory.numTensors;
    if (numTensors > 0) {
      console.log(`[LiteRT] Disposing ${numTensors} TensorFlow.js tensors`);
      tf.disposeVariables();
      console.log('[LiteRT] ✅ Tensors disposed');
    }
  } catch (e) {
    console.warn('[LiteRT] ⚠️  Error disposing tensors (non-fatal):', e);
  }

  // 4. NOTE: We do NOT remove WebGL backend from registry
  // Removing it causes "Backend not found" errors on next init
  // TensorFlow.js manages backend lifecycle automatically
  // Just disposing tensors and model is enough

  // 5. NOTE: We do NOT reset liteRtWasmLoaded flag
  // WASM runtime is loaded ONCE and reused for all models
  // Resetting causes "LiteRT is already loading / loaded" error
  // Only model instances need cleanup, not the runtime itself
  console.log('[LiteRT] ✅ Keeping WASM runtime (reusable across models)');

  // 6. Forget the model's shapes; the next load reads its own.
  maxSequenceLength = null;
  embeddingDimension = null;

  // 7. Mark as uninitialized
  isInitialized = false;

  console.log('[LiteRT] ========================================');
  console.log('[LiteRT] ✅ Cleanup completed');
  console.log('[LiteRT] ========================================');
};

/**
 * Check if initialized
 * @returns {boolean} True if initialized
 */
window.isLiteRtEmbeddingsInitialized = function() {
  return isInitialized;
};

// Log module loaded
console.log('LiteRT Embeddings module loaded successfully');
