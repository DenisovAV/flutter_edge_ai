/**
 * LiteRT Embeddings API for Dart/JS Interop
 *
 * Provides window-scoped functions for embedding generation
 * using LiteRT.js + SentencePiece
 */

// ============================================================================
// Imports
// ============================================================================

import * as tf from '@tensorflow/tfjs-core';
import '@tensorflow/tfjs-backend-webgl';
import { loadLiteRt, loadAndCompile, Tensor } from '@litertjs/core';
import { SentencePieceProcessor } from '@sctg/sentencepiece-js';

// ============================================================================
// Constants (matching iOS implementation)
// ============================================================================

const TASK_PREFIX = "task: search result | query: ";
const DOC_PREFIX = "title: none | text: ";
const BOS_TOKEN = 2;
const EOS_TOKEN = 1;
const PAD_TOKEN = 0;
let MAX_SEQUENCE_LENGTH = 256; // Default, can be overridden
const EXPECTED_EMBEDDING_DIM = 768;

// ============================================================================
// Global State
// ============================================================================

let tfliteModel = null;
let tokenizer = null;
let isInitialized = false;
let liteRtWasmLoaded = false;  // Track if LiteRT WASM runtime is loaded

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

    // Auto-detect sequence length from model input shape (like iOS/Android)
    try {
      const inputDetails = tfliteModel.getInputDetails();
      if (inputDetails && inputDetails.length > 0) {
        const inputShape = inputDetails[0].shape;
        if (inputShape && inputShape.length >= 2) {
          const detectedSequenceLength = inputShape[1];
          if (detectedSequenceLength !== MAX_SEQUENCE_LENGTH) {
            MAX_SEQUENCE_LENGTH = detectedSequenceLength;
            console.log(`[LiteRT] Auto-detected maxSequenceLength: ${MAX_SEQUENCE_LENGTH}`);
          }
        }
      }
    } catch (e) {
      console.warn('[LiteRT] Failed to auto-detect sequence length, using default:', e);
    }

    return tfliteModel;
  } catch (error) {
    throw new Error('Failed to load LiteRT model: ' + error.message);
  }
}

// ============================================================================
// Text Preprocessing
// ============================================================================

function preprocessTextForEmbedding(text) {
  // Step 1: Tokenize prefix
  const prefixTokens = tokenizer.encode(TASK_PREFIX, false);

  // Step 2: Add "▁" before text and tokenize
  const processedText = "▁" + text;
  const textTokens = tokenizer.encode(processedText, false);

  // Step 3: Combine prefix + text
  let combinedTokens = [...prefixTokens, ...textTokens];

  // Step 4: Add BOS at start and EOS at end
  combinedTokens.unshift(BOS_TOKEN);
  combinedTokens.push(EOS_TOKEN);

  // Step 5: Pad or truncate to MAX_SEQUENCE_LENGTH
  if (combinedTokens.length > MAX_SEQUENCE_LENGTH) {
    combinedTokens = combinedTokens.slice(0, MAX_SEQUENCE_LENGTH);
  } else if (combinedTokens.length < MAX_SEQUENCE_LENGTH) {
    const padLength = MAX_SEQUENCE_LENGTH - combinedTokens.length;
    combinedTokens = [...combinedTokens, ...new Array(padLength).fill(PAD_TOKEN)];
  }

  return combinedTokens;
}

function preprocessDocumentForEmbedding(text) {
  const prefixTokens = tokenizer.encode(DOC_PREFIX, false);
  const processedText = "▁" + text;
  const textTokens = tokenizer.encode(processedText, false);
  let combinedTokens = [...prefixTokens, ...textTokens];
  combinedTokens.unshift(BOS_TOKEN);
  combinedTokens.push(EOS_TOKEN);

  if (combinedTokens.length > MAX_SEQUENCE_LENGTH) {
    combinedTokens = combinedTokens.slice(0, MAX_SEQUENCE_LENGTH);
  } else if (combinedTokens.length < MAX_SEQUENCE_LENGTH) {
    const padLength = MAX_SEQUENCE_LENGTH - combinedTokens.length;
    combinedTokens = [...combinedTokens, ...new Array(padLength).fill(PAD_TOKEN)];
  }
  return combinedTokens;
}

