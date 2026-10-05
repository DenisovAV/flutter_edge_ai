async function j(e) {
  if (typeof importScripts == "function")
    importScripts(e.toString());
  else {
    const t = document.createElement("script");
    return t.src = e.toString(), t.crossOrigin = "anonymous", new Promise((r, n) => {
      t.addEventListener("load", () => {
        r();
      }, !1), t.addEventListener("error", (o) => {
        n(o);
      }, !1), document.body.appendChild(t);
    });
  }
}
var z = async (e, t, r, n, o) => {
  if (t && await j(t), !self.ModuleFactory)
    throw new Error("ModuleFactory not set.");
  const s = await self.ModuleFactory(self.Module || o);
  return self.ModuleFactory = self.Module = void 0, new e(s, n);
}, f = {
  NONE: 0,
  FLOAT32: 1,
  INT32: 2,
  UINT8: 3,
  INT64: 4,
  STRING: 5,
  BOOL: 6,
  INT16: 7,
  COMPLEX64: 8,
  INT8: 9,
  FLOAT16: 10,
  FLOAT64: 11,
  COMPLEX128: 12,
  UINT64: 13,
  RESOURCE: 14,
  VARIANT: 15,
  UINT32: 16,
  UINT16: 17,
  INT4: 18,
  BFLOAT16: 19
}, C = {
  [f.NONE]: "NONE",
  [f.FLOAT32]: "FLOAT32",
  [f.INT32]: "INT32",
  [f.UINT8]: "UINT8",
  [f.INT64]: "INT64",
  [f.STRING]: "STRING",
  [f.BOOL]: "BOOL",
  [f.INT16]: "INT16",
  [f.COMPLEX64]: "COMPLEX64",
  [f.INT8]: "INT8",
  [f.FLOAT16]: "FLOAT16",
  [f.FLOAT64]: "FLOAT64",
  [f.COMPLEX128]: "COMPLEX128",
  [f.UINT64]: "UINT64",
  [f.RESOURCE]: "RESOURCE",
  [f.VARIANT]: "VARIANT",
  [f.UINT32]: "UINT32",
  [f.UINT16]: "UINT16",
  [f.INT4]: "INT4",
  [f.BFLOAT16]: "BFLOAT16"
}, p = {
  HOST_MEMORY: 1,
  WEB_GPU_BUFFER: 20,
  WEB_GPU_BUFFER_FP16: 21,
  WEB_GPU_BUFFER_PACKED: 26
}, E = {
  [p.HOST_MEMORY]: "HOST_MEMORY",
  [p.WEB_GPU_BUFFER]: "WEB_GPU_BUFFER",
  [p.WEB_GPU_BUFFER_FP16]: "WEB_GPU_BUFFER_FP16",
  [p.WEB_GPU_BUFFER_PACKED]: "WEB_GPU_BUFFER_PACKED"
}, H = Object.freeze([
  {
    dtype: "float32",
    typedArrayConstructor: Float32Array,
    elementType: f.FLOAT32
  },
  {
    dtype: "int32",
    typedArrayConstructor: Int32Array,
    elementType: f.INT32
  },
  {
    dtype: "uint8",
    typedArrayConstructor: Uint8Array,
    elementType: f.UINT8
  }
]);
function B(e) {
  for (const t of H)
    if (t.dtype === e || t.typedArrayConstructor === e || e instanceof t.typedArrayConstructor || t.elementType === e)
      return t;
  throw typeof e == "string" ? new Error(`DType ${e} is not supported.`) : e instanceof Object ? new Error(`Typed array ${"name" in e ? e.name : e.constructor.name} is not supported.`) : new Error(
    `Element type ${C[e] ?? e} is not supported.`
  );
}
var Y = class extends Error {
  constructor() {
    super(
      "LiteRT is not initialized yet. Please call loadLiteRt() and wait for its promise to resolve to load the LiteRT WASM module."
    );
  }
}, A = void 0, S = void 0;
function y() {
  if (!A)
    throw new Y();
  return A;
}
function q(e) {
  A = e;
}
function V() {
  return S;
}
function K() {
  return !!S;
}
function W(e) {
  S = e;
}
var J = {
  webgpu: p.WEB_GPU_BUFFER_PACKED,
  wasm: p.HOST_MEMORY
}, X = {
  [p.HOST_MEMORY]: "wasm",
  [p.WEB_GPU_BUFFER]: "webgpu",
  [p.WEB_GPU_BUFFER_FP16]: "webgpu",
  [p.WEB_GPU_BUFFER_PACKED]: "webgpu"
}, Z = [
  "shader-f16",
  "subgroups"
], U = class I {
  constructor(t) {
    this.options = t, this.liteRtEnvironment = y().liteRtWasm.LiteRtEnvironment.create(
      t.webGpuDevice
    );
  }
  liteRtEnvironment;
  static async create(t = {}) {
    let r = null;
    if ("webGpuDevice" in t)
      t.webGpuDevice && (r = t.webGpuDevice);
    else
      try {
        r = await Q();
      } catch (n) {
        console.warn("Failed to create default WebGPU device:", n);
      }
    return new I({
      ...t,
      webGpuDevice: r
    });
  }
  get webGpuDevice() {
    return this.options.webGpuDevice;
  }
  delete() {
    this.liteRtEnvironment.delete();
  }
};
async function Q() {
  const e = {
    powerPreference: "high-performance"
  }, t = await navigator.gpu.requestAdapter(e);
  if (!t)
    throw new Error("No GPU adapter found.");
  const r = {
    maxBufferSize: t.limits.maxBufferSize,
    maxStorageBufferBindingSize: t.limits.maxStorageBufferBindingSize,
    maxStorageBuffersPerShaderStage: t.limits.maxStorageBuffersPerShaderStage,
    maxTextureDimension2D: t.limits.maxTextureDimension2D
  }, n = [];
  for (const o of Z)
    t.features.has(o) && n.push(o);
  return await t.requestDevice({
    requiredFeatures: n,
    requiredLimits: r
  });
}
function b(e) {
  const t = new Array(e.size());
  for (let r = 0; r < e.size(); ++r)
    t[r] = e.get(r);
  return e.delete(), t;
}
function k(e, t) {
  for (const r of e)
    t.push_back(r);
}
function ee(e) {
  const t = e.shift(), r = y().liteRtWasm;
  if (t instanceof r.LiteRtTensorBuffer)
    return { liteRtTensorBuffer: t };
  if (ArrayBuffer.isView(t))
    return { typedArray: t };
  if (t instanceof GPUBuffer)
    return { gpuBuffer: t };
  throw new Error(
    `Unknown type (${t?.constructor.name ?? t}) provided to create a Tensor`
  );
}
function te(e) {
  return Array.isArray(e[0]) || e[0] instanceof Int32Array ? { shape: e.shift() } : {};
}
function M(e) {
  for (; e.length > 0 && e[0] === void 0; )
    e.shift();
}
function re(e) {
  if (M(e), typeof e[0] == "string") {
    const t = e.shift();
    return { dataType: B(t).dtype };
  } else
    return {};
}
function ne(e) {
  return M(e), e[0] instanceof U ? { environment: e.shift() } : {};
}
function oe(e) {
  return M(e), e[0] instanceof Function ? { onDelete: e.shift() } : {};
}
function se(e) {
  return {
    ...ee(e),
    ...te(e),
    ...re(e),
    ...ne(e),
    ...oe(e)
  };
}
var R = class D {
  liteRtTensorBuffer;
  type;
  environment;
  deletedInternal = !1;
  onDelete;
  static copyFunctions = /* @__PURE__ */ new Map();
  constructor(t, r, n, o, s) {
    const {
      typedArray: a,
      gpuBuffer: i,
      liteRtTensorBuffer: u,
      shape: l,
      dataType: d,
      environment: c,
      onDelete: m
    } = se([t, r, n, o, s]);
    if (this.onDelete = m, this.environment = c ?? y().getDefaultEnvironment(), u) {
      if (l)
        throw new Error(
          "A LiteRtTensorBuffer cannot be provided with a shape."
        );
      if (d)
        throw new Error(
          "A LiteRtTensorBuffer cannot be provided with a data type."
        );
      this.liteRtTensorBuffer = u;
    } else if (i) {
      if (!l)
        throw new Error("A GPUBuffer must be provided with a shape.");
      if (!d)
        throw new Error("A GPUBuffer must be provided with a data type.");
      const [h, w] = ae(
        i,
        l,
        d,
        this.environment
      );
      this.liteRtTensorBuffer = h;
      const g = this.onDelete;
      this.onDelete = () => {
        y().liteRtWasm.wgpuBufferRelease(w), g?.();
      };
    } else if (a)
      this.liteRtTensorBuffer = ue(
        a,
        l,
        c
      );
    else
      throw new Error("No data provided to create a Tensor.");
    this.type = ie(this.liteRtTensorBuffer);
  }
  static fromTypedArray(t, r, n) {
    return new D(t, r, n);
  }
  ensureNotDeleted() {
    if (this.deleted)
      throw new Error("Tensor is deleted and cannot be used.");
  }
  async data() {
    if (this.ensureNotDeleted(), this.liteRtTensorBuffer.bufferType().value === p.HOST_MEMORY)
      return this.toTypedArray();
    const t = await this.copyTo("wasm"), r = await t.data();
    return t.delete(), r;
  }
  toTypedArray() {
    this.ensureNotDeleted();
    const t = y().liteRtWasm;
    if (this.liteRtTensorBuffer.isWebGpuMemory())
      throw new Error(
        "Cannot convert a Tensor with WebGPU memory to a TypedArray."
      );
    if (this.liteRtTensorBuffer.bufferType().value !== t.LiteRtTensorBufferType.HOST_MEMORY.value)
      throw new Error(
        "Cannot convert a Tensor with non-host memory to a TypedArray."
      );
    if (this.liteRtTensorBuffer.size() !== this.liteRtTensorBuffer.packedSize() || this.liteRtTensorBuffer.offset() !== 0)
      throw new Error("Tensors with strides or padding are not yet supported.");
    const r = this.liteRtTensorBuffer.tensorType(), n = r.elementType(), o = t.liteRtGetByteWidth(n);
    r.delete();
    const s = B(
      n.value
    ).typedArrayConstructor;
    if (s.BYTES_PER_ELEMENT !== o)
      throw new Error(
        `Byte width ${o} of the tensor's element type ${C[n.value]} does not match the expected byte width ${s.BYTES_PER_ELEMENT} of the ${s.name}.`
      );
    const a = this.liteRtTensorBuffer.lock(
      y().liteRtWasm.LiteRtTensorBufferLockMode.READ
    );
    try {
      const i = t.HEAPU8.slice(
        a,
        a + this.liteRtTensorBuffer.packedSize()
      );
      return new s(
        i.buffer,
        i.byteOffset,
        i.byteLength / o
      );
    } finally {
      this.liteRtTensorBuffer.unlock();
    }
  }
  getBufferType() {
    return this.ensureNotDeleted(), this.liteRtTensorBuffer.bufferType().value;
  }
  /**
   * Returns the underlying GPUBuffer of the Tensor.
   *
   * Note that the lifetime of the returned GPUBuffer is dependant upon how the
   * Tensor was created. If the Tensor was constructed from a GPUBuffer, then
   * the GPUBuffer will NOT be released when the Tensor is deleted. If the
   * Tensor was copied/moved to GPU from host memory, then the GPU buffer will
   * be released when the Tensor is deleted.
   *
   * The GPU buffer may be larger than the actual data in the tensor.
   *
   * @return The GPUBuffer containing the Tensor's data.
   */
  toGpuBuffer() {
    this.ensureNotDeleted();
    const t = y().liteRtWasm;
    if (!this.liteRtTensorBuffer.isWebGpuMemory())
      throw new Error(
        "Cannot convert a Tensor with non-WebGPU memory to a GPUBuffer."
      );
    const r = this.liteRtTensorBuffer.bufferType().value;
    if (r !== t.LiteRtTensorBufferType.WEB_GPU_BUFFER.value && r !== t.LiteRtTensorBufferType.WEB_GPU_BUFFER_FP16.value && r !== t.LiteRtTensorBufferType.WEB_GPU_BUFFER_PACKED.value)
      throw new Error(
        "Cannot convert a Tensor with host memory to a GPUBuffer."
      );
    if (this.liteRtTensorBuffer.size() !== this.liteRtTensorBuffer.packedSize() || this.liteRtTensorBuffer.offset() !== 0)
      throw new Error("Tensors with strides or padding are not yet supported.");
    const n = this.liteRtTensorBuffer.getWebGpuBuffer();
    return t.WebGPU.getJsObject(n);
  }
  getCopyFunctionSet(t) {
    this.ensureNotDeleted();
    const r = this.getBufferType(), n = D.copyFunctions.get(r);
    if (!n)
      throw new Error(
        `TensorBufferType ${E[r] ?? r} does not support copying or moving`
      );
    const o = typeof t == "string" ? J[t] : t;
    if (o == null)
      throw new Error(
        `Unknown destination '${t}' for copying or moving.`
      );
    const s = n.get(o);
    if (!s) {
      const a = [...n].map(
        ([i]) => E[i] ?? i
      );
      throw new Error(
        `TensorBufferType ${E[r]} does not support copying or moving to ${E[o]}. It supports the following TensorBufferTypes: [${a.join(
          ", "
        )}].`
      );
    }
    return [s, o];
  }
  /**
   * Copies the tensor to the given accelerator.
   *
   * @param destination The accelerator or buffer type to copy to.
   * @return A promise that resolves to the copied tensor.
   */
  async copyTo(t, r) {
    const [n, o] = this.getCopyFunctionSet(t);
    if (!n.copyTo)
      throw new Error(
        `Copying to ${E[o]} is not supported by this tensor.`
      );
    return n.copyTo(this, r);
  }
  /**
   * Moves the tensor to the given accelerator.
   *
   * @param destination The accelerator or buffer type to move to.
   * @return A promise that resolves to the moved tensor.
   */
  async moveTo(t, r) {
    const [n, o] = this.getCopyFunctionSet(t);
    if (!n.moveTo)
      throw new Error(
        `Moving to ${E[o]} is not supported by this tensor.`
      );
    return n.moveTo(this, r);
  }
  get bufferType() {
    return this.liteRtTensorBuffer.bufferType().value;
  }
  get accelerator() {
    const t = X[this.bufferType];
    if (t === void 0)
      throw new Error(
        `TensorBufferType ${E[this.bufferType]} has an unknown accelerator type.`
      );
    return t;
  }
  get deleted() {
    return this.deletedInternal;
  }
  delete() {
    this.deletedInternal || (this.deletedInternal = !0, this.liteRtTensorBuffer.delete(), this.onDelete?.());
  }
};
function ie(e) {
  const t = e.tensorType(), r = t.elementType(), n = t.layout(), o = n.dimensions();
  return n.delete(), t.delete(), {
    dtype: B(r.value).dtype,
    layout: { dimensions: b(o) }
  };
}
function ae(e, t, r, n) {
  const s = y().liteRtWasm, a = new s.VectorInt32();
  k(t, a);
  const i = s.LiteRtLayout.create(a);
  a.delete();
  const u = s.LiteRtRankedTensorType.create(
    { value: B(r).elementType },
    i
  );
  i.delete();
  const l = s.WebGPU.importJsBuffer(e), d = s.LiteRtTensorBuffer.createFromWebGpuBuffer(
    n.liteRtEnvironment,
    u,
    s.LiteRtTensorBufferType.WEB_GPU_BUFFER_PACKED,
    l,
    e.size
  );
  return u.delete(), [d, l];
}
function ue(e, t, r) {
  const n = y(), o = n.liteRtWasm;
  r = r ?? n.getDefaultEnvironment();
  const s = B(e).elementType, a = new o.VectorInt32();
  k(t ?? [e.length], a);
  const i = o.LiteRtLayout.create(a);
  a.delete();
  const u = i.numElements();
  if (e.length !== u)
    throw i.delete(), new Error(
      `Number of elements ${e.length} of the provided TypedArray does not match the expected number of elements ${u}.`
    );
  const l = o.LiteRtRankedTensorType.create(
    { value: s },
    i
  );
  i.delete();
  const c = e.constructor.BYTES_PER_ELEMENT * e.length, m = l.bytes();
  if (c !== m)
    throw l.delete(), new Error(
      `Byte length ${c} of the provided TypedArray does not match the expected buffer size ${m}.`
    );
  const h = o.LiteRtTensorBuffer.createManaged(
    r.liteRtEnvironment,
    o.LiteRtTensorBufferType.HOST_MEMORY,
    l,
    c
  );
  l.delete();
  const w = h.lock(
    o.LiteRtTensorBufferLockMode.WRITE
  );
  try {
    const g = new Uint8Array(
      e.buffer,
      e.byteOffset,
      e.byteLength
    );
    o.HEAPU8.set(g, w);
  } finally {
    h.unlock();
  }
  return h;
}
var le = class {
  constructor(e, t, r, n) {
    this.signatureIndex = e, this.liteRtModel = t, this.liteRtCompiledModel = r, this.options = n, this.liteRtSimpleSignature = t.getSignature(e);
    const o = b(this.liteRtSimpleSignature.inputNames()), s = [];
    for (let u = 0; u < o.length; u++) {
      const l = o[u], d = t.getInputTensorType(e, u), c = r.getInputBufferRequirements(e, u);
      s.push(L(l, u, d, c));
    }
    this.inputDetails = Object.freeze(s);
    const a = b(this.liteRtSimpleSignature.outputNames()), i = [];
    for (let u = 0; u < a.length; u++) {
      const l = a[u], d = t.getOutputTensorType(e, u), c = r.getOutputBufferRequirements(e, u);
      i.push(L(l, u, d, c));
    }
    this.outputDetails = Object.freeze(i);
  }
  inputDetails;
  outputDetails;
  liteRtSimpleSignature;
  deletedInternal = !1;
  /**
   * The string key corresponding to this signature in the model.
   */
  get key() {
    return this.ensureNotDeleted(), this.liteRtSimpleSignature.key();
  }
  /**
   * Get details about each input tensor.
   */
  getInputDetails() {
    return this.ensureNotDeleted(), this.inputDetails;
  }
  /**
   * Get details about each output tensor.
   */
  getOutputDetails() {
    return this.ensureNotDeleted(), this.outputDetails;
  }
  async run(e) {
    this.ensureNotDeleted();
    const t = this.inputsToArray(e), { inputsOnAccelerator: r, cleanup: n } = await this.ensureInputsOnAccelerator(t);
    let o;
    try {
      o = await this.runWithArray(r);
    } finally {
      n();
    }
    return Array.isArray(e) || e instanceof R ? o : this.outputsToRecord(o);
  }
  inputsToArray(e) {
    if (Array.isArray(e)) {
      if (e.length !== this.inputDetails.length)
        throw new Error(
          `run() called with ${e.length} inputs, but signature expects ${this.inputDetails.length} inputs`
        );
      return e;
    }
    if (e instanceof R) {
      if (this.inputDetails.length !== 1)
        throw new Error(
          `run() called with a single tensor, but signature expects ${this.inputDetails.length} inputs`
        );
      return [e];
    }
    const t = [];
    for (const r of this.inputDetails) {
      if (!(r.name in e))
        throw new Error(
          `run() called with input record that is missing input ${r.name} with index ${r.index}`
        );
      t.push(e[r.name]);
    }
    return t;
  }
  outputsToRecord(e) {
    const t = {};
    for (let r = 0; r < this.outputDetails.length; r++)
      t[this.outputDetails[r].name] = e[r];
    return t;
  }
  /**
   * Ensures that all input tensors are on the correct accelerator. Copies any
   * tensors that are not on the correct accelerator.
   *
   * @param inputs The input tensors to be passed to the signature. They must
   *     be in the same order and quantity as the input details.
   * @return A promise that resolves to a list of input tensors that are on the
   *     correct accelerator, and a cleanup function that deletes any tensors
   *     that were copied.
   */
  async ensureInputsOnAccelerator(e) {
    const t = [], r = [], n = this.getInputDetails();
    if (e.length !== n.length)
      throw new Error(`ensureInputsOnAccelerator() called with ${e.length} inputs, but signature expects ${n.length} inputs`);
    for (let o = 0; o < e.length; o++) {
      const s = e[o], a = s.getBufferType(), i = n[o].supportedBufferTypes;
      if (i.size === 0)
        throw new Error(`Tensor ${n[o].name} with index ${n[o].index} has no supported buffer types.`);
      if (i.has(a))
        r.push(s);
      else {
        const u = i.values().next().value, l = await s.copyTo(u);
        t.push(l), r.push(l);
      }
    }
    return {
      inputsOnAccelerator: r,
      cleanup: () => {
        for (const o of t)
          o.delete();
      }
    };
  }
  async runWithArray(e) {
    for (let r = 0; r < e.length; r++) {
      const n = e[r], o = this.liteRtModel.getInputTensorType(this.signatureIndex, r), s = this.liteRtCompiledModel.getInputBufferRequirements(
        this.signatureIndex,
        r
      );
      y().liteRtWasm.checkTensorBufferCompatible(
        n.liteRtTensorBuffer,
        o,
        s
      ), o.delete(), s.delete();
    }
    return (await this.liteRtCompiledModel.run(
      this.signatureIndex,
      e.map((r) => r.liteRtTensorBuffer)
    )).map(
      (r) => new R(r, this.options.environment)
    );
  }
  get deleted() {
    return this.deletedInternal;
  }
  ensureNotDeleted() {
    if (this.deleted)
      throw new Error(
        "CompiledModelSignatureRunner is deleted and cannot be used."
      );
  }
  delete() {
    this.deletedInternal || (this.deletedInternal = !0, this.liteRtSimpleSignature.delete());
  }
};
function L(e, t, r, n) {
  const o = r.layout(), s = b(o.dimensions());
  o.delete();
  const a = new Set(b(n.supportedTypes()).map(({ value: u }) => u)), i = {
    name: e,
    index: t,
    dtype: B(r.elementType().value).dtype,
    shape: new Int32Array(s),
    supportedBufferTypes: a
  };
  return r.delete(), n.delete(), i;
}
var fe = class {
  constructor(e, t, r, n) {
    this.model = e, this.liteRtCompiledModel = t, this.options = r, this.onDelete = n;
    const o = e.liteRtModel.getNumSignatures(), s = {};
    for (let a = 0; a < o; a++) {
      const i = new le(
        a,
        e.liteRtModel,
        t,
        r
      );
      s[i.key] = i;
    }
    this.compiledModelSignatureRunners = Object.freeze(s), this.defaultSignature = Object.values(this.signatures)[0], this.key = this.defaultSignature.key;
  }
  defaultSignature;
  compiledModelSignatureRunners;
  key;
  deletedInternal = !1;
  get signatures() {
    return this.ensureNotDeleted(), this.compiledModelSignatureRunners;
  }
  getInputDetails() {
    return this.ensureNotDeleted(), this.defaultSignature.getInputDetails();
  }
  getOutputDetails() {
    return this.ensureNotDeleted(), this.defaultSignature.getOutputDetails();
  }
  async run(e, t) {
    this.ensureNotDeleted();
    const [r, n] = this.parseRunInputs(e, t);
    return await r.run(n);
  }
  parseRunInputs(e, t) {
    let r, n;
    if (typeof e == "string") {
      if (r = this.signatures[e], !r)
        throw new Error(
          `No signature named ${e} found in model.`
        );
      if (!t)
        throw new Error(
          `No input provided for signature ${e}`
        );
      n = t;
    } else
      r = this.defaultSignature, n = e;
    return [r, n];
  }
  get deleted() {
    return this.deletedInternal;
  }
  ensureNotDeleted() {
    if (this.deleted)
      throw new Error("CompiledModel is deleted and cannot be used.");
  }
  get isFullyAccelerated() {
    return this.ensureNotDeleted(), this.liteRtCompiledModel.isFullyAccelerated();
  }
  delete() {
    if (!this.deletedInternal) {
      this.deletedInternal = !0, this.liteRtCompiledModel.delete(), this.model.delete();
      for (const e of Object.values(
        this.compiledModelSignatureRunners
      ))
        e.delete();
      this.onDelete();
    }
  }
};
async function ce(e) {
  const t = await fetch(e);
  return new Uint8Array(await t.arrayBuffer());
}
async function de(e) {
  let t = 0, r = new Uint8Array(
    1024
    /* arbitrary starting size */
  );
  const n = 2e9;
  for (; ; ) {
    const { done: o, value: s } = await e.read();
    if (s) {
      if (r.byteLength < t + s.byteLength) {
        if (t + s.byteLength > n)
          throw new Error(`Model is too large (> ${n} bytes).`);
        const a = new Uint8Array(Math.min(
          n,
          Math.max(r.byteLength, s.byteLength) * 2
        ));
        a.set(r), r = a;
      }
      r.set(s, t), t += s.byteLength;
    }
    if (o)
      break;
  }
  return r.slice(0, t);
}
var pe = class {
  constructor(e, t) {
    this.liteRtModel = e, this.onDelete = t;
  }
  delete() {
    this.liteRtModel.delete(), this.onDelete();
  }
};
function he(e = {}, t, r) {
  return {
    environment: t,
    accelerator: e.accelerator ?? (t.webGpuDevice ? "webgpu" : "wasm"),
    cpuOptions: e.cpuOptions ?? { numThreads: r },
    gpuOptions: e.gpuOptions ?? {},
    webNNOptions: e.webNNOptions ?? {}
  };
}
var ye = new Uint8Array([
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  5,
  1,
  96,
  0,
  1,
  123,
  3,
  2,
  1,
  0,
  10,
  15,
  1,
  13,
  0,
  65,
  1,
  253,
  15,
  65,
  2,
  253,
  15,
  253,
  128,
  2,
  11
]), Te = new Uint8Array([
  0,
  97,
  115,
  109,
  1,
  0,
  0,
  0,
  1,
  4,
  1,
  96,
  0,
  0,
  3,
  2,
  1,
  0,
  5,
  4,
  1,
  3,
  1,
  1,
  10,
  11,
  1,
  9,
  0,
  65,
  0,
  254,
  16,
  2,
  0,
  26,
  11
]), T = {
  relaxedSimd: void 0,
  threads: void 0,
  jspi: void 0,
  webnn: void 0
};
function x() {
  return "Suspending" in WebAssembly;
}
function me() {
  return typeof navigator < "u" && !!navigator.ml;
}
async function F(e) {
  try {
    return await WebAssembly.instantiate(e), { supported: !0 };
  } catch (t) {
    return { supported: !1, error: t };
  }
}
var we = {
  relaxedSimd: () => (T.relaxedSimd === void 0 && (T.relaxedSimd = F(ye)), T.relaxedSimd),
  threads: () => {
    if (T.threads === void 0)
      try {
        typeof MessageChannel < "u" && new MessageChannel().port1.postMessage(new SharedArrayBuffer(1)), T.threads = F(Te);
      } catch (e) {
        T.threads = Promise.resolve({ supported: !1, error: e });
      }
    return T.threads;
  },
  jspi: () => {
    if (T.jspi === void 0) {
      const e = x();
      T.jspi = Promise.resolve({
        supported: e,
        error: e ? void 0 : new Error("JSPI is not supported")
      });
    }
    return T.jspi;
  },
  webnn: () => {
    if (T.webnn === void 0) {
      const e = me();
      T.webnn = Promise.resolve({
        supported: e,
        error: e ? void 0 : new Error("WebNN is not supported")
      });
    }
    return T.webnn;
  }
};
async function Re(e) {
  const t = we[e]?.();
  if (!t)
    throw new Error(`Unknown feature: ${e}`);
  return (await t).supported;
}
function De(e, t) {
  return y().loadAndCompile(e, t);
}
var Ee = class {
  liteRtWasm;
  defaultEnvironment;
  objectsToDelete = /* @__PURE__ */ new Set();
  constructor(e) {
    this.liteRtWasm = e, this.liteRtWasm.setupLogging();
  }
  setDefaultEnvironment(e) {
    this.defaultEnvironment = e;
  }
  getDefaultEnvironment() {
    if (!this.defaultEnvironment)
      throw new Error("Default environment is not set.");
    return this.defaultEnvironment;
  }
  setWebGpuDevice(e) {
    const t = this.getDefaultEnvironment();
    this.setDefaultEnvironment(new U({
      ...t.options,
      webGpuDevice: e
    }));
  }
  getWebGpuDevice() {
    return this.getDefaultEnvironment().webGpuDevice;
  }
  /**
   * Registers an object to be deleted when this LiteRt instance is deleted.
   * Internal use only.
   */
  _registerObjectForDeletion(e) {
    this.objectsToDelete.add(e);
  }
  /**
   * Unregisters an object from being deleted when this LiteRt instance is
   * deleted. Internal use only.
   */
  _unregisterObjectForDeletion(e) {
    this.objectsToDelete.delete(e);
  }
  /**
   * Loads and compiles a LiteRt model.
   *
   * @param model The model data. This can be a string (the model url), a URL
   *     object, a Uint8Array (the model bytes), or a
   *     ReadableStreamDefaultReader (for streaming model loading).
   * @param compileOptions The options for compiling the model. This includes
   *     the accelerator to use ('webgpu' or 'wasm') and the WebGPU device
   *     (for direct GPU model inputs / outputs).
   * @returns A promise that resolves to the CompiledModel.
   */
  async loadAndCompile(e, t = {}) {
    let r;
    if (typeof e == "string" || e instanceof URL)
      r = await ce(e);
    else if (e instanceof Uint8Array)
      r = e;
    else if (e instanceof ReadableStreamDefaultReader)
      r = await de(e);
    else
      throw new Error("Unsupported model type.");
    const n = t.environment ?? this.getDefaultEnvironment(), o = t.accelerator ?? (n.webGpuDevice ? "webgpu" : "wasm"), s = o === "webgpu";
    if (s && !n.webGpuDevice)
      throw new Error(
        "WebGPU was requested but no WebGPU device is set in the environment."
      );
    const a = he(
      t,
      n,
      this.liteRtWasm.getThreadCount()
    ), i = this.liteRtWasm._malloc(r.byteLength);
    this.liteRtWasm.HEAPU8.set(r, i);
    const u = this.liteRtWasm.loadModel(
      a.environment.liteRtEnvironment,
      i,
      r.byteLength
    ), l = await this.liteRtWasm.compileModel(
      a.environment.liteRtEnvironment,
      u,
      a
    ), d = new pe(u, () => {
      this.liteRtWasm._free(i);
    }), c = new fe(
      d,
      l,
      a,
      () => {
        this.objectsToDelete.delete(c);
      }
    );
    if (this.objectsToDelete.add(c), (s || o === "webnn") && !c.isFullyAccelerated)
      if (x())
        console.warn(
          `%c[LiteRT]%c Model not fully compiled for ${o}. Partially delegating to WASM execution.`,
          "background: #FFA000; color: black; font-weight: bold; padding: 2px 5px; border-radius: 3px;",
          "font-weight: bold;"
        );
      else {
        console.warn(
          `%c[LiteRT]%c Model not fully compiled for ${o} on non-JSPI browser. Falling back to WASM execution.`,
          "background: #D32F2F; color: white; font-weight: bold; padding: 2px 5px; border-radius: 3px;",
          "color: #D32F2F; font-weight: bold;"
        ), c.delete();
        const w = {
          ...t,
          accelerator: "wasm"
        };
        return this.loadAndCompile(r, w);
      }
    return c;
  }
  delete() {
    for (const e of this.objectsToDelete)
      e.delete();
  }
};
function Be(e, t) {
  if (!e) return t;
  if (!t) return e;
  const r = e.endsWith("/") ? e : e + "/", n = t.startsWith("/") ? t.substring(1) : t;
  return r + n;
}
var ge = "litert_wasm_internal.js", be = "litert_wasm_compat_internal.js";
async function ve(e, t) {
  const r = e;
  r.endsWith(".wasm") || r.endsWith(".js");
  const n = await Re("relaxedSimd");
  let o = be;
  n && (o = ge);
  let s = e;
  if (r.endsWith(".wasm"))
    throw new Error(
      "Please load the `.js` file corresponding to the `.wasm` file, or load the directory containing it."
    );
  return r.endsWith(".js") || (s = Be(e, o)), z(Ee, s);
}
function Se(e, t) {
  if (K())
    throw new Error("LiteRT is already loading / loaded.");
  return W(ve(e).then(async (r) => (q(r), r.setDefaultEnvironment(
    await U.create()
  ), r)).catch((r) => {
    throw W(void 0), r;
  })), V();
}
Promise.resolve();
async function O(e, t = {}) {
  const r = t.environment ?? e.environment, n = y().liteRtWasm, o = e.liteRtTensorBuffer;
  if (o.bufferType().value !== p.HOST_MEMORY)
    throw new Error(
      "Source tensor is not in host memory. Cannot copy to host memory."
    );
  const a = o.lock(
    n.LiteRtTensorBufferLockMode.READ
  );
  let i;
  try {
    i = n.LiteRtTensorBuffer.createManaged(
      r.liteRtEnvironment,
      n.LiteRtTensorBufferType.HOST_MEMORY,
      o.tensorType(),
      o.size()
    );
    const u = i.lock(
      n.LiteRtTensorBufferLockMode.WRITE
    );
    try {
      const l = new Uint8Array(
        n.HEAPU8.buffer,
        a,
        o.size()
      );
      n.HEAPU8.set(l, u);
    } finally {
      i.unlock();
    }
  } finally {
    o.unlock();
  }
  if (!i)
    throw new Error("Failed to create destination tensor buffer.");
  return new R(i, r);
}
async function G(e, t = {}) {
  const r = t.environment ?? e.environment, n = r.webGpuDevice;
  if (!n)
    throw new Error(
      "No WebGPU device is available. Did you forget to pass a destination environment that has a WebGPU device?"
    );
  const o = y().liteRtWasm, a = e.liteRtTensorBuffer.size() + 3 & -4, i = n.createBuffer({
    size: a,
    usage: GPUBufferUsage.MAP_WRITE | GPUBufferUsage.COPY_SRC,
    mappedAtCreation: !0
  }), u = await i.getMappedRange(), l = new Uint8Array(u), d = e.liteRtTensorBuffer.lock(
    o.LiteRtTensorBufferLockMode.READ
  );
  try {
    const h = new Uint8Array(
      o.HEAPU8.buffer,
      d,
      e.liteRtTensorBuffer.size()
    );
    l.set(h);
  } finally {
    e.liteRtTensorBuffer.unlock();
  }
  i.unmap();
  const c = n.createBuffer({
    size: a,
    usage: GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE
  }), m = n.createCommandEncoder();
  return m.copyBufferToBuffer(
    i,
    0,
    c,
    0,
    a
  ), n.queue.submit([m.finish()]), i.destroy(), new R(
    c,
    e.type.layout.dimensions,
    e.type.dtype,
    r,
    () => {
      c.destroy();
    }
  );
}
async function N(e, t = {}) {
  const r = t.environment ?? e.environment, n = e.environment.webGpuDevice;
  if (!n)
    throw new Error(
      "No WebGPU device is available. Does the source tensor have a WebGPU device?"
    );
  const o = y().liteRtWasm, s = e.liteRtTensorBuffer, a = s.bufferType();
  if (a !== o.LiteRtTensorBufferType.WEB_GPU_BUFFER_PACKED)
    throw new Error(`Cannot convert a tensor with a non-WebGPU buffer type ${a} to a CPU tensor.`);
  const i = o.WebGPU.getJsObject(
    s.getWebGpuBuffer()
  ), u = s.offset(), l = s.tensorType(), d = l.layout(), c = d.numElements(), m = B(l.elementType().value).typedArrayConstructor;
  d.delete(), l.delete();
  let h = i, w = () => {
  };
  if (!(i.usage & GPUBufferUsage.MAP_READ)) {
    h = n.createBuffer({
      size: i.size,
      usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ
    }), w = () => {
      h.destroy();
    };
    const _ = n.createCommandEncoder();
    _.copyBufferToBuffer(
      i,
      0,
      h,
      0,
      i.size
    ), n.queue.submit([_.finish()]);
  }
  await h.mapAsync(GPUMapMode.READ);
  const g = h.getMappedRange(), P = new m(g, u, c), $ = new R(P, e.type.layout.dimensions, r);
  return h.unmap(), w(), $;
}
function v(e) {
  return async (t, r) => {
    const n = await e(t, r);
    return t.delete(), n;
  };
}
function Ae() {
  R.copyFunctions.set(p.HOST_MEMORY, /* @__PURE__ */ new Map([
    [
      p.HOST_MEMORY,
      {
        copyTo: O,
        // There might be a more efficient way to move
        // from CPU to CPU.
        moveTo: v(O)
      }
    ],
    [
      p.WEB_GPU_BUFFER_PACKED,
      {
        copyTo: G,
        moveTo: v(G)
      }
    ]
  ])), R.copyFunctions.set(p.WEB_GPU_BUFFER_PACKED, /* @__PURE__ */ new Map([
    [
      p.HOST_MEMORY,
      {
        copyTo: N,
        moveTo: v(N)
      }
    ]
  ]));
}
Ae();
export {
  R as T,
  De as a,
  Se as l
};
