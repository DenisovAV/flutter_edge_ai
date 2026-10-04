import { m as b, d as R, s as A, r as S } from "./tensorflow.js";
import { l as k, a as y, T as h } from "./litert.js";
import { S as M } from "./sentencepiece.js";
const z = "task: search result | query: ", F = "title: none | text: ", p = 2, T = 1, L = 0;
let c = 256;
const g = 768;
let a = null, d = null, u = !1, m = !1;
async function x(n) {
  try {
    const o = await fetch(n);
    if (!o.ok)
      throw new Error(`Failed to fetch tokenizer: ${o.status} ${o.statusText}`);
    const r = await o.arrayBuffer(), t = new M();
    if (typeof t.loadFromBuffer == "function")
      await t.loadFromBuffer(new Uint8Array(r));
    else {
      const e = new Uint8Array(r);
      let l = "";
      for (let s = 0; s < e.length; s++)
        l += String.fromCharCode(e[s]);
      const i = btoa(l);
      await t.loadFromB64StringModel(i);
    }
    return d = {
      encode: (e, l = !1) => {
        const i = t.encodeIds(e);
        return l ? [p, ...i, T] : i;
      },
      decode: (e) => t.decodeIds(e),
      processor: t
    }, d;
  } catch (o) {
    throw new Error("Failed to load SentencePiece tokenizer: " + o.message);
  }
}
async function C(n, o = "/node_modules/@litertjs/core/wasm/") {
  try {
    console.log(`[LiteRT] Loading model from: ${n}`), console.log(`[LiteRT] WASM loaded flag: ${m}`), await A("webgl"), await S(), m ? console.log("[LiteRT] WASM runtime already loaded, reusing") : (console.log(`[LiteRT] Loading WASM runtime from: ${o}`), await k(o), m = !0, console.log("[LiteRT] WASM runtime loaded successfully"));
    try {
      console.log("[LiteRT] Attempting to compile model with WebGPU..."), a = await y(n, {
        accelerator: "webgpu"
      }), console.log("[LiteRT] Model compiled with WebGPU successfully");
    } catch (r) {
      console.warn("[LiteRT] WebGPU not available, falling back to WASM:", r.message), a = await y(n, {
        accelerator: "wasm"
      }), console.log("[LiteRT] Model compiled with WASM successfully");
    }
    try {
      const r = a.getInputDetails();
      if (r && r.length > 0) {
        const t = r[0].shape;
        if (t && t.length >= 2) {
          const e = t[1];
          e !== c && (c = e, console.log(`[LiteRT] Auto-detected maxSequenceLength: ${c}`));
        }
      }
    } catch (r) {
      console.warn("[LiteRT] Failed to auto-detect sequence length, using default:", r);
    }
    return a;
  } catch (r) {
    throw new Error("Failed to load LiteRT model: " + r.message);
  }
}
function D(n) {
  const o = d.encode(z, !1), r = "▁" + n, t = d.encode(r, !1);
  let e = [...o, ...t];
  if (e.unshift(p), e.push(T), e.length > c)
    e = e.slice(0, c);
  else if (e.length < c) {
    const l = c - e.length;
    e = [...e, ...new Array(l).fill(L)];
  }
  return e;
}
function I(n) {
  const o = d.encode(F, !1), r = "▁" + n, t = d.encode(r, !1);
  let e = [...o, ...t];
  if (e.unshift(p), e.push(T), e.length > c)
    e = e.slice(0, c);
  else if (e.length < c) {
    const l = c - e.length;
    e = [...e, ...new Array(l).fill(L)];
  }
  return e;
}
async function E(n) {
  if (!a || !d)
    throw new Error("Model or tokenizer not initialized. Call loadLiteRtEmbeddings first.");
  const o = D(n), r = new Int32Array(o), t = new h(r, [1, c]), e = t;
  try {
    const i = (await a.run(e))[0];
    let s = i;
    i.accelerator === "webgpu" && (s = await i.moveTo("wasm"));
    const w = s.toTypedArray(), f = Array.from(w);
    return f.length !== g && console.warn(`Unexpected embedding dimension: ${f.length}, expected ${g}`), e !== t && !e.deleted && e.delete(), t.deleted || t.delete(), s !== i && !s.deleted && s.delete(), i.deleted || i.delete(), f;
  } catch (l) {
    try {
      e !== t && !e.deleted && e.delete(), t.deleted || t.delete();
    } catch (i) {
      console.warn("[LiteRT] Tensor cleanup failed:", i);
    }
    throw l;
  }
}
async function _(n) {
  if (!a || !d)
    throw new Error("Model or tokenizer not initialized. Call loadLiteRtEmbeddings first.");
  const o = I(n), r = new Int32Array(o), t = new h(r, [1, c]), e = t;
  try {
    const i = (await a.run(e))[0];
    let s = i;
    i.accelerator === "webgpu" && (s = await i.moveTo("wasm"));
    const w = s.toTypedArray(), f = Array.from(w);
    return f.length !== g && console.warn(`Unexpected embedding dimension: ${f.length}, expected ${g}`), e !== t && !e.deleted && e.delete(), t.deleted || t.delete(), s !== i && !s.deleted && s.delete(), i.deleted || i.delete(), f;
  } catch (l) {
    try {
      e !== t && !e.deleted && e.delete(), t.deleted || t.delete();
    } catch (i) {
      console.warn("[LiteRT] Tensor cleanup failed:", i);
    }
    throw l;
  }
}
window.loadLiteRtEmbeddings = async function(n, o, r) {
  try {
    if (u) {
      console.log("[LiteRT] Cleaning up previous model before reinitialization (hot restart detected)");
      try {
        await window.cleanupLiteRtEmbeddings();
      } catch (e) {
        console.warn("[LiteRT] Non-fatal cleanup error (will reinitialize anyway):", e), a = null, d = null, m = !1, u = !1;
      }
    }
    const t = r ?? "/node_modules/@litertjs/core/wasm/";
    await x(o), await C(n, t), u = !0;
  } catch (t) {
    throw u = !1, new Error("Failed to initialize LiteRT embeddings: " + t.message);
  }
};
window.generateEmbedding = async function(n) {
  if (!u)
    throw new Error("LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.");
  if (typeof n != "string" || n.trim().length === 0)
    throw new Error("Text must be a non-empty string");
  const o = await E(n);
  return new Float32Array(o);
};
window.generateDocumentEmbedding = async function(n) {
  if (!u)
    throw new Error("LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.");
  if (typeof n != "string" || n.trim().length === 0)
    throw new Error("Text must be a non-empty string");
  const o = await _(n);
  return new Float32Array(o);
};
window.generateEmbeddings = async function(n) {
  if (!u)
    throw new Error("LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.");
  if (!Array.isArray(n))
    throw new Error("texts must be an array");
  const o = [];
  for (const r of n) {
    if (typeof r != "string" || r.trim().length === 0)
      throw new Error("All texts must be non-empty strings");
    const t = await E(r);
    o.push(new Float32Array(t));
  }
  return o;
};
window.getLiteRtEmbeddingDimension = function() {
  return g;
};
window.cleanupLiteRtEmbeddings = async function() {
  if (console.log("[LiteRT] ========================================"), console.log("[LiteRT] Starting cleanup..."), console.log("[LiteRT] ========================================"), a)
    try {
      typeof a.delete == "function" && !a.deleted && (a.delete(), console.log("[LiteRT] ✅ Model deleted"));
    } catch (n) {
      console.warn("[LiteRT] ⚠️  Error deleting model (non-fatal):", n);
    }
  if (a = null, d)
    try {
      d.processor && typeof d.processor.delete == "function" && (d.processor.delete(), console.log("[LiteRT] ✅ Tokenizer deleted"));
    } catch (n) {
      console.warn("[LiteRT] ⚠️  Error deleting tokenizer (non-fatal):", n);
    }
  d = null;
  try {
    const o = b().numTensors;
    o > 0 && (console.log(`[LiteRT] Disposing ${o} TensorFlow.js tensors`), R(), console.log("[LiteRT] ✅ Tensors disposed"));
  } catch (n) {
    console.warn("[LiteRT] ⚠️  Error disposing tensors (non-fatal):", n);
  }
  console.log("[LiteRT] ✅ Keeping WASM runtime (reusable across models)"), c = 256, console.log("[LiteRT] ✅ Reset MAX_SEQUENCE_LENGTH to default"), u = !1, console.log("[LiteRT] ========================================"), console.log("[LiteRT] ✅ Cleanup completed"), console.log("[LiteRT] ========================================");
};
window.isLiteRtEmbeddingsInitialized = function() {
  return u;
};
console.log("LiteRT Embeddings module loaded successfully");