// ============================================================================
// Embedding Generation
// ============================================================================

async function generateEmbeddingInternal(text) {
  if (!tfliteModel || !tokenizer) {
    throw new Error('Model or tokenizer not initialized. Call loadLiteRtEmbeddings first.');
  }

  // Step 1: Preprocess text
  const tokens = preprocessTextForEmbedding(text);

  // Step 2: Create input tensor
  const inputArray = new Int32Array(tokens);
  const inputTensor = new Tensor(inputArray, [1, MAX_SEQUENCE_LENGTH]);

  // Input placement. 0.2.x exposed CompiledModel.accelerator and this
  // moved the tensor to the GPU by hand; 2.x has no such field (only
  // options.accelerator) and run() places inputs itself, so the branch
  // read undefined and never fired. Dropped rather than repaired: the
  // measured behaviour — identical vectors, WebGPU still selected — IS
  // the no-move path.
  const gpuTensor = inputTensor;

  try {
    // Step 4: Run inference
    // @litertjs/core 2.x returns a promise here; 0.2.x returned the tensors
    // directly. Awaiting is the whole migration on our side.
    const outputTensors = await tfliteModel.run(gpuTensor);

    // Step 5: Extract embeddings
    const outputTensor = outputTensors[0];
    reportAccelerator(outputTensor.accelerator);

    // Move back to CPU to read data
    let cpuTensor = outputTensor;
    if (outputTensor.accelerator === 'webgpu') {
      cpuTensor = await outputTensor.moveTo('wasm');
    }

    // Get data as array
    const embeddingsTypedArray = cpuTensor.toTypedArray();
    const embeddingArray = Array.from(embeddingsTypedArray);

    // Validate dimension
    if (embeddingArray.length !== EXPECTED_EMBEDDING_DIM) {
      console.warn(`Unexpected embedding dimension: ${embeddingArray.length}, expected ${EXPECTED_EMBEDDING_DIM}`);
    }

    // Cleanup tensors
    if (gpuTensor !== inputTensor && !gpuTensor.deleted) gpuTensor.delete();
    if (!inputTensor.deleted) inputTensor.delete();
    if (cpuTensor !== outputTensor && !cpuTensor.deleted) cpuTensor.delete();
    if (!outputTensor.deleted) outputTensor.delete();

    return embeddingArray;
  } catch (error) {
    // Cleanup on error
    try {
      if (gpuTensor !== inputTensor && !gpuTensor.deleted) gpuTensor.delete();
      if (!inputTensor.deleted) inputTensor.delete();
    } catch (cleanupErr) {
      console.warn('[LiteRT] Tensor cleanup failed:', cleanupErr);
    }
    throw error;
  }
}

