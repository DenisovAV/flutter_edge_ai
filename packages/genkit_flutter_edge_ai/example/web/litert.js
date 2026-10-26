async function ue(t) {
  if (typeof importScripts == "function")
    importScripts(t.toString());
  else {
    const e = document.createElement("script");
    return e.src = t.toString(), e.crossOrigin = "anonymous", new Promise((n, r) => {
      e.addEventListener("load", () => {
        n();
      }, !1), e.addEventListener("error", (s) => {
        r(s);
      }, !1), document.body.appendChild(e);
    });
  }
}
var de = async (t, e, n, r, s) => {
  if (e && await ue(e), !self.ModuleFactory)
    throw new Error("ModuleFactory not set.");
  const o = await self.ModuleFactory(self.Module || s);
  return self.ModuleFactory = self.Module = void 0, new t(o, r);
}, h = {
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
}, $ = {
  [h.NONE]: "NONE",
  [h.FLOAT32]: "FLOAT32",
  [h.INT32]: "INT32",
  [h.UINT8]: "UINT8",
  [h.INT64]: "INT64",
  [h.STRING]: "STRING",
  [h.BOOL]: "BOOL",
  [h.INT16]: "INT16",
  [h.COMPLEX64]: "COMPLEX64",
  [h.INT8]: "INT8",
  [h.FLOAT16]: "FLOAT16",
  [h.FLOAT64]: "FLOAT64",
  [h.COMPLEX128]: "COMPLEX128",
  [h.UINT64]: "UINT64",
  [h.RESOURCE]: "RESOURCE",
  [h.VARIANT]: "VARIANT",
  [h.UINT32]: "UINT32",
  [h.UINT16]: "UINT16",
  [h.INT4]: "INT4",
  [h.BFLOAT16]: "BFLOAT16"
}, v = {
  HOST_MEMORY: 1,
  WEB_GPU_BUFFER: 20,
  WEB_GPU_BUFFER_FP16: 21,
  WEB_GPU_BUFFER_PACKED: 26
}, P = {
  [v.HOST_MEMORY]: "HOST_MEMORY",
  [v.WEB_GPU_BUFFER]: "WEB_GPU_BUFFER",
  [v.WEB_GPU_BUFFER_FP16]: "WEB_GPU_BUFFER_FP16",
  [v.WEB_GPU_BUFFER_PACKED]: "WEB_GPU_BUFFER_PACKED"
}, ce = typeof Float16Array < "u" ? Float16Array : void 0, fe = typeof BigInt64Array < "u" ? BigInt64Array : void 0, pe = typeof BigUint64Array < "u" ? BigUint64Array : void 0, he = Object.freeze([
  {
    dtype: "float32",
    typedArrayConstructor: Float32Array,
    elementType: h.FLOAT32
  },
  {
    dtype: "int32",
    typedArrayConstructor: Int32Array,
    elementType: h.INT32
  },
  {
    dtype: "uint8",
    typedArrayConstructor: Uint8Array,
    elementType: h.UINT8
  },
  {
    dtype: "int8",
    typedArrayConstructor: Int8Array,
    elementType: h.INT8
  },
  {
    dtype: "bool",
    typedArrayConstructor: Uint8Array,
    elementType: h.BOOL
  },
  {
    dtype: "uint16",
    typedArrayConstructor: Uint16Array,
    elementType: h.UINT16
  },
  {
    dtype: "int16",
    typedArrayConstructor: Int16Array,
    elementType: h.INT16
  },
  {
    dtype: "float16",
    typedArrayConstructor: ce,
    elementType: h.FLOAT16
  },
  {
    dtype: "int64",
    typedArrayConstructor: fe,
    elementType: h.INT64
  },
  {
    dtype: "uint64",
    typedArrayConstructor: pe,
    elementType: h.UINT64
  },
  {
    dtype: "float64",
    typedArrayConstructor: Float64Array,
    elementType: h.FLOAT64
  }
]);
function M(t) {
  for (const e of he)
    if (e.dtype === t || e.typedArrayConstructor === t || e.typedArrayConstructor && t instanceof e.typedArrayConstructor || e.elementType === t)
      return e;
  throw typeof t == "string" ? new Error(`DType ${t} is not supported.`) : t instanceof Object ? new Error(`Typed array ${"name" in t ? t.name : t.constructor.name} is not supported.`) : new Error(`Element type ${$[t] ?? t} is not supported.`);
}
var me = class extends Error {
  constructor() {
    super(
      "LiteRT is not initialized yet. Please call loadLiteRt() and wait for its promise to resolve to load the LiteRT WASM module."
    );
  }
}, j = void 0, z = void 0;
function d() {
  if (!j)
    throw new me();
  return j;
}
function ye(t) {
  j = t;
}
function we() {
  return z;
}
function Te() {
  return !!z;
}
function V(t) {
  z = t;
}
var Re = {
  webgpu: v.WEB_GPU_BUFFER_PACKED,
  wasm: v.HOST_MEMORY
}, ge = {
  [v.HOST_MEMORY]: "wasm",
  [v.WEB_GPU_BUFFER]: "webgpu",
  [v.WEB_GPU_BUFFER_FP16]: "webgpu",
  [v.WEB_GPU_BUFFER_PACKED]: "webgpu"
}, ve = [
  "shader-f16",
  "subgroups"
], K = class te {
  constructor(e) {
    this.options = e, this.liteRtEnvironment = d().liteRtWasm.LiteRtEnvironment.create(
      e.webGpuDevice
    );
  }
  liteRtEnvironment;
  static async create(e = {}) {
    let n = null;
    if ("webGpuDevice" in e)
      e.webGpuDevice && (n = e.webGpuDevice);
    else
      try {
        n = await Ee();
      } catch (r) {
        console.warn("Failed to create default WebGPU device:", r);
      }
    return new te({
      ...e,
      webGpuDevice: n
    });
  }
  get webGpuDevice() {
    return this.options.webGpuDevice;
  }
  delete() {
    this.liteRtEnvironment.delete();
  }
};
async function Ee() {
  const t = {
    powerPreference: "high-performance"
  }, e = await navigator.gpu.requestAdapter(t);
  if (!e)
    throw new Error("No GPU adapter found.");
  const n = {
    maxBufferSize: e.limits.maxBufferSize,
    maxStorageBufferBindingSize: e.limits.maxStorageBufferBindingSize,
    maxStorageBuffersPerShaderStage: e.limits.maxStorageBuffersPerShaderStage,
    maxTextureDimension2D: e.limits.maxTextureDimension2D
  }, r = [];
  for (const s of ve)
    e.features.has(s) && r.push(s);
  return await e.requestDevice({
    requiredFeatures: r,
    requiredLimits: n
  });
}
function L(t) {
  const e = new Array(t.size());
  for (let n = 0; n < t.size(); ++n)
    e[n] = t.get(n);
  return t.delete(), e;
}
function q(t, e) {
  for (const n of t)
    e.push_back(n);
}
function Ae(t) {
  const e = t.shift(), n = d().liteRtWasm;
  if (e instanceof n.LiteRtTensorHandle)
    return { liteRtTensorHandle: e };
  if (ArrayBuffer.isView(e))
    return { typedArray: e };
  if (e instanceof GPUBuffer)
    return { gpuBuffer: e };
  throw new Error(
    `Unknown type (${e?.constructor.name ?? e}) provided to create a Tensor`
  );
}
function be(t) {
  return Array.isArray(t[0]) || t[0] instanceof Int32Array ? { shape: t.shift() } : {};
}
function Y(t) {
  for (; t.length > 0 && t[0] === void 0; )
    t.shift();
}
function De(t) {
  if (Y(t), typeof t[0] == "string") {
    const e = t.shift();
    return { dataType: M(e).dtype };
  } else
    return {};
}
function He(t) {
  return Y(t), t[0] instanceof K ? { environment: t.shift() } : {};
}
function We(t) {
  return Y(t), t[0] instanceof Function ? { onDelete: t.shift() } : {};
}
function Se(t) {
  return {
    ...Ae(t),
    ...be(t),
    ...De(t),
    ...He(t),
    ...We(t)
  };
}
var u = class _ {
  liteRtTensorHandle;
  /** @deprecated Use liteRtTensorHandle instead. */
  get liteRtTensorBuffer() {
    return console.warn(
      "liteRtTensorBuffer is deprecated. Use liteRtTensorHandle instead."
    ), this.liteRtTensorHandle;
  }
  type;
  get shape() {
    return this.type.layout.dimensions;
  }
  get dtype() {
    return this.type.dtype;
  }
  environment;
  deletedInternal = !1;
  onDelete;
  static copyFunctions = /* @__PURE__ */ new Map();
  constructor(e, n, r, s, o) {
    const {
      typedArray: i,
      gpuBuffer: a,
      liteRtTensorHandle: l,
      liteRtTensorBuffer: f,
      shape: c,
      dataType: p,
      environment: y,
      onDelete: A
    } = Se([e, n, r, s, o]);
    this.onDelete = A, this.environment = y ?? d().getDefaultEnvironment();
    const T = l ?? f;
    if (T) {
      if (c)
        throw new Error(
          "A LiteRtTensorHandle cannot be provided with a shape."
        );
      if (p)
        throw new Error(
          "A LiteRtTensorHandle cannot be provided with a data type."
        );
      this.liteRtTensorHandle = T;
    } else if (a) {
      if (!c)
        throw new Error("A GPUBuffer must be provided with a shape.");
      if (!p)
        throw new Error("A GPUBuffer must be provided with a data type.");
      const [N, S] = Ne(
        a,
        c,
        p,
        this.environment
      );
      this.liteRtTensorHandle = N;
      const m = this.onDelete;
      this.onDelete = () => {
        d().liteRtWasm.wgpuBufferRelease(S), m?.();
      };
    } else if (i)
      this.liteRtTensorHandle = Be(
        i,
        c,
        p,
        y
      );
    else
      throw new Error("No data provided to create a Tensor.");
    this.type = Me(this.liteRtTensorHandle);
  }
  static fromTypedArray(e, n, r) {
    return new _(e, n, r);
  }
  static placeholderCounter = 0;
  /**
   * Creates a symbolic placeholder Tensor for JIT graph compilation.
   */
  static createPlaceholder(e = {}) {
    const r = d().liteRtWasm, s = e.shape ?? [1], o = e.dataType ?? "float32", i = e.name || `placeholder_${_.placeholderCounter++}`, a = new r.VectorInt32();
    q(s, a);
    const l = r.LiteRtLayout.create(a);
    a.delete();
    const f = r.LiteRtRankedTensorType.create(
      { value: M(o).elementType },
      l
    );
    l.delete();
    const c = r.LiteRtTensorHandle.createPlaceholder(
      f,
      i
    );
    return f.delete(), new _(c, e.environment);
  }
  ensureNotDeleted() {
    if (this.deleted)
      throw new Error("Tensor is deleted and cannot be used.");
  }
  add(e) {
    return Pe(this, e);
  }
  mul(e) {
    return Ue(this, e);
  }
  sub(e) {
    return Ie(this, e);
  }
  div(e) {
    return _e(this, e);
  }
  pow(e) {
    return Le(this, e);
  }
  minimum(e) {
    return Fe(this, e);
  }
  maximum(e) {
    return Ce(this, e);
  }
  floorDiv(e) {
    return Ge(this, e);
  }
  floorMod(e) {
    return $e(this, e);
  }
  equal(e) {
    return Oe(this, e);
  }
  notEqual(e) {
    return ke(this, e);
  }
  less(e) {
    return xe(this, e);
  }
  greater(e) {
    return je(this, e);
  }
  lessEqual(e) {
    return ze(this, e);
  }
  greaterEqual(e) {
    return ne(this, e);
  }
  logicalAnd(e) {
    return Ke(this, e);
  }
  logicalOr(e) {
    return qe(this, e);
  }
  logicalNot() {
    return Ye(this);
  }
  select(e, n) {
    return Ve(this, e, n);
  }
  relu() {
    return Je(this);
  }
  toString() {
    return this.ensureNotDeleted(), `${this.type.dtype}[${Array.from(this.type.layout.dimensions).join(
      ", "
    )}]`;
  }
  batchMatMul(e, n, r) {
    return Xe(this, e, n, r);
  }
  fullyConnected(e, n) {
    return Ze(this, e, n);
  }
  softmax(e) {
    return Qe(this, e);
  }
  logistic() {
    return et(this);
  }
  tanh() {
    return tt(this);
  }
  gelu(e) {
    return nt(this, e);
  }
  relu6() {
    return rt(this);
  }
  leakyRelu(e) {
    return st(this, e);
  }
  elu() {
    return ot(this);
  }
  hardSwish() {
    return it(this);
  }
  logSoftmax() {
    return at(this);
  }
  conv2d(e, n) {
    return lt(this, e, n);
  }
  depthwiseConv2d(e, n) {
    return ut(this, e, n);
  }
  reshape(e) {
    return dt(this, e);
  }
  transpose(e) {
    return ct(this, e);
  }
  concat(e, n = 0) {
    const r = Array.isArray(e) ? [this, ...e] : [this, e];
    return ft(r, n);
  }
  slice(e, n) {
    return pt(this, e, n);
  }
  pad(e) {
    return ht(this, e);
  }
  expandDims(e) {
    return mt(this, e);
  }
  squeeze(e) {
    return yt(this, e);
  }
  tile(e) {
    return wt(this, e);
  }
  unpack(e, n = 0) {
    return Tt(this, e, n);
  }
  split(e, n = 0) {
    return Rt(this, e, n);
  }
  mean(e, n = !1) {
    return gt(this, e, n);
  }
  sum(e, n = !1) {
    return vt(this, e, n);
  }
  reduceMax(e, n = !1) {
    return Et(this, e, n);
  }
  argMax(e = 0, n = "int32") {
    return At(this, e, n);
  }
  resizeBilinear(e, n, r) {
    return bt(this, e, n, r);
  }
  resizeNearestNeighbor(e, n, r) {
    return Dt(
      this,
      e,
      n,
      r
    );
  }
  maxPool2d(e, n, r) {
    return Ht(this, e, n, r);
  }
  avgPool2d(e, n, r) {
    return Wt(this, e, n, r);
  }
  transposeConv2d(e, n, r = {}) {
    return St(this, e, n, r);
  }
  gather(e, n = 0, r = 0) {
    return Mt(this, e, n, r);
  }
  gatherNd(e) {
    return Nt(this, e);
  }
  oneHot(e, n = 1, r = 0, s = -1) {
    return Bt(this, e, n, r, s);
  }
  embeddingLookup(e) {
    return Pt(this, e);
  }
  topK(e) {
    return Ut(this, e);
  }
  nonMaxSuppression(e, n, r = {}) {
    return It(this, e, n, r);
  }
  cumsum(e = 0, n = !1, r = !1) {
    return _t(this, e, n, r);
  }
  reverse(e) {
    return Lt(this, e);
  }
  spaceToDepth(e) {
    return Ft(this, e);
  }
  depthToSpace(e) {
    return Ct(this, e);
  }
  pRelu(e) {
    return Gt(this, e);
  }
  dynamicUpdateSlice(e, n) {
    return $t(this, e, n);
  }
  abs() {
    return Ot(this);
  }
  neg() {
    return kt(this);
  }
  sqrt() {
    return xt(this);
  }
  rsqrt() {
    return jt(this);
  }
  exp() {
    return zt(this);
  }
  log() {
    return Kt(this);
  }
  sin() {
    return qt(this);
  }
  cos() {
    return Yt(this);
  }
  ceil() {
    return Vt(this);
  }
  floor() {
    return Jt(this);
  }
  round() {
    return Xt(this);
  }
  async data() {
    if (this.ensureNotDeleted(), this.liteRtTensorHandle.bufferType().value === v.HOST_MEMORY)
      return this.toTypedArray();
    const e = await this.copyTo("wasm"), n = await e.data();
    return e.delete(), n;
  }
  toTypedArray() {
    this.ensureNotDeleted();
    const e = d().liteRtWasm;
    if (this.liteRtTensorHandle.isWebGpuMemory())
      throw new Error(
        "Cannot convert a Tensor with WebGPU memory to a TypedArray."
      );
    if (this.liteRtTensorHandle.bufferType().value !== e.LiteRtTensorBufferType.HOST_MEMORY.value)
      throw new Error(
        "Cannot convert a Tensor with non-host memory to a TypedArray."
      );
    if (this.liteRtTensorHandle.size() !== this.liteRtTensorHandle.packedSize() || this.liteRtTensorHandle.offset() !== 0)
      throw new Error("Tensors with strides or padding are not yet supported.");
    const n = this.liteRtTensorHandle.tensorType(), r = n.elementType(), s = e.liteRtGetByteWidth(r);
    n.delete();
    const o = M(
      r.value
    ).typedArrayConstructor;
    if (o === void 0)
      throw new Error(
        `DType ${$[r.value]} is not supported in this environment (missing TypedArray constructor).`
      );
    if (o.BYTES_PER_ELEMENT !== s)
      throw new Error(
        `Byte width ${s} of the tensor's element type ${$[r.value]} does not match the expected byte width ${o.BYTES_PER_ELEMENT} of the ${o.name}.`
      );
    const i = this.liteRtTensorHandle.lock(
      d().liteRtWasm.LiteRtTensorBufferLockMode.READ
    );
    try {
      const a = e.HEAPU8.slice(
        i,
        i + this.liteRtTensorHandle.packedSize()
      );
      return new o(
        a.buffer,
        a.byteOffset,
        a.byteLength / s
      );
    } finally {
      this.liteRtTensorHandle.unlock();
    }
  }
  getBufferType() {
    return this.ensureNotDeleted(), this.liteRtTensorHandle.bufferType().value;
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
    const e = d().liteRtWasm;
    if (!this.liteRtTensorHandle.isWebGpuMemory())
      throw new Error(
        "Cannot convert a Tensor with non-WebGPU memory to a GPUBuffer."
      );
    const n = this.liteRtTensorHandle.bufferType().value;
    if (n !== e.LiteRtTensorBufferType.WEB_GPU_BUFFER.value && n !== e.LiteRtTensorBufferType.WEB_GPU_BUFFER_PACKED.value)
      throw new Error(
        "Cannot convert a Tensor with host memory to a GPUBuffer."
      );
    if (this.liteRtTensorHandle.size() !== this.liteRtTensorHandle.packedSize() || this.liteRtTensorHandle.offset() !== 0)
      throw new Error("Tensors with strides or padding are not yet supported.");
    const r = this.liteRtTensorHandle.getWebGpuBuffer();
    return e.WebGPU.getJsObject(r);
  }
  getCopyFunctionSet(e) {
    this.ensureNotDeleted();
    const n = this.getBufferType(), r = _.copyFunctions.get(n);
    if (!r)
      throw new Error(
        `TensorBufferType ${P[n] ?? n} does not support copying or moving`
      );
    const s = typeof e == "string" ? Re[e] : e;
    if (s == null)
      throw new Error(
        `Unknown destination '${e}' for copying or moving.`
      );
    const o = r.get(s);
    if (!o) {
      const i = [...r].map(
        ([a]) => P[a] ?? a
      );
      throw new Error(
        `TensorBufferType ${P[n]} does not support copying or moving to ${P[s]}. It supports the following TensorBufferTypes: [${i.join(
          ", "
        )}].`
      );
    }
    return [o, s];
  }
  /**
   * Copies the tensor to the given accelerator.
   *
   * @param destination The accelerator or buffer type to copy to.
   * @return A promise that resolves to the copied tensor.
   */
  async copyTo(e, n) {
    const [r, s] = this.getCopyFunctionSet(e);
    if (!r.copyTo)
      throw new Error(
        `Copying to ${P[s]} is not supported by this tensor.`
      );
    return r.copyTo(this, n);
  }
  /**
   * Moves the tensor to the given accelerator.
   *
   * @param destination The accelerator or buffer type to move to.
   * @return A promise that resolves to the moved tensor.
   */
  async moveTo(e, n) {
    const [r, s] = this.getCopyFunctionSet(e);
    if (!r.moveTo)
      throw new Error(
        `Moving to ${P[s]} is not supported by this tensor.`
      );
    return r.moveTo(this, n);
  }
  get bufferType() {
    return this.liteRtTensorHandle.bufferType().value;
  }
  get accelerator() {
    const e = ge[this.bufferType];
    if (e === void 0)
      throw new Error(
        `TensorBufferType ${P[this.bufferType]} has an unknown accelerator type.`
      );
    return e;
  }
  get deleted() {
    return this.deletedInternal;
  }
  delete() {
    this.deletedInternal || (this.deletedInternal = !0, this.liteRtTensorHandle.delete(), this.onDelete?.());
  }
};
function Me(t) {
  const e = t.tensorType(), n = e.elementType(), r = e.layout(), s = r.dimensions();
  return r.delete(), e.delete(), {
    dtype: M(n.value).dtype,
    layout: { dimensions: L(s) }
  };
}
function Ne(t, e, n, r) {
  const o = d().liteRtWasm, i = new o.VectorInt32();
  q(e, i);
  const a = o.LiteRtLayout.create(i);
  i.delete();
  const l = o.LiteRtRankedTensorType.create(
    { value: M(n).elementType },
    a
  );
  a.delete();
  const f = o.WebGPU.importJsBuffer(t), c = o.LiteRtTensorHandle.createFromWebGpuBuffer(
    r.liteRtEnvironment,
    l,
    o.LiteRtTensorBufferType.WEB_GPU_BUFFER_PACKED,
    f,
    t.size
  );
  return l.delete(), [c, f];
}
function Be(t, e, n, r) {
  const s = d(), o = s.liteRtWasm;
  r = r ?? s.getDefaultEnvironment();
  const i = n ? M(n).elementType : M(t).elementType, a = new o.VectorInt32();
  q(e ?? [t.length], a);
  const l = o.LiteRtLayout.create(a);
  a.delete();
  const f = l.numElements();
  if (t.length !== f)
    throw l.delete(), new Error(
      `Number of elements ${t.length} of the provided TypedArray does not match the expected number of elements ${f}.`
    );
  const c = o.LiteRtRankedTensorType.create(
    { value: i },
    l
  );
  l.delete();
  const y = t.constructor.BYTES_PER_ELEMENT * t.length, A = c.bytes();
  if (y !== A)
    throw c.delete(), new Error(
      `Byte length ${y} of the provided TypedArray does not match the expected buffer size ${A}.`
    );
  const T = o.LiteRtTensorHandle.createManaged(
    r.liteRtEnvironment,
    o.LiteRtTensorBufferType.HOST_MEMORY,
    c,
    y
  );
  c.delete();
  const N = T.lock(
    o.LiteRtTensorBufferLockMode.WRITE
  );
  try {
    const S = new Uint8Array(
      t.buffer,
      t.byteOffset,
      t.byteLength
    );
    o.HEAPU8.set(S, N);
  } finally {
    T.unlock();
  }
  return T;
}
function g(t) {
  return (e, n) => {
    if (e.environment !== n.environment)
      throw new Error(
        "Cannot perform arithmetic operations on tensors from different environments."
      );
    e.ensureNotDeleted(), n.ensureNotDeleted();
    const r = t(
      d().liteRtWasm,
      e.liteRtTensorHandle,
      n.liteRtTensorHandle
    );
    return new u(r, e.environment);
  };
}
function w(t) {
  return (e) => {
    e.ensureNotDeleted();
    const n = t(d().liteRtWasm, e.liteRtTensorHandle);
    return new u(n, e.environment);
  };
}
var Pe = g(
  (t, e, n) => t.add(e, n)
), Ue = g(
  (t, e, n) => t.mul(e, n)
), Ie = g(
  (t, e, n) => t.sub(e, n)
), _e = g(
  (t, e, n) => t.div(e, n)
), Le = g(
  (t, e, n) => t.pow(e, n)
), Fe = g(
  (t, e, n) => t.minimum(e, n)
), Ce = g(
  (t, e, n) => t.maximum(e, n)
), Ge = g(
  (t, e, n) => t.floorDiv(e, n)
), $e = g(
  (t, e, n) => t.floorMod(e, n)
), Oe = g(
  (t, e, n) => t.equal(e, n)
), ke = g(
  (t, e, n) => t.notEqual(e, n)
), xe = g(
  (t, e, n) => t.less(e, n)
), je = g(
  (t, e, n) => t.greater(e, n)
), ne = g(
  (t, e, n) => t.greaterEqual(e, n)
), ze = (t, e) => ne(e, t), Ke = g(
  (t, e, n) => t.logicalAnd(e, n)
), qe = g(
  (t, e, n) => t.logicalOr(e, n)
), Ye = w(
  (t, e) => t.logicalNot(e)
);
function Ve(t, e, n) {
  U([t, e, n]);
  const s = d().liteRtWasm.select(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    n.liteRtTensorHandle
  );
  return new u(s, t.environment);
}
var Je = w(
  (t, e) => t.relu(e)
);
function Xe(t, e, n = !1, r = !1) {
  t.ensureNotDeleted(), e.ensureNotDeleted();
  const o = d().liteRtWasm.batchMatMul(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    n,
    r
  );
  return new u(o, t.environment);
}
function Ze(t, e, n) {
  t.ensureNotDeleted(), e.ensureNotDeleted(), n?.ensureNotDeleted();
  const s = d().liteRtWasm.fullyConnected(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    n?.liteRtTensorHandle
  );
  return new u(s, t.environment);
}
function Qe(t, e = 1) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.softmax(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
var et = w(
  (t, e) => t.logistic(e)
), tt = w(
  (t, e) => t.tanh(e)
);
function nt(t, e = !1) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.gelu(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
var rt = w(
  (t, e) => t.relu6(e)
);
function st(t, e = 0.2) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.leakyRelu(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
var ot = w(
  (t, e) => t.elu(e)
), it = w(
  (t, e) => t.hardSwish(e)
), at = w(
  (t, e) => t.logSoftmax(e)
);
function F(t = "SAME") {
  return typeof t == "number" ? t : t.toUpperCase() === "VALID" ? 1 : 0;
}
function lt(t, e, n = {}) {
  t.ensureNotDeleted(), e.ensureNotDeleted(), n.bias && n.bias.ensureNotDeleted();
  const r = n.strideH ?? 1, s = n.strideW ?? 1, o = F(n.padding), i = n.dilationH ?? 1, a = n.dilationW ?? 1, f = d().liteRtWasm.conv2d(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    n.bias?.liteRtTensorHandle,
    r,
    s,
    o,
    i,
    a
  );
  return new u(f, t.environment);
}
function ut(t, e, n = {}) {
  t.ensureNotDeleted(), e.ensureNotDeleted(), n.bias && n.bias.ensureNotDeleted();
  const r = n.strideH ?? 1, s = n.strideW ?? 1, o = F(n.padding), i = n.depthMultiplier ?? 1, a = n.dilationH ?? 1, l = n.dilationW ?? 1, c = d().liteRtWasm.depthwiseConv2d(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    n.bias?.liteRtTensorHandle,
    r,
    s,
    o,
    i,
    a,
    l
  );
  return new u(c, t.environment);
}
function dt(t, e) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.reshape(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
function ct(t, e) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.transpose(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
function U(t) {
  t = Array.isArray(t) ? t : [t];
  for (let e = 0; e < t.length; e++) {
    const n = t[e];
    if (n.ensureNotDeleted(), n.environment !== t[0].environment)
      throw new Error(
        `Tensor 0 and tensor ${e} are from different environments`
      );
  }
}
function ft(t, e = 0) {
  if (t.length === 0)
    throw new Error("concat requires at least one input tensor.");
  U(t);
  const n = t[0].type.layout.dimensions.length, r = e < 0 ? e + n : e;
  if (r < 0 || r >= n)
    throw new Error(
      `concat axis ${e} is out of bounds for tensor of rank ${n}.`
    );
  const s = d().liteRtWasm, o = t.map((a) => a.liteRtTensorHandle), i = s.concatenation(o, r);
  return new u(i, t[0].environment);
}
function pt(t, e, n) {
  t.ensureNotDeleted();
  const s = d().liteRtWasm.slice(t.liteRtTensorHandle, e, n);
  return new u(s, t.environment);
}
function ht(t, e) {
  t.ensureNotDeleted();
  const n = t.type.layout.dimensions.length;
  let r, s = !1;
  if (e instanceof u) {
    if (U([t, e]), e.type.dtype !== "int32")
      throw new Error(
        `pad requires paddings tensor to have dtype 'int32', but got '${e.type.dtype}'.`
      );
    const i = e.type.layout.dimensions;
    if (i.length !== 2 || i[0] !== n || i[1] !== 2)
      throw new Error(
        `pad requires paddings shape to be [${n}, 2], but got [${i.join(", ")}].`
      );
    r = e;
  } else {
    if (e.length !== n || e.some((a) => a.length !== 2))
      throw new Error(`pad requires paddings shape to be [${n}, 2].`);
    const i = new Int32Array(n * 2);
    for (let a = 0; a < n; ++a) {
      if (e[a][0] < 0 || e[a][1] < 0)
        throw new Error("pad values must be non-negative.");
      i[a * 2] = e[a][0], i[a * 2 + 1] = e[a][1];
    }
    r = u.fromTypedArray(
      i,
      [n, 2],
      t.environment
    ), s = !0;
  }
  let o;
  try {
    o = d().liteRtWasm.pad(
      t.liteRtTensorHandle,
      r.liteRtTensorHandle
    );
  } finally {
    s && r.delete();
  }
  return new u(o, t.environment);
}
function mt(t, e) {
  t.ensureNotDeleted();
  const n = t.type.layout.dimensions.length, r = e < 0 ? e + n + 1 : e;
  if (r < 0 || r > n)
    throw new Error(
      `expandDims axis ${e} is out of bounds for tensor of rank ${n}.`
    );
  const o = d().liteRtWasm.expandDims(t.liteRtTensorHandle, r);
  return new u(o, t.environment);
}
function yt(t, e) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.squeeze(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
function wt(t, e) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.tile(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
function Tt(t, e, n = 0) {
  t.ensureNotDeleted();
  const r = t.type.layout.dimensions.length, s = n < 0 ? n + r : n;
  if (s < 0 || s >= r)
    throw new Error(
      `unpack axis ${n} is out of bounds for tensor of rank ${r}.`
    );
  return d().liteRtWasm.unpack(
    t.liteRtTensorHandle,
    e,
    s
  ).map((a) => new u(a, t.environment));
}
function Rt(t, e, n = 0) {
  t.ensureNotDeleted();
  const r = t.type.layout.dimensions.length, s = n < 0 ? n + r : n;
  if (s < 0 || s >= r)
    throw new Error(
      `split axis ${n} is out of bounds for tensor of rank ${r}.`
    );
  return d().liteRtWasm.split(
    t.liteRtTensorHandle,
    s,
    e
  ).map((a) => new u(a, t.environment));
}
function gt(t, e, n = !1) {
  t.ensureNotDeleted();
  const r = re(e, t.type.layout.dimensions.length), o = d().liteRtWasm.mean(t.liteRtTensorHandle, r, n);
  return new u(o, t.environment);
}
function re(t, e) {
  return t === void 0 ? Array.from({ length: e }, (r, s) => s) : (typeof t == "number" ? [t] : t).map((r) => r < 0 ? r + e : r);
}
function vt(t, e, n = !1) {
  t.ensureNotDeleted();
  const r = re(e, t.type.layout.dimensions.length), o = d().liteRtWasm.sum(t.liteRtTensorHandle, r, n);
  return new u(o, t.environment);
}
function Et(t, e, n = !1) {
  t.ensureNotDeleted();
  let r;
  if (e === void 0) {
    const i = t.type.layout.dimensions.length;
    r = Array.from({ length: i }, (a, l) => l);
  } else typeof e == "number" ? r = [e] : r = e;
  const o = d().liteRtWasm.reduceMax(t.liteRtTensorHandle, r, n);
  return new u(o, t.environment);
}
function At(t, e = 0, n = "int32") {
  t.ensureNotDeleted();
  const s = d().liteRtWasm.argMax(t.liteRtTensorHandle, e, n);
  return new u(s, t.environment);
}
function bt(t, e, n, r) {
  t.ensureNotDeleted();
  let s = !1, o = !1;
  typeof n == "boolean" ? (s = n, o = r ?? !1) : n && (s = n.alignCorners ?? !1, o = n.halfPixelCenters ?? !1);
  const a = d().liteRtWasm.resizeBilinear(
    t.liteRtTensorHandle,
    Array.from(e),
    s,
    o
  );
  return new u(a, t.environment);
}
function Dt(t, e, n, r) {
  t.ensureNotDeleted();
  let s = !1, o = !1;
  typeof n == "boolean" ? (s = n, o = r ?? !1) : n && (s = n.alignCorners ?? !1, o = n.halfPixelCenters ?? !1);
  const a = d().liteRtWasm.resizeNearestNeighbor(
    t.liteRtTensorHandle,
    Array.from(e),
    s,
    o
  );
  return new u(a, t.environment);
}
function se(t, e, n) {
  let r = 2, s = 2, o = 2, i = 2, a = 0;
  if (typeof t == "object" && !Array.isArray(t)) {
    const l = t;
    l.filterSize !== void 0 && (Array.isArray(l.filterSize) ? (r = l.filterSize[0], s = l.filterSize[1]) : (r = l.filterSize, s = l.filterSize)), l.filterHeight !== void 0 && (r = l.filterHeight), l.filterWidth !== void 0 && (s = l.filterWidth), l.strides !== void 0 ? Array.isArray(l.strides) ? (o = l.strides[0], i = l.strides[1]) : (o = l.strides, i = l.strides) : (o = r, i = s), l.strideH !== void 0 && (o = l.strideH), l.strideW !== void 0 && (i = l.strideW), a = F(l.padding);
  } else
    t !== void 0 && (Array.isArray(t) ? (r = t[0], s = t[1]) : (r = t, s = t)), e !== void 0 ? Array.isArray(e) ? (o = e[0], i = e[1]) : (o = e, i = e) : (o = r, i = s), a = F(n);
  return { filterHeight: r, filterWidth: s, strideH: o, strideW: i, paddingVal: a };
}
function Ht(t, e, n, r) {
  t.ensureNotDeleted();
  const { filterHeight: s, filterWidth: o, strideH: i, strideW: a, paddingVal: l } = se(e, n, r), c = d().liteRtWasm.maxPool2d(
    t.liteRtTensorHandle,
    s,
    o,
    i,
    a,
    l
  );
  return new u(c, t.environment);
}
function Wt(t, e, n, r) {
  t.ensureNotDeleted();
  const { filterHeight: s, filterWidth: o, strideH: i, strideW: a, paddingVal: l } = se(e, n, r), c = d().liteRtWasm.avgPool2d(
    t.liteRtTensorHandle,
    s,
    o,
    i,
    a,
    l
  );
  return new u(c, t.environment);
}
function St(t, e, n, r = {}) {
  U(
    r.bias ? [t, e, r.bias] : [t, e]
  );
  let s = 1, o = 1;
  r.strides !== void 0 && (Array.isArray(r.strides) ? (s = r.strides[0], o = r.strides[1]) : (s = r.strides, o = r.strides)), r.strideH !== void 0 && (s = r.strideH), r.strideW !== void 0 && (o = r.strideW);
  const i = F(r.padding), l = d().liteRtWasm.transposeConv2d(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    Array.from(n),
    r.bias?.liteRtTensorHandle,
    s,
    o,
    i
  );
  return new u(l, t.environment);
}
function Mt(t, e, n = 0, r = 0) {
  U([t, e]);
  const o = d().liteRtWasm.gather(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    n,
    r
  );
  return new u(o, t.environment);
}
function Nt(t, e) {
  U([t, e]);
  const r = d().liteRtWasm.gatherNd(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle
  );
  return new u(r, t.environment);
}
function Bt(t, e, n = 1, r = 0, s = -1) {
  t.ensureNotDeleted();
  const i = d().liteRtWasm.oneHot(
    t.liteRtTensorHandle,
    e,
    n,
    r,
    s
  );
  return new u(i, t.environment);
}
var Pt = g((t, e, n) => t.embeddingLookup(e, n));
function Ut(t, e) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.topK(t.liteRtTensorHandle, e);
  return {
    values: new u(r[0], t.environment),
    indices: new u(r[1], t.environment)
  };
}
function It(t, e, n, r = {}) {
  U([t, e]);
  const s = r.iouThreshold ?? 0.5, o = r.scoreThreshold ?? 0, i = r.softNmsSigma ?? 0, l = d().liteRtWasm.nonMaxSuppressionV5(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    n,
    s,
    o,
    i
  );
  return {
    selectedIndices: new u(l[0], t.environment),
    selectedScores: new u(l[1], t.environment),
    validOutputs: new u(l[2], t.environment)
  };
}
function _t(t, e = 0, n = !1, r = !1) {
  t.ensureNotDeleted();
  const o = d().liteRtWasm.cumsum(
    t.liteRtTensorHandle,
    e,
    n,
    r
  );
  return new u(o, t.environment);
}
function Lt(t, e) {
  t.ensureNotDeleted();
  const n = typeof e == "number" ? [e] : e, s = d().liteRtWasm.reverse(t.liteRtTensorHandle, n);
  return new u(s, t.environment);
}
function Ft(t, e) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.spaceToDepth(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
function Ct(t, e) {
  t.ensureNotDeleted();
  const r = d().liteRtWasm.depthToSpace(t.liteRtTensorHandle, e);
  return new u(r, t.environment);
}
var Gt = g(
  (t, e, n) => t.prelu(e, n)
);
function $t(t, e, n) {
  t.ensureNotDeleted(), e.ensureNotDeleted();
  const s = d().liteRtWasm.dynamicUpdateSlice(
    t.liteRtTensorHandle,
    e.liteRtTensorHandle,
    n
  );
  return new u(s, t.environment);
}
var Ot = w(
  (t, e) => t.abs(e)
), kt = w(
  (t, e) => t.neg(e)
), xt = w(
  (t, e) => t.sqrt(e)
), jt = w(
  (t, e) => t.rsqrt(e)
), zt = w(
  (t, e) => t.exp(e)
), Kt = w(
  (t, e) => t.log(e)
), qt = w(
  (t, e) => t.sin(e)
), Yt = w(
  (t, e) => t.cos(e)
), Vt = w(
  (t, e) => t.ceil(e)
), Jt = w(
  (t, e) => t.floor(e)
), Xt = w(
  (t, e) => t.round(e)
);
function Zt(t, e) {
  if (t.length !== e.length) return !1;
  for (let n = 0; n < t.length; n++)
    if (t[n] !== e[n]) return !1;
  return !0;
}
var Qt = class {
  constructor(t, e, n, r) {
    this.signatureIndex = t, this.liteRtModel = e, this.liteRtCompiledModel = n, this.options = r, this.liteRtSimpleSignature = e.getSignature(t);
    const s = L(this.liteRtSimpleSignature.inputNames()), o = [];
    for (let l = 0; l < s.length; l++) {
      const f = s[l], c = e.getInputTensorType(t, l), p = n.getInputBufferRequirements(t, l);
      o.push(J(f, l, c, p));
    }
    this.inputDetails = Object.freeze(o);
    const i = L(this.liteRtSimpleSignature.outputNames()), a = [];
    for (let l = 0; l < i.length; l++) {
      const f = i[l], c = e.getOutputTensorType(t, l), p = n.getOutputBufferRequirements(t, l);
      a.push(J(f, l, c, p));
    }
    this.outputDetails = Object.freeze(a);
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
  async run(t) {
    this.ensureNotDeleted();
    const e = this.inputsToArray(t), { inputsOnAccelerator: n, cleanup: r } = await this.ensureInputsOnAccelerator(e);
    let s;
    try {
      s = await this.runWithArray(n);
    } finally {
      r();
    }
    return Array.isArray(t) || t instanceof u ? s : this.outputsToRecord(s);
  }
  inputsToArray(t) {
    if (Array.isArray(t)) {
      if (t.length !== this.inputDetails.length)
        throw new Error(
          `run() called with ${t.length} inputs, but signature expects ${this.inputDetails.length} inputs`
        );
      return t;
    }
    if (t instanceof u) {
      if (this.inputDetails.length !== 1)
        throw new Error(
          `run() called with a single tensor, but signature expects ${this.inputDetails.length} inputs`
        );
      return [t];
    }
    const e = [];
    for (const n of this.inputDetails) {
      if (!(n.name in t))
        throw new Error(
          `run() called with input record that is missing input ${n.name} with index ${n.index}`
        );
      e.push(t[n.name]);
    }
    return e;
  }
  outputsToRecord(t) {
    const e = {};
    for (let n = 0; n < this.outputDetails.length; n++)
      e[this.outputDetails[n].name] = t[n];
    return e;
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
  async ensureInputsOnAccelerator(t) {
    const e = [], n = [], r = this.getInputDetails();
    if (t.length !== r.length)
      throw new Error(`ensureInputsOnAccelerator() called with ${t.length} inputs, but signature expects ${r.length} inputs`);
    for (let s = 0; s < t.length; s++) {
      const o = t[s], i = o.getBufferType(), a = r[s].supportedBufferTypes;
      if (a.size === 0)
        throw new Error(`Tensor ${r[s].name} with index ${r[s].index} has no supported buffer types.`);
      if (o.type.dtype !== r[s].dtype || !Zt(o.type.layout.dimensions, r[s].shape)) {
        const l = `${r[s].dtype}[${Array.from(r[s].shape).join(", ")}]`;
        throw new Error(
          `TensorBuffer ranked tensor type ${o.toString()} does not match expected ranked tensor type ${l}`
        );
      }
      if (a.has(i))
        n.push(o);
      else {
        const l = a.values().next().value, f = await o.copyTo(l);
        e.push(f), n.push(f);
      }
    }
    return {
      inputsOnAccelerator: n,
      cleanup: () => {
        for (const s of e)
          s.delete();
      }
    };
  }
  async runWithArray(t) {
    for (let n = 0; n < t.length; n++) {
      const r = t[n], s = this.liteRtModel.getInputTensorType(this.signatureIndex, n), o = this.liteRtCompiledModel.getInputBufferRequirements(
        this.signatureIndex,
        n
      );
      d().liteRtWasm.checkTensorBufferCompatible(
        r.liteRtTensorHandle,
        s,
        o
      ), s.delete(), o.delete();
    }
    return (await this.liteRtCompiledModel.run(
      this.signatureIndex,
      t.map((n) => n.liteRtTensorHandle)
    )).map(
      (n) => new u(n, this.options.environment)
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
function J(t, e, n, r) {
  const s = n.layout(), o = L(s.dimensions());
  s.delete();
  const i = new Set(L(r.supportedTypes()).map(({ value: l }) => l)), a = {
    name: t,
    index: e,
    dtype: M(n.elementType().value).dtype,
    shape: new Int32Array(o),
    supportedBufferTypes: i
  };
  return n.delete(), r.delete(), a;
}
var oe = class {
  constructor(t, e, n, r) {
    this.model = t, this.liteRtCompiledModel = e, this.options = n, this.onDelete = r;
    const s = t.liteRtModel.getNumSignatures(), o = {};
    for (let i = 0; i < s; i++) {
      const a = new Qt(
        i,
        t.liteRtModel,
        e,
        n
      );
      o[a.key] = a;
    }
    this.compiledModelSignatureRunners = Object.freeze(o), this.defaultSignature = Object.values(this.signatures)[0], this.key = this.defaultSignature.key;
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
  async run(t, e) {
    this.ensureNotDeleted();
    const [n, r] = this.parseRunInputs(t, e);
    return await n.run(r);
  }
  parseRunInputs(t, e) {
    let n, r;
    if (typeof t == "string") {
      if (n = this.signatures[t], !n)
        throw new Error(
          `No signature named ${t} found in model.`
        );
      if (!e)
        throw new Error(
          `No input provided for signature ${t}`
        );
      r = e;
    } else
      n = this.defaultSignature, r = t;
    return [n, r];
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
      for (const t of Object.values(
        this.compiledModelSignatureRunners
      ))
        t.delete();
      this.onDelete();
    }
  }
};
async function en(t) {
  const e = await fetch(t);
  return new Uint8Array(await e.arrayBuffer());
}
async function tn(t) {
  let e = 0, n = new Uint8Array(
    1024
    /* arbitrary starting size */
  );
  const r = 2e9;
  for (; ; ) {
    const { done: s, value: o } = await t.read();
    if (o) {
      if (n.byteLength < e + o.byteLength) {
        if (e + o.byteLength > r)
          throw new Error(`Model is too large (> ${r} bytes).`);
        const i = new Uint8Array(Math.min(
          r,
          Math.max(n.byteLength, o.byteLength) * 2
        ));
        i.set(n), n = i;
      }
      n.set(o, e), e += o.byteLength;
    }
    if (s)
      break;
  }
  return n.slice(0, e);
}
var ie = class {
  constructor(t, e) {
    this.liteRtModel = t, this.onDelete = e;
  }
  delete() {
    this.liteRtModel.delete(), this.onDelete();
  }
};
function ae(t = {}, e, n) {
  return {
    environment: e,
    accelerator: t.accelerator ?? (e.webGpuDevice ? "webgpu" : "wasm"),
    cpuOptions: t.cpuOptions ?? { numThreads: n },
    gpuOptions: t.gpuOptions ?? {},
    webNNOptions: t.webNNOptions ?? {}
  };
}
var nn = new Uint8Array([
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
]), rn = new Uint8Array([
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
]), b = {
  relaxedSimd: void 0,
  threads: void 0,
  jspi: void 0,
  webnn: void 0
};
function le() {
  return "Suspending" in WebAssembly;
}
function sn() {
  return typeof navigator < "u" && !!navigator.ml;
}
async function X(t) {
  try {
    return await WebAssembly.instantiate(t), { supported: !0 };
  } catch (e) {
    return { supported: !1, error: e };
  }
}
var on = {
  relaxedSimd: () => (b.relaxedSimd === void 0 && (b.relaxedSimd = X(nn)), b.relaxedSimd),
  threads: () => {
    if (b.threads === void 0)
      try {
        typeof MessageChannel < "u" && new MessageChannel().port1.postMessage(new SharedArrayBuffer(1)), b.threads = X(rn);
      } catch (t) {
        b.threads = Promise.resolve({ supported: !1, error: t });
      }
    return b.threads;
  },
  jspi: () => {
    if (b.jspi === void 0) {
      const t = le();
      b.jspi = Promise.resolve({
        supported: t,
        error: t ? void 0 : new Error("JSPI is not supported")
      });
    }
    return b.jspi;
  },
  webnn: () => {
    if (b.webnn === void 0) {
      const t = sn();
      b.webnn = Promise.resolve({
        supported: t,
        error: t ? void 0 : new Error("WebNN is not supported")
      });
    }
    return b.webnn;
  }
};
async function an(t) {
  const e = on[t]?.();
  if (!e)
    throw new Error(`Unknown feature: ${t}`);
  return (await e).supported;
}
function I(t) {
  return typeof t == "object" && t !== null && !(t instanceof u) && "shape" in t && Array.isArray(t.shape) && (t.shape.length === 0 || typeof t.shape[0] == "number");
}
function ln(t) {
  if (t.length === 0)
    throw new Error("compile() requires at least one input specification.");
  if (t.length === 1) {
    const e = t[0];
    if (typeof e == "object" && e !== null && !(e instanceof u) && !I(e) && "signatures" in e) {
      const n = e.signatures;
      if (Array.isArray(n))
        return n.map((r, s) => {
          if (Array.isArray(r))
            return { name: `signature_${s}`, rawInputs: r };
          if (typeof r == "object" && r !== null && "inputs" in r) {
            const o = Array.isArray(r.inputs) ? r.inputs : [r.inputs];
            return { name: r.name ?? `signature_${s}`, rawInputs: o };
          } else
            return { name: `signature_${s}`, rawInputs: [r] };
        });
      if (typeof n == "object" && n !== null)
        return Object.keys(n).map((r) => {
          const s = n[r], o = Array.isArray(s) ? s : [s];
          return { name: r, rawInputs: o };
        });
    }
    if (Array.isArray(e) && e.length > 0 && e.every(
      (r) => Array.isArray(r) || typeof r == "object" && r !== null && !(r instanceof u) && !I(r) && "inputs" in r
    ))
      return e.map((r, s) => {
        if (Array.isArray(r))
          return { name: `signature_${s}`, rawInputs: r };
        {
          const o = Array.isArray(r.inputs) ? r.inputs : [r.inputs];
          return { name: r.name ?? `signature_${s}`, rawInputs: o };
        }
      });
    if (typeof e == "object" && e !== null && !(e instanceof u) && !I(e) && !Array.isArray(e)) {
      const n = Object.keys(e);
      if (!n.every(
        (s) => e[s] instanceof u || I(e[s])
      ) && n.length > 0)
        return n.map((s) => {
          const o = e[s], i = Array.isArray(o) ? o : [o];
          return { name: s, rawInputs: i };
        });
    }
  }
  return [{ name: "serving_default", rawInputs: t }];
}
var un = class {
  constructor(t, e = {}) {
    this.fn = t, this.options = e;
  }
  compiledModels = [];
  compilationPromise;
  cacheKeyToSignature = /* @__PURE__ */ new Map();
  deletedInternal = !1;
  get compiledModel() {
    return this.compiledModels.length > 0 ? this.compiledModels[this.compiledModels.length - 1] : void 0;
  }
  get deleted() {
    return this.deletedInternal;
  }
  ensureNotDeleted() {
    if (this.deletedInternal)
      throw new Error("AuthoredModel is deleted and cannot be used.");
  }
  parseInputs(t, e) {
    let n = [], r = !1, s = !1, o = !1, i = [];
    if (t.length === 1) {
      const c = t[0];
      c instanceof u || I(c) ? (n = [c], r = !0) : Array.isArray(c) ? (n = c, s = !0) : typeof c == "object" && c !== null && (i = Object.keys(c).sort(), n = i.map((p) => c[p]), o = !0);
    } else
      n = t;
    const a = [], l = [];
    for (let c = 0; c < n.length; c++) {
      const p = n[c];
      if (p instanceof u)
        a.push(p), l.push({
          shape: p.type.layout.dimensions,
          dtype: p.type.dtype
        });
      else if (!e && I(p)) {
        const y = p.dataType ?? "float32";
        l.push({
          shape: p.shape,
          dtype: y
        });
      } else {
        const y = e ? "Tensor" : "Tensor or PlaceholderSpec ({ shape: Dimensions, dataType?: DType })";
        throw new Error(`Input at index ${c} is not a valid ${y}.`);
      }
    }
    const f = o ? i.map(
      (c, p) => `${c}:${l[p].dtype}[${l[p].shape.join(",")}]`
    ).join(";") : l.map((c) => `${c.dtype}[${c.shape.join(",")}]`).join(";");
    return {
      normalizedInputs: l,
      inputTensors: e ? a : void 0,
      cacheKey: f,
      isSingleInput: r,
      isArrayInput: s,
      isDictInput: o,
      dictKeys: i
    };
  }
  async compileSignaturesInternal(t) {
    const e = d(), n = e.liteRtWasm, r = this.options.environment ?? e.getDefaultEnvironment(), s = [], o = /* @__PURE__ */ new Set();
    for (let m = 0; m < t.length; m++) {
      const W = t[m], R = this.parseInputs(
        W.rawInputs,
        /* requireTensors= */
        !1
      );
      if (o.has(R.cacheKey))
        throw new Error(
          `Duplicate signature input specification for '${R.cacheKey}'. Each signature in a compile call must have distinct input shapes or dtypes.`
        );
      o.add(R.cacheKey);
      const H = W.name ?? (t.length === 1 ? "serving_default" : `signature_${m}`);
      s.push({ name: H, parsed: R });
    }
    const i = [], a = [], l = [];
    let f = 0, c = 0;
    const p = [];
    try {
      for (const { name: W, parsed: R } of s) {
        const H = R.normalizedInputs.map(
          (E, G) => {
            const k = R.isDictInput ? R.dictKeys[G] : `input_${G}`;
            return u.createPlaceholder({
              shape: E.shape,
              dataType: E.dtype,
              environment: r,
              name: k
            });
          }
        );
        a.push(...H);
        let D;
        if (R.isSingleInput)
          D = this.fn(H[0]);
        else if (R.isArrayInput)
          D = this.fn(H);
        else if (R.isDictInput) {
          const E = {};
          R.dictKeys.forEach((G, k) => {
            E[G] = H[k];
          }), D = this.fn(E);
        } else
          D = this.fn(...H);
        let B = [], C = "single", O;
        if (D instanceof u)
          B = [D], C = "single";
        else if (Array.isArray(D))
          B = D, C = "array";
        else if (typeof D == "object" && D !== null)
          O = Object.keys(D), B = O.map((E) => D[E]), C = "dict";
        else
          throw new Error(
            "AuthoredModel function must return a Tensor, Tensor[], or Record<string, Tensor>."
          );
        for (let E = 0; E < B.length; E++)
          if (!(B[E] instanceof u))
            throw new Error(
              `Output at index ${E} for signature '${W}' is not a Tensor.`
            );
        l.push(...B), i.push({
          name: W,
          inputHandles: H.map((E) => E.liteRtTensorHandle),
          outputHandles: B.map((E) => E.liteRtTensorHandle)
        }), p.push({
          outputFormat: C,
          outputDictKeys: O
        });
      }
      const m = n.createModelDataFromTensorGraph(i);
      f = m.modelDataPtr, c = m.modelSize;
    } finally {
      for (const m of a)
        m.delete();
      for (const m of l)
        m.delete();
    }
    const y = n.loadModel(
      r.liteRtEnvironment,
      f,
      c
    ), A = ae(
      this.options,
      r,
      n.getThreadCount()
    );
    let T;
    try {
      T = await n.compileModel(
        r.liteRtEnvironment,
        y,
        A
      );
    } catch (m) {
      throw n._free(f), y.delete(), m;
    }
    const N = new ie(y, () => {
      n._free(f);
    }), S = new oe(
      N,
      T,
      A,
      () => {
      }
    );
    this.compiledModels.push(S);
    for (let m = 0; m < s.length; m++) {
      const { name: W, parsed: R } = s[m], H = p[m];
      this.cacheKeyToSignature.set(R.cacheKey, {
        compiledModel: S,
        signatureName: W,
        cacheKey: R.cacheKey,
        outputFormat: H.outputFormat,
        outputDictKeys: H.outputDictKeys
      });
    }
    return S;
  }
  /**
   * Compiles the model graph ahead of time into a CompiledModel.
   *
   * Can be invoked with:
   * 1. A single signature (e.g. `compile({ shape: [1, 256, 256, 3] })` or `compile(specA, specB)`)
   * 2. Multiple signatures as an array of input tuples (e.g. `compile([ [{shape: [1, 10]}], [{shape: [4, 10]}] ])`)
   * 3. Multiple named signatures as a dictionary (e.g. `compile({ lowRes: [{shape: [1, 10]}], highRes: [{shape: [4, 10]}] })`)
   *
   * When multiple signatures are provided in a single compile() call, they share the same constant weight buffers.
   * Multiple compile() calls are permitted; each call generates a new CompiledModel.
   */
  async compile(...t) {
    this.ensureNotDeleted();
    const e = ln(t);
    e.length === 1 && e[0].name === "signature_0" && (e[0].name = "serving_default"), this.compilationPromise = this.compileSignaturesInternal(e), await this.compilationPromise;
  }
  /**
   * Returns true if a compiled signature exists in the model for the given input specs or tensors.
   */
  hasCompiledSignature(...t) {
    if (this.ensureNotDeleted(), this.compiledModels.length === 0)
      return !1;
    const { cacheKey: e } = this.parseInputs(
      t,
      /* requireTensors= */
      !1
    );
    return this.cacheKeyToSignature.has(e);
  }
  /**
   * Executes the authored tensor model with concrete inputs.
   *
   * If the input shape/type has not been compiled yet, it is compiled silently under the hood
   * with a notice logged to the console.
   */
  async run(...t) {
    this.ensureNotDeleted();
    const e = this.parseInputs(
      t,
      /* requireTensors= */
      !0
    );
    this.compilationPromise && await this.compilationPromise, this.ensureNotDeleted();
    let n = this.cacheKeyToSignature.get(e.cacheKey);
    n || (console.log(
      `[LiteRT] JIT compiling model for input shape/type '${e.cacheKey}' under the hood...`
    ), this.compilationPromise = this.compileSignaturesInternal([
      { name: "serving_default", rawInputs: t }
    ]), await this.compilationPromise, n = this.cacheKeyToSignature.get(e.cacheKey));
    const r = await n.compiledModel.run(
      n.signatureName,
      e.inputTensors
    );
    switch (n.outputFormat) {
      case "single":
        return r[0];
      case "array":
        return r;
      case "dict": {
        const s = {};
        return n.outputDictKeys.forEach((o, i) => {
          s[o] = r[i];
        }), s;
      }
      default: {
        const s = n.outputFormat;
        throw new Error(`Unhandled output format: ${s}`);
      }
    }
  }
  delete() {
    if (!this.deletedInternal) {
      this.deletedInternal = !0;
      for (const t of this.compiledModels)
        t.delete();
      this.compiledModels.length = 0, this.cacheKeyToSignature.clear();
    }
  }
};
function yn(t, e) {
  return d().loadAndCompile(t, e);
}
var dn = class {
  liteRtWasm;
  defaultEnvironment;
  objectsToDelete = /* @__PURE__ */ new Set();
  constructor(t) {
    this.liteRtWasm = t, this.liteRtWasm.setupLogging();
  }
  setDefaultEnvironment(t) {
    this.defaultEnvironment = t;
  }
  getDefaultEnvironment() {
    if (!this.defaultEnvironment)
      throw new Error("Default environment is not set.");
    return this.defaultEnvironment;
  }
  setWebGpuDevice(t) {
    const e = this.getDefaultEnvironment();
    this.setDefaultEnvironment(new K({
      ...e.options,
      webGpuDevice: t
    }));
  }
  getWebGpuDevice() {
    return this.getDefaultEnvironment().webGpuDevice;
  }
  /**
   * Registers an object to be deleted when this LiteRt instance is deleted.
   * Internal use only.
   */
  _registerObjectForDeletion(t) {
    this.objectsToDelete.add(t);
  }
  /**
   * Unregisters an object from being deleted when this LiteRt instance is
   * deleted. Internal use only.
   */
  _unregisterObjectForDeletion(t) {
    this.objectsToDelete.delete(t);
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
  async loadAndCompile(t, e = {}) {
    let n;
    if (typeof t == "string" || t instanceof URL)
      n = await en(t);
    else if (t instanceof Uint8Array)
      n = t;
    else if (t instanceof ReadableStreamDefaultReader)
      n = await tn(t);
    else
      throw new Error("Unsupported model type.");
    const r = e.environment ?? this.getDefaultEnvironment(), s = e.accelerator ?? (r.webGpuDevice ? "webgpu" : "wasm"), o = s === "webgpu";
    if (o && !r.webGpuDevice)
      throw new Error(
        "WebGPU was requested but no WebGPU device is set in the environment."
      );
    const i = ae(
      e,
      r,
      this.liteRtWasm.getThreadCount()
    ), a = this.liteRtWasm._malloc(n.byteLength) >>> 0;
    if (a === 0)
      throw new Error(
        `Failed to allocate ${n.byteLength} bytes of Wasm memory for the model.`
      );
    this.liteRtWasm.HEAPU8.set(n, a);
    const l = this.liteRtWasm.loadModel(
      i.environment.liteRtEnvironment,
      a,
      n.byteLength
    ), f = await this.liteRtWasm.compileModel(
      i.environment.liteRtEnvironment,
      l,
      i
    ), c = new ie(l, () => {
      this.liteRtWasm._free(a);
    }), p = new oe(
      c,
      f,
      i,
      () => {
        this.objectsToDelete.delete(p);
      }
    );
    if (this.objectsToDelete.add(p), (o || s === "webnn") && !p.isFullyAccelerated)
      if (le())
        console.warn(
          `%c[LiteRT]%c Model not fully compiled for ${s}. Partially delegating to WASM execution.`,
          "background: #FFA000; color: black; font-weight: bold; padding: 2px 5px; border-radius: 3px;",
          "font-weight: bold;"
        );
      else {
        console.warn(
          `%c[LiteRT]%c Model not fully compiled for ${s} on non-JSPI browser. Falling back to WASM execution.`,
          "background: #D32F2F; color: white; font-weight: bold; padding: 2px 5px; border-radius: 3px;",
          "color: #D32F2F; font-weight: bold;"
        ), p.delete();
        const T = {
          ...e,
          accelerator: "wasm"
        };
        return this.loadAndCompile(n, T);
      }
    return p;
  }
  /**
   * Authors a tensor arithmetic function into an AuthoredModel.
   */
  author(t, e = {}) {
    const n = e.environment ?? this.getDefaultEnvironment(), r = new un(t, { ...e, environment: n });
    return this.objectsToDelete.add(r), r;
  }
  delete() {
    for (const t of this.objectsToDelete)
      t.delete();
  }
};
function cn(t, e) {
  if (!t) return e;
  if (!e) return t;
  const n = t.endsWith("/") ? t : t + "/", r = e.startsWith("/") ? e.substring(1) : e;
  return n + r;
}
var fn = "litert_wasm_internal.js", pn = "litert_wasm_compat_internal.js";
async function hn(t, e) {
  const n = t;
  n.endsWith(".wasm") || n.endsWith(".js");
  const r = await an("relaxedSimd");
  let s = pn;
  r && (s = fn);
  let o = t;
  if (n.endsWith(".wasm"))
    throw new Error(
      "Please load the `.js` file corresponding to the `.wasm` file, or load the directory containing it."
    );
  return n.endsWith(".js") || (o = cn(t, s)), de(dn, o);
}
function wn(t, e) {
  if (Te())
    throw new Error("LiteRT is already loading / loaded.");
  return V(hn(t).then(async (n) => (ye(n), n.setDefaultEnvironment(
    await K.create()
  ), n)).catch((n) => {
    throw V(void 0), n;
  })), we();
}
Promise.resolve();
async function Z(t, e = {}) {
  const n = e.environment ?? t.environment, r = d().liteRtWasm, s = t.liteRtTensorHandle;
  if (s.bufferType().value !== v.HOST_MEMORY)
    throw new Error(
      "Source tensor is not in host memory. Cannot copy to host memory."
    );
  const i = s.lock(
    r.LiteRtTensorBufferLockMode.READ
  );
  let a;
  try {
    a = r.LiteRtTensorHandle.createManaged(
      n.liteRtEnvironment,
      r.LiteRtTensorBufferType.HOST_MEMORY,
      s.tensorType(),
      s.size()
    );
    const l = a.lock(
      r.LiteRtTensorBufferLockMode.WRITE
    );
    try {
      const f = new Uint8Array(
        r.HEAPU8.buffer,
        i,
        s.size()
      );
      r.HEAPU8.set(f, l);
    } finally {
      a.unlock();
    }
  } finally {
    s.unlock();
  }
  if (!a)
    throw new Error("Failed to create destination tensor handle.");
  return new u(a, n);
}
async function Q(t, e = {}) {
  const n = e.environment ?? t.environment, r = n.webGpuDevice;
  if (!r)
    throw new Error(
      "No WebGPU device is available. Did you forget to pass a destination environment that has a WebGPU device?"
    );
  const s = d().liteRtWasm, i = t.liteRtTensorHandle.size() + 3 & -4, a = r.createBuffer({
    size: i,
    usage: GPUBufferUsage.MAP_WRITE | GPUBufferUsage.COPY_SRC,
    mappedAtCreation: !0
  }), l = await a.getMappedRange(), f = new Uint8Array(l), c = t.liteRtTensorHandle.lock(
    s.LiteRtTensorBufferLockMode.READ
  );
  try {
    const A = new Uint8Array(
      s.HEAPU8.buffer,
      c,
      t.liteRtTensorHandle.size()
    );
    f.set(A);
  } finally {
    t.liteRtTensorHandle.unlock();
  }
  a.unmap();
  const p = r.createBuffer({
    size: i,
    usage: GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST | GPUBufferUsage.STORAGE
  }), y = r.createCommandEncoder();
  return y.copyBufferToBuffer(
    a,
    0,
    p,
    0,
    i
  ), r.queue.submit([y.finish()]), a.destroy(), new u(
    p,
    t.type.layout.dimensions,
    t.type.dtype,
    n,
    () => {
      p.destroy();
    }
  );
}
async function ee(t, e = {}) {
  const n = e.environment ?? t.environment, r = t.environment.webGpuDevice;
  if (!r)
    throw new Error(
      "No WebGPU device is available. Does the source tensor have a WebGPU device?"
    );
  const s = d().liteRtWasm, o = t.liteRtTensorHandle, i = o.bufferType();
  if (i !== s.LiteRtTensorBufferType.WEB_GPU_BUFFER_PACKED)
    throw new Error(`Cannot convert a tensor with a non-WebGPU buffer type ${i} to a CPU tensor.`);
  const a = s.WebGPU.getJsObject(
    o.getWebGpuBuffer()
  ), l = o.offset(), f = o.tensorType(), c = f.layout(), p = c.numElements(), y = f.elementType().value, A = M(y).typedArrayConstructor;
  if (c.delete(), f.delete(), A === void 0)
    throw new Error(
      `DType ${$[y]} is not supported in this environment (missing TypedArray constructor).`
    );
  let T = a, N = () => {
  };
  if (!(a.usage & GPUBufferUsage.MAP_READ)) {
    T = r.createBuffer({
      size: a.size,
      usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ
    }), N = () => {
      T.destroy();
    };
    const R = r.createCommandEncoder();
    R.copyBufferToBuffer(
      a,
      0,
      T,
      0,
      a.size
    ), r.queue.submit([R.finish()]);
  }
  await T.mapAsync(GPUMapMode.READ);
  const S = T.getMappedRange(), m = new A(S, l, p), W = new u(m, t.type.layout.dimensions, n);
  return T.unmap(), N(), W;
}
function x(t) {
  return async (e, n) => {
    const r = await t(e, n);
    return e.delete(), r;
  };
}
function mn() {
  const t = /* @__PURE__ */ new Map([
    [
      v.HOST_MEMORY,
      {
        copyTo: Z,
        moveTo: x(Z)
      }
    ],
    [
      v.WEB_GPU_BUFFER_PACKED,
      {
        copyTo: Q,
        moveTo: x(Q)
      }
    ]
  ]);
  u.copyFunctions.set(v.HOST_MEMORY, t);
  const e = /* @__PURE__ */ new Map([
    [
      v.HOST_MEMORY,
      {
        copyTo: ee,
        moveTo: x(ee)
      }
    ]
  ]);
  u.copyFunctions.set(v.WEB_GPU_BUFFER_PACKED, e);
}
mn();
export {
  u as T,
  yn as a,
  wn as l
};
