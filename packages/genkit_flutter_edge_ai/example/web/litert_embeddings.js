import { m as E, d as k, s as $, r as S } from "./tensorflow.js";
import { l as M, a as y, T as I } from "./litert.js";
import { S as _ } from "./sentencepiece.js";
const z = 2, L = 2, R = 1, F = 0;
let r = null, s = null, u = !1, w = !1, c = null, f = null, p = null, a = null, d = null, m = null;
async function W(e) {
  try {
    const t = await fetch(e);
    if (!t.ok)
      throw new Error(`Failed to fetch tokenizer: ${t.status} ${t.statusText}`);
    const n = await t.arrayBuffer(), o = new _();
    if (typeof o.loadFromBuffer == "function")
      await o.loadFromBuffer(new Uint8Array(n));
    else {
      const l = new Uint8Array(n);
      let i = "";
      for (let h = 0; h < l.length; h++)
        i += String.fromCharCode(l[h]);
      const g = btoa(i);
      await o.loadFromB64StringModel(g);
    }
    return s = {
      encode: (l, i = !1) => {
        const g = o.encodeIds(l);
        return i ? [L, ...g, R] : g;
      },
      decode: (l) => o.decodeIds(l),
      processor: o
    }, s;
  } catch (t) {
    throw new Error("Failed to load SentencePiece tokenizer: " + t.message);
  }
}
async function B(e, t = "/node_modules/@litertjs/core/wasm/") {
  try {
    console.log(`[LiteRT] Loading model from: ${e}`), console.log(`[LiteRT] WASM loaded flag: ${w}`), await $("webgl"), await S(), w ? console.log("[LiteRT] WASM runtime already loaded, reusing") : (console.log(`[LiteRT] Loading WASM runtime from: ${t}`), await M(t), w = !0, console.log("[LiteRT] WASM runtime loaded successfully"));
    try {
      console.log("[LiteRT] Attempting to compile model with WebGPU..."), a = "webgpu", r = await y(e, {
        accelerator: "webgpu"
      }), console.log("[LiteRT] Model compiled, accelerator confirmed on first run");
    } catch (n) {
      console.warn("[LiteRT] WebGPU not available, falling back to WASM:", n.message), a = "wasm", r = await y(e, {
        accelerator: "wasm"
      }), console.log("[LiteRT] Model compiled with WASM successfully");
    }
    return d = r.options?.accelerator ?? null, d && d !== a && console.warn(
      `[LiteRT] Compiled for ${d}, not the requested ${a}. LiteRT recompiled without raising.`
    ), v(r), x(r), c = C(r), f = D(r), console.log(
      `[LiteRT] Model input length ${c}, dimension ${f}`
    ), r;
  } catch (n) {
    throw new Error("Failed to load LiteRT model: " + n.message);
  }
}
function x(e) {
  const t = e.getInputDetails() ?? [];
  if (t.length === 1) return;
  const n = Array.from(t, (o) => o?.name).filter(Boolean);
  throw new Error(
    `the model declares ${t.length} inputs` + (n.length ? ` (${n.join(", ")})` : "") + " but LiteRT.js embeddings feed exactly one: the token ids. A graph that also takes attention_mask or token_type_ids (a BERT / MiniLM export) cannot run here; register flutter_edge_ai_onnx's OnnxEmbeddingBackend and install the .onnx export of the same model instead."
  );
}
function C(e) {
  const t = e.getInputDetails()?.[0]?.shape, n = t && t.length >= 2 ? t[1] : void 0;
  if (!Number.isInteger(n) || n <= 0)
    throw new Error(
      `cannot read the input sequence length from the model (input 0 shape: ${b(t)})`
    );
  return n;
}
function D(e) {
  const t = e.getOutputDetails()?.[0]?.shape, n = t && t.length >= 1 ? t[t.length - 1] : void 0;
  if (!Number.isInteger(n) || n <= 0)
    throw new Error(
      `cannot read the embedding dimension from the model (output 0 shape: ${b(t)})`
    );
  return n;
}
function b(e) {
  return e ? `[${Array.from(e).join(", ")}]` : "none";
}
function A(e) {
  if (!u || !s)
    throw new Error("LiteRT embeddings not initialized. Call loadLiteRtEmbeddings first.");
  if (typeof e != "string")
    throw new Error(`The text must be a string, got ${typeof e}`);
  return [L, ...s.processor.encodeIds(e), R];
}
async function O(e) {
  const t = new Int32Array(c).fill(F);
  t.set(e);
  const n = new I(t, [1, c]);
  let o = [], l = null;
  try {
    o = await r.run(n);
    const i = o[0];
    if (!i) throw new Error("the model returned no output tensor");
    return N(i.accelerator), l = i.accelerator === "webgpu" ? await i.moveTo("wasm") : i, Float32Array.from(l.toTypedArray());
  } finally {
    for (const i of Array.isArray(o) ? o : [])
      T(i);
    T(l), T(n);
  }
}
function T(e) {
  if (!(!e || e.deleted))
    try {
      e.delete();
    } catch (t) {
      console.warn("[LiteRT] Could not free a tensor:", t);
    }
}
function v(e) {
  if (d && d !== a) {
    m = !1;
    return;
  }
  let t;
  try {
    t = e.isFullyAccelerated;
  } catch {
    return;
  }
  const n = d ?? a;
  n !== "wasm" && (t === !1 ? (m = !1, console.warn(
    `[LiteRT] Model is not fully accelerated on ${n}. Unsupported ops run in WASM, so the accelerator reported after the first embedding is where the output buffer lives, not where every op ran.`
  )) : t === !0 && (m = !0));
}
function N(e) {
  p !== null || !e || (p = e, a && e !== a ? console.warn(
    `[LiteRT] Running on ${e}, not the requested ${a}. LiteRT fell back without raising — the model was not fully accelerated.`
  ) : console.log(`[LiteRT] Running on ${e}`));
}
window.liteRtEmbeddingsApiVersion = z;
window.loadLiteRtEmbeddings = async function(e, t, n) {
  try {
    if (u) {
      console.log("[LiteRT] Cleaning up previous model before reinitialization (hot restart detected)");
      try {
        await window.cleanupLiteRtEmbeddings();
      } catch (l) {
        console.warn("[LiteRT] Non-fatal cleanup error (will reinitialize anyway):", l), r = null, s = null, w = !1, u = !1, c = null, f = null;
      }
    }
    const o = n ?? "/node_modules/@litertjs/core/wasm/";
    return await W(t), await B(e, o), u = !0, { dimension: f, maxInputTokens: c };
  } catch (o) {
    throw u = !1, new Error("Failed to initialize LiteRT embeddings: " + o.message);
  }
};
window.embedLiteRtText = async function(e) {
  const t = A(e);
  return t.length > c ? {
    status: "too_long",
    actualTokens: t.length,
    maxInputTokens: c
  } : { status: "ok", values: await O(t) };
};
window.tokenizeLiteRtText = function(e) {
  return Int32Array.from(A(e));
};
window.getLiteRtEmbeddingAccelerator = function() {
  return p;
};
window.getLiteRtEmbeddingFullyAccelerated = function() {
  return m;
};
window.getLiteRtEmbeddingDimension = function() {
  return f;
};
window.cleanupLiteRtEmbeddings = async function() {
  if (p = null, a = null, d = null, m = null, console.log("[LiteRT] ========================================"), console.log("[LiteRT] Starting cleanup..."), console.log("[LiteRT] ========================================"), r)
    try {
      typeof r.delete == "function" && !r.deleted && (r.delete(), console.log("[LiteRT] ✅ Model deleted"));
    } catch (e) {
      console.warn("[LiteRT] ⚠️  Error deleting model (non-fatal):", e);
    }
  if (r = null, s)
    try {
      s.processor && typeof s.processor.delete == "function" && (s.processor.delete(), console.log("[LiteRT] ✅ Tokenizer deleted"));
    } catch (e) {
      console.warn("[LiteRT] ⚠️  Error deleting tokenizer (non-fatal):", e);
    }
  s = null;
  try {
    const t = E().numTensors;
    t > 0 && (console.log(`[LiteRT] Disposing ${t} TensorFlow.js tensors`), k(), console.log("[LiteRT] ✅ Tensors disposed"));
  } catch (e) {
    console.warn("[LiteRT] ⚠️  Error disposing tensors (non-fatal):", e);
  }
  console.log("[LiteRT] ✅ Keeping WASM runtime (reusable across models)"), c = null, f = null, u = !1, console.log("[LiteRT] ========================================"), console.log("[LiteRT] ✅ Cleanup completed"), console.log("[LiteRT] ========================================");
};
window.isLiteRtEmbeddingsInitialized = function() {
  return u;
};
console.log("LiteRT Embeddings module loaded successfully");
