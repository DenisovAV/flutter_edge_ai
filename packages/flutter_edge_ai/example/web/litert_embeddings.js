import { m as M, d as F, s as $, r as z } from "./tensorflow.js";
import { l as C, a as b, T as E } from "./litert.js";
import { S as x } from "./sentencepiece.js";
const _ = "task: search result | query: ", D = "title: none | text: ", L = 2, R = 1, A = 0;
let c = 256;
const p = 768;
let l = null, d = null, f = !1, T = !1, y = null, u = null, g = null, w = null;
async function I(t) {
  try {
    const o = await fetch(t);
    if (!o.ok)
      throw new Error(`Failed to fetch tokenizer: ${o.status} ${o.statusText}`);
    const r = await o.arrayBuffer(), n = new x();
    if (typeof n.loadFromBuffer == "function")
      await n.loadFromBuffer(new Uint8Array(r));
    else {
      const e = new Uint8Array(r);
      let a = "";
      for (let s = 0; s < e.length; s++)
        a += String.fromCharCode(e[s]);
      const i = btoa(a);
      await n.loadFromB64StringModel(i);
    }
    return d = {
      encode: (e, a = !1) => {
        const i = n.encodeIds(e);
        return a ? [L, ...i, R] : i;
      },
      decode: (e) => n.decodeIds(e),
      processor: n
    }, d;
  } catch (o) {
    throw new Error("Failed to load SentencePiece tokenizer: " + o.message);
  }
}
async function W(t, o = "/node_modules/@litertjs/core/wasm/") {
  try {
    console.log(`[LiteRT] Loading model from: ${t}`), console.log(`[LiteRT] WASM loaded flag: ${T}`), await $("webgl"), await z(), T ? console.log("[LiteRT] WASM runtime already loaded, reusing") : (console.log(`[LiteRT] Loading WASM runtime from: ${o}`), await C(o), T = !0, console.log("[LiteRT] WASM runtime loaded successfully"));
    try {
      console.log("[LiteRT] Attempting to compile model with WebGPU..."), u = "webgpu", l = await b(t, {
        accelerator: "webgpu"
      }), console.log("[LiteRT] Model compiled, accelerator confirmed on first run");
    } catch (r) {
      console.warn("[LiteRT] WebGPU not available, falling back to WASM:", r.message), u = "wasm", l = await b(t, {
        accelerator: "wasm"
      }), console.log("[LiteRT] Model compiled with WASM successfully");
    }
    g = l.options?.accelerator ?? null, g && g !== u && console.warn(
      `[LiteRT] Compiled for ${g}, not the requested ${u}. LiteRT recompiled without raising.`
    ), v(l);
    try {
      const r = l.getInputDetails();
      if (r && r.length > 0) {
        const n = r[0].shape;
        if (n && n.length >= 2) {
          const e = n[1];
          e !== c && (c = e, console.log(`[LiteRT] Auto-detected maxSequenceLength: ${c}`));
        }
      }
    } catch (r) {
      console.warn("[LiteRT] Failed to auto-detect sequence length, using default:", r);
    }
    return l;
  } catch (r) {
    throw new Error("Failed to load LiteRT model: " + r.message);
  }
}
function N(t) {
  const o = d.encode(_, !1), r = "▁" + t, n = d.encode(r, !1);
  let e = [...o, ...n];
  if (e.unshift(L), e.push(R), e.length > c)
    e = e.slice(0, c);
  else if (e.length < c) {
    const a = c - e.length;
    e = [...e, ...new Array(a).fill(A)];
  }
  return e;
}
function U(t) {
  const o = d.encode(D, !1), r = "▁" + t, n = d.encode(r, !1);
  let e = [...o, ...n];
  if (e.unshift(L), e.push(R), e.length > c)
    e = e.slice(0, c);
  else if (e.length < c) {
    const a = c - e.length;
    e = [...e, ...new Array(a).fill(A)];
  }
  return e;
}
async function k(t) {
  if (!l || !d)
    throw new Error("Model or tokenizer not initialized. Call loadLiteRtEmbeddings first.");
  const o = N(t), r = new Int32Array(o), n = new E(r, [1, c]), e = n;
  try {
    const i = (await l.run(e))[0];
    S(i.accelerator);
    let s = i;
    i.accelerator === "webgpu" && (s = await i.moveTo("wasm"));
    const h = s.toTypedArray(), m = Array.from(h);
    return m.length !== p && console.warn(`Unexpected embedding dimension: ${m.length}, expected ${p}`), e !== n && !e.deleted && e.delete(), n.deleted || n.delete(), s !== i && !s.deleted && s.delete(), i.deleted || i.delete(), m;
  } catch (a) {
    try {
      e !== n && !e.deleted && e.delete(), n.deleted || n.delete();
    } catch (i) {
      console.warn("[LiteRT] Tensor cleanup failed:", i);
    }
    throw a;
  }
}
async function B(t) {
  if (!l || !d)
    throw new Error("Model or tokenizer not initialized. Call loadLiteRtEmbeddings first.");
  const o = U(t), r = new Int32Array(o), n = new E(r, [1, c]), e = n;
  try {
    const i = (await l.run(e))[0];
    S(i.accelerator);
    let s = i;
    i.accelerator === "webgpu" && (s = await i.moveTo("wasm"));
    const h = s.toTypedArray(), m = Array.from(h);
    return m.length !== p && console.warn(`Unexpected embedding dimension: ${m.length}, expected ${p}`), e !== n && !e.deleted && e.delete(), n.deleted || n.delete(), s !== i && !s.deleted && s.delete(), i.deleted || i.delete(), m;
  } catch (a) {
    try {
      e !== n && !e.deleted && e.delete(), n.deleted || n.delete();
    } catch (i) {
      console.warn("[LiteRT] Tensor cleanup failed:", i);
    }
    throw a;
  }
}
function v(t) {
  if (g && g !== u) {
    w = !1;
    return;
  }
  let o;
  try {
    o = t.isFullyAccelerated;
  } catch {
    return;
  }
  const r = g ?? u;
  r !== "wasm" && (o === !1 ? (w = !1, console.warn(
    `[LiteRT] Model is not fully accelerated on ${r}. Unsupported ops run in WASM, so the accelerator reported after the first embedding is where the output buffer lives, not where every op ran.`
  )) : o === !0 && (w = !0));
}
function S(t) {
  y !== null || !t || (y = t, u && t !== u ? console.warn(
    `[LiteRT] Running on ${t}, not the requested ${u}. LiteRT fell back without raising — the model was not fully accelerated.`
  ) : console.log(`[LiteRT] Running on ${t}`));
}
window.loadLiteRtEmbeddings = async function(t, o, r) {
  try {
    if (f) {
      console.log("[LiteRT] Cleaning up previous model before reinitialization (hot restart detected)");
      try {
        await window.cleanupLiteRtEmbeddings();
      } catch (e) {
        console.warn("[LiteRT] Non-fatal cleanup error (will reinitialize anyway):", e), l = null, d = null, T = !1, f = !1;
      }
    }
    const n = r ?? "/node_modules/@litertjs/core/wasm/";
    await I(o), await W(t, n), f = !0;
  } catch (n) {
    throw f = !1, new Error("Failed to initialize LiteRT embeddings: " + n.message);
  }
};
window.generateEmbedding = async function(t) {
  if (!f)
    throw new Error("LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.");
  if (typeof t != "string" || t.trim().length === 0)
    throw new Error("Text must be a non-empty string");
  const o = await k(t);
  return new Float32Array(o);
};
window.generateDocumentEmbedding = async function(t) {
  if (!f)
    throw new Error("LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.");
  if (typeof t != "string" || t.trim().length === 0)
    throw new Error("Text must be a non-empty string");
  const o = await B(t);
  return new Float32Array(o);
};
window.generateEmbeddings = async function(t) {
  if (!f)
    throw new Error("LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.");
  if (!Array.isArray(t))
    throw new Error("texts must be an array");
  const o = [];
  for (const r of t) {
    if (typeof r != "string" || r.trim().length === 0)
      throw new Error("All texts must be non-empty strings");
    const n = await k(r);
    o.push(new Float32Array(n));
  }
  return o;
};
window.getLiteRtEmbeddingAccelerator = function() {
  return y;
};
window.getLiteRtEmbeddingFullyAccelerated = function() {
  return w;
};
window.getLiteRtEmbeddingDimension = function() {
  return p;
};
window.cleanupLiteRtEmbeddings = async function() {
  if (y = null, u = null, g = null, w = null, console.log("[LiteRT] ========================================"), console.log("[LiteRT] Starting cleanup..."), console.log("[LiteRT] ========================================"), l)
    try {
      typeof l.delete == "function" && !l.deleted && (l.delete(), console.log("[LiteRT] ✅ Model deleted"));
    } catch (t) {
      console.warn("[LiteRT] ⚠️  Error deleting model (non-fatal):", t);
    }
  if (l = null, d)
    try {
      d.processor && typeof d.processor.delete == "function" && (d.processor.delete(), console.log("[LiteRT] ✅ Tokenizer deleted"));
    } catch (t) {
      console.warn("[LiteRT] ⚠️  Error deleting tokenizer (non-fatal):", t);
    }
  d = null;
  try {
    const o = M().numTensors;
    o > 0 && (console.log(`[LiteRT] Disposing ${o} TensorFlow.js tensors`), F(), console.log("[LiteRT] ✅ Tensors disposed"));
  } catch (t) {
    console.warn("[LiteRT] ⚠️  Error disposing tensors (non-fatal):", t);
  }
  console.log("[LiteRT] ✅ Keeping WASM runtime (reusable across models)"), c = 256, console.log("[LiteRT] ✅ Reset MAX_SEQUENCE_LENGTH to default"), f = !1, console.log("[LiteRT] ========================================"), console.log("[LiteRT] ✅ Cleanup completed"), console.log("[LiteRT] ========================================");
};
window.isLiteRtEmbeddingsInitialized = function() {
  return f;
};
console.log("LiteRT Embeddings module loaded successfully");