async function generateDocumentEmbeddingInternal(text) {
  if (!tfliteModel || !tokenizer) {
    throw new Error('Model or tokenizer not initialized. Call loadLiteRtEmbeddings first.');
  }

  const tokens = preprocessDocumentForEmbedding(text);
  const inputArray = new Int32Array(tokens);
  const inputTensor = new Tensor(inputArray, [1, MAX_SEQUENCE_LENGTH]);

  // See generateEmbeddingInternal: 2.x run() places inputs itself.
  const gpuTensor = inputTensor;

  try {
    // @litertjs/core 2.x returns a promise here; 0.2.x returned the tensors
    // directly. Awaiting is the whole migration on our side.
    const outputTensors = await tfliteModel.run(gpuTensor);
    const outputTensor = outputTensors[0];
    // Documents are the path a RAG ingest takes, and usually the FIRST
    // embedding an app ever makes — leaving this out kept the accelerator null
    // for a whole corpus.
    reportAccelerator(outputTensor.accelerator);

    let cpuTensor = outputTensor;
    if (outputTensor.accelerator === 'webgpu') {
      cpuTensor = await outputTensor.moveTo('wasm');
    }

    const embeddingsTypedArray = cpuTensor.toTypedArray();
    const embeddingArray = Array.from(embeddingsTypedArray);

    if (embeddingArray.length !== EXPECTED_EMBEDDING_DIM) {
      console.warn(`Unexpected embedding dimension: ${embeddingArray.length}, expected ${EXPECTED_EMBEDDING_DIM}`);
    }

    if (gpuTensor !== inputTensor && !gpuTensor.deleted) gpuTensor.delete();
    if (!inputTensor.deleted) inputTensor.delete();
    if (cpuTensor !== outputTensor && !cpuTensor.deleted) cpuTensor.delete();
    if (!outputTensor.deleted) outputTensor.delete();

    return embeddingArray;
  } catch (error) {
    try {
      if (gpuTensor !== inputTensor && !gpuTensor.deleted) gpuTensor.delete();
      if (!inputTensor.deleted) inputTensor.delete();
    } catch (cleanupErr) {
      console.warn('[LiteRT] Tensor cleanup failed:', cleanupErr);
    }
    throw error;
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
 * Initialize LiteRT embeddings
 * @param {string} modelPath - Path to .tflite model file
 * @param {string} tokenizerPath - Path to sentencepiece.model file
 * @param {string|null|undefined} wasmPath - Optional path to WASM files
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
      }
    }

    // IMPORTANT: Check for null and convert to undefined to trigger default parameter
    // Dart's null becomes JavaScript null (not undefined), which bypasses default parameters
    const effectiveWasmPath = (wasmPath === null || wasmPath === undefined)
      ? '/node_modules/@litertjs/core/wasm/'
      : wasmPath;

    // Load tokenizer
    await loadSentencePieceTokenizer(tokenizerPath);

    // Load model (auto-detects sequence length from model)
    await loadLiteRTModel(modelPath, effectiveWasmPath);

    isInitialized = true;
  } catch (error) {
    isInitialized = false;
    throw new Error('Failed to initialize LiteRT embeddings: ' + error.message);
  }
};

/**
 * Generate embedding for a single text
 * @param {string} text - Text to embed
 * @returns {Promise<Float32Array>} Embedding vector
 */
window.generateEmbedding = async function(text) {
  if (!isInitialized) {
    throw new Error('LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.');
  }

  if (typeof text !== 'string' || text.trim().length === 0) {
    throw new Error('Text must be a non-empty string');
  }

  const embedding = await generateEmbeddingInternal(text);
  return new Float32Array(embedding);
};

/**
 * Generate document embedding for a single text (uses document prefix)
 * @param {string} text - Text to embed
 * @returns {Promise<Float32Array>} Embedding vector
 */
window.generateDocumentEmbedding = async function(text) {
  if (!isInitialized) {
    throw new Error('LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.');
  }
  if (typeof text !== 'string' || text.trim().length === 0) {
    throw new Error('Text must be a non-empty string');
  }
  const embedding = await generateDocumentEmbeddingInternal(text);
  return new Float32Array(embedding);
};

/**
 * Generate embeddings for multiple texts (batch)
 * @param {string[]} texts - Array of texts to embed
 * @returns {Promise<Float32Array[]>} Array of embedding vectors
 */
window.generateEmbeddings = async function(texts) {
  if (!isInitialized) {
    throw new Error('LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.');
  }

  if (!Array.isArray(texts)) {
    throw new Error('texts must be an array');
  }

  const embeddings = [];
  for (const text of texts) {
    if (typeof text !== 'string' || text.trim().length === 0) {
      throw new Error('All texts must be non-empty strings');
    }

    const embedding = await generateEmbeddingInternal(text);
    embeddings.push(new Float32Array(embedding));
  }

  return embeddings;
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
 * Get the dimension of embeddings
 * @returns {number} Embedding dimension (768)
 */
window.getLiteRtEmbeddingDimension = function() {
  return EXPECTED_EMBEDDING_DIM;
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

  // 6. Reset sequence length to default
  // Next model will auto-detect its own sequence length
  MAX_SEQUENCE_LENGTH = 256;
  console.log('[LiteRT] ✅ Reset MAX_SEQUENCE_LENGTH to default');

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
