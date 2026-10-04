function Qa(n, e) {
  for (var t = 0; t < e.length; t++) {
    const s = e[t];
    if (typeof s != "string" && !Array.isArray(s)) {
      for (const o in s)
        if (o !== "default" && !(o in n)) {
          const r = Object.getOwnPropertyDescriptor(s, o);
          r && Object.defineProperty(n, o, r.get ? r : {
            enumerable: !0,
            get: () => s[o]
          });
        }
    }
  }
  return Object.freeze(Object.defineProperty(n, Symbol.toStringTag, { value: "Module" }));
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Za = 1e-7, Ja = 1e-4;
class ec {
  constructor(e, t) {
    this.backend = e, this.dataMover = t, this.data = /* @__PURE__ */ new WeakMap(), this.dataIdsCount = 0;
  }
  get(e) {
    return this.data.has(e) || this.dataMover.moveData(this.backend, e), this.data.get(e);
  }
  set(e, t) {
    this.dataIdsCount++, this.data.set(e, t);
  }
  has(e) {
    return this.data.has(e);
  }
  delete(e) {
    return this.dataIdsCount--, this.data.delete(e);
  }
  numDataIds() {
    return this.dataIdsCount;
  }
}
class vr {
  refCount(e) {
    return fe("refCount");
  }
  incRef(e) {
    return fe("incRef");
  }
  timerAvailable() {
    return !0;
  }
  time(e) {
    return fe("time");
  }
  read(e) {
    return fe("read");
  }
  readSync(e) {
    return fe("readSync");
  }
  readToGPU(e, t) {
    return fe("readToGPU");
  }
  numDataIds() {
    return fe("numDataIds");
  }
  disposeData(e, t) {
    return fe("disposeData");
  }
  write(e, t, s) {
    return fe("write");
  }
  move(e, t, s, o, r) {
    return fe("move");
  }
  createTensorFromGPUData(e, t, s) {
    return fe("createTensorFromGPUData");
  }
  memory() {
    return fe("memory");
  }
  /** Returns the highest precision for floats in bits (e.g. 16 or 32) */
  floatPrecision() {
    return fe("floatPrecision");
  }
  /** Returns the smallest representable number.  */
  epsilon() {
    return this.floatPrecision() === 32 ? Za : Ja;
  }
  dispose() {
    return fe("dispose");
  }
}
function fe(n) {
  throw new Error(`'${n}' not yet implemented or not found in the registry. This kernel may not be supported by the tfjs backend you have chosen`);
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Gs(n) {
  return n % 2 === 0 ? n : n + 1;
}
function on(n, e, t) {
  const s = n[e];
  n[e] = n[t], n[t] = s;
}
function tc(n) {
  let e = 0;
  for (let t = 0; t < n.length; t++)
    e += n[t];
  return e;
}
function N(n, e) {
  if (!n)
    throw new Error(typeof e == "string" ? e : e());
}
function $r(n, e, t = "") {
  N(Z(n, e), () => t + ` Shapes ${n} and ${e} must match`);
}
function T(n) {
  if (n.length === 0)
    return 1;
  let e = n[0];
  for (let t = 1; t < n.length; t++)
    e *= n[t];
  return e;
}
function Z(n, e) {
  if (n === e)
    return !0;
  if (n == null || e == null || n.length !== e.length)
    return !1;
  for (let t = 0; t < n.length; t++)
    if (n[t] !== e[t])
      return !1;
  return !0;
}
function Sr(n) {
  return n % 1 === 0;
}
function bs(n) {
  const e = Math.ceil(Math.sqrt(n));
  return [e, Math.ceil(n / e)];
}
function _t(n, e) {
  return e <= n.length ? n : n + " ".repeat(e - n.length);
}
function bo(n, e = (o) => 0, t, s) {
  return new Promise((o, r) => {
    let i = 0;
    const a = () => {
      if (n()) {
        o();
        return;
      }
      i++;
      const c = e(i);
      if (t != null && i >= t) {
        r();
        return;
      }
      s != null ? s(a, c) : setTimeout(a, c);
    };
    a();
  });
}
function nc(n, e) {
  let t = 1, s = -1;
  for (let r = 0; r < n.length; ++r)
    if (n[r] >= 0)
      t *= n[r];
    else if (n[r] === -1) {
      if (s !== -1)
        throw Error(`Shapes can only have 1 implicit size. Found -1 at dim ${s} and dim ${r}`);
      s = r;
    } else if (n[r] < 0)
      throw Error(`Shapes can not be < 0. Found ${n[r]} at dim ${r}`);
  if (s === -1) {
    if (e > 0 && e !== t)
      throw Error(`Size(${e}) must match the product of shape ${n}`);
    return n;
  }
  if (t === 0)
    throw Error(`Cannot infer the missing size in [${n}] when there are 0 elements`);
  if (e % t !== 0)
    throw Error(`The implicit shape can't be a fractional number. Got ${e} / ${t}`);
  const o = n.slice();
  return o[s] = e / t, o;
}
function de(n, e) {
  const t = e.length;
  return n = n == null ? e.map((s, o) => o) : [].concat(n), N(n.every((s) => s >= -t && s < t), () => `All values in axis param must be in range [-${t}, ${t}) but got axis ${n}`), N(n.every((s) => Sr(s)), () => `All values in axis param must be integers but got axis ${n}`), n.map((s) => s < 0 ? t + s : s);
}
function yt(n, e) {
  const t = [], s = [];
  for (let o = 0; o < n.length; ++o)
    n[o] !== 1 && (t.push(n[o]), s.push(o));
  return { newShape: t, keptDims: s };
}
function pt(n, e) {
  return q(n, e);
}
function q(n, e) {
  let t = null;
  if (n == null || n === "float32")
    t = new Float32Array(e);
  else if (n === "int32")
    t = new Int32Array(e);
  else if (n === "bool")
    t = new Uint8Array(e);
  else if (n === "string")
    t = new Array(e);
  else
    throw new Error(`Unknown data type ${n}`);
  return t;
}
function sc(n, e) {
  for (let t = 0; t < n.length; t++) {
    const s = n[t];
    if (isNaN(s) || !isFinite(s))
      throw Error(`A tensor of type ${e} being uploaded contains ${s}.`);
  }
}
function oc(n) {
  return n === "bool" || n === "complex64" || n === "float32" || n === "int32" || n === "string";
}
function rc(n, e) {
  return !(e === "complex64" || e === "float32" && n !== "complex64" || e === "int32" && n !== "float32" && n !== "complex64" || e === "bool" && n === "bool");
}
function Ln(n) {
  if (n === "float32" || n === "int32")
    return 4;
  if (n === "complex64")
    return 8;
  if (n === "bool")
    return 1;
  throw new Error(`Unknown dtype ${n}`);
}
function ic(n) {
  if (n == null)
    return 0;
  let e = 0;
  return n.forEach((t) => e += t.length), e;
}
function Kn(n) {
  return typeof n == "string" || n instanceof String;
}
function ac(n) {
  return typeof n == "boolean";
}
function cc(n) {
  return typeof n == "number";
}
function gn(n) {
  return Array.isArray(n) ? gn(n[0]) : n instanceof Float32Array ? "float32" : n instanceof Int32Array || n instanceof Uint8Array || n instanceof Uint8ClampedArray ? "int32" : cc(n) ? "float32" : Kn(n) ? "string" : ac(n) ? "bool" : "float32";
}
function ws(n) {
  return !!(n && n.constructor && n.call && n.apply);
}
function ys(n, e) {
  for (let t = e; t < n; ++t)
    if (n % t === 0)
      return t;
  return n;
}
function Q(n) {
  const e = n.length;
  if (e < 2)
    return [];
  const t = new Array(e - 1);
  t[e - 2] = n[e - 1];
  for (let s = e - 3; s >= 0; --s)
    t[s] = t[s + 1] * n[s + 1];
  return t;
}
function Ir(n, e, t, s = !1) {
  const o = new Array();
  if (e.length === 1) {
    const r = e[0] * (s ? 2 : 1);
    for (let i = 0; i < r; i++)
      o[i] = t[n + i];
  } else {
    const r = e[0], i = e.slice(1), a = i.reduce((c, l) => c * l) * (s ? 2 : 1);
    for (let c = 0; c < r; c++)
      o[c] = Ir(n + c * a, i, t, s);
  }
  return o;
}
function wo(n, e, t = !1) {
  if (n.length === 0)
    return e[0];
  const s = n.reduce((o, r) => o * r) * (t ? 2 : 1);
  if (s === 0)
    return [];
  if (s !== e.length)
    throw new Error(`[${n}] does not match the input size ${e.length}${t ? " for a complex tensor" : ""}.`);
  return Ir(0, n, e, t);
}
function lc(n, e) {
  const t = nt(n, e);
  for (let s = 0; s < t.length; s++)
    t[s] = 1;
  return t;
}
function nt(n, e) {
  if (e == null || e === "float32" || e === "complex64")
    return new Float32Array(n);
  if (e === "int32")
    return new Int32Array(n);
  if (e === "bool")
    return new Uint8Array(n);
  throw new Error(`Unknown data type ${e}`);
}
function xn(n) {
  n.forEach((e) => {
    N(Number.isInteger(e) && e >= 0, () => `Tensor must have a shape comprised of positive integers but got shape [${n}].`);
  });
}
function vs(n, e, t) {
  if (e === 0)
    return 0;
  if (e === 1)
    return n[0];
  let s = n[n.length - 1];
  for (let o = 0; o < n.length - 1; ++o)
    s += t[o] * n[o];
  return s;
}
function zs(n, e, t) {
  if (e === 0)
    return [];
  if (e === 1)
    return [n];
  const s = new Array(e);
  for (let o = 0; o < s.length - 1; ++o)
    s[o] = Math.floor(n / t[o]), n -= s[o] * t[o];
  return s[s.length - 1] = n, s;
}
function Hs(n) {
  return n && n.then && typeof n.then == "function";
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const yo = "tfjsflags";
class uc {
  // tslint:disable-next-line: no-any
  constructor(e) {
    this.global = e, this.flags = {}, this.flagRegistry = {}, this.urlFlags = {}, this.getQueryParams = dc, this.populateURLFlags();
  }
  setPlatform(e, t) {
    this.platform != null && (y().getBool("IS_TEST") || y().getBool("PROD") || console.warn(`Platform ${this.platformName} has already been set. Overwriting the platform with ${e}.`)), this.platformName = e, this.platform = t;
  }
  registerFlag(e, t, s) {
    if (this.flagRegistry[e] = { evaluationFn: t, setHook: s }, this.urlFlags[e] != null) {
      const o = this.urlFlags[e];
      y().getBool("IS_TEST") || y().getBool("PROD") || console.warn(`Setting feature override from URL ${e}: ${o}.`), this.set(e, o);
    }
  }
  async getAsync(e) {
    return e in this.flags ? this.flags[e] : (this.flags[e] = await this.evaluateFlag(e), this.flags[e]);
  }
  get(e) {
    if (e in this.flags)
      return this.flags[e];
    const t = this.evaluateFlag(e);
    if (Hs(t))
      throw new Error(`Flag ${e} cannot be synchronously evaluated. Please use getAsync() instead.`);
    return this.flags[e] = t, this.flags[e];
  }
  getNumber(e) {
    return this.get(e);
  }
  getBool(e) {
    return this.get(e);
  }
  getString(e) {
    return this.get(e);
  }
  getFlags() {
    return this.flags;
  }
  // For backwards compatibility.
  get features() {
    return this.flags;
  }
  set(e, t) {
    if (this.flagRegistry[e] == null)
      throw new Error(`Cannot set flag ${e} as it has not been registered.`);
    this.flags[e] = t, this.flagRegistry[e].setHook != null && this.flagRegistry[e].setHook(t);
  }
  evaluateFlag(e) {
    if (this.flagRegistry[e] == null)
      throw new Error(`Cannot evaluate flag '${e}': no evaluation function found.`);
    return this.flagRegistry[e].evaluationFn();
  }
  setFlags(e) {
    this.flags = Object.assign({}, e);
  }
  reset() {
    this.flags = {}, this.urlFlags = {}, this.populateURLFlags();
  }
  populateURLFlags() {
    if (typeof this.global > "u" || typeof this.global.location > "u" || typeof this.global.location.search > "u")
      return;
    const e = this.getQueryParams(this.global.location.search);
    yo in e && e[yo].split(",").forEach((s) => {
      const [o, r] = s.split(":");
      this.urlFlags[o] = fc(o, r);
    });
  }
}
function dc(n) {
  const e = {};
  return n.replace(/[?&]([^=?&]+)(?:=([^&]*))?/g, (t, ...s) => (hc(e, s[0], s[1]), s.join("="))), e;
}
function hc(n, e, t) {
  n[decodeURIComponent(e)] = decodeURIComponent(t || "");
}
function fc(n, e) {
  const t = e.toLowerCase();
  return t === "true" || t === "false" ? t === "true" : `${+t}` === t ? +t : e;
}
function y() {
  return Rr;
}
let Rr = null;
function pc(n) {
  Rr = n;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
let cs;
function Tr() {
  if (cs == null) {
    let n;
    if (typeof window < "u")
      n = window;
    else if (typeof global < "u")
      n = global;
    else if (typeof process < "u")
      n = process;
    else if (typeof self < "u")
      n = self;
    else
      throw new Error("Could not find a global object");
    cs = n;
  }
  return cs;
}
function mc() {
  const n = Tr();
  return n._tfGlobals == null && (n._tfGlobals = /* @__PURE__ */ new Map()), n._tfGlobals;
}
function Xs(n, e) {
  const t = mc();
  if (t.has(n))
    return t.get(n);
  {
    const s = e();
    return t.set(n, s), t.get(n);
  }
}
const Er = "Abs", gc = "Acos", xc = "Acosh", qs = "Add", Cc = "AddN", bc = "All", wc = "Any", yc = "ArgMax", vc = "ArgMin", $c = "Asin", Sc = "Asinh", Ic = "Atan", Rc = "Atanh", Tc = "Atan2", Ec = "AvgPool", Nc = "AvgPoolGrad", kc = "AvgPool3D", Ac = "AvgPool3DGrad", Fc = "BatchMatMul", Dc = "BatchToSpaceND", Oc = "Bincount", Pc = "BitwiseAnd", _c = "BroadcastArgs", js = "Cast", Lc = "Ceil", Bc = "ClipByValue", Nr = "Complex", kr = "ComplexAbs", Mc = "Concat", Vc = "Conv2D", Uc = "Conv2DBackpropFilter", Wc = "Conv2DBackpropInput", Gc = "Conv3D", zc = "Conv3DBackpropFilterV2", Hc = "Conv3DBackpropInputV2", Xc = "Cos", qc = "Cosh", jc = "Cumprod", Kc = "Cumsum", Yc = "CropAndResize", Qc = "DenseBincount", Zc = "DepthToSpace", Jc = "DepthwiseConv2dNative", el = "DepthwiseConv2dNativeBackpropFilter", tl = "DepthwiseConv2dNativeBackpropInput", nl = "Diag", sl = "Dilation2D", Ar = "RealDiv", ol = "Einsum", rl = "Elu", il = "EluGrad", al = "Erf", cl = "Equal", ll = "Exp", ul = "ExpandDims", dl = "Expm1", hl = "FFT", Fr = "Fill", fl = "FlipLeftRight", pl = "Floor", Dr = "FloorDiv", ml = "FusedBatchNorm", gl = "GatherV2", xl = "GatherNd", Cl = "Greater", bl = "GreaterEqual", Ks = "Identity", wl = "IFFT", yl = "Imag", vl = "IsFinite", $l = "IsInf", Sl = "IsNan", Il = "LeakyRelu", Rl = "Less", Tl = "LessEqual", El = "LinSpace", Nl = "Log", kl = "Log1p", Al = "LogicalAnd", Fl = "LogicalNot", Dl = "LogicalOr", Ol = "LRN", Pl = "LRNGrad", _l = "Max", Or = "Maximum", Ll = "MaxPool", Bl = "MaxPoolGrad", Ml = "MaxPool3D", Vl = "MaxPool3DGrad", Ul = "MaxPoolWithArgmax", Wl = "Mean", Gl = "Min", zl = "Minimum", Hl = "MirrorPad", Xl = "Mod", ql = "Multinomial", Pr = "Multiply", jl = "Neg", Kl = "NotEqual", Yl = "NonMaxSuppressionV3", Ql = "NonMaxSuppressionV4", Zl = "NonMaxSuppressionV5", Jl = "OnesLike", eu = "OneHot", tu = "Pack", nu = "PadV2", _r = "Pow", su = "Prelu", ou = "Prod", ru = "RaggedGather", iu = "RaggedRange", au = "RaggedTensorToTensor", cu = "Range", lu = "Real", uu = "Reciprocal", du = "Relu", Lr = "Reshape", hu = "ResizeNearestNeighbor", fu = "ResizeNearestNeighborGrad", pu = "ResizeBilinear", mu = "ResizeBilinearGrad", gu = "Relu6", xu = "Reverse", Cu = "Round", bu = "Rsqrt", wu = "ScatterNd", yu = "TensorScatterUpdate", vu = "SearchSorted", $u = "Select", Su = "Selu", Iu = "Slice", Ru = "Sin", Tu = "Sinh", Eu = "Sign", Nu = "Sigmoid", ku = "Softplus", Br = "Sqrt", Au = "Sum", Fu = "SpaceToBatchND", Du = "SplitV", Ou = "Softmax", Pu = "SparseFillEmptyRows", _u = "SparseReshape", Lu = "SparseSegmentMean", Bu = "SparseSegmentSum", Mu = "SparseToDense", Vu = "SquaredDifference", Uu = "Square", Wu = "StaticRegexReplace", Gu = "StridedSlice", zu = "StringNGrams", Hu = "StringSplit", Xu = "StringToHashBucketFast", Mr = "Sub", qu = "Tan", ju = "Tanh", Vr = "Tile", Ku = "TopK", Yu = "Transform", Qu = "Transpose", Zu = "Unique", Ju = "Unpack", ed = "UnsortedSegmentSum", Ur = "ZerosLike", td = "Step", nd = "FromPixels", sd = "RotateWithOffset", od = "_FusedMatMul", rd = "FusedConv2D", id = "FusedDepthwiseConv2D";
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Pe(...n) {
  y().getBool("IS_TEST") || y().getBool("PROD") || console.warn(...n);
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Bn = Xs("kernelRegistry", () => /* @__PURE__ */ new Map()), ad = Xs("gradRegistry", () => /* @__PURE__ */ new Map());
function vo(n, e) {
  const t = Wr(n, e);
  return Bn.get(t);
}
function $o(n) {
  return ad.get(n);
}
function So(n) {
  const e = Bn.entries(), t = [];
  for (; ; ) {
    const { done: s, value: o } = e.next();
    if (s)
      break;
    const [r, i] = o, [a] = r.split("_");
    a === n && t.push(i);
  }
  return t;
}
function cd(n) {
  const { kernelName: e, backendName: t } = n, s = Wr(e, t);
  Bn.has(s) && Pe(`The kernel '${e}' for backend '${t}' is already registered`), Bn.set(s, n);
}
function Wr(n, e) {
  return `${e}_${n}`;
}
/**
 * @license
 * Copyright 2023 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Gr(n) {
  return n instanceof Float32Array || n instanceof Int32Array || n instanceof Uint8Array || n instanceof Uint8ClampedArray;
}
function ld(n) {
  return n && n.__esModule && Object.prototype.hasOwnProperty.call(n, "default") ? n.default : n;
}
var zr = W, $e = null;
try {
  $e = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([
    0,
    97,
    115,
    109,
    1,
    0,
    0,
    0,
    1,
    13,
    2,
    96,
    0,
    1,
    127,
    96,
    4,
    127,
    127,
    127,
    127,
    1,
    127,
    3,
    7,
    6,
    0,
    1,
    1,
    1,
    1,
    1,
    6,
    6,
    1,
    127,
    1,
    65,
    0,
    11,
    7,
    50,
    6,
    3,
    109,
    117,
    108,
    0,
    1,
    5,
    100,
    105,
    118,
    95,
    115,
    0,
    2,
    5,
    100,
    105,
    118,
    95,
    117,
    0,
    3,
    5,
    114,
    101,
    109,
    95,
    115,
    0,
    4,
    5,
    114,
    101,
    109,
    95,
    117,
    0,
    5,
    8,
    103,
    101,
    116,
    95,
    104,
    105,
    103,
    104,
    0,
    0,
    10,
    191,
    1,
    6,
    4,
    0,
    35,
    0,
    11,
    36,
    1,
    1,
    126,
    32,
    0,
    173,
    32,
    1,
    173,
    66,
    32,
    134,
    132,
    32,
    2,
    173,
    32,
    3,
    173,
    66,
    32,
    134,
    132,
    126,
    34,
    4,
    66,
    32,
    135,
    167,
    36,
    0,
    32,
    4,
    167,
    11,
    36,
    1,
    1,
    126,
    32,
    0,
    173,
    32,
    1,
    173,
    66,
    32,
    134,
    132,
    32,
    2,
    173,
    32,
    3,
    173,
    66,
    32,
    134,
    132,
    127,
    34,
    4,
    66,
    32,
    135,
    167,
    36,
    0,
    32,
    4,
    167,
    11,
    36,
    1,
    1,
    126,
    32,
    0,
    173,
    32,
    1,
    173,
    66,
    32,
    134,
    132,
    32,
    2,
    173,
    32,
    3,
    173,
    66,
    32,
    134,
    132,
    128,
    34,
    4,
    66,
    32,
    135,
    167,
    36,
    0,
    32,
    4,
    167,
    11,
    36,
    1,
    1,
    126,
    32,
    0,
    173,
    32,
    1,
    173,
    66,
    32,
    134,
    132,
    32,
    2,
    173,
    32,
    3,
    173,
    66,
    32,
    134,
    132,
    129,
    34,
    4,
    66,
    32,
    135,
    167,
    36,
    0,
    32,
    4,
    167,
    11,
    36,
    1,
    1,
    126,
    32,
    0,
    173,
    32,
    1,
    173,
    66,
    32,
    134,
    132,
    32,
    2,
    173,
    32,
    3,
    173,
    66,
    32,
    134,
    132,
    130,
    34,
    4,
    66,
    32,
    135,
    167,
    36,
    0,
    32,
    4,
    167,
    11
  ])), {}).exports;
} catch {
}
function W(n, e, t) {
  this.low = n | 0, this.high = e | 0, this.unsigned = !!t;
}
W.prototype.__isLong__;
Object.defineProperty(W.prototype, "__isLong__", { value: !0 });
function ge(n) {
  return (n && n.__isLong__) === !0;
}
W.isLong = ge;
var Io = {}, Ro = {};
function vt(n, e) {
  var t, s, o;
  return e ? (n >>>= 0, (o = 0 <= n && n < 256) && (s = Ro[n], s) ? s : (t = G(n, (n | 0) < 0 ? -1 : 0, !0), o && (Ro[n] = t), t)) : (n |= 0, (o = -128 <= n && n < 128) && (s = Io[n], s) ? s : (t = G(n, n < 0 ? -1 : 0, !1), o && (Io[n] = t), t));
}
W.fromInt = vt;
function Se(n, e) {
  if (isNaN(n))
    return e ? ut : Ie;
  if (e) {
    if (n < 0)
      return ut;
    if (n >= Hr)
      return jr;
  } else {
    if (n <= -Eo)
      return pe;
    if (n + 1 >= Eo)
      return qr;
  }
  return n < 0 ? Se(-n, e).neg() : G(n % Mt | 0, n / Mt | 0, e);
}
W.fromNumber = Se;
function G(n, e, t) {
  return new W(n, e, t);
}
W.fromBits = G;
var Mn = Math.pow;
function Ys(n, e, t) {
  if (n.length === 0)
    throw Error("empty string");
  if (n === "NaN" || n === "Infinity" || n === "+Infinity" || n === "-Infinity")
    return Ie;
  if (typeof e == "number" ? (t = e, e = !1) : e = !!e, t = t || 10, t < 2 || 36 < t)
    throw RangeError("radix");
  var s;
  if ((s = n.indexOf("-")) > 0)
    throw Error("interior hyphen");
  if (s === 0)
    return Ys(n.substring(1), e, t).neg();
  for (var o = Se(Mn(t, 8)), r = Ie, i = 0; i < n.length; i += 8) {
    var a = Math.min(8, n.length - i), c = parseInt(n.substring(i, i + a), t);
    if (a < 8) {
      var l = Se(Mn(t, a));
      r = r.mul(l).add(Se(c));
    } else
      r = r.mul(o), r = r.add(Se(c));
  }
  return r.unsigned = e, r;
}
W.fromString = Ys;
function Le(n, e) {
  return typeof n == "number" ? Se(n, e) : typeof n == "string" ? Ys(n, e) : G(n.low, n.high, typeof e == "boolean" ? e : n.unsigned);
}
W.fromValue = Le;
var To = 65536, ud = 1 << 24, Mt = To * To, Hr = Mt * Mt, Eo = Hr / 2, No = vt(ud), Ie = vt(0);
W.ZERO = Ie;
var ut = vt(0, !0);
W.UZERO = ut;
var Pt = vt(1);
W.ONE = Pt;
var Xr = vt(1, !0);
W.UONE = Xr;
var $s = vt(-1);
W.NEG_ONE = $s;
var qr = G(-1, 2147483647, !1);
W.MAX_VALUE = qr;
var jr = G(-1, -1, !0);
W.MAX_UNSIGNED_VALUE = jr;
var pe = G(0, -2147483648, !1);
W.MIN_VALUE = pe;
var I = W.prototype;
I.toInt = function() {
  return this.unsigned ? this.low >>> 0 : this.low;
};
I.toNumber = function() {
  return this.unsigned ? (this.high >>> 0) * Mt + (this.low >>> 0) : this.high * Mt + (this.low >>> 0);
};
I.toString = function(e) {
  if (e = e || 10, e < 2 || 36 < e)
    throw RangeError("radix");
  if (this.isZero())
    return "0";
  if (this.isNegative())
    if (this.eq(pe)) {
      var t = Se(e), s = this.div(t), o = s.mul(t).sub(this);
      return s.toString(e) + o.toInt().toString(e);
    } else
      return "-" + this.neg().toString(e);
  for (var r = Se(Mn(e, 6), this.unsigned), i = this, a = ""; ; ) {
    var c = i.div(r), l = i.sub(c.mul(r)).toInt() >>> 0, u = l.toString(e);
    if (i = c, i.isZero())
      return u + a;
    for (; u.length < 6; )
      u = "0" + u;
    a = "" + u + a;
  }
};
I.getHighBits = function() {
  return this.high;
};
I.getHighBitsUnsigned = function() {
  return this.high >>> 0;
};
I.getLowBits = function() {
  return this.low;
};
I.getLowBitsUnsigned = function() {
  return this.low >>> 0;
};
I.getNumBitsAbs = function() {
  if (this.isNegative())
    return this.eq(pe) ? 64 : this.neg().getNumBitsAbs();
  for (var e = this.high != 0 ? this.high : this.low, t = 31; t > 0 && !(e & 1 << t); t--)
    ;
  return this.high != 0 ? t + 33 : t + 1;
};
I.isZero = function() {
  return this.high === 0 && this.low === 0;
};
I.eqz = I.isZero;
I.isNegative = function() {
  return !this.unsigned && this.high < 0;
};
I.isPositive = function() {
  return this.unsigned || this.high >= 0;
};
I.isOdd = function() {
  return (this.low & 1) === 1;
};
I.isEven = function() {
  return (this.low & 1) === 0;
};
I.equals = function(e) {
  return ge(e) || (e = Le(e)), this.unsigned !== e.unsigned && this.high >>> 31 === 1 && e.high >>> 31 === 1 ? !1 : this.high === e.high && this.low === e.low;
};
I.eq = I.equals;
I.notEquals = function(e) {
  return !this.eq(
    /* validates */
    e
  );
};
I.neq = I.notEquals;
I.ne = I.notEquals;
I.lessThan = function(e) {
  return this.comp(
    /* validates */
    e
  ) < 0;
};
I.lt = I.lessThan;
I.lessThanOrEqual = function(e) {
  return this.comp(
    /* validates */
    e
  ) <= 0;
};
I.lte = I.lessThanOrEqual;
I.le = I.lessThanOrEqual;
I.greaterThan = function(e) {
  return this.comp(
    /* validates */
    e
  ) > 0;
};
I.gt = I.greaterThan;
I.greaterThanOrEqual = function(e) {
  return this.comp(
    /* validates */
    e
  ) >= 0;
};
I.gte = I.greaterThanOrEqual;
I.ge = I.greaterThanOrEqual;
I.compare = function(e) {
  if (ge(e) || (e = Le(e)), this.eq(e))
    return 0;
  var t = this.isNegative(), s = e.isNegative();
  return t && !s ? -1 : !t && s ? 1 : this.unsigned ? e.high >>> 0 > this.high >>> 0 || e.high === this.high && e.low >>> 0 > this.low >>> 0 ? -1 : 1 : this.sub(e).isNegative() ? -1 : 1;
};
I.comp = I.compare;
I.negate = function() {
  return !this.unsigned && this.eq(pe) ? pe : this.not().add(Pt);
};
I.neg = I.negate;
I.add = function(e) {
  ge(e) || (e = Le(e));
  var t = this.high >>> 16, s = this.high & 65535, o = this.low >>> 16, r = this.low & 65535, i = e.high >>> 16, a = e.high & 65535, c = e.low >>> 16, l = e.low & 65535, u = 0, d = 0, h = 0, f = 0;
  return f += r + l, h += f >>> 16, f &= 65535, h += o + c, d += h >>> 16, h &= 65535, d += s + a, u += d >>> 16, d &= 65535, u += t + i, u &= 65535, G(h << 16 | f, u << 16 | d, this.unsigned);
};
I.subtract = function(e) {
  return ge(e) || (e = Le(e)), this.add(e.neg());
};
I.sub = I.subtract;
I.multiply = function(e) {
  if (this.isZero())
    return Ie;
  if (ge(e) || (e = Le(e)), $e) {
    var t = $e.mul(
      this.low,
      this.high,
      e.low,
      e.high
    );
    return G(t, $e.get_high(), this.unsigned);
  }
  if (e.isZero())
    return Ie;
  if (this.eq(pe))
    return e.isOdd() ? pe : Ie;
  if (e.eq(pe))
    return this.isOdd() ? pe : Ie;
  if (this.isNegative())
    return e.isNegative() ? this.neg().mul(e.neg()) : this.neg().mul(e).neg();
  if (e.isNegative())
    return this.mul(e.neg()).neg();
  if (this.lt(No) && e.lt(No))
    return Se(this.toNumber() * e.toNumber(), this.unsigned);
  var s = this.high >>> 16, o = this.high & 65535, r = this.low >>> 16, i = this.low & 65535, a = e.high >>> 16, c = e.high & 65535, l = e.low >>> 16, u = e.low & 65535, d = 0, h = 0, f = 0, p = 0;
  return p += i * u, f += p >>> 16, p &= 65535, f += r * u, h += f >>> 16, f &= 65535, f += i * l, h += f >>> 16, f &= 65535, h += o * u, d += h >>> 16, h &= 65535, h += r * l, d += h >>> 16, h &= 65535, h += i * c, d += h >>> 16, h &= 65535, d += s * u + o * l + r * c + i * a, d &= 65535, G(f << 16 | p, d << 16 | h, this.unsigned);
};
I.mul = I.multiply;
I.divide = function(e) {
  if (ge(e) || (e = Le(e)), e.isZero())
    throw Error("division by zero");
  if ($e) {
    if (!this.unsigned && this.high === -2147483648 && e.low === -1 && e.high === -1)
      return this;
    var t = (this.unsigned ? $e.div_u : $e.div_s)(
      this.low,
      this.high,
      e.low,
      e.high
    );
    return G(t, $e.get_high(), this.unsigned);
  }
  if (this.isZero())
    return this.unsigned ? ut : Ie;
  var s, o, r;
  if (this.unsigned) {
    if (e.unsigned || (e = e.toUnsigned()), e.gt(this))
      return ut;
    if (e.gt(this.shru(1)))
      return Xr;
    r = ut;
  } else {
    if (this.eq(pe)) {
      if (e.eq(Pt) || e.eq($s))
        return pe;
      if (e.eq(pe))
        return Pt;
      var i = this.shr(1);
      return s = i.div(e).shl(1), s.eq(Ie) ? e.isNegative() ? Pt : $s : (o = this.sub(e.mul(s)), r = s.add(o.div(e)), r);
    } else if (e.eq(pe))
      return this.unsigned ? ut : Ie;
    if (this.isNegative())
      return e.isNegative() ? this.neg().div(e.neg()) : this.neg().div(e).neg();
    if (e.isNegative())
      return this.div(e.neg()).neg();
    r = Ie;
  }
  for (o = this; o.gte(e); ) {
    s = Math.max(1, Math.floor(o.toNumber() / e.toNumber()));
    for (var a = Math.ceil(Math.log(s) / Math.LN2), c = a <= 48 ? 1 : Mn(2, a - 48), l = Se(s), u = l.mul(e); u.isNegative() || u.gt(o); )
      s -= c, l = Se(s, this.unsigned), u = l.mul(e);
    l.isZero() && (l = Pt), r = r.add(l), o = o.sub(u);
  }
  return r;
};
I.div = I.divide;
I.modulo = function(e) {
  if (ge(e) || (e = Le(e)), $e) {
    var t = (this.unsigned ? $e.rem_u : $e.rem_s)(
      this.low,
      this.high,
      e.low,
      e.high
    );
    return G(t, $e.get_high(), this.unsigned);
  }
  return this.sub(this.div(e).mul(e));
};
I.mod = I.modulo;
I.rem = I.modulo;
I.not = function() {
  return G(~this.low, ~this.high, this.unsigned);
};
I.and = function(e) {
  return ge(e) || (e = Le(e)), G(this.low & e.low, this.high & e.high, this.unsigned);
};
I.or = function(e) {
  return ge(e) || (e = Le(e)), G(this.low | e.low, this.high | e.high, this.unsigned);
};
I.xor = function(e) {
  return ge(e) || (e = Le(e)), G(this.low ^ e.low, this.high ^ e.high, this.unsigned);
};
I.shiftLeft = function(e) {
  return ge(e) && (e = e.toInt()), (e &= 63) === 0 ? this : e < 32 ? G(this.low << e, this.high << e | this.low >>> 32 - e, this.unsigned) : G(0, this.low << e - 32, this.unsigned);
};
I.shl = I.shiftLeft;
I.shiftRight = function(e) {
  return ge(e) && (e = e.toInt()), (e &= 63) === 0 ? this : e < 32 ? G(this.low >>> e | this.high << 32 - e, this.high >> e, this.unsigned) : G(this.high >> e - 32, this.high >= 0 ? 0 : -1, this.unsigned);
};
I.shr = I.shiftRight;
I.shiftRightUnsigned = function(e) {
  if (ge(e) && (e = e.toInt()), e &= 63, e === 0)
    return this;
  var t = this.high;
  if (e < 32) {
    var s = this.low;
    return G(s >>> e | t << 32 - e, t >>> e, this.unsigned);
  } else return e === 32 ? G(t, 0, this.unsigned) : G(t >>> e - 32, 0, this.unsigned);
};
I.shru = I.shiftRightUnsigned;
I.shr_u = I.shiftRightUnsigned;
I.toSigned = function() {
  return this.unsigned ? G(this.low, this.high, !1) : this;
};
I.toUnsigned = function() {
  return this.unsigned ? this : G(this.low, this.high, !0);
};
I.toBytes = function(e) {
  return e ? this.toBytesLE() : this.toBytesBE();
};
I.toBytesLE = function() {
  var e = this.high, t = this.low;
  return [
    t & 255,
    t >>> 8 & 255,
    t >>> 16 & 255,
    t >>> 24,
    e & 255,
    e >>> 8 & 255,
    e >>> 16 & 255,
    e >>> 24
  ];
};
I.toBytesBE = function() {
  var e = this.high, t = this.low;
  return [
    e >>> 24,
    e >>> 16 & 255,
    e >>> 8 & 255,
    e & 255,
    t >>> 24,
    t >>> 16 & 255,
    t >>> 8 & 255,
    t & 255
  ];
};
W.fromBytes = function(e, t, s) {
  return s ? W.fromBytesLE(e, t) : W.fromBytesBE(e, t);
};
W.fromBytesLE = function(e, t) {
  return new W(
    e[0] | e[1] << 8 | e[2] << 16 | e[3] << 24,
    e[4] | e[5] << 8 | e[6] << 16 | e[7] << 24,
    t
  );
};
W.fromBytesBE = function(e, t) {
  return new W(
    e[4] << 24 | e[5] << 16 | e[6] << 8 | e[7],
    e[0] << 24 | e[1] << 16 | e[2] << 8 | e[3],
    t
  );
};
const Kr = /* @__PURE__ */ ld(zr), dd = /* @__PURE__ */ Qa({
  __proto__: null,
  default: Kr
}, [zr]);
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const at = (
  // tslint:disable-next-line
  Kr || dd
);
function Yn(n) {
  return at.fromString(n, !0, 16);
}
const Yr = Yn("c3a5c85c97cb3127"), it = Yn("b492b66fbe98f273"), oe = Yn("9ae16a3b2f90404f");
function Ss(n) {
  return n.xor(n.shru(47));
}
function Qr(n, e, t) {
  const s = n.slice(e, e + t);
  return at.fromBytes(Array.from(s), !0, !0);
}
function U(n, e) {
  return Qr(n, e, 8);
}
function ko(n, e) {
  return Qr(n, e, 4);
}
function X(n, e) {
  return e === 0 ? n : n.shru(e).or(n.shl(64 - e));
}
function tt(n, e, t = Yn("9ddfea08eb382d69")) {
  let s = n.xor(e).mul(t);
  s = s.xor(s.shru(47));
  let o = e.xor(s).mul(t);
  return o = o.xor(o.shru(47)), o = o.mul(t), o;
}
function hd(n, e, t, s, o, r) {
  o = o.add(n), r = X(r.add(o).add(s), 21);
  const i = o;
  return o = o.add(e), o = o.add(t), r = r.add(X(o, 44)), [o.add(s), r.add(i)];
}
function Rn(n, e, t, s) {
  return hd(U(n, e), U(n, e + 8), U(n, e + 16), U(n, e + 24), t, s);
}
function fd(n, e = n.length) {
  if (e >= 8) {
    const t = oe.add(e * 2), s = U(n, 0).add(oe), o = U(n, e - 8), r = X(o, 37).mul(t).add(s), i = X(s, 25).add(o).mul(t);
    return tt(r, i, t);
  }
  if (e >= 4) {
    const t = oe.add(e * 2), s = ko(n, 0);
    return tt(s.shl(3).add(e), ko(n, e - 4), t);
  }
  if (e > 0) {
    const t = n[0], s = n[e >> 1], o = n[e - 1], r = t + (s << 8), i = e + (o << 2);
    return Ss(oe.mul(r).xor(Yr.mul(i))).mul(oe);
  }
  return oe;
}
function pd(n, e = n.length) {
  const t = oe.add(e * 2), s = U(n, 0).mul(it), o = U(n, 8), r = U(n, e - 8).mul(t), i = U(n, e - 16).mul(oe);
  return tt(X(s.add(o), 43).add(X(r, 30)).add(i), s.add(X(o.add(oe), 18)).add(r), t);
}
function md(n, e = n.length) {
  const t = oe.add(e * 2), s = U(n, 0).mul(oe), o = U(n, 8), r = U(n, e - 8).mul(t), i = U(n, e - 16).mul(oe), a = X(s.add(o), 43).add(X(r, 30)).add(i), c = tt(a, s.add(X(o.add(oe), 18)).add(r), t), l = U(n, 16).mul(t), u = U(n, 24), d = a.add(U(n, e - 32)).mul(t), h = c.add(U(n, e - 24)).mul(t);
  return tt(X(l.add(u), 43).add(X(d, 30)).add(h), l.add(X(u.add(s), 18)).add(d), t);
}
function gd(n, e = n.length) {
  const t = at.fromNumber(81, !0);
  if (e <= 32)
    return e <= 16 ? fd(n, e) : pd(n, e);
  if (e <= 64)
    return md(n, e);
  let s = t, o = t.mul(it).add(113), r = Ss(o.mul(oe).add(113)).mul(oe), i = [at.UZERO, at.UZERO], a = [at.UZERO, at.UZERO];
  s = s.mul(oe).add(U(n, 0));
  let c = 0;
  const l = (e - 1 >> 6) * 64, u = l + (e - 1 & 63) - 63;
  do
    s = X(s.add(o).add(i[0]).add(U(n, c + 8)), 37).mul(it), o = X(o.add(i[1]).add(U(n, c + 48)), 42).mul(it), s = s.xor(a[1]), o = o.add(i[0]).add(U(n, c + 40)), r = X(r.add(a[0]), 33).mul(it), i = Rn(n, c, i[1].mul(it), s.add(a[0])), a = Rn(n, c + 32, r.add(a[1]), o.add(U(n, c + 16))), [r, s] = [s, r], c += 64;
  while (c !== l);
  const d = it.add(r.and(255).shl(1));
  return c = u, a[0] = a[0].add(e - 1 & 63), i[0] = i[0].add(a[0]), a[0] = a[0].add(i[0]), s = X(s.add(o).add(i[0]).add(U(n, c + 8)), 37).mul(d), o = X(o.add(i[1]).add(U(n, c + 48)), 42).mul(d), s = s.xor(a[1].mul(9)), o = o.add(i[0].mul(9).add(U(n, c + 40))), r = X(r.add(a[0]), 33).mul(d), i = Rn(n, c, i[1].mul(d), s.add(a[0])), a = Rn(n, c + 32, r.add(a[1]), o.add(U(n, c + 16))), [r, s] = [s, r], tt(tt(i[0], a[0], d).add(Ss(o).mul(Yr)).add(r), tt(i[1], a[1], d).add(s), d);
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Xt(n, e) {
  return e === "string" ? ht(n) : Qn([n], e);
}
function xd(n, e) {
  return n instanceof Float32Array && e === "float32" || n instanceof Int32Array && e === "int32" || n instanceof Uint8Array && e === "bool";
}
function Qn(n, e) {
  if (e === "string")
    throw new Error("Cannot convert a string[] to a TypedArray");
  if (Array.isArray(n) && (n = mt(n)), y().getBool("DEBUG") && sc(n, e), xd(n, e))
    return n;
  if (e == null || e === "float32" || e === "complex64")
    return new Float32Array(n);
  if (e === "int32")
    return new Int32Array(n);
  if (e === "bool") {
    const t = new Uint8Array(n.length);
    for (let s = 0; s < t.length; ++s)
      Math.round(n[s]) !== 0 && (t[s] = 1);
    return t;
  } else
    throw new Error(`Unknown data type ${e}`);
}
function Fe() {
  return y().platform.now();
}
function ht(n, e = "utf-8") {
  return e = e || "utf-8", y().platform.encode(n, e);
}
function Vt(n, e = "utf-8") {
  return e = e || "utf-8", y().platform.decode(n, e);
}
function Te(n) {
  return y().platform.isTypedArray != null ? y().platform.isTypedArray(n) : Gr(n);
}
function mt(n, e = [], t = !1) {
  if (e == null && (e = []), typeof n == "boolean" || typeof n == "number" || typeof n == "string" || Hs(n) || n == null || Te(n) && t)
    e.push(n);
  else if (Array.isArray(n) || Te(n))
    for (let s = 0; s < n.length; ++s)
      mt(n[s], e, t);
  else {
    let s = -1;
    for (const o of Object.keys(n))
      /^([1-9]+[0-9]*|0)$/.test(o) && (s = Math.max(s, Number(o)));
    for (let o = 0; o <= s; o++)
      mt(n[o], e, t);
  }
  return e;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Cd {
  constructor(e, t) {
    this.backendTimer = e, this.logger = t, t == null && (this.logger = new wd());
  }
  profileKernel(e, t, s) {
    let o;
    const r = () => {
      o = s();
    };
    let i;
    const a = Fe();
    if (this.backendTimer.timerAvailable())
      i = this.backendTimer.time(r);
    else {
      r();
      for (const l of o)
        l.dataSync();
      i = Promise.resolve({ kernelMs: Fe() - a });
    }
    if (y().getBool("CHECK_COMPUTATION_FOR_ERRORS"))
      for (let l = 0; l < o.length; l++) {
        const u = o[l];
        u.data().then((d) => {
          bd(d, u.dtype, e);
        });
      }
    return {
      kernelName: e,
      outputs: o,
      inputs: t,
      timeMs: i.then((l) => l.kernelMs),
      extraInfo: i.then((l) => l.getExtraProfileInfo != null ? l.getExtraProfileInfo() : "")
    };
  }
  logKernelProfile(e) {
    const { kernelName: t, outputs: s, timeMs: o, inputs: r, extraInfo: i } = e;
    s.forEach((a) => {
      Promise.all([a.data(), o, i]).then((c) => {
        this.logger.logKernelProfile(t, a, c[0], c[1], r, c[2]);
      });
    });
  }
}
function bd(n, e, t) {
  if (e !== "float32")
    return !1;
  for (let s = 0; s < n.length; s++) {
    const o = n[s];
    if (isNaN(o) || !isFinite(o))
      return console.warn(`Found ${o} in the result of '${t}'`), !0;
  }
  return !1;
}
class wd {
  logKernelProfile(e, t, s, o, r, i) {
    const a = typeof o == "number" ? _t(`${o}ms`, 9) : o.error, c = _t(e, 25), l = t.rank, u = t.size, d = _t(t.shape.toString(), 14);
    let h = "";
    for (const f in r) {
      const p = r[f];
      if (p != null) {
        const x = p.shape || t.shape, g = x.length;
        h += `${f}: ${g}D ${g > 0 ? x : ""} `;
      }
    }
    console.log(`%c${c}	%c${a}	%c${l}D ${d}	%c${u}	%c${h}	%c${i}`, "font-weight:bold", "color:red", "color:blue", "color: orange", "color: green", "color: steelblue");
  }
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function yd(n, e, t) {
  const s = {}, o = {};
  for (let c = 0; c < e.length; c++)
    s[e[c].id] = !0;
  for (let c = 0; c < n.length; c++) {
    const l = n[c], u = l.inputs;
    for (const d in u) {
      const h = u[d];
      let f = !1;
      for (let p = 0; p < e.length; p++)
        if (s[h.id]) {
          l.outputs.forEach((x) => s[x.id] = !0), f = !0, o[l.id] = !0;
          break;
        }
      if (f)
        break;
    }
  }
  const r = {};
  r[t.id] = !0;
  const i = {};
  for (let c = n.length - 1; c >= 0; c--) {
    const l = n[c], u = l.inputs;
    for (let d = 0; d < l.outputs.length; d++)
      if (r[l.outputs[d].id]) {
        for (const h in u)
          r[u[h].id] = !0, i[l.id] = !0;
        break;
      }
  }
  const a = [];
  for (let c = 0; c < n.length; c++) {
    const l = n[c];
    if (o[l.id] && i[l.id]) {
      const u = {};
      for (const h in l.inputs) {
        const f = l.inputs[h];
        s[f.id] && (u[h] = f);
      }
      const d = Object.assign({}, l);
      d.inputs = u, d.outputs = l.outputs, a.push(d);
    }
  }
  return a;
}
function vd(n, e, t, s) {
  for (let o = e.length - 1; o >= 0; o--) {
    const r = e[o], i = [];
    if (r.outputs.forEach((c) => {
      const l = n[c.id];
      l != null ? i.push(l) : i.push(null);
    }), r.gradient == null)
      throw new Error(`Cannot compute gradient: gradient function not found for ${r.kernelName}.`);
    const a = r.gradient(i);
    for (const c in r.inputs) {
      if (!(c in a))
        throw new Error(`Cannot backprop through input ${c}. Available gradients found: ${Object.keys(a)}.`);
      const l = t(() => a[c]());
      if (l.dtype !== "float32")
        throw new Error(`Error in gradient for op ${r.kernelName}. The gradient of input ${c} must have 'float32' dtype, but has '${l.dtype}'`);
      const u = r.inputs[c];
      if (!Z(l.shape, u.shape))
        throw new Error(`Error in gradient for op ${r.kernelName}. The gradient of input '${c}' has shape '${l.shape}', which does not match the shape of the input '${u.shape}'`);
      if (n[u.id] == null)
        n[u.id] = l;
      else {
        const d = n[u.id];
        n[u.id] = s(d, l), d.dispose();
      }
    }
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ao = 20, rn = 3, ls = 7;
function $d(n, e, t, s) {
  const o = Q(e), r = Sd(n, e, t, o), i = e.length, a = Pn(n, e, t, o, r), c = ["Tensor"];
  return s && (c.push(`  dtype: ${t}`), c.push(`  rank: ${i}`), c.push(`  shape: [${e}]`), c.push("  values:")), c.push(a.map((l) => "    " + l).join(`
`)), c.join(`
`);
}
function Sd(n, e, t, s) {
  const o = T(e), r = s[s.length - 1], i = new Array(r).fill(0), a = e.length, c = t === "complex64" ? cn(n) : n;
  if (a > 1)
    for (let l = 0; l < o / r; l++) {
      const u = l * r;
      for (let d = 0; d < r; d++)
        i[d] = Math.max(i[d], an(c[u + d], 0, t).length);
    }
  return i;
}
function an(n, e, t) {
  let s;
  return Array.isArray(n) ? s = `${parseFloat(n[0].toFixed(ls))} + ${parseFloat(n[1].toFixed(ls))}j` : Kn(n) ? s = `'${n}'` : t === "bool" ? s = Zr(n) : s = parseFloat(n.toFixed(ls)).toString(), _t(s, e);
}
function Zr(n) {
  return n === 0 ? "false" : "true";
}
function Pn(n, e, t, s, o, r = !0) {
  const i = t === "complex64" ? 2 : 1, a = e[0], c = e.length;
  if (c === 0) {
    if (t === "complex64") {
      const x = cn(n);
      return [an(x[0], 0, t)];
    }
    return t === "bool" ? [Zr(n[0])] : [n[0].toString()];
  }
  if (c === 1) {
    if (a > Ao) {
      const g = rn * i;
      let m = Array.from(n.slice(0, g)), C = Array.from(n.slice((a - rn) * i, a * i));
      return t === "complex64" && (m = cn(m), C = cn(C)), [
        "[" + m.map((b, w) => an(b, o[w], t)).join(", ") + ", ..., " + C.map((b, w) => an(b, o[a - rn + w], t)).join(", ") + "]"
      ];
    }
    return [
      "[" + (t === "complex64" ? cn(n) : Array.from(n)).map((g, m) => an(g, o[m], t)).join(", ") + "]"
    ];
  }
  const l = e.slice(1), u = s.slice(1), d = s[0] * i, h = [];
  if (a > Ao) {
    for (let x = 0; x < rn; x++) {
      const g = x * d, m = g + d;
      h.push(...Pn(
        n.slice(g, m),
        l,
        t,
        u,
        o,
        !1
        /* isLast */
      ));
    }
    h.push("...");
    for (let x = a - rn; x < a; x++) {
      const g = x * d, m = g + d;
      h.push(...Pn(
        n.slice(g, m),
        l,
        t,
        u,
        o,
        x === a - 1
        /* isLast */
      ));
    }
  } else
    for (let x = 0; x < a; x++) {
      const g = x * d, m = g + d;
      h.push(...Pn(
        n.slice(g, m),
        l,
        t,
        u,
        o,
        x === a - 1
        /* isLast */
      ));
    }
  const f = c === 2 ? "," : "";
  h[0] = "[" + (a > 0 ? h[0] + f : "");
  for (let x = 1; x < h.length - 1; x++)
    h[x] = " " + h[x] + f;
  let p = `,
`;
  for (let x = 2; x < c; x++)
    p += `
`;
  return h[h.length - 1] = " " + h[h.length - 1] + "]" + (r ? "" : p), h;
}
function cn(n) {
  const e = [];
  for (let t = 0; t < n.length; t += 2)
    e.push([n[t], n[t + 1]]);
  return e;
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Vn {
  constructor(e, t, s) {
    if (this.dtype = t, this.shape = e.slice(), this.size = T(e), s != null) {
      const o = s.length;
      N(o === this.size, () => `Length of values '${o}' does not match the size inferred by the shape '${this.size}'.`);
    }
    if (t === "complex64")
      throw new Error("complex64 dtype TensorBuffers are not supported. Please create a TensorBuffer for the real and imaginary parts separately and call tf.complex(real, imag).");
    this.values = s || q(t, this.size), this.strides = Q(e);
  }
  /**
   * Sets a value in the buffer at a given location.
   *
   * @param value The value to set.
   * @param locs  The location indices.
   *
   * @doc {heading: 'Tensors', subheading: 'Creation'}
   */
  set(e, ...t) {
    t.length === 0 && (t = [0]), N(t.length === this.rank, () => `The number of provided coordinates (${t.length}) must match the rank (${this.rank})`);
    const s = this.locToIndex(t);
    this.values[s] = e;
  }
  /**
   * Returns the value in the buffer at the provided location.
   *
   * @param locs The location indices.
   *
   * @doc {heading: 'Tensors', subheading: 'Creation'}
   */
  get(...e) {
    e.length === 0 && (e = [0]);
    let t = 0;
    for (const o of e) {
      if (o < 0 || o >= this.shape[t]) {
        const r = `Requested out of range element at ${e}.   Buffer shape=${this.shape}`;
        throw new Error(r);
      }
      t++;
    }
    let s = e[e.length - 1];
    for (let o = 0; o < e.length - 1; ++o)
      s += this.strides[o] * e[o];
    return this.values[s];
  }
  locToIndex(e) {
    if (this.rank === 0)
      return 0;
    if (this.rank === 1)
      return e[0];
    let t = e[e.length - 1];
    for (let s = 0; s < e.length - 1; ++s)
      t += this.strides[s] * e[s];
    return t;
  }
  indexToLoc(e) {
    if (this.rank === 0)
      return [];
    if (this.rank === 1)
      return [e];
    const t = new Array(this.shape.length);
    for (let s = 0; s < t.length - 1; ++s)
      t[s] = Math.floor(e / this.strides[s]), e -= t[s] * this.strides[s];
    return t[t.length - 1] = e, t;
  }
  get rank() {
    return this.shape.length;
  }
  /**
   * Creates an immutable `tf.Tensor` object from the buffer.
   *
   * @doc {heading: 'Tensors', subheading: 'Creation'}
   */
  toTensor() {
    return De().makeTensor(this.values, this.shape, this.dtype);
  }
}
let De = null, Dt = null;
function Id(n) {
  De = n;
}
function Rd(n) {
  Dt = n;
}
class ve {
  constructor(e, t, s, o) {
    this.kept = !1, this.isDisposedInternal = !1, this.shape = e.slice(), this.dtype = t || "float32", this.size = T(e), this.strides = Q(e), this.dataId = s, this.id = o, this.rankType = this.rank < 5 ? this.rank.toString() : "higher";
  }
  get rank() {
    return this.shape.length;
  }
  /**
   * Returns a promise of `tf.TensorBuffer` that holds the underlying data.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  async buffer() {
    const e = await this.data();
    return Dt.buffer(this.shape, this.dtype, e);
  }
  /**
   * Returns a `tf.TensorBuffer` that holds the underlying data.
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  bufferSync() {
    return Dt.buffer(this.shape, this.dtype, this.dataSync());
  }
  /**
   * Returns the tensor data as a nested array. The transfer of data is done
   * asynchronously.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  async array() {
    const e = await this.data();
    return wo(this.shape, e, this.dtype === "complex64");
  }
  /**
   * Returns the tensor data as a nested array. The transfer of data is done
   * synchronously.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  arraySync() {
    return wo(this.shape, this.dataSync(), this.dtype === "complex64");
  }
  /**
   * Asynchronously downloads the values from the `tf.Tensor`. Returns a
   * promise of `TypedArray` that resolves when the computation has finished.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  async data() {
    this.throwIfDisposed();
    const e = De().read(this.dataId);
    if (this.dtype === "string") {
      const t = await e;
      try {
        return t.map((s) => Vt(s));
      } catch {
        throw new Error("Failed to decode the string bytes into utf-8. To get the original bytes, call tensor.bytes().");
      }
    }
    return e;
  }
  /**
   * Copy the tensor's data to a new GPU resource. Comparing to the `dataSync()`
   * and `data()`, this method prevents data from being downloaded to CPU.
   *
   * For WebGL backend, the data will be stored on a densely packed texture.
   * This means that the texture will use the RGBA channels to store value.
   *
   * For WebGPU backend, the data will be stored on a buffer. There is no
   * parameter, so can not use a user-defined size to create the buffer.
   *
   * @param options:
   *     For WebGL,
   *         - customTexShape: Optional. If set, will use the user defined
   *     texture shape to create the texture.
   *
   * @returns For WebGL backend, a GPUData contains the new texture and
   *     its information.
   *     {
   *        tensorRef: The tensor that is associated with this texture,
   *        texture: WebGLTexture,
   *        texShape: [number, number] // [height, width]
   *     }
   *
   *     For WebGPU backend, a GPUData contains the new buffer.
   *     {
   *        tensorRef: The tensor that is associated with this buffer,
   *        buffer: GPUBuffer,
   *     }
   *
   *     Remember to dispose the GPUData after it is used by
   *     `res.tensorRef.dispose()`.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  dataToGPU(e) {
    return this.throwIfDisposed(), De().readToGPU(this.dataId, e);
  }
  /**
   * Synchronously downloads the values from the `tf.Tensor`. This blocks the
   * UI thread until the values are ready, which can cause performance issues.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  dataSync() {
    this.throwIfDisposed();
    const e = De().readSync(this.dataId);
    if (this.dtype === "string")
      try {
        return e.map((t) => Vt(t));
      } catch {
        throw new Error("Failed to decode the string bytes into utf-8. To get the original bytes, call tensor.bytes().");
      }
    return e;
  }
  /** Returns the underlying bytes of the tensor's data. */
  async bytes() {
    this.throwIfDisposed();
    const e = await De().read(this.dataId);
    return this.dtype === "string" ? e : new Uint8Array(e.buffer);
  }
  /**
   * Disposes `tf.Tensor` from memory.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  dispose() {
    this.isDisposed || (De().disposeTensor(this), this.isDisposedInternal = !0);
  }
  get isDisposed() {
    return this.isDisposedInternal;
  }
  throwIfDisposed() {
    if (this.isDisposed)
      throw new Error("Tensor is disposed.");
  }
  /**
   * Prints the `tf.Tensor`. See `tf.print` for details.
   *
   * @param verbose Whether to print verbose information about the tensor,
   *    including dtype and size.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  print(e = !1) {
    return Dt.print(this, e);
  }
  /**
   * Returns a copy of the tensor. See `tf.clone` for details.
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  clone() {
    return this.throwIfDisposed(), Dt.clone(this);
  }
  /**
   * Returns a human-readable description of the tensor. Useful for logging.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  toString(e = !1) {
    const t = this.dataSync();
    return $d(t, this.shape, this.dtype, e);
  }
  cast(e) {
    return this.throwIfDisposed(), Dt.cast(this, e);
  }
  variable(e = !0, t, s) {
    return this.throwIfDisposed(), De().makeVariable(this, e, t, s);
  }
}
Object.defineProperty(ve, Symbol.hasInstance, {
  value: (n) => !!n && n.data != null && n.dataSync != null && n.throwIfDisposed != null
});
function Td() {
  return Xs("Tensor", () => ve);
}
Td();
class Un extends ve {
  constructor(e, t, s, o) {
    super(e.shape, e.dtype, e.dataId, o), this.trainable = t, this.name = s;
  }
  /**
   * Assign a new `tf.Tensor` to this variable. The new `tf.Tensor` must have
   * the same shape and dtype as the old `tf.Tensor`.
   *
   * @param newValue New tensor to be assigned to this variable.
   *
   * @doc {heading: 'Tensors', subheading: 'Classes'}
   */
  assign(e) {
    if (e.dtype !== this.dtype)
      throw new Error(`dtype of the new value (${e.dtype}) and previous value (${this.dtype}) must match`);
    if (!Z(e.shape, this.shape))
      throw new Error(`shape of the new value (${e.shape}) and previous value (${this.shape}) must match`);
    De().disposeTensor(this), this.dataId = e.dataId, De().incRef(
      this,
      null
      /* backend */
    );
  }
  dispose() {
    De().disposeVariable(this), this.isDisposedInternal = !0;
  }
}
Object.defineProperty(Un, Symbol.hasInstance, {
  value: (n) => n instanceof ve && n.assign != null && n.assign instanceof Function
});
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
var Fo;
(function(n) {
  n.R0 = "R0", n.R1 = "R1", n.R2 = "R2", n.R3 = "R3", n.R4 = "R4", n.R5 = "R5", n.R6 = "R6";
})(Fo || (Fo = {}));
var Is;
(function(n) {
  n.float32 = "float32", n.int32 = "int32", n.bool = "int32", n.complex64 = "complex64";
})(Is || (Is = {}));
var Rs;
(function(n) {
  n.float32 = "float32", n.int32 = "int32", n.bool = "bool", n.complex64 = "complex64";
})(Rs || (Rs = {}));
var Ts;
(function(n) {
  n.float32 = "float32", n.int32 = "float32", n.bool = "float32", n.complex64 = "complex64";
})(Ts || (Ts = {}));
var Es;
(function(n) {
  n.float32 = "complex64", n.int32 = "complex64", n.bool = "complex64", n.complex64 = "complex64";
})(Es || (Es = {}));
const Ed = {
  float32: Ts,
  int32: Is,
  bool: Rs,
  complex64: Es
};
function ze(n, e) {
  if (n === "string" || e === "string") {
    if (n === "string" && e === "string")
      return "string";
    throw new Error(`Can not upcast ${n} with ${e}`);
  }
  return Ed[n][e];
}
function Qs(n) {
  return ze(n, "int32");
}
function Jr(n) {
  return n != null && typeof n == "object" && "texture" in n && n.texture instanceof WebGLTexture;
}
function ei(n) {
  return typeof GPUBuffer < "u" && n != null && typeof n == "object" && "buffer" in n && n.buffer instanceof GPUBuffer;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function $t(n, e) {
  if (n.dtype === e.dtype)
    return [n, e];
  const t = ze(n.dtype, e.dtype);
  return [n.cast(t), e.cast(t)];
}
function ti(n) {
  const e = [];
  return ni(n, e, /* @__PURE__ */ new Set()), e;
}
function ni(n, e, t) {
  if (n == null)
    return;
  if (n instanceof ve) {
    e.push(n);
    return;
  }
  if (!Nd(n))
    return;
  const s = n;
  for (const o in s) {
    const r = s[o];
    t.has(r) || (t.add(r), ni(r, e, t));
  }
}
function Nd(n) {
  return Array.isArray(n) || typeof n == "object";
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function us(n) {
  return n.kernelName != null;
}
class Do {
  constructor() {
    this.registeredVariables = {}, this.nextTapeNodeId = 0, this.numBytes = 0, this.numTensors = 0, this.numStringTensors = 0, this.numDataBuffers = 0, this.gradientDepth = 0, this.kernelDepth = 0, this.scopeStack = [], this.numDataMovesStack = [], this.nextScopeId = 0, this.tensorInfo = /* @__PURE__ */ new WeakMap(), this.profiling = !1, this.activeProfile = {
      newBytes: 0,
      newTensors: 0,
      peakBytes: 0,
      kernels: [],
      result: null,
      get kernelNames() {
        return Array.from(new Set(this.kernels.map((e) => e.name)));
      }
    };
  }
  dispose() {
    for (const e in this.registeredVariables)
      this.registeredVariables[e].dispose();
  }
}
class Ut {
  constructor(e) {
    this.ENV = e, this.registry = {}, this.registryFactory = {}, this.pendingBackendInitId = 0, this.state = new Do();
  }
  async ready() {
    if (this.pendingBackendInit != null)
      return this.pendingBackendInit.then(() => {
      });
    if (this.backendInstance != null)
      return;
    const e = this.getSortedBackends();
    for (let t = 0; t < e.length; t++) {
      const s = e[t];
      if (await this.initializeBackend(s).success) {
        await this.setBackend(s);
        return;
      }
    }
    throw new Error("Could not initialize any backends, all backend initializations failed.");
  }
  get backend() {
    if (this.pendingBackendInit != null)
      throw new Error(`Backend '${this.backendName}' has not yet been initialized. Make sure to await tf.ready() or await tf.setBackend() before calling other methods`);
    if (this.backendInstance == null) {
      const { name: e, asyncInit: t } = this.initializeBackendsAndReturnBest();
      if (t)
        throw new Error(`The highest priority backend '${e}' has not yet been initialized. Make sure to await tf.ready() or await tf.setBackend() before calling other methods`);
      this.setBackend(e);
    }
    return this.backendInstance;
  }
  backendNames() {
    return Object.keys(this.registryFactory);
  }
  findBackend(e) {
    if (!(e in this.registry))
      if (e in this.registryFactory) {
        const { asyncInit: t } = this.initializeBackend(e);
        if (t)
          return null;
      } else
        return null;
    return this.registry[e];
  }
  findBackendFactory(e) {
    return e in this.registryFactory ? this.registryFactory[e].factory : null;
  }
  registerBackend(e, t, s = 1) {
    return e in this.registryFactory ? (Pe(`${e} backend was already registered. Reusing existing backend factory.`), !1) : (this.registryFactory[e] = { factory: t, priority: s }, !0);
  }
  async setBackend(e) {
    if (this.registryFactory[e] == null)
      throw new Error(`Backend name '${e}' not found in registry`);
    if (this.backendName = e, this.registry[e] == null) {
      this.backendInstance = null;
      const { success: t, asyncInit: s } = this.initializeBackend(e);
      if (!(s ? await t : t))
        return !1;
    }
    return this.backendInstance = this.registry[e], this.setupRegisteredKernels(), this.profiler = new Cd(this.backendInstance), !0;
  }
  setupRegisteredKernels() {
    So(this.backendName).forEach((t) => {
      t.setupFunc != null && t.setupFunc(this.backendInstance);
    });
  }
  disposeRegisteredKernels(e) {
    So(e).forEach((s) => {
      s.disposeFunc != null && s.disposeFunc(this.registry[e]);
    });
  }
  /**
   * Initializes a backend by looking up the backend name in the factory
   * registry and calling the factory method. Returns a boolean representing
   * whether the initialization of the backend suceeded. Throws an error if
   * there is no backend in the factory registry.
   */
  initializeBackend(e) {
    const t = this.registryFactory[e];
    if (t == null)
      throw new Error(`Cannot initialize backend ${e}, no registration found.`);
    try {
      const s = t.factory();
      if (s && !(s instanceof vr) && typeof s.then == "function") {
        const o = ++this.pendingBackendInitId, r = s.then((i) => o < this.pendingBackendInitId ? !1 : (this.registry[e] = i, this.pendingBackendInit = null, !0)).catch((i) => (o < this.pendingBackendInitId || (this.pendingBackendInit = null, Pe(`Initialization of backend ${e} failed`), Pe(i.stack || i.message)), !1));
        return this.pendingBackendInit = r, { success: r, asyncInit: !0 };
      } else
        return this.registry[e] = s, { success: !0, asyncInit: !1 };
    } catch (s) {
      return Pe(`Initialization of backend ${e} failed`), Pe(s.stack || s.message), { success: !1, asyncInit: !1 };
    }
  }
  removeBackend(e) {
    if (!(e in this.registryFactory))
      throw new Error(`${e} backend not found in registry`);
    this.backendName === e && this.pendingBackendInit != null && this.pendingBackendInitId++, e in this.registry && (this.disposeRegisteredKernels(e), this.registry[e].dispose(), delete this.registry[e]), delete this.registryFactory[e], this.backendName === e && (this.pendingBackendInit = null, this.backendName = null, this.backendInstance = null);
  }
  getSortedBackends() {
    if (Object.keys(this.registryFactory).length === 0)
      throw new Error("No backend found in registry.");
    return Object.keys(this.registryFactory).sort((e, t) => this.registryFactory[t].priority - this.registryFactory[e].priority);
  }
  initializeBackendsAndReturnBest() {
    const e = this.getSortedBackends();
    for (let t = 0; t < e.length; t++) {
      const s = e[t], { success: o, asyncInit: r } = this.initializeBackend(s);
      if (r || o)
        return { name: s, asyncInit: r };
    }
    throw new Error("Could not initialize any backends, all backend initializations failed.");
  }
  moveData(e, t) {
    const s = this.state.tensorInfo.get(t), o = s.backend, r = this.readSync(t), i = o.refCount(t);
    o.disposeData(t, !0), s.backend = e, e.move(t, r, s.shape, s.dtype, i), this.shouldCheckForMemLeaks() && this.state.numDataMovesStack[this.state.numDataMovesStack.length - 1]++;
  }
  tidy(e, t) {
    let s = null;
    if (t == null) {
      if (typeof e != "function")
        throw new Error("Please provide a function to tidy()");
      t = e;
    } else {
      if (typeof e != "string" && !(e instanceof String))
        throw new Error("When calling with two arguments, the first argument to tidy() must be a string");
      if (typeof t != "function")
        throw new Error("When calling with two arguments, the 2nd argument to tidy() must be a function");
      s = e;
    }
    let o;
    return this.scopedRun(() => this.startScope(s), () => this.endScope(o), () => (o = t(), o instanceof Promise && console.error("Cannot return a Promise inside of tidy."), o));
  }
  scopedRun(e, t, s) {
    e();
    try {
      const o = s();
      return t(), o;
    } catch (o) {
      throw t(), o;
    }
  }
  nextTensorId() {
    return Ut.nextTensorId++;
  }
  nextVariableId() {
    return Ut.nextVariableId++;
  }
  /**
   * This method is called instead of the public-facing tensor.clone() when
   * saving a tensor for backwards pass. It makes sure to add the clone
   * operation to the tape regardless of being called inside a kernel
   * execution.
   */
  clone(e) {
    const t = D.runKernel(Ks, { x: e }), s = { x: e }, o = (i) => ({
      x: () => {
        const a = "float32", c = { x: i }, l = { dtype: a };
        return D.runKernel(
          js,
          c,
          // tslint:disable-next-line: no-unnecessary-type-assertion
          l
        );
      }
    }), r = [];
    return this.addTapeNode(this.state.activeScope.name, s, [t], o, r, {}), t;
  }
  /**
   * Execute a kernel with the given name and return the output tensor.
   *
   * @param kernelName The name of the kernel to execute.
   * @param inputs A map of input names to tensors.
   * @param attrs A map of attribute names to their values. An attribute is a
   *     primitive (non-tensor) input to the kernel.
   * @param inputsToSave A list of tensors, inputs to save for the backprop
   *     computation.
   * @param outputsToSave A list of booleans, specifying which output to save
   *     for the backprop computation. These are booleans since the output
   * tensors are not visible to the user.
   */
  runKernel(e, t, s) {
    if (this.backendName == null && this.backend, !(vo(e, this.backendName) != null))
      throw new Error(`Kernel '${e}' not registered for backend '${this.backendName}'`);
    return this.runKernelFunc({ kernelName: e, inputs: t, attrs: s });
  }
  shouldCheckForMemLeaks() {
    return this.ENV.getBool("IS_TEST");
  }
  checkKernelForMemLeak(e, t, s) {
    const o = this.backend.numDataIds();
    let r = 0;
    s.forEach((c) => {
      r += c.dtype === "complex64" ? 3 : 1;
    });
    const i = this.state.numDataMovesStack[this.state.numDataMovesStack.length - 1], a = o - t - r - i;
    if (a > 0)
      throw new Error(`Backend '${this.backendName}' has an internal memory leak (${a} data ids) after running '${e}'`);
  }
  /**
   * Internal helper method to execute a kernel Func
   *
   * Use `runKernel` to execute kernels from outside of engine.
   */
  runKernelFunc(e) {
    let t, s = [];
    const o = this.isTapeOn(), r = this.state.numBytes, i = this.state.numTensors;
    this.shouldCheckForMemLeaks() && this.state.numDataMovesStack.push(0);
    let a;
    this.backendName == null && this.backend;
    let c;
    const l = us(e) ? e.kernelName : this.state.activeScope != null ? this.state.activeScope.name : "";
    if (us(e)) {
      const { kernelName: p, inputs: x, attrs: g } = e;
      this.backendName == null && this.backend;
      const m = vo(p, this.backendName);
      N(m != null, () => `Cannot find registered kernel '${p}' for backend '${this.backendName}'`), a = () => {
        const C = this.backend.numDataIds();
        c = m.kernelFunc({ inputs: x, attrs: g, backend: this.backend });
        const b = Array.isArray(c) ? c : [c];
        this.shouldCheckForMemLeaks() && this.checkKernelForMemLeak(p, C, b);
        const w = b.map((v) => v.rank != null ? v : this.makeTensorFromTensorInfo(v));
        if (o) {
          const v = this.getTensorsForGradient(p, x, w);
          s = this.saveTensorsForBackwardMode(v);
        }
        return w;
      };
    } else {
      const { forwardFunc: p } = e, x = (g) => {
        o && (s = g.map((m) => this.keep(this.clone(m))));
      };
      a = () => {
        const g = this.backend.numDataIds();
        c = this.tidy(() => p(this.backend, x));
        const m = Array.isArray(c) ? c : [c];
        return this.shouldCheckForMemLeaks() && this.checkKernelForMemLeak(l, g, m), m;
      };
    }
    const { inputs: u, attrs: d } = e, h = us(e) ? null : e.backwardsFunc;
    let f;
    return this.scopedRun(
      // Stop recording to a tape when running a kernel.
      () => this.state.kernelDepth++,
      () => this.state.kernelDepth--,
      () => {
        !this.ENV.getBool("DEBUG") && !this.state.profiling ? t = a() : (f = this.profiler.profileKernel(l, u, () => a()), this.ENV.getBool("DEBUG") && this.profiler.logKernelProfile(f), t = f.outputs);
      }
    ), o && this.addTapeNode(l, u, t, h, s, d), this.state.profiling && this.state.activeProfile.kernels.push({
      name: l,
      bytesAdded: this.state.numBytes - r,
      totalBytesSnapshot: this.state.numBytes,
      tensorsAdded: this.state.numTensors - i,
      totalTensorsSnapshot: this.state.numTensors,
      inputShapes: Object.keys(u).map((p) => u[p] != null ? u[p].shape : null),
      outputShapes: t.map((p) => p.shape),
      kernelTimeMs: f.timeMs,
      extraInfo: f.extraInfo
    }), Array.isArray(c) ? t : t[0];
  }
  /**
   * Saves tensors used in forward mode for use in backward mode.
   *
   * @param tensors the list of tensors to save.
   */
  saveTensorsForBackwardMode(e) {
    return e.map((s) => this.keep(this.clone(s)));
  }
  /**
   * Returns a list of tensors to save for a given gradient calculation.
   *
   * @param kernelName name of kernel to look up gradient for.
   * @param inputs a map of input tensors.
   * @param outputs an array of output tensors from forward mode of kernel.
   */
  getTensorsForGradient(e, t, s) {
    const o = $o(e);
    if (o != null) {
      const r = o.inputsToSave || [], i = o.outputsToSave || [];
      let a;
      o.saveAllInputs ? (N(Array.isArray(t), () => "saveAllInputs is true, expected inputs to be an array."), a = Object.keys(t).map((l) => t[l])) : a = r.map((l) => t[l]);
      const c = s.filter((l, u) => i[u]);
      return a.concat(c);
    }
    return [];
  }
  /**
   * Internal method used by public APIs for tensor creation. Makes a new
   * tensor with the provided shape, dtype and values. It always
   * creates a new data id and writes the values to the underlying backend.
   */
  makeTensor(e, t, s, o) {
    if (e == null)
      throw new Error("Values passed to engine.makeTensor() are null");
    s = s || "float32", o = o || this.backend;
    let r = e;
    s === "string" && Kn(e[0]) && (r = e.map((c) => ht(c)));
    const i = o.write(r, t, s), a = new ve(t, s, i, this.nextTensorId());
    if (this.trackTensor(a, o), s === "string") {
      const c = this.state.tensorInfo.get(i), l = ic(r);
      this.state.numBytes += l - c.bytes, c.bytes = l;
    }
    return a;
  }
  /**
   * Internal method used by backends. Makes a new tensor
   * that is a wrapper around an existing data id. It doesn't create
   * a new data id, only increments the ref count used in memory tracking.
   * @deprecated
   */
  makeTensorFromDataId(e, t, s, o) {
    s = s || "float32";
    const r = { dataId: e, shape: t, dtype: s };
    return this.makeTensorFromTensorInfo(r, o);
  }
  /**
   * Internal method used by backends. Makes a new tensor that is a wrapper
   * around an existing data id in TensorInfo. It doesn't create a new data id,
   * only increments the ref count used in memory tracking.
   */
  makeTensorFromTensorInfo(e, t) {
    const { dataId: s, shape: o, dtype: r } = e, i = new ve(o, r, s, this.nextTensorId());
    return this.trackTensor(i, t), i;
  }
  makeVariable(e, t = !0, s, o) {
    s = s || this.nextVariableId().toString(), o != null && o !== e.dtype && (e = e.cast(o));
    const r = new Un(e, t, s, this.nextTensorId());
    if (this.state.registeredVariables[r.name] != null)
      throw new Error(`Variable with name ${r.name} was already registered`);
    return this.state.registeredVariables[r.name] = r, this.incRef(r, this.backend), r;
  }
  trackTensor(e, t) {
    this.state.numTensors++, e.dtype === "string" && this.state.numStringTensors++;
    let s = 0;
    e.dtype !== "complex64" && e.dtype !== "string" && (s = e.size * Ln(e.dtype)), this.state.numBytes += s, this.state.tensorInfo.has(e.dataId) || (this.state.numDataBuffers++, this.state.tensorInfo.set(e.dataId, {
      backend: t || this.backend,
      dtype: e.dtype,
      shape: e.shape,
      bytes: s
    })), e instanceof Un || this.track(e);
  }
  // Track the tensor by dataId and increase the refCount for the dataId in the
  // backend.
  // TODO(pyu10055): This is currently used by makeVariable method, to increase
  // refCount on the backend for the dataId. It can potentially be replaced with
  // Identity op indead of calling backend directly.
  incRef(e, t) {
    this.trackTensor(e, t), this.backend.incRef(e.dataId);
  }
  removeDataId(e, t) {
    this.state.tensorInfo.has(e) && this.state.tensorInfo.get(e).backend === t && (this.state.tensorInfo.delete(e), this.state.numDataBuffers--);
  }
  disposeTensor(e) {
    if (!this.state.tensorInfo.has(e.dataId))
      return;
    const t = this.state.tensorInfo.get(e.dataId);
    if (this.state.numTensors--, e.dtype === "string" && (this.state.numStringTensors--, this.state.numBytes -= t.bytes), e.dtype !== "complex64" && e.dtype !== "string") {
      const s = e.size * Ln(e.dtype);
      this.state.numBytes -= s;
    }
    t.backend.disposeData(e.dataId) && this.removeDataId(e.dataId, t.backend);
  }
  disposeVariables() {
    for (const e in this.state.registeredVariables) {
      const t = this.state.registeredVariables[e];
      this.disposeVariable(t);
    }
  }
  disposeVariable(e) {
    this.disposeTensor(e), this.state.registeredVariables[e.name] != null && delete this.state.registeredVariables[e.name];
  }
  memory() {
    const e = this.backend.memory();
    return e.numTensors = this.state.numTensors, e.numDataBuffers = this.state.numDataBuffers, e.numBytes = this.state.numBytes, this.state.numStringTensors > 0 && (e.unreliable = !0, e.reasons == null && (e.reasons = []), e.reasons.push("Memory usage by string tensors is approximate (2 bytes per character)")), e;
  }
  async profile(e) {
    this.state.profiling = !0;
    const t = this.state.numBytes, s = this.state.numTensors;
    this.state.activeProfile.kernels = [], this.state.activeProfile.result = await e(), this.state.profiling = !1, this.state.activeProfile.peakBytes = Math.max(...this.state.activeProfile.kernels.map((o) => o.totalBytesSnapshot)), this.state.activeProfile.newBytes = this.state.numBytes - t, this.state.activeProfile.newTensors = this.state.numTensors - s;
    for (const o of this.state.activeProfile.kernels)
      o.kernelTimeMs = await o.kernelTimeMs, o.extraInfo = await o.extraInfo;
    return this.state.activeProfile;
  }
  isTapeOn() {
    return this.state.gradientDepth > 0 && this.state.kernelDepth === 0;
  }
  addTapeNode(e, t, s, o, r, i) {
    const a = { id: this.state.nextTapeNodeId++, kernelName: e, inputs: t, outputs: s, saved: r }, c = $o(e);
    c != null && (o = c.gradFunc), o != null && (a.gradient = (l) => (l = l.map((u, d) => {
      if (u == null) {
        const h = s[d], f = nt(h.size, h.dtype);
        return this.makeTensor(f, h.shape, h.dtype);
      }
      return u;
    }), o(l.length > 1 ? l : l[0], r, i))), this.state.activeTape.push(a);
  }
  keep(e) {
    return e.kept = !0, e;
  }
  startTape() {
    this.state.gradientDepth === 0 && (this.state.activeTape = []), this.state.gradientDepth++;
  }
  endTape() {
    this.state.gradientDepth--;
  }
  /**
   * Start a scope. Use this with endScope() to achieve the same functionality
   * as scope() without the need for a function closure.
   */
  startScope(e) {
    const t = {
      track: [],
      name: "unnamed scope",
      id: this.state.nextScopeId++
    };
    e && (t.name = e), this.state.scopeStack.push(t), this.state.activeScope = t;
  }
  /**
   * End a scope. Use this with startScope() to achieve the same functionality
   * as scope() without the need for a function closure.
   */
  endScope(e) {
    const t = ti(e), s = new Set(t.map((r) => r.id));
    for (let r = 0; r < this.state.activeScope.track.length; r++) {
      const i = this.state.activeScope.track[r];
      !i.kept && !s.has(i.id) && i.dispose();
    }
    const o = this.state.scopeStack.pop();
    this.state.activeScope = this.state.scopeStack.length === 0 ? null : this.state.scopeStack[this.state.scopeStack.length - 1], t.forEach((r) => {
      !r.kept && r.scopeId === o.id && this.track(r);
    });
  }
  /**
   * Returns gradients of `f` with respect to each of the `xs`. The gradients
   * returned are of the same length as `xs`, but some might be null if `f`
   * was not a function of that `x`. It also takes optional dy to multiply the
   * gradient, which defaults to `1`.
   */
  gradients(e, t, s, o = !1) {
    if (N(t.length > 0, () => "gradients() received an empty list of xs."), s != null && s.dtype !== "float32")
      throw new Error(`dy must have 'float32' dtype, but has '${s.dtype}'`);
    const r = this.scopedRun(() => this.startTape(), () => this.endTape(), () => this.tidy("forward", e));
    N(r instanceof ve, () => "The result y returned by f() must be a tensor.");
    const i = yd(this.state.activeTape, t, r);
    if (!o && i.length === 0 && t.length > 0)
      throw new Error("Cannot compute gradient of y=f(x) with respect to x. Make sure that the f you passed encloses all operations that lead from x to y.");
    return this.tidy("backward", () => {
      const a = {};
      a[r.id] = s ?? kd(r.shape), vd(
        a,
        i,
        // Pass the tidy function to avoid circular dep with `tape.ts`.
        (l) => this.tidy(l),
        // Pass an add function to avoide a circular dep with `tape.ts`.
        Ad
      );
      const c = t.map((l) => a[l.id]);
      return this.state.gradientDepth === 0 && (this.state.activeTape.forEach((l) => {
        for (const u of l.saved)
          u.dispose();
      }), this.state.activeTape = null), { value: r, grads: c };
    });
  }
  customGrad(e) {
    return N(ws(e), () => "The f passed in customGrad(f) must be a function."), (...t) => {
      N(t.every((a) => a instanceof ve), () => "The args passed in customGrad(f)(x1, x2,...) must all be tensors");
      let s;
      const o = {};
      t.forEach((a, c) => {
        o[c] = a;
      });
      const r = (a, c) => (s = e(...t, c), N(s.value instanceof ve, () => "The function f passed in customGrad(f) must return an object where `obj.value` is a tensor"), N(ws(s.gradFunc), () => "The function f passed in customGrad(f) must return an object where `obj.gradFunc` is a function."), s.value), i = (a, c) => {
        const l = s.gradFunc(a, c), u = Array.isArray(l) ? l : [l];
        N(u.length === t.length, () => "The function f passed in customGrad(f) must return an object where `obj.gradFunc` is a function that returns the same number of tensors as inputs passed to f(...)."), N(u.every((h) => h instanceof ve), () => "The function f passed in customGrad(f) must return an object where `obj.gradFunc` is a function that returns a list of only tensors.");
        const d = {};
        return u.forEach((h, f) => {
          d[f] = () => h;
        }), d;
      };
      return this.runKernelFunc({
        forwardFunc: r,
        backwardsFunc: i,
        inputs: o
      });
    };
  }
  readSync(e) {
    return this.state.tensorInfo.get(e).backend.readSync(e);
  }
  read(e) {
    return this.state.tensorInfo.get(e).backend.read(e);
  }
  readToGPU(e, t) {
    return this.state.tensorInfo.get(e).backend.readToGPU(e, t);
  }
  async time(e) {
    const t = Fe(), s = await this.backend.time(e);
    return s.wallMs = Fe() - t, s;
  }
  /**
   * Tracks a Tensor in the current scope to be automatically cleaned up
   * when the current scope ends, and returns the value.
   *
   * @param result The Tensor to track in the current scope.
   */
  track(e) {
    return this.state.activeScope != null && (e.scopeId = this.state.activeScope.id, this.state.activeScope.track.push(e)), e;
  }
  get registeredVariables() {
    return this.state.registeredVariables;
  }
  /**
   * Resets the engine state. Removes all backends but does not remove
   * registered backend factories.
   */
  reset() {
    this.pendingBackendInitId++, this.state.dispose(), this.ENV.reset(), this.state = new Do();
    for (const e in this.registry)
      this.disposeRegisteredKernels(e), this.registry[e].dispose(), delete this.registry[e];
    this.backendName = null, this.backendInstance = null, this.pendingBackendInit = null;
  }
}
Ut.nextTensorId = 0;
Ut.nextVariableId = 0;
function kd(n) {
  const e = lc(T(n), "float32");
  return D.makeTensor(e, n, "float32");
}
function si() {
  const n = Tr();
  if (n._tfengine == null) {
    const e = new uc(n);
    n._tfengine = new Ut(e);
  }
  return pc(n._tfengine.ENV), Id(() => n._tfengine), n._tfengine;
}
const D = si();
function Ad(n, e) {
  const t = { a: n, b: e };
  return D.runKernel(qs, t);
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Fd() {
  return typeof navigator < "u" && navigator != null;
}
function oi(n) {
  if (n || Fd()) {
    if (n || (n = navigator), n.product === "ReactNative")
      return !0;
    const e = n.userAgent || n.vendor || // tslint:disable-next-line:no-any
    (typeof window < "u" ? window.opera : "");
    if (!e) {
      const t = n;
      return t.userAgentData && t.userAgentData.mobile;
    }
    return /(android|bb\d+|meego).+mobile|avantgo|bada\/|blackberry|blazer|compal|elaine|fennec|hiptop|iemobile|ip(hone|od)|iris|kindle|lge |maemo|midp|mmp|mobile.+firefox|netfront|opera m(ob|in)i|palm( os)?|phone|p(ixi|re)\/|plucker|pocket|psp|series(4|6)0|symbian|treo|up\.(browser|link)|vodafone|wap|windows ce|xda|xiino/i.test(e) || // tslint:disable-next-line:max-line-length
    /1207|6310|6590|3gso|4thp|50[1-6]i|770s|802s|a wa|abac|ac(er|oo|s\-)|ai(ko|rn)|al(av|ca|co)|amoi|an(ex|ny|yw)|aptu|ar(ch|go)|as(te|us)|attw|au(di|\-m|r |s )|avan|be(ck|ll|nq)|bi(lb|rd)|bl(ac|az)|br(e|v)w|bumb|bw\-(n|u)|c55\/|capi|ccwa|cdm\-|cell|chtm|cldc|cmd\-|co(mp|nd)|craw|da(it|ll|ng)|dbte|dc\-s|devi|dica|dmob|do(c|p)o|ds(12|\-d)|el(49|ai)|em(l2|ul)|er(ic|k0)|esl8|ez([4-7]0|os|wa|ze)|fetc|fly(\-|_)|g1 u|g560|gene|gf\-5|g\-mo|go(\.w|od)|gr(ad|un)|haie|hcit|hd\-(m|p|t)|hei\-|hi(pt|ta)|hp( i|ip)|hs\-c|ht(c(\-| |_|a|g|p|s|t)|tp)|hu(aw|tc)|i\-(20|go|ma)|i230|iac( |\-|\/)|ibro|idea|ig01|ikom|im1k|inno|ipaq|iris|ja(t|v)a|jbro|jemu|jigs|kddi|keji|kgt( |\/)|klon|kpt |kwc\-|kyo(c|k)|le(no|xi)|lg( g|\/(k|l|u)|50|54|\-[a-w])|libw|lynx|m1\-w|m3ga|m50\/|ma(te|ui|xo)|mc(01|21|ca)|m\-cr|me(rc|ri)|mi(o8|oa|ts)|mmef|mo(01|02|bi|de|do|t(\-| |o|v)|zz)|mt(50|p1|v )|mwbp|mywa|n10[0-2]|n20[2-3]|n30(0|2)|n50(0|2|5)|n7(0(0|1)|10)|ne((c|m)\-|on|tf|wf|wg|wt)|nok(6|i)|nzph|o2im|op(ti|wv)|oran|owg1|p800|pan(a|d|t)|pdxg|pg(13|\-([1-8]|c))|phil|pire|pl(ay|uc)|pn\-2|po(ck|rt|se)|prox|psio|pt\-g|qa\-a|qc(07|12|21|32|60|\-[2-7]|i\-)|qtek|r380|r600|raks|rim9|ro(ve|zo)|s55\/|sa(ge|ma|mm|ms|ny|va)|sc(01|h\-|oo|p\-)|sdk\/|se(c(\-|0|1)|47|mc|nd|ri)|sgh\-|shar|sie(\-|m)|sk\-0|sl(45|id)|sm(al|ar|b3|it|t5)|so(ft|ny)|sp(01|h\-|v\-|v )|sy(01|mb)|t2(18|50)|t6(00|10|18)|ta(gt|lk)|tcl\-|tdg\-|tel(i|m)|tim\-|t\-mo|to(pl|sh)|ts(70|m\-|m3|m5)|tx\-9|up(\.b|g1|si)|utst|v400|v750|veri|vi(rg|te)|vk(40|5[0-3]|\-v)|vm40|voda|vulc|vx(52|53|60|61|70|80|81|83|85|98)|w3c(\-| )|webc|whit|wi(g |nc|nw)|wmlb|wonu|x700|yas\-|your|zeto|zte\-/i.test(e.substr(0, 4));
  }
  return !1;
}
function ri() {
  return typeof window < "u" && window.document != null || //@ts-ignore
  typeof WorkerGlobalScope < "u";
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ue = y();
ue.registerFlag("DEBUG", () => !1, (n) => {
  n && console.warn("Debugging mode is ON. The output of every math call will be downloaded to CPU and checked for NaNs. This significantly impacts performance.");
});
ue.registerFlag("IS_BROWSER", () => ri());
ue.registerFlag("IS_NODE", () => typeof process < "u" && typeof process.versions < "u" && typeof process.versions.node < "u");
ue.registerFlag("IS_CHROME", () => typeof navigator < "u" && navigator != null && navigator.userAgent != null && /Chrome/.test(navigator.userAgent) && /Google Inc/.test(navigator.vendor));
ue.registerFlag("IS_SAFARI", () => typeof navigator < "u" && navigator != null && navigator.userAgent != null && /Safari/.test(navigator.userAgent) && /Apple/.test(navigator.vendor));
ue.registerFlag("PROD", () => !1);
ue.registerFlag("TENSORLIKE_CHECK_SHAPE_CONSISTENCY", () => ue.getBool("DEBUG"));
ue.registerFlag("DEPRECATION_WARNINGS_ENABLED", () => !0);
ue.registerFlag("IS_TEST", () => !1);
ue.registerFlag("CHECK_COMPUTATION_FOR_ERRORS", () => ue.getBool("DEBUG"));
ue.registerFlag("WRAP_TO_IMAGEBITMAP", () => !1);
ue.registerFlag("CANVAS2D_WILL_READ_FREQUENTLY_FOR_GPU", () => !1);
ue.registerFlag("USE_SETTIMEOUTCUSTOM", () => !1);
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Dd(n, e) {
  let t = n;
  if (Te(n))
    return e === "string" ? [] : [n.length];
  if (Jr(n)) {
    const o = n.channels || "RGBA";
    return [n.height, n.width * o.length];
  } else if (ei(n))
    return [n.buffer.size / (e == null ? 4 : Ln(e))];
  if (!Array.isArray(n))
    return [];
  const s = [];
  for (; Array.isArray(t) || Te(t) && e !== "string"; )
    s.push(t.length), t = t[0];
  return Array.isArray(n) && y().getBool("TENSORLIKE_CHECK_SHAPE_CONSISTENCY") && ii(n, s, []), s;
}
function ii(n, e, t) {
  if (t = t || [], !Array.isArray(n) && !Te(n)) {
    N(e.length === 0, () => `Element arr[${t.join("][")}] is a primitive, but should be an array/TypedArray of ${e[0]} elements`);
    return;
  }
  N(e.length > 0, () => `Element arr[${t.join("][")}] should be a primitive, but is an array of ${n.length} elements`), N(n.length === e[0], () => `Element arr[${t.join("][")}] should have ${e[0]} elements, but has ${n.length} elements`);
  const s = e.slice(1);
  for (let o = 0; o < n.length; ++o)
    ii(n[o], s, t.concat(o));
}
function Oo(n, e, t, s) {
  if (n !== "string_or_numeric") {
    if (n == null)
      throw new Error("Expected dtype cannot be null.");
    if (n !== "numeric" && n !== e || n === "numeric" && e === "string")
      throw new Error(`Argument '${t}' passed to '${s}' must be ${n} tensor, but got ${e} tensor`);
  }
}
function z(n, e, t, s = "numeric") {
  if (n instanceof ve)
    return Oo(s, n.dtype, e, t), n;
  let o = gn(n);
  if (o !== "string" && ["bool", "int32", "float32"].indexOf(s) >= 0 && (o = s), Oo(s, o, e, t), n == null || !Te(n) && !Array.isArray(n) && typeof n != "number" && typeof n != "boolean" && typeof n != "string") {
    const c = n == null ? "null" : n.constructor.name;
    throw new Error(`Argument '${e}' passed to '${t}' must be a Tensor or TensorLike, but got '${c}'`);
  }
  const r = Dd(n, o);
  !Te(n) && !Array.isArray(n) && (n = [n]);
  const a = o !== "string" ? Qn(n, o) : mt(n, [], !0);
  return D.makeTensor(a, r, o);
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Od = "__op";
function ce(n) {
  const e = Object.keys(n);
  if (e.length !== 1)
    throw new Error(`Please provide an object with a single key (operation name) mapping to a function. Got an object with ${e.length} keys.`);
  let t = e[0];
  const s = n[t];
  t.endsWith("_") && (t = t.substring(0, t.length - 1)), t = t + Od;
  const o = (...r) => {
    D.startScope(t);
    try {
      const i = s(...r);
      return Hs(i) && console.error("Cannot return a Promise inside of tidy."), D.endScope(i), i;
    } catch (i) {
      throw D.endScope(null), i;
    }
  };
  return Object.defineProperty(o, "name", { value: t, configurable: !0 }), o;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Pd(n, e) {
  const t = z(n, "real", "complex"), s = z(e, "imag", "complex");
  $r(t.shape, s.shape, `real and imag shapes, ${t.shape} and ${s.shape}, must match in call to tf.complex().`);
  const o = { real: t, imag: s };
  return D.runKernel(Nr, o);
}
const _d = /* @__PURE__ */ ce({ complex_: Pd });
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ld(n, e, t, s) {
  if (s == null)
    s = gn(n);
  else if (s === "complex64")
    throw new Error("Cannot construct a complex64 tensor directly. Please use tf.complex(real, imag).");
  if (ei(n) || Jr(n)) {
    if (s !== "float32" && s !== "int32")
      throw new Error(`Creating tensor from GPU data only supports 'float32'|'int32' dtype, while the dtype is ${s}.`);
    return D.backend.createTensorFromGPUData(n, e || t, s);
  }
  if (!Te(n) && !Array.isArray(n) && typeof n != "number" && typeof n != "boolean" && typeof n != "string")
    throw new Error("values passed to tensor(values) must be a number/boolean/string or an array of numbers/booleans/strings, or a TypedArray");
  if (e != null) {
    xn(e);
    const o = T(e), r = T(t);
    N(o === r, () => `Based on the provided shape, [${e}], the tensor should have ${o} values but has ${r}`);
    for (let i = 0; i < t.length; ++i) {
      const a = t[i], c = i === t.length - 1 ? a !== T(e.slice(i)) : !0;
      N(t[i] === e[i] || !c, () => `Error creating a new Tensor. Inferred shape (${t}) does not match the provided shape (${e}). `);
    }
  }
  return !Te(n) && !Array.isArray(n) && (n = [n]), e = e || t, n = s !== "string" ? Qn(n, s) : mt(n, [], !0), D.makeTensor(n, e, s);
}
class St {
  /**
   * Concatenate a number of ArrayBuffers into one.
   *
   * @param buffers An array of ArrayBuffers to concatenate, or a single
   *     ArrayBuffer.
   * @returns Result of concatenating `buffers` in order.
   */
  static join(e) {
    return new St(e).slice();
  }
  constructor(e) {
    if (this.shards = [], this.previousShardIndex = 0, e == null || (e instanceof Array || (e = [e]), e = e.map((s) => Te(s) ? s.buffer : s), e.length === 0))
      return;
    this.bufferUniformSize = e[0].byteLength;
    let t = 0;
    for (let s = 0; s < e.length; s++) {
      const o = e[s];
      s !== e.length - 1 && o.byteLength !== this.bufferUniformSize && (this.bufferUniformSize = void 0);
      const r = t + o.byteLength;
      this.shards.push({ buffer: o, start: t, end: r }), t = r;
    }
    this.shards.length === 0 && (this.byteLength = 0), this.byteLength = this.shards[this.shards.length - 1].end;
  }
  slice(e = 0, t = this.byteLength) {
    if (this.shards.length === 0)
      return new ArrayBuffer(0);
    if (e = isNaN(Number(e)) ? 0 : e, t = isNaN(Number(t)) ? 0 : t, e = Math.max(0, e), t = Math.min(this.byteLength, t), t <= e)
      return new ArrayBuffer(0);
    const s = this.findShardForByte(e);
    if (s === -1)
      throw new Error(`Could not find start shard for byte ${e}`);
    const o = t - e, r = new ArrayBuffer(o), i = new Uint8Array(r);
    let a = 0;
    for (let c = s; c < this.shards.length; c++) {
      const l = this.shards[c], d = e + a - l.start, h = a, p = Math.min(t, l.end) - l.start, x = new Uint8Array(l.buffer, d, p - d);
      if (i.set(x, h), a += x.length, t < l.end)
        break;
    }
    return r;
  }
  /**
   * Get the index of the shard that contains the byte at `byteIndex`.
   */
  findShardForByte(e) {
    if (this.shards.length === 0 || e < 0 || e >= this.byteLength)
      return -1;
    if (this.bufferUniformSize != null)
      return this.previousShardIndex = Math.floor(e / this.bufferUniformSize), this.previousShardIndex;
    function t(o) {
      return e < o.start ? -1 : e >= o.end ? 1 : 0;
    }
    if (t(this.shards[this.previousShardIndex]) === 0)
      return this.previousShardIndex;
    const s = Bd(this.shards, t);
    return s === -1 ? -1 : (this.previousShardIndex = s, this.previousShardIndex);
  }
}
function Bd(n, e) {
  let t = 0, s = n.length;
  for (; t <= s; ) {
    const o = Math.floor((s - t) / 2) + t, r = e(n[o]);
    if (r === 0)
      return o;
    r < 0 ? s = o : t = o + 1;
  }
  return -1;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Zs = typeof Buffer < "u" && (typeof Blob > "u" || typeof atob > "u" || typeof btoa > "u");
function Po(n) {
  return Zs ? Buffer.byteLength(n, "utf8") : new Blob([n]).size;
}
function Md(n) {
  if (Zs)
    return Buffer.from(n).toString("base64");
  const e = new Uint8Array(n);
  let t = "";
  for (let s = 0, o = e.length; s < o; s++)
    t += String.fromCharCode(e[s]);
  return btoa(t);
}
function Vd(n) {
  if (Zs) {
    const s = Buffer.from(n, "base64");
    return s.buffer.slice(s.byteOffset, s.byteOffset + s.byteLength);
  }
  const e = atob(n), t = new Uint8Array(e.length);
  for (let s = 0; s < e.length; ++s)
    t.set([e.charCodeAt(s)], s);
  return t.buffer;
}
function ai(n, e) {
  const t = {
    modelTopology: n.modelTopology,
    format: n.format,
    generatedBy: n.generatedBy,
    convertedBy: n.convertedBy,
    weightsManifest: e
  };
  return n.signature != null && (t.signature = n.signature), n.userDefinedMetadata != null && (t.userDefinedMetadata = n.userDefinedMetadata), n.modelInitializer != null && (t.modelInitializer = n.modelInitializer), n.initializerSignature != null && (t.initializerSignature = n.initializerSignature), n.trainingConfig != null && (t.trainingConfig = n.trainingConfig), t;
}
function Ud(n, e, t) {
  const s = {
    modelTopology: n.modelTopology,
    format: n.format,
    generatedBy: n.generatedBy,
    convertedBy: n.convertedBy
  };
  if (n.trainingConfig != null && (s.trainingConfig = n.trainingConfig), n.weightsManifest != null) {
    if (!e)
      throw new Error("modelJSON has weightsManifest but weightSpecs is null");
    if (!t)
      throw new Error("modelJSON has weightsManifest but weightData is null");
    s.weightSpecs = e, s.weightData = t;
  }
  return n.signature != null && (s.signature = n.signature), n.userDefinedMetadata != null && (s.userDefinedMetadata = n.userDefinedMetadata), n.modelInitializer != null && (s.modelInitializer = n.modelInitializer), n.initializerSignature != null && (s.initializerSignature = n.initializerSignature), s;
}
async function Wd(n, e) {
  let t, s;
  return n.weightsManifest != null && ([t, s] = await e(n.weightsManifest)), Ud(n, t, s);
}
function Zn(n) {
  if (n.modelTopology instanceof ArrayBuffer)
    throw new Error("Expected JSON model topology, received ArrayBuffer.");
  return {
    dateSaved: /* @__PURE__ */ new Date(),
    modelTopologyType: "JSON",
    modelTopologyBytes: n.modelTopology == null ? 0 : Po(JSON.stringify(n.modelTopology)),
    weightSpecsBytes: n.weightSpecs == null ? 0 : Po(JSON.stringify(n.weightSpecs)),
    weightDataBytes: n.weightData == null ? 0 : new St(n.weightData).byteLength
  };
}
function Gd(n) {
  const e = [];
  for (const t of n)
    e.push(...t.weights);
  return e;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class K {
  constructor() {
    this.saveRouters = [], this.loadRouters = [];
  }
  static getInstance() {
    return K.instance == null && (K.instance = new K()), K.instance;
  }
  /**
   * Register a save-handler router.
   *
   * @param saveRouter A function that maps a URL-like string onto an instance
   * of `IOHandler` with the `save` method defined or `null`.
   */
  static registerSaveRouter(e) {
    K.getInstance().saveRouters.push(e);
  }
  /**
   * Register a load-handler router.
   *
   * @param loadRouter A function that maps a URL-like string onto an instance
   * of `IOHandler` with the `load` method defined or `null`.
   */
  static registerLoadRouter(e) {
    K.getInstance().loadRouters.push(e);
  }
  /**
   * Look up IOHandler for saving, given a URL-like string.
   *
   * @param url
   * @returns If only one match is found, an instance of IOHandler with the
   * `save` method defined. If no match is found, `null`.
   * @throws Error, if more than one match is found.
   */
  static getSaveHandlers(e) {
    return K.getHandlers(e, "save");
  }
  /**
   * Look up IOHandler for loading, given a URL-like string.
   *
   * @param url
   * @param loadOptions Optional, custom load options.
   * @returns All valid handlers for `url`, given the currently registered
   *   handler routers.
   */
  static getLoadHandlers(e, t) {
    return K.getHandlers(e, "load", t);
  }
  static getHandlers(e, t, s) {
    const o = [];
    return (t === "load" ? K.getInstance().loadRouters : K.getInstance().saveRouters).forEach((i) => {
      const a = i(e, s);
      a !== null && o.push(a);
    }), o;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ns = "tensorflowjs", ks = 1, dt = "models_store", Je = "model_info_store";
function ci() {
  if (!y().getBool("IS_BROWSER"))
    throw new Error("Failed to obtain IndexedDB factory because the current environmentis not a web browser.");
  const n = typeof window > "u" ? self : window, e = n.indexedDB || n.mozIndexedDB || n.webkitIndexedDB || n.msIndexedDB || n.shimIndexedDB;
  if (e == null)
    throw new Error("The current browser does not appear to support IndexedDB.");
  return e;
}
function As(n) {
  const e = n.result;
  e.createObjectStore(dt, { keyPath: "modelPath" }), e.createObjectStore(Je, { keyPath: "modelPath" });
}
class gt {
  constructor(e) {
    if (this.indexedDB = ci(), e == null || !e)
      throw new Error("For IndexedDB, modelPath must not be null, undefined or empty.");
    this.modelPath = e;
  }
  async save(e) {
    if (e.modelTopology instanceof ArrayBuffer)
      throw new Error("BrowserLocalStorage.save() does not support saving model topology in binary formats yet.");
    return this.databaseAction(this.modelPath, e);
  }
  async load() {
    return this.databaseAction(this.modelPath);
  }
  /**
   * Perform database action to put model artifacts into or read model artifacts
   * from IndexedDB object store.
   *
   * Whether the action is put or get depends on whether `modelArtifacts` is
   * specified. If it is specified, the action will be put; otherwise the action
   * will be get.
   *
   * @param modelPath A unique string path for the model.
   * @param modelArtifacts If specified, it will be the model artifacts to be
   *   stored in IndexedDB.
   * @returns A `Promise` of `SaveResult`, if the action is put, or a `Promise`
   *   of `ModelArtifacts`, if the action is get.
   */
  databaseAction(e, t) {
    return new Promise((s, o) => {
      const r = this.indexedDB.open(Ns, ks);
      r.onupgradeneeded = () => As(r), r.onsuccess = () => {
        const i = r.result;
        if (t == null) {
          const a = i.transaction(dt, "readonly"), l = a.objectStore(dt).get(this.modelPath);
          l.onsuccess = () => {
            if (l.result == null)
              return i.close(), o(new Error(`Cannot find model with path '${this.modelPath}' in IndexedDB.`));
            s(l.result.modelArtifacts);
          }, l.onerror = (u) => (i.close(), o(l.error)), a.oncomplete = () => i.close();
        } else {
          t.weightData = St.join(t.weightData);
          const a = Zn(t), c = i.transaction(Je, "readwrite");
          let l = c.objectStore(Je), u;
          try {
            u = l.put({ modelPath: this.modelPath, modelArtifactsInfo: a });
          } catch (h) {
            return o(h);
          }
          let d;
          u.onsuccess = () => {
            d = i.transaction(dt, "readwrite");
            const h = d.objectStore(dt);
            let f;
            try {
              f = h.put({
                modelPath: this.modelPath,
                modelArtifacts: t,
                modelArtifactsInfo: a
              });
            } catch (p) {
              return o(p);
            }
            f.onsuccess = () => s({ modelArtifactsInfo: a }), f.onerror = (p) => {
              l = c.objectStore(Je);
              const x = l.delete(this.modelPath);
              x.onsuccess = () => (i.close(), o(f.error)), x.onerror = (g) => (i.close(), o(f.error));
            };
          }, u.onerror = (h) => (i.close(), o(u.error)), c.oncomplete = () => {
            d == null ? i.close() : d.oncomplete = () => i.close();
          };
        }
      }, r.onerror = (i) => o(r.error);
    });
  }
}
gt.URL_SCHEME = "indexeddb://";
const li = (n) => y().getBool("IS_BROWSER") && !Array.isArray(n) && n.startsWith(gt.URL_SCHEME) ? zd(n.slice(gt.URL_SCHEME.length)) : null;
K.registerSaveRouter(li);
K.registerLoadRouter(li);
function zd(n) {
  return new gt(n);
}
function Hd(n) {
  return n.startsWith(gt.URL_SCHEME) ? n.slice(gt.URL_SCHEME.length) : n;
}
class Xd {
  constructor() {
    this.indexedDB = ci();
  }
  async listModels() {
    return new Promise((e, t) => {
      const s = this.indexedDB.open(Ns, ks);
      s.onupgradeneeded = () => As(s), s.onsuccess = () => {
        const o = s.result, r = o.transaction(Je, "readonly"), a = r.objectStore(Je).getAll();
        a.onsuccess = () => {
          const c = {};
          for (const l of a.result)
            c[l.modelPath] = l.modelArtifactsInfo;
          e(c);
        }, a.onerror = (c) => (o.close(), t(a.error)), r.oncomplete = () => o.close();
      }, s.onerror = (o) => t(s.error);
    });
  }
  async removeModel(e) {
    return e = Hd(e), new Promise((t, s) => {
      const o = this.indexedDB.open(Ns, ks);
      o.onupgradeneeded = () => As(o), o.onsuccess = () => {
        const r = o.result, i = r.transaction(Je, "readwrite"), a = i.objectStore(Je), c = a.get(e);
        let l;
        c.onsuccess = () => {
          if (c.result == null)
            return r.close(), s(new Error(`Cannot find model with path '${e}' in IndexedDB.`));
          {
            const u = a.delete(e), d = () => {
              l = r.transaction(dt, "readwrite");
              const f = l.objectStore(dt).delete(e);
              f.onsuccess = () => t(c.result.modelArtifactsInfo), f.onerror = (p) => s(c.error);
            };
            u.onsuccess = d, u.onerror = (h) => (d(), r.close(), s(c.error));
          }
        }, c.onerror = (u) => (r.close(), s(c.error)), i.oncomplete = () => {
          l == null ? r.close() : l.oncomplete = () => r.close();
        };
      }, o.onerror = (r) => s(o.error);
    });
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Xe = "/", Ot = "tensorflowjs_models", ui = "info", qd = "model_topology", jd = "weight_specs", Kd = "weight_data", Yd = "model_metadata";
function di(n) {
  return {
    info: [Ot, n, ui].join(Xe),
    topology: [Ot, n, qd].join(Xe),
    weightSpecs: [Ot, n, jd].join(Xe),
    weightData: [Ot, n, Kd].join(Xe),
    modelMetadata: [Ot, n, Yd].join(Xe)
  };
}
function hi(n) {
  for (const e of Object.values(n))
    window.localStorage.removeItem(e);
}
function Qd(n) {
  const e = n.split(Xe);
  if (e.length < 3)
    throw new Error(`Invalid key format: ${n}`);
  return e.slice(1, e.length - 1).join(Xe);
}
function Zd(n) {
  return n.startsWith(xt.URL_SCHEME) ? n.slice(xt.URL_SCHEME.length) : n;
}
class xt {
  constructor(e) {
    if (!y().getBool("IS_BROWSER") || typeof window > "u" || typeof window.localStorage > "u")
      throw new Error("The current environment does not support local storage.");
    if (this.LS = window.localStorage, e == null || !e)
      throw new Error("For local storage, modelPath must not be null, undefined or empty.");
    this.modelPath = e, this.keys = di(this.modelPath);
  }
  /**
   * Save model artifacts to browser local storage.
   *
   * See the documentation to `browserLocalStorage` for details on the saved
   * artifacts.
   *
   * @param modelArtifacts The model artifacts to be stored.
   * @returns An instance of SaveResult.
   */
  async save(e) {
    if (e.modelTopology instanceof ArrayBuffer)
      throw new Error("BrowserLocalStorage.save() does not support saving model topology in binary formats yet.");
    {
      const t = JSON.stringify(e.modelTopology), s = JSON.stringify(e.weightSpecs), o = Zn(e), r = St.join(e.weightData);
      try {
        this.LS.setItem(this.keys.info, JSON.stringify(o)), this.LS.setItem(this.keys.topology, t), this.LS.setItem(this.keys.weightSpecs, s), this.LS.setItem(this.keys.weightData, Md(r));
        const i = {
          format: e.format,
          generatedBy: e.generatedBy,
          convertedBy: e.convertedBy,
          signature: e.signature != null ? e.signature : void 0,
          userDefinedMetadata: e.userDefinedMetadata != null ? e.userDefinedMetadata : void 0,
          modelInitializer: e.modelInitializer != null ? e.modelInitializer : void 0,
          initializerSignature: e.initializerSignature != null ? e.initializerSignature : void 0,
          trainingConfig: e.trainingConfig != null ? e.trainingConfig : void 0
        };
        return this.LS.setItem(this.keys.modelMetadata, JSON.stringify(i)), { modelArtifactsInfo: o };
      } catch {
        throw hi(this.keys), new Error(`Failed to save model '${this.modelPath}' to local storage: size quota being exceeded is a possible cause of this failure: modelTopologyBytes=${o.modelTopologyBytes}, weightSpecsBytes=${o.weightSpecsBytes}, weightDataBytes=${o.weightDataBytes}.`);
      }
    }
  }
  /**
   * Load a model from local storage.
   *
   * See the documentation to `browserLocalStorage` for details on the saved
   * artifacts.
   *
   * @returns The loaded model (if loading succeeds).
   */
  async load() {
    const e = JSON.parse(this.LS.getItem(this.keys.info));
    if (e == null)
      throw new Error(`In local storage, there is no model with name '${this.modelPath}'`);
    if (e.modelTopologyType !== "JSON")
      throw new Error("BrowserLocalStorage does not support loading non-JSON model topology yet.");
    const t = {}, s = JSON.parse(this.LS.getItem(this.keys.topology));
    if (s == null)
      throw new Error(`In local storage, the topology of model '${this.modelPath}' is missing.`);
    t.modelTopology = s;
    const o = JSON.parse(this.LS.getItem(this.keys.weightSpecs));
    if (o == null)
      throw new Error(`In local storage, the weight specs of model '${this.modelPath}' are missing.`);
    t.weightSpecs = o;
    const r = this.LS.getItem(this.keys.modelMetadata);
    if (r != null) {
      const a = JSON.parse(r);
      t.format = a.format, t.generatedBy = a.generatedBy, t.convertedBy = a.convertedBy, a.signature != null && (t.signature = a.signature), a.userDefinedMetadata != null && (t.userDefinedMetadata = a.userDefinedMetadata), a.modelInitializer != null && (t.modelInitializer = a.modelInitializer), a.initializerSignature != null && (t.initializerSignature = a.initializerSignature), a.trainingConfig != null && (t.trainingConfig = a.trainingConfig);
    }
    const i = this.LS.getItem(this.keys.weightData);
    if (i == null)
      throw new Error(`In local storage, the binary weight values of model '${this.modelPath}' are missing.`);
    return t.weightData = Vd(i), t;
  }
}
xt.URL_SCHEME = "localstorage://";
const fi = (n) => y().getBool("IS_BROWSER") && !Array.isArray(n) && n.startsWith(xt.URL_SCHEME) ? Jd(n.slice(xt.URL_SCHEME.length)) : null;
K.registerSaveRouter(fi);
K.registerLoadRouter(fi);
function Jd(n) {
  return new xt(n);
}
class eh {
  constructor() {
    N(y().getBool("IS_BROWSER"), () => "Current environment is not a web browser"), N(typeof window > "u" || typeof window.localStorage < "u", () => "Current browser does not appear to support localStorage"), this.LS = window.localStorage;
  }
  async listModels() {
    const e = {}, t = Ot + Xe, s = Xe + ui;
    for (let o = 0; o < this.LS.length; ++o) {
      const r = this.LS.key(o);
      if (r.startsWith(t) && r.endsWith(s)) {
        const i = Qd(r);
        e[i] = JSON.parse(this.LS.getItem(r));
      }
    }
    return e;
  }
  async removeModel(e) {
    e = Zd(e);
    const t = di(e);
    if (this.LS.getItem(t.info) == null)
      throw new Error(`Cannot find model at path '${e}'`);
    const s = JSON.parse(this.LS.getItem(t.info));
    return hi(t), s;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const _o = "://";
class Ve {
  constructor() {
    this.managers = {};
  }
  static getInstance() {
    return Ve.instance == null && (Ve.instance = new Ve()), Ve.instance;
  }
  /**
   * Register a save-handler router.
   *
   * @param saveRouter A function that maps a URL-like string onto an instance
   * of `IOHandler` with the `save` method defined or `null`.
   */
  static registerManager(e, t) {
    N(e != null, () => "scheme must not be undefined or null."), e.endsWith(_o) && (e = e.slice(0, e.indexOf(_o))), N(e.length > 0, () => "scheme must not be an empty string.");
    const s = Ve.getInstance();
    N(s.managers[e] == null, () => `A model store manager is already registered for scheme '${e}'.`), s.managers[e] = t;
  }
  static getManager(e) {
    const t = Ve.getInstance().managers[e];
    if (t == null)
      throw new Error(`Cannot find model manager for scheme '${e}'`);
    return t;
  }
  static getSchemes() {
    return Object.keys(Ve.getInstance().managers);
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class th {
  constructor() {
    this.messageName = "setTimeoutCustom", this.functionRefs = [], this.handledMessageCount = 0, this.hasEventListener = !1;
  }
  fetch(e, t) {
    return fetch(e, t);
  }
  now() {
    return performance.now();
  }
  encode(e, t) {
    if (t !== "utf-8" && t !== "utf8")
      throw new Error(`Browser's encoder only supports utf-8, but got ${t}`);
    return this.textEncoder == null && (this.textEncoder = new TextEncoder()), this.textEncoder.encode(e);
  }
  decode(e, t) {
    return new TextDecoder(t).decode(e);
  }
  // If the setTimeout nesting level is greater than 5 and timeout is less
  // than 4ms, timeout will be clamped to 4ms, which hurts the perf.
  // Interleaving window.postMessage and setTimeout will trick the browser and
  // avoid the clamp.
  setTimeoutCustom(e, t) {
    if (typeof window > "u" || !y().getBool("USE_SETTIMEOUTCUSTOM")) {
      setTimeout(e, t);
      return;
    }
    this.functionRefs.push(e), setTimeout(() => {
      window.postMessage({ name: this.messageName, index: this.functionRefs.length - 1 }, "*");
    }, t), this.hasEventListener || (this.hasEventListener = !0, window.addEventListener("message", (s) => {
      if (s.source === window && s.data.name === this.messageName) {
        s.stopPropagation();
        const o = this.functionRefs[s.data.index];
        o(), this.handledMessageCount++, this.handledMessageCount === this.functionRefs.length && (this.functionRefs = [], this.handledMessageCount = 0);
      }
    }, !0));
  }
  isTypedArray(e) {
    return Gr(e);
  }
}
if (y().get("IS_BROWSER")) {
  y().setPlatform("browser", new th());
  try {
    Ve.registerManager(xt.URL_SCHEME, new eh());
  } catch {
  }
  try {
    Ve.registerManager(gt.URL_SCHEME, new Xd());
  } catch {
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const nh = {
  // tslint:disable-next-line:no-require-imports
  importFetch: () => require("node-fetch")
};
let ds;
class sh {
  constructor() {
    this.util = require("util"), this.textEncoder = new this.util.TextEncoder();
  }
  fetch(e, t) {
    return y().global.fetch != null ? y().global.fetch(e, t) : (ds == null && (ds = nh.importFetch()), ds(e, t));
  }
  now() {
    const e = process.hrtime();
    return e[0] * 1e3 + e[1] / 1e6;
  }
  encode(e, t) {
    if (t !== "utf-8" && t !== "utf8")
      throw new Error(`Node built-in encoder only supports utf-8, but got ${t}`);
    return this.textEncoder.encode(e);
  }
  decode(e, t) {
    return e.length === 0 ? "" : new this.util.TextDecoder(t).decode(e);
  }
  isTypedArray(e) {
    return this.util.types.isFloat32Array(e) || this.util.types.isInt32Array(e) || this.util.types.isUint8Array(e) || this.util.types.isUint8ClampedArray(e);
  }
}
y().get("IS_NODE") && !y().get("IS_BROWSER") && y().setPlatform("node", new sh());
/**
 * @license
 * Copyright 2020 Google Inc. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function J(n, e = "float32", t) {
  return e = e || "float32", xn(n), new Vn(n, e, t);
}
/**
 * @license
 * Copyright 2020 Google Inc. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function oh(n, e) {
  const t = z(n, "x", "cast");
  if (!oc(e))
    throw new Error(`Failed to cast to unknown dtype ${e}`);
  if (e === "string" && t.dtype !== "string" || e !== "string" && t.dtype === "string")
    throw new Error("Only strings can be casted to strings");
  const s = { x: t }, o = { dtype: e };
  return D.runKernel(js, s, o);
}
const Fs = /* @__PURE__ */ ce({ cast_: oh });
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function rh(n) {
  const t = { x: z(n, "x", "clone", "string_or_numeric") };
  return D.runKernel(Ks, t);
}
const pi = /* @__PURE__ */ ce({ clone_: rh });
/**
 * @license
 * Copyright 2020 Google Inc. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ih(n, e = !1) {
  console.log(n.toString(e));
}
/**
 * @license
 * Copyright 2020 Google Inc. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
si();
const ah = {
  buffer: J,
  cast: Fs,
  clone: pi,
  print: ih
};
Rd(ah);
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function CS() {
  D.disposeVariables();
}
function Qe() {
  return D;
}
function bS() {
  return D.memory();
}
function H(n, e) {
  return D.tidy(n, e);
}
function Ce(n) {
  ti(n).forEach((t) => t.dispose());
}
function ch(n) {
  return D.keep(n);
}
function wS(n) {
  return D.setBackend(n);
}
function yS() {
  return D.ready();
}
function lh(n, e, t = 1) {
  return D.registerBackend(n, e, t);
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function uh(n, e) {
  let t = z(n, "a", "add"), s = z(e, "b", "add");
  [t, s] = $t(t, s);
  const o = { a: t, b: s };
  return D.runKernel(qs, o);
}
const M = /* @__PURE__ */ ce({ add_: uh });
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function dh(n, e) {
  let t = z(n, "a", "floorDiv"), s = z(e, "b", "floorDiv");
  [t, s] = $t(t, s);
  const o = { a: t, b: s };
  return D.runKernel(Dr, o);
}
const hh = /* @__PURE__ */ ce({ floorDiv_: dh });
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function fh(n, e) {
  let t = z(n, "a", "div"), s = z(e, "b", "div");
  if ([t, s] = $t(t, s), t.dtype === "int32" && s.dtype === "int32")
    return hh(t, s);
  const o = { a: t, b: s }, r = {};
  return D.runKernel(Ar, o, r);
}
const We = /* @__PURE__ */ ce({ div_: fh });
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ph(n, e) {
  let t = z(n, "a", "mul"), s = z(e, "b", "mul");
  [t, s] = $t(t, s);
  const o = { a: t, b: s };
  return D.runKernel(Pr, o);
}
const P = /* @__PURE__ */ ce({ mul_: ph });
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function mh(n) {
  const e = z(n, "x", "abs");
  if (e.dtype === "complex64") {
    const t = { x: e };
    return D.runKernel(kr, t);
  } else {
    const t = { x: e };
    return D.runKernel(Er, t);
  }
}
const gh = /* @__PURE__ */ ce({ abs_: mh });
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function mi(n, e, t, s, o = "NHWC", r) {
  const i = n[3], a = [...e, i], c = Kt(o);
  return Be(n, a, t, r, s, null, null, c);
}
function qt(n, e, t, s, o, r, i = "channelsLast") {
  const [a, c] = Wn(e);
  let l;
  if (i === "channelsLast")
    l = [a, c, n[3], n[3]];
  else if (i === "channelsFirst")
    l = [a, c, n[1], n[1]];
  else
    throw new Error(`Unknown dataFormat ${i}`);
  return Be(n, l, t, s, o, r, !1, i);
}
function Cn(n, e, t, s, o, r, i = "NDHWC") {
  const [a, c, l] = Ds(e);
  let u, d;
  if (i === "NDHWC")
    d = "channelsLast", u = [a, c, l, n[4], n[4]];
  else if (i === "NCDHW")
    d = "channelsFirst", u = [a, c, l, n[1], n[1]];
  else
    throw new Error(`Unknown dataFormat ${i}`);
  return bn(n, u, t, s, o, !1, d, r);
}
function Be(n, e, t, s, o, r, i = !1, a = "channelsLast") {
  let [c, l, u, d] = [-1, -1, -1, -1];
  if (a === "channelsLast")
    [c, l, u, d] = n;
  else if (a === "channelsFirst")
    [c, d, l, u] = n;
  else
    throw new Error(`Unknown dataFormat ${a}`);
  const [h, f, , p] = e, [x, g] = Wn(t), [m, C] = Wn(s), b = Lt(h, m), w = Lt(f, C), { padInfo: v, outHeight: E, outWidth: R } = bh(o, l, u, x, g, b, w, r, a), $ = i ? p * d : p;
  let F;
  return a === "channelsFirst" ? F = [c, $, E, R] : a === "channelsLast" && (F = [c, E, R, $]), {
    batchSize: c,
    dataFormat: a,
    inHeight: l,
    inWidth: u,
    inChannels: d,
    outHeight: E,
    outWidth: R,
    outChannels: $,
    padInfo: v,
    strideHeight: x,
    strideWidth: g,
    filterHeight: h,
    filterWidth: f,
    effectiveFilterHeight: b,
    effectiveFilterWidth: w,
    dilationHeight: m,
    dilationWidth: C,
    inShape: n,
    outShape: F,
    filterShape: e
  };
}
function bn(n, e, t, s, o, r = !1, i = "channelsLast", a) {
  let [c, l, u, d, h] = [-1, -1, -1, -1, -1];
  if (i === "channelsLast")
    [c, l, u, d, h] = n;
  else if (i === "channelsFirst")
    [c, h, l, u, d] = n;
  else
    throw new Error(`Unknown dataFormat ${i}`);
  const [f, p, x, , g] = e, [m, C, b] = Ds(t), [w, v, E] = Ds(s), R = Lt(f, w), $ = Lt(p, v), F = Lt(x, E), { padInfo: O, outDepth: L, outHeight: B, outWidth: he } = wh(o, l, u, d, m, C, b, R, $, F, a), j = r ? g * h : g;
  let te;
  return i === "channelsFirst" ? te = [c, j, L, B, he] : i === "channelsLast" && (te = [c, L, B, he, j]), {
    batchSize: c,
    dataFormat: i,
    inDepth: l,
    inHeight: u,
    inWidth: d,
    inChannels: h,
    outDepth: L,
    outHeight: B,
    outWidth: he,
    outChannels: j,
    padInfo: O,
    strideDepth: m,
    strideHeight: C,
    strideWidth: b,
    filterDepth: f,
    filterHeight: p,
    filterWidth: x,
    effectiveFilterDepth: R,
    effectiveFilterHeight: $,
    effectiveFilterWidth: F,
    dilationDepth: w,
    dilationHeight: v,
    dilationWidth: E,
    inShape: n,
    outShape: te,
    filterShape: e
  };
}
function xh(n, e, t, s, o) {
  s == null && (s = Js(n, e, t));
  const r = n[0], i = n[1], a = dn((r - e + 2 * s) / t + 1, o), c = dn((i - e + 2 * s) / t + 1, o);
  return [a, c];
}
function Ch(n, e, t, s, o, r) {
  o == null && (o = Js(n, e[0], s[0]));
  const i = [0, 0, 0, t];
  for (let a = 0; a < 3; a++)
    n[a] + 2 * o >= e[a] && (i[a] = dn((n[a] - e[a] + 2 * o) / s[a] + 1, r));
  return i;
}
function Js(n, e, t, s = 1) {
  const o = Lt(e, s);
  return Math.floor((n[0] * (t - 1) - t + o) / 2);
}
function Wn(n) {
  return typeof n == "number" ? [n, n, n] : n.length === 2 ? [n[0], n[1], 1] : n;
}
function Ds(n) {
  return typeof n == "number" ? [n, n, n] : n;
}
function Lt(n, e) {
  return e <= 1 ? n : n + (n - 1) * (e - 1);
}
function bh(n, e, t, s, o, r, i, a, c) {
  let l, u, d;
  if (typeof n == "number") {
    l = { top: n, bottom: n, left: n, right: n, type: n === 0 ? "VALID" : "NUMBER" };
    const f = xh([e, t], r, s, n, a);
    u = f[0], d = f[1];
  } else if (n === "same") {
    u = Math.ceil(e / s), d = Math.ceil(t / o);
    const h = Math.max(0, (u - 1) * s + r - e), f = Math.max(0, (d - 1) * o + i - t), p = Math.floor(h / 2), x = h - p, g = Math.floor(f / 2), m = f - g;
    l = { top: p, bottom: x, left: g, right: m, type: "SAME" };
  } else if (n === "valid")
    l = { top: 0, bottom: 0, left: 0, right: 0, type: "VALID" }, u = Math.ceil((e - r + 1) / s), d = Math.ceil((t - i + 1) / o);
  else if (typeof n == "object") {
    const h = c === "channelsLast" ? n[1][0] : n[2][0], f = c === "channelsLast" ? n[1][1] : n[2][1], p = c === "channelsLast" ? n[2][0] : n[3][0], x = c === "channelsLast" ? n[2][1] : n[3][1];
    l = { top: h, bottom: f, left: p, right: x, type: h === 0 && f === 0 && p === 0 && x === 0 ? "VALID" : "EXPLICIT" }, u = dn((e - r + h + f) / s + 1, a), d = dn((t - i + p + x) / o + 1, a);
  } else
    throw Error(`Unknown padding parameter: ${n}`);
  return { padInfo: l, outHeight: u, outWidth: d };
}
function wh(n, e, t, s, o, r, i, a, c, l, u) {
  let d, h, f, p;
  if (n === "valid" && (n = 0), typeof n == "number") {
    d = {
      top: n,
      bottom: n,
      left: n,
      right: n,
      front: n,
      back: n,
      type: n === 0 ? "VALID" : "NUMBER"
    };
    const g = Ch([e, t, s, 1], [a, c, l], 1, [o, r, i], n, u);
    h = g[0], f = g[1], p = g[2];
  } else if (n === "same") {
    h = Math.ceil(e / o), f = Math.ceil(t / r), p = Math.ceil(s / i);
    const x = (h - 1) * o + a - e, g = (f - 1) * r + c - t, m = (p - 1) * i + l - s, C = Math.floor(x / 2), b = x - C, w = Math.floor(g / 2), v = g - w, E = Math.floor(m / 2), R = m - E;
    d = { top: w, bottom: v, left: E, right: R, front: C, back: b, type: "SAME" };
  } else
    throw Error(`Unknown padding parameter: ${n}`);
  return { padInfo: d, outDepth: h, outHeight: f, outWidth: p };
}
function dn(n, e) {
  if (!e)
    return Math.trunc(n);
  switch (e) {
    case "round":
      return Math.round(n);
    case "ceil":
      return Math.ceil(n);
    case "floor":
      return Math.floor(n);
    default:
      throw new Error(`Unknown roundingMode ${e}`);
  }
}
function Os(n) {
  const [e, t, s] = Wn(n);
  return e === 1 && t === 1 && s === 1;
}
function jt(n, e) {
  return Os(n) || Os(e);
}
function Kt(n) {
  if (n === "NHWC")
    return "channelsLast";
  if (n === "NCHW")
    return "channelsFirst";
  throw new Error(`Unknown dataFormat ${n}`);
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function yh(n, e) {
  const s = { x: z(n, "x", "reshape", "string_or_numeric") }, o = { shape: e };
  return D.runKernel(Lr, s, o);
}
const gi = /* @__PURE__ */ ce({ reshape_: yh });
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function vh(n, e) {
  let t = z(n, "broadcastTo", "x");
  const s = t.shape;
  if (xn(e), e.length < t.rank)
    throw new Error(`broadcastTo(): shape.length=${e.length} < input.rank=${t.rank}.`);
  if (e.length > t.rank) {
    const l = t.shape.slice();
    for (; l.length < e.length; )
      l.unshift(1);
    t = gi(t, l);
  }
  const o = t.shape, r = Array.from(e);
  for (let l = e.length - 1; l >= 0; l--)
    if (o[l] === e[l])
      r[l] = 1;
    else if (t.shape[l] !== 1)
      throw new Error(`broadcastTo(): [${s}] cannot be broadcast to [${e}].`);
  if (r.map((l, u) => l > 1 ? u : -1).filter((l) => l >= 0).length === 0)
    return pi(t);
  const a = { x: t }, c = { reps: r };
  return D.runKernel(Vr, a, c);
}
const $h = /* @__PURE__ */ ce({ broadcastTo_: vh });
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Sh(n, e, t) {
  xn(n), t = t || gn(e);
  const s = { shape: n, value: e, dtype: t };
  return D.runKernel(Fr, {}, s);
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Gn(n, e) {
  const t = n.length, s = [];
  for (let o = 0; o < t; o++) {
    const r = t - 1 - o, i = n[r] || 1;
    (e[e.length - 1 - o] || 1) > 1 && i === 1 && s.unshift(r);
  }
  return s;
}
function ie(n, e) {
  const t = Math.max(n.length, e.length), s = new Array(t);
  for (let o = 0; o < t; o++) {
    let r = n[n.length - o - 1];
    r == null && (r = 1);
    let i = e[e.length - o - 1];
    if (i == null && (i = 1), r === 1)
      s[t - o - 1] = i;
    else if (i === 1)
      s[t - o - 1] = r;
    else if (r !== i) {
      const a = `Operands could not be broadcast together with shapes ${n} and ${e}.`;
      throw Error(a);
    } else
      s[t - o - 1] = r;
  }
  return s;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ih(n) {
  const t = { x: z(n, "x", "zerosLike") };
  return D.runKernel(Ur, t);
}
const Ge = /* @__PURE__ */ ce({ zerosLike_: Ih });
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function eo(n, e) {
  for (let t = 0; t < n.length; ++t)
    if (n[n.length - t - 1] !== e - 1 - t)
      return !1;
  return !0;
}
function xi(n, e, t) {
  const s = n.length + e.length, o = [];
  let r = 0, i = 0;
  for (let a = 0; a < s; a++)
    t.indexOf(a) === -1 ? o.push(n[r++]) : o.push(e[i++]);
  return o;
}
function He(n, e) {
  const t = [], s = n.length;
  for (let r = 0; r < s; r++)
    e.indexOf(r) === -1 && t.push(n[r]);
  const o = e.map((r) => n[r]);
  return [t, o];
}
function qe(n, e) {
  const t = e.map((s) => 1);
  return xi(n, t, e);
}
function Me(n, e, t) {
  N(eo(e, t), () => `${n} supports only inner-most axes for now. Got axes ${e} and rank-${t} input.`);
}
function Ee(n, e) {
  if (eo(n, e))
    return null;
  const t = [];
  for (let s = 0; s < e; ++s)
    n.indexOf(s) === -1 && t.push(s);
  return n.forEach((s) => t.push(s)), t;
}
function to(n) {
  return n.map((e, t) => [t, e]).sort((e, t) => e[1] - t[1]).map((e) => e[0]);
}
function Ne(n, e) {
  const t = [];
  for (let s = e - n; s < e; ++s)
    t.push(s);
  return t;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Rh(n, e) {
  let t = z(n, "base", "pow"), s = z(e, "exp", "pow");
  [t, s] = $t(t, s);
  const o = { a: t, b: s };
  return D.runKernel(_r, o);
}
const Lo = /* @__PURE__ */ ce({ pow_: Rh });
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function st(n, e) {
  if ((Te(n) && e !== "string" || Array.isArray(n)) && e !== "complex64")
    throw new Error("Error creating a new Scalar: value must be a primitive (number|boolean|string)");
  if (e === "string" && Te(n) && !(n instanceof Uint8Array))
    throw new Error("When making a scalar from encoded string, the value must be `Uint8Array`.");
  return Ld(n, [], [], e);
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Th(n) {
  const t = { x: z(n, "x", "sqrt", "float32") };
  return D.runKernel(Br, t);
}
const Wt = /* @__PURE__ */ ce({ sqrt_: Th });
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Eh(n) {
  const e = z(n, "x", "square"), t = {};
  return D.runKernel("Square", { x: e }, t);
}
const ft = /* @__PURE__ */ ce({ square_: Eh });
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Nh(n, e) {
  N(ws(n), () => "The f passed in variableGrads(f) must be a function"), N(e == null || Array.isArray(e) && e.every((l) => l instanceof Un), () => "The varList passed in variableGrads(f, varList) must be an array of variables");
  const t = e != null;
  if (!t) {
    e = [];
    for (const l in D.registeredVariables)
      e.push(D.registeredVariables[l]);
  }
  const s = t ? e.filter((l) => !l.trainable) : null, o = e.length;
  e = e.filter((l) => l.trainable), N(e.length > 0, () => `variableGrads() expects at least one of the input variables to be trainable, but none of the ${o} variables is trainable.`);
  const r = !0, { value: i, grads: a } = D.gradients(n, e, null, r);
  N(a.some((l) => l != null), () => "Cannot find a connection between any variable and the result of the loss function y=f(x). Please make sure the operations that use variables are inside the function f passed to minimize()."), N(i.rank === 0, () => `The f passed in variableGrads(f) must return a scalar, but it returned a rank-${i.rank} tensor`);
  const c = {};
  return e.forEach((l, u) => {
    a[u] != null && (c[l.name] = a[u]);
  }), s?.forEach((l) => c[l.name] = null), { value: i, grads: c };
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function kh(n, e) {
  let t = z(n, "a", "sub"), s = z(e, "b", "sub");
  [t, s] = $t(t, s);
  const o = { a: t, b: s };
  return D.runKernel(Mr, o);
}
const Bt = /* @__PURE__ */ ce({ sub_: kh });
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ah(n, e) {
  let t = z(n, "a", "maximum"), s = z(e, "b", "maximum");
  [t, s] = $t(t, s), t.dtype === "bool" && (t = Fs(t, "int32"), s = Fs(s, "int32")), ie(t.shape, s.shape);
  const o = { a: t, b: s };
  return D.runKernel(Or, o);
}
const Fh = /* @__PURE__ */ ce({ maximum_: Ah });
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ps(n, e = "float32") {
  if (xn(n), e === "complex64") {
    const s = Ps(n, "float32"), o = Ps(n, "float32");
    return _d(s, o);
  }
  const t = nt(T(n), e);
  return D.makeTensor(t, n, e);
}
const vS = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null
}, Symbol.toStringTag, { value: "Module" }));
function Jn(n, e, t) {
  const s = e.shape.length, o = s > 1 ? e.shape[s - 1] : 1, r = t.length;
  let i = 1;
  for (let d = o; d < r; ++d)
    i *= t[d];
  const a = o < 1 ? 1 : o, c = T(e.shape) / a, l = [...Q(t.slice(0, o)), 1], u = T(t);
  return { sliceRank: o, numUpdates: c, sliceSize: i, strides: l, outputSize: u };
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Dh(n, e) {
  const t = [];
  for (let r = 0; r < e.length; r++)
    e[r] && t.push(r);
  const s = J(n, "int32"), o = J([t.length, n.length], "int32");
  for (let r = 0; r < t.length; r++) {
    const i = s.indexToLoc(t[r]), a = r * n.length;
    o.values.set(i, a);
  }
  return o.toTensor();
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Oh(n, e, t) {
  const s = Ph(n, e, t), o = s < 0 ? -(s + 1) : s;
  n.splice(o, 0, e);
}
function Ph(n, e, t) {
  return Lh(n, e, t || _h);
}
function _h(n, e) {
  return n > e ? 1 : n < e ? -1 : 0;
}
function Lh(n, e, t) {
  let s = 0, o = n.length, r = 0, i = !1;
  for (; s < o; ) {
    r = s + (o - s >>> 1);
    const a = t(e, n[r]);
    a > 0 ? s = r + 1 : (o = r, i = !a);
  }
  return i ? s : -s - 1;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Bh(n, e, t, s, o) {
  return no(
    n,
    e,
    t,
    s,
    o,
    0
    /* softNmsSigma */
  );
}
function Mh(n, e, t, s, o, r) {
  return no(
    n,
    e,
    t,
    s,
    o,
    0,
    !1,
    r,
    !0
    /* returnValidOutputs */
  );
}
function Vh(n, e, t, s, o, r) {
  return no(
    n,
    e,
    t,
    s,
    o,
    r,
    !0
    /* returnScoresTensor */
  );
}
function no(n, e, t, s, o, r, i = !1, a = !1, c = !1) {
  const l = [];
  for (let g = 0; g < e.length; g++)
    e[g] > o && l.push({ score: e[g], boxIndex: g, suppressBeginIndex: 0 });
  l.sort(Bo);
  const u = r > 0 ? -0.5 / r : 0, d = [], h = [];
  for (; d.length < t && l.length > 0; ) {
    const g = l.pop(), { score: m, boxIndex: C, suppressBeginIndex: b } = g;
    if (m < o)
      break;
    let w = !1;
    for (let v = d.length - 1; v >= b; --v) {
      const E = Uh(n, C, d[v]);
      if (E >= s) {
        w = !0;
        break;
      }
      if (g.score = g.score * Wh(s, u, E), g.score <= o)
        break;
    }
    g.suppressBeginIndex = d.length, w || (g.score === m ? (d.push(C), h.push(g.score)) : g.score > o && Oh(l, g, Bo));
  }
  const f = d.length, p = t - f;
  a && p > 0 && (d.push(...new Array(p).fill(0)), h.push(...new Array(p).fill(0)));
  const x = { selectedIndices: d };
  return i && (x.selectedScores = h), c && (x.validOutputs = f), x;
}
function Uh(n, e, t) {
  const s = n.subarray(e * 4, e * 4 + 4), o = n.subarray(t * 4, t * 4 + 4), r = Math.min(s[0], s[2]), i = Math.min(s[1], s[3]), a = Math.max(s[0], s[2]), c = Math.max(s[1], s[3]), l = Math.min(o[0], o[2]), u = Math.min(o[1], o[3]), d = Math.max(o[0], o[2]), h = Math.max(o[1], o[3]), f = (a - r) * (c - i), p = (d - l) * (h - u);
  if (f <= 0 || p <= 0)
    return 0;
  const x = Math.max(r, l), g = Math.max(i, u), m = Math.min(a, d), C = Math.min(c, h), b = Math.max(m - x, 0) * Math.max(C - g, 0);
  return b / (f + p - b);
}
function Wh(n, e, t) {
  const s = Math.exp(e * t * t);
  return t <= n ? s : 0;
}
function Bo(n, e) {
  return n.score - e.score || n.score === e.score && e.boxIndex - n.boxIndex;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Gh = /* @__PURE__ */ new Map(), zh = /* @__PURE__ */ new Map();
class Hh {
  /**
   * Return the class name for this class to use in serialization contexts.
   *
   * Generally speaking this will be the same thing that constructor.name
   * would have returned.  However, the class name needs to be robust
   * against minification for serialization/deserialization to work properly.
   *
   * There's also places such as initializers.VarianceScaling, where
   * implementation details between different languages led to different
   * class hierarchies and a non-leaf node is used for serialization purposes.
   */
  getClassName() {
    return this.constructor.className;
  }
  /**
   * Creates an instance of T from a ConfigDict.
   *
   * This works for most descendants of serializable.  A few need to
   * provide special handling.
   * @param cls A Constructor for the class to instantiate.
   * @param config The Configuration for the object.
   */
  /** @nocollapse */
  static fromConfig(e, t) {
    return new e(t);
  }
}
class ct {
  constructor() {
    this.classNameMap = {};
  }
  /**
   * Returns the singleton instance of the map.
   */
  static getMap() {
    return ct.instance == null && (ct.instance = new ct()), ct.instance;
  }
  /**
   * Registers the class as serializable.
   */
  static register(e) {
    ct.getMap().classNameMap[e.className] = [e, e.fromConfig];
  }
}
function Xh(n, e, t) {
  N(n.className != null, () => "Class being registered does not have the static className property defined."), N(typeof n.className == "string", () => "className is required to be a string, but got type " + typeof n.className), N(n.className.length > 0, () => "Class being registered has an empty-string as its className, which is disallowed."), typeof e > "u" && (e = "Custom"), typeof t > "u" && (t = n.className);
  const s = t, o = e + ">" + s;
  return ct.register(n), Gh.set(o, n), zh.set(n, o), n;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class It extends Hh {
  /**
   * Executes `f()` and minimizes the scalar output of `f()` by computing
   * gradients of y with respect to the list of trainable variables provided by
   * `varList`. If no list is provided, it defaults to all trainable variables.
   *
   * @param f The function to execute and whose output to minimize.
   * @param returnCost Whether to return the scalar cost value produced by
   * executing `f()`.
   * @param varList An optional list of variables to update. If specified, only
   * the trainable variables in varList will be updated by minimize. Defaults to
   * all trainable variables.
   *
   * @doc {heading: 'Training', subheading: 'Optimizers'}
   */
  minimize(e, t = !1, s) {
    const { value: o, grads: r } = this.computeGradients(e, s);
    if (s != null) {
      const i = s.map((a) => ({ name: a.name, tensor: r[a.name] }));
      this.applyGradients(i);
    } else
      this.applyGradients(r);
    return Ce(r), t ? o : (o.dispose(), null);
  }
  /**
   * The number of iterations that this optimizer instance has been invoked for.
   */
  get iterations() {
    return this.iterations_ == null && (this.iterations_ = 0), this.iterations_;
  }
  incrementIterations() {
    this.iterations_ = this.iterations + 1;
  }
  /**
   * Executes f() and computes the gradient of the scalar output of f() with
   * respect to the list of trainable variables provided by `varList`. If no
   * list is provided, it defaults to all trainable variables.
   *
   * @param f The function to execute and whose output to use for computing
   * gradients with respect to variables.
   * @param varList An optional list of variables to compute gradients with
   * respect to. If specified, only the trainable variables in varList will have
   * gradients computed with respect to. Defaults to all trainable variables.
   *
   * @doc {heading: 'Training', subheading: 'Optimizers'}
   */
  computeGradients(e, t) {
    return Nh(e, t);
  }
  /**
   * Dispose the variables (if any) owned by this optimizer instance.
   */
  dispose() {
    this.iterations_ != null && Ce(this.iterations_);
  }
  async saveIterations() {
    return this.iterations_ == null && (this.iterations_ = 0), {
      name: "iter",
      // TODO(cais): Use 'int64' type when available.
      tensor: st(this.iterations_, "int32")
    };
  }
  async getWeights() {
    throw new Error("getWeights() is not implemented for this optimizer yet.");
  }
  async setWeights(e) {
    throw new Error(`setWeights() is not implemented for this optimizer class ${this.getClassName()}`);
  }
  /**
   * Extract the first element of the weight values and set it
   * as the iterations counter variable of this instance of optimizer.
   *
   * @param weightValues
   * @returns Weight values with the first element consumed and excluded.
   */
  async extractIterations(e) {
    return this.iterations_ = (await e[0].tensor.data())[0], e.slice(1);
  }
}
Object.defineProperty(It, Symbol.hasInstance, {
  value: (n) => n.minimize != null && n.computeGradients != null && n.applyGradients != null
});
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class qh extends It {
  /** @nocollapse */
  static get className() {
    return "Adadelta";
  }
  constructor(e, t, s = null) {
    super(), this.learningRate = e, this.rho = t, this.epsilon = s, this.accumulatedGrads = [], this.accumulatedUpdates = [], s == null && (this.epsilon = D.backend.epsilon());
  }
  applyGradients(e) {
    (Array.isArray(e) ? e.map((s) => s.name) : Object.keys(e)).forEach((s, o) => {
      const r = D.registeredVariables[s], i = !1;
      this.accumulatedGrads[o] == null && (this.accumulatedGrads[o] = {
        originalName: `${s}/accum_grad`,
        variable: H(() => Ge(r).variable(i))
      }), this.accumulatedUpdates[o] == null && (this.accumulatedUpdates[o] = {
        originalName: `${s}/accum_var`,
        variable: H(() => Ge(r).variable(i))
      });
      const a = Array.isArray(e) ? e[o].tensor : e[s];
      if (a == null)
        return;
      const c = this.accumulatedGrads[o].variable, l = this.accumulatedUpdates[o].variable;
      H(() => {
        const u = M(P(c, this.rho), P(ft(a), 1 - this.rho)), d = P(We(Wt(M(l, this.epsilon)), Wt(M(c, this.epsilon))), a), h = M(P(l, this.rho), P(ft(d), 1 - this.rho));
        c.assign(u), l.assign(h);
        const f = M(P(d, -this.learningRate), r);
        r.assign(f);
      });
    }), this.incrementIterations();
  }
  dispose() {
    this.accumulatedUpdates != null && (Ce(this.accumulatedGrads.map((e) => e.variable)), Ce(this.accumulatedUpdates.map((e) => e.variable)));
  }
  async getWeights() {
    const e = [...this.accumulatedGrads, ...this.accumulatedUpdates];
    return [await this.saveIterations()].concat(e.map((t) => ({ name: t.originalName, tensor: t.variable })));
  }
  async setWeights(e) {
    e = await this.extractIterations(e);
    const t = e.length / 2, s = !1;
    this.accumulatedGrads = e.slice(0, t).map((o) => ({
      originalName: o.name,
      variable: o.tensor.variable(s)
    })), this.accumulatedUpdates = e.slice(t, t * 2).map((o) => ({
      originalName: o.name,
      variable: o.tensor.variable(s)
    }));
  }
  getConfig() {
    return {
      learningRate: this.learningRate,
      rho: this.rho,
      epsilon: this.epsilon
    };
  }
  /** @nocollapse */
  static fromConfig(e, t) {
    return new e(t.learningRate, t.rho, t.epsilon);
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class jh extends It {
  /** @nocollapse */
  static get className() {
    return "Adagrad";
  }
  constructor(e, t = 0.1) {
    super(), this.learningRate = e, this.initialAccumulatorValue = t, this.accumulatedGrads = [];
  }
  applyGradients(e) {
    (Array.isArray(e) ? e.map((s) => s.name) : Object.keys(e)).forEach((s, o) => {
      const r = D.registeredVariables[s];
      this.accumulatedGrads[o] == null && (this.accumulatedGrads[o] = {
        originalName: `${s}/accumulator`,
        variable: H(() => Sh(r.shape, this.initialAccumulatorValue).variable(!1))
      });
      const i = Array.isArray(e) ? e[o].tensor : e[s];
      if (i == null)
        return;
      const a = this.accumulatedGrads[o].variable;
      H(() => {
        const c = M(a, ft(i));
        a.assign(c);
        const l = M(P(We(i, Wt(M(c, D.backend.epsilon()))), -this.learningRate), r);
        r.assign(l);
      });
    }), this.incrementIterations();
  }
  dispose() {
    this.accumulatedGrads != null && Ce(this.accumulatedGrads.map((e) => e.variable));
  }
  async getWeights() {
    return [await this.saveIterations()].concat(this.accumulatedGrads.map((e) => ({ name: e.originalName, tensor: e.variable })));
  }
  async setWeights(e) {
    e = await this.extractIterations(e);
    const t = !1;
    this.accumulatedGrads = e.map((s) => ({ originalName: s.name, variable: s.tensor.variable(t) }));
  }
  getConfig() {
    return {
      learningRate: this.learningRate,
      initialAccumulatorValue: this.initialAccumulatorValue
    };
  }
  /** @nocollapse */
  static fromConfig(e, t) {
    return new e(t.learningRate, t.initialAccumulatorValue);
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Kh extends It {
  /** @nocollapse */
  static get className() {
    return "Adam";
  }
  constructor(e, t, s, o = null) {
    super(), this.learningRate = e, this.beta1 = t, this.beta2 = s, this.epsilon = o, this.accumulatedFirstMoment = [], this.accumulatedSecondMoment = [], H(() => {
      this.accBeta1 = st(t).variable(), this.accBeta2 = st(s).variable();
    }), o == null && (this.epsilon = D.backend.epsilon());
  }
  applyGradients(e) {
    const t = Array.isArray(e) ? e.map((s) => s.name) : Object.keys(e);
    H(() => {
      const s = Bt(1, this.accBeta1), o = Bt(1, this.accBeta2);
      t.forEach((r, i) => {
        const a = D.registeredVariables[r], c = !1;
        this.accumulatedFirstMoment[i] == null && (this.accumulatedFirstMoment[i] = {
          originalName: `${r}/m`,
          variable: H(() => Ge(a).variable(c))
        }), this.accumulatedSecondMoment[i] == null && (this.accumulatedSecondMoment[i] = {
          originalName: `${r}/v`,
          variable: H(() => Ge(a).variable(c))
        });
        const l = Array.isArray(e) ? e[i].tensor : e[r];
        if (l == null)
          return;
        const u = this.accumulatedFirstMoment[i].variable, d = this.accumulatedSecondMoment[i].variable, h = M(P(u, this.beta1), P(l, 1 - this.beta1)), f = M(P(d, this.beta2), P(ft(l), 1 - this.beta2)), p = We(h, s), x = We(f, o);
        u.assign(h), d.assign(f);
        const g = M(P(We(p, M(Wt(x), this.epsilon)), -this.learningRate), a);
        a.assign(g);
      }), this.accBeta1.assign(P(this.accBeta1, this.beta1)), this.accBeta2.assign(P(this.accBeta2, this.beta2));
    }), this.incrementIterations();
  }
  dispose() {
    this.accBeta1.dispose(), this.accBeta2.dispose(), this.accumulatedFirstMoment != null && Ce(this.accumulatedFirstMoment.map((e) => e.variable)), this.accumulatedSecondMoment != null && Ce(this.accumulatedSecondMoment.map((e) => e.variable));
  }
  async getWeights() {
    const e = [...this.accumulatedFirstMoment, ...this.accumulatedSecondMoment];
    return [await this.saveIterations()].concat(e.map((t) => ({ name: t.originalName, tensor: t.variable })));
  }
  async setWeights(e) {
    e = await this.extractIterations(e), H(() => {
      this.accBeta1.assign(Lo(this.beta1, this.iterations_ + 1)), this.accBeta2.assign(Lo(this.beta2, this.iterations_ + 1));
    });
    const t = e.length / 2, s = !1;
    this.accumulatedFirstMoment = e.slice(0, t).map((o) => ({
      originalName: o.name,
      variable: o.tensor.variable(s)
    })), this.accumulatedSecondMoment = e.slice(t, t * 2).map((o) => ({
      originalName: o.name,
      variable: o.tensor.variable(s)
    }));
  }
  getConfig() {
    return {
      learningRate: this.learningRate,
      beta1: this.beta1,
      beta2: this.beta2,
      epsilon: this.epsilon
    };
  }
  /** @nocollapse */
  static fromConfig(e, t) {
    return new e(t.learningRate, t.beta1, t.beta2, t.epsilon);
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Yh extends It {
  /** @nocollapse */
  static get className() {
    return "Adamax";
  }
  constructor(e, t, s, o = null, r = 0) {
    super(), this.learningRate = e, this.beta1 = t, this.beta2 = s, this.epsilon = o, this.decay = r, this.accumulatedFirstMoment = [], this.accumulatedWeightedInfNorm = [], H(() => {
      this.iteration = st(0).variable(), this.accBeta1 = st(t).variable();
    }), o == null && (this.epsilon = D.backend.epsilon());
  }
  applyGradients(e) {
    const t = Array.isArray(e) ? e.map((s) => s.name) : Object.keys(e);
    H(() => {
      const s = Bt(1, this.accBeta1), o = We(-this.learningRate, M(P(this.iteration, this.decay), 1));
      t.forEach((r, i) => {
        const a = D.registeredVariables[r], c = !1;
        this.accumulatedFirstMoment[i] == null && (this.accumulatedFirstMoment[i] = {
          originalName: `${r}/m`,
          variable: Ge(a).variable(c)
        }), this.accumulatedWeightedInfNorm[i] == null && (this.accumulatedWeightedInfNorm[i] = {
          originalName: `${r}/v`,
          variable: Ge(a).variable(c)
        });
        const l = Array.isArray(e) ? e[i].tensor : e[r];
        if (l == null)
          return;
        const u = this.accumulatedFirstMoment[i].variable, d = this.accumulatedWeightedInfNorm[i].variable, h = M(P(u, this.beta1), P(l, 1 - this.beta1)), f = P(d, this.beta2), p = gh(l), x = Fh(f, p);
        u.assign(h), d.assign(x);
        const g = M(P(We(o, s), We(h, M(x, this.epsilon))), a);
        a.assign(g);
      }), this.iteration.assign(M(this.iteration, 1)), this.accBeta1.assign(P(this.accBeta1, this.beta1));
    }), this.incrementIterations();
  }
  dispose() {
    this.accBeta1.dispose(), this.iteration.dispose(), this.accumulatedFirstMoment != null && Ce(this.accumulatedFirstMoment.map((e) => e.variable)), this.accumulatedWeightedInfNorm != null && Ce(this.accumulatedWeightedInfNorm.map((e) => e.variable));
  }
  async getWeights() {
    throw new Error("getWeights() is not implemented for Adamax yet.");
  }
  async setWeights(e) {
    throw new Error("setWeights() is not implemented for Adamax yet.");
  }
  getConfig() {
    return {
      learningRate: this.learningRate,
      beta1: this.beta1,
      beta2: this.beta2,
      epsilon: this.epsilon,
      decay: this.decay
    };
  }
  /** @nocollapse */
  static fromConfig(e, t) {
    return new e(t.learningRate, t.beta1, t.beta2, t.epsilon, t.decay);
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Ci extends It {
  /** @nocollapse */
  static get className() {
    return "SGD";
  }
  constructor(e) {
    super(), this.learningRate = e, this.setLearningRate(e);
  }
  applyGradients(e) {
    (Array.isArray(e) ? e.map((s) => s.name) : Object.keys(e)).forEach((s, o) => {
      const r = Array.isArray(e) ? e[o].tensor : e[s];
      if (r == null)
        return;
      const i = D.registeredVariables[s];
      H(() => {
        const a = M(P(this.c, r), i);
        i.assign(a);
      });
    }), this.incrementIterations();
  }
  /**
   * Sets the learning rate of the optimizer.
   */
  setLearningRate(e) {
    this.learningRate = e, this.c != null && this.c.dispose(), this.c = ch(st(-e));
  }
  dispose() {
    this.c.dispose();
  }
  async getWeights() {
    return [await this.saveIterations()];
  }
  async setWeights(e) {
    if (e = await this.extractIterations(e), e.length !== 0)
      throw new Error("SGD optimizer does not have settable weights.");
  }
  getConfig() {
    return { learningRate: this.learningRate };
  }
  /** @nocollapse */
  static fromConfig(e, t) {
    return new e(t.learningRate);
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Qh extends Ci {
  /** @nocollapse */
  // Name matters for Python compatibility.
  static get className() {
    return "Momentum";
  }
  constructor(e, t, s = !1) {
    super(e), this.learningRate = e, this.momentum = t, this.useNesterov = s, this.accumulations = [], this.m = st(this.momentum);
  }
  applyGradients(e) {
    (Array.isArray(e) ? e.map((s) => s.name) : Object.keys(e)).forEach((s, o) => {
      const r = D.registeredVariables[s];
      this.accumulations[o] == null && (this.accumulations[o] = {
        originalName: `${s}/momentum`,
        variable: H(() => Ge(r).variable(!1))
      });
      const i = this.accumulations[o].variable, a = Array.isArray(e) ? e[o].tensor : e[s];
      a != null && H(() => {
        let c;
        const l = M(P(this.m, i), a);
        this.useNesterov ? c = M(P(this.c, M(a, P(l, this.m))), r) : c = M(P(this.c, l), r), i.assign(l), r.assign(c);
      });
    }), this.incrementIterations();
  }
  dispose() {
    this.m.dispose(), this.accumulations != null && Ce(this.accumulations.map((e) => e.variable));
  }
  /**
   * Sets the momentum of the optimizer.
   *
   * @param momentum
   */
  setMomentum(e) {
    this.momentum = e;
  }
  async getWeights() {
    return [await this.saveIterations()].concat(this.accumulations.map((e) => ({ name: e.originalName, tensor: e.variable })));
  }
  async setWeights(e) {
    e = await this.extractIterations(e);
    const t = !1;
    this.accumulations = e.map((s) => ({ originalName: s.name, variable: s.tensor.variable(t) }));
  }
  getConfig() {
    return {
      learningRate: this.learningRate,
      momentum: this.momentum,
      useNesterov: this.useNesterov
    };
  }
  /** @nocollapse */
  static fromConfig(e, t) {
    return new e(t.learningRate, t.momentum, t.useNesterov);
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Zh extends It {
  /** @nocollapse */
  static get className() {
    return "RMSProp";
  }
  constructor(e, t = 0.9, s = 0, o = null, r = !1) {
    if (super(), this.learningRate = e, this.decay = t, this.momentum = s, this.epsilon = o, this.accumulatedMeanSquares = [], this.accumulatedMoments = [], this.accumulatedMeanGrads = [], this.centered = r, o == null && (this.epsilon = D.backend.epsilon()), e == null)
      throw new Error("learningRate for RMSPropOptimizer must be defined.");
  }
  applyGradients(e) {
    (Array.isArray(e) ? e.map((s) => s.name) : Object.keys(e)).forEach((s, o) => {
      const r = D.registeredVariables[s], i = !1;
      this.accumulatedMeanSquares[o] == null && (this.accumulatedMeanSquares[o] = {
        originalName: `${s}/rms`,
        variable: H(() => Ge(r).variable(i))
      }), this.accumulatedMoments[o] == null && (this.accumulatedMoments[o] = {
        originalName: `${s}/momentum`,
        variable: H(() => Ge(r).variable(i))
      }), this.accumulatedMeanGrads[o] == null && this.centered && (this.accumulatedMeanGrads[o] = {
        originalName: `${s}/mg`,
        variable: H(() => Ge(r).variable(i))
      });
      const a = Array.isArray(e) ? e[o].tensor : e[s];
      if (a == null)
        return;
      const c = this.accumulatedMeanSquares[o].variable, l = this.accumulatedMoments[o].variable;
      H(() => {
        const u = M(P(c, this.decay), P(ft(a), 1 - this.decay));
        if (this.centered) {
          const d = this.accumulatedMeanGrads[o].variable, h = M(P(d, this.decay), P(a, 1 - this.decay)), f = We(P(a, this.learningRate), Wt(Bt(u, M(ft(h), this.epsilon)))), p = M(P(l, this.momentum), f);
          c.assign(u), d.assign(h), l.assign(p);
          const x = Bt(r, p);
          r.assign(x);
        } else {
          const d = M(P(c, this.decay), P(ft(a), 1 - this.decay)), h = M(P(l, this.momentum), We(P(a, this.learningRate), Wt(M(d, this.epsilon))));
          c.assign(d), l.assign(h);
          const f = Bt(r, h);
          r.assign(f);
        }
      });
    }), this.incrementIterations();
  }
  dispose() {
    this.accumulatedMeanSquares != null && Ce(this.accumulatedMeanSquares.map((e) => e.variable)), this.accumulatedMeanGrads != null && this.centered && Ce(this.accumulatedMeanGrads.map((e) => e.variable)), this.accumulatedMoments != null && Ce(this.accumulatedMoments.map((e) => e.variable));
  }
  async getWeights() {
    const e = [...this.accumulatedMeanSquares, ...this.accumulatedMoments];
    return this.centered && e.push(...this.accumulatedMeanGrads), [await this.saveIterations()].concat(e.map((t) => ({ name: t.originalName, tensor: t.variable })));
  }
  async setWeights(e) {
    e = await this.extractIterations(e);
    const t = this.centered ? e.length / 3 : e.length / 2, s = !1;
    this.accumulatedMeanSquares = e.slice(0, t).map((o) => ({
      originalName: o.name,
      variable: o.tensor.variable(s)
    })), this.accumulatedMoments = e.slice(t, t * 2).map((o) => ({
      originalName: o.name,
      variable: o.tensor.variable(s)
    })), this.centered && (this.accumulatedMeanGrads = e.slice(t * 2, t * 3).map((o) => ({
      originalName: o.name,
      variable: o.tensor.variable(s)
    })));
  }
  getConfig() {
    return {
      learningRate: this.learningRate,
      decay: this.decay,
      momentum: this.momentum,
      epsilon: this.epsilon,
      centered: this.centered
    };
  }
  /** @nocollapse */
  static fromConfig(e, t) {
    return new e(t.learningRate, t.decay, t.momentum, t.epsilon, t.centered);
  }
}
/**
 * @license
 * Copyright 2022 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Jh = [
  qh,
  jh,
  Kh,
  Yh,
  Qh,
  Zh,
  Ci
];
function ef() {
  for (const n of Jh)
    Xh(n);
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const tf = "model", nf = ".json", sf = ".weights.bin";
function Mo(n) {
  return new Promise((e) => setTimeout(e)).then(n);
}
class Ct {
  constructor(e) {
    if (!y().getBool("IS_BROWSER"))
      throw new Error("browserDownloads() cannot proceed because the current environment is not a browser.");
    e.startsWith(Ct.URL_SCHEME) && (e = e.slice(Ct.URL_SCHEME.length)), (e == null || e.length === 0) && (e = tf), this.modelJsonFileName = e + nf, this.weightDataFileName = e + sf;
  }
  async save(e) {
    if (typeof document > "u")
      throw new Error("Browser downloads are not supported in this environment since `document` is not present");
    const t = St.join(e.weightData), s = window.URL.createObjectURL(new Blob([t], { type: "application/octet-stream" }));
    if (e.modelTopology instanceof ArrayBuffer)
      throw new Error("BrowserDownloads.save() does not support saving model topology in binary formats yet.");
    {
      const o = [{
        paths: ["./" + this.weightDataFileName],
        weights: e.weightSpecs
      }], r = ai(e, o), i = window.URL.createObjectURL(new Blob([JSON.stringify(r)], { type: "application/json" })), a = this.modelJsonAnchor == null ? document.createElement("a") : this.modelJsonAnchor;
      if (a.download = this.modelJsonFileName, a.href = i, await Mo(() => a.dispatchEvent(new MouseEvent("click"))), e.weightData != null) {
        const c = this.weightDataAnchor == null ? document.createElement("a") : this.weightDataAnchor;
        c.download = this.weightDataFileName, c.href = s, await Mo(() => c.dispatchEvent(new MouseEvent("click")));
      }
      return { modelArtifactsInfo: Zn(e) };
    }
  }
}
Ct.URL_SCHEME = "downloads://";
const of = (n) => y().getBool("IS_BROWSER") && !Array.isArray(n) && n.startsWith(Ct.URL_SCHEME) ? rf(n.slice(Ct.URL_SCHEME.length)) : null;
K.registerSaveRouter(of);
function rf(n = "model") {
  return new Ct(n);
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Vo(n, e, t, s) {
  i(n), t = t ?? 0, s = s ?? 1, a(t, s);
  let o = 0;
  const r = (c) => (c.then((l) => {
    const u = t + ++o / n.length * (s - t);
    return e(u), l;
  }), c);
  function i(c) {
    N(c != null && Array.isArray(c) && c.length > 0, () => "promises must be a none empty array");
  }
  function a(c, l) {
    N(c >= 0 && c <= 1, () => `Progress fraction must be in range [0, 1], but got startFraction ${c}`), N(l >= 0 && l <= 1, () => `Progress fraction must be in range [0, 1], but got endFraction ${l}`), N(l >= c, () => `startFraction must be no more than endFraction, but got startFraction ${c} and endFraction ${l}`);
  }
  return Promise.all(n.map(r));
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
async function af(n, e) {
  e == null && (e = {});
  const t = e.fetchFunc == null ? y().platform.fetch : e.fetchFunc, s = n.map((d) => t(d, e.requestInit, { isBinary: !0 })), a = (e.onProgress == null ? await Promise.all(s) : await Vo(s, e.onProgress, 0, 0.5)).map((d) => d.arrayBuffer());
  return e.onProgress == null ? await Promise.all(a) : await Vo(a, e.onProgress, 0.5, 1);
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const cf = "application/octet-stream", lf = "application/json";
class so {
  constructor(e, t) {
    if (this.DEFAULT_METHOD = "POST", t == null && (t = {}), this.weightPathPrefix = t.weightPathPrefix, this.onProgress = t.onProgress, this.weightUrlConverter = t.weightUrlConverter, t.fetchFunc != null ? (N(typeof t.fetchFunc == "function", () => "Must pass a function that matches the signature of `fetch` (see https://developer.mozilla.org/en-US/docs/Web/API/Fetch_API)"), this.fetch = t.fetchFunc) : this.fetch = y().platform.fetch, N(e != null && e.length > 0, () => "URL path for http must not be null, undefined or empty."), Array.isArray(e) && N(e.length === 2, () => `URL paths for http must have a length of 2, (actual length is ${e.length}).`), this.path = e, t.requestInit != null && t.requestInit.body != null)
      throw new Error("requestInit is expected to have no pre-existing body, but has one.");
    this.requestInit = t.requestInit || {};
  }
  async save(e) {
    if (e.modelTopology instanceof ArrayBuffer)
      throw new Error("BrowserHTTPRequest.save() does not support saving model topology in binary formats yet.");
    const t = Object.assign({ method: this.DEFAULT_METHOD }, this.requestInit);
    t.body = new FormData();
    const s = [{
      paths: ["./model.weights.bin"],
      weights: e.weightSpecs
    }], o = ai(e, s);
    if (t.body.append("model.json", new Blob([JSON.stringify(o)], { type: lf }), "model.json"), e.weightData != null) {
      const i = St.join(e.weightData);
      t.body.append("model.weights.bin", new Blob([i], { type: cf }), "model.weights.bin");
    }
    const r = await this.fetch(this.path, t);
    if (r.ok)
      return {
        modelArtifactsInfo: Zn(e),
        responses: [r]
      };
    throw new Error(`BrowserHTTPRequest.save() failed due to HTTP response status ${r.status}.`);
  }
  /**
   * Load model artifacts via HTTP request(s).
   *
   * See the documentation to `tf.io.http` for details on the saved
   * artifacts.
   *
   * @returns The loaded model artifacts (if loading succeeds).
   */
  async load() {
    const e = await this.fetch(this.path, this.requestInit);
    if (!e.ok)
      throw new Error(`Request to ${this.path} failed with status code ${e.status}. Please verify this URL points to the model JSON of the model to load.`);
    let t;
    try {
      t = await e.json();
    } catch {
      let i = `Failed to parse model JSON of response from ${this.path}.`;
      throw this.path.endsWith(".pb") ? i += " Your path contains a .pb file extension. Support for .pb models have been removed in TensorFlow.js 1.0 in favor of .json models. You can re-convert your Python TensorFlow model using the TensorFlow.js 1.0 conversion scripts or you can convert your.pb models with the 'pb2json'NPM script in the tensorflow/tfjs-converter repository." : i += " Please make sure the server is serving valid JSON for this request.", new Error(i);
    }
    const s = t.modelTopology, o = t.weightsManifest;
    if (s == null && o == null)
      throw new Error(`The JSON from HTTP path ${this.path} contains neither model topology or manifest for weights.`);
    return Wd(t, (r) => this.loadWeights(r));
  }
  async loadWeights(e) {
    const t = Array.isArray(this.path) ? this.path[1] : this.path, [s, o] = uf(t), r = this.weightPathPrefix || s, i = Gd(e), a = [], c = [];
    for (const u of e)
      for (const d of u.paths)
        this.weightUrlConverter != null ? c.push(this.weightUrlConverter(d)) : a.push(r + d + o);
    this.weightUrlConverter && a.push(...await Promise.all(c));
    const l = await af(a, {
      requestInit: this.requestInit,
      fetchFunc: this.fetch,
      onProgress: this.onProgress
    });
    return [i, l];
  }
}
so.URL_SCHEME_REGEX = /^https?:\/\//;
function uf(n) {
  const e = n.lastIndexOf("/"), t = n.lastIndexOf("?"), s = n.substring(0, e), o = t > e ? n.substring(t) : "";
  return [s + "/", o];
}
function Uo(n) {
  return n.match(so.URL_SCHEME_REGEX) != null;
}
const bi = (n, e) => {
  if (typeof fetch > "u" && (e == null || e.fetchFunc == null))
    return null;
  {
    let t = !0;
    if (Array.isArray(n) ? t = n.every((s) => Uo(s)) : t = Uo(n), t)
      return df(n, e);
  }
  return null;
};
K.registerSaveRouter(bi);
K.registerLoadRouter(bi);
function df(n, e) {
  return new so(n, e);
}
function wi(n, e) {
  const t = n.shape.length, s = e.shape.length;
  if (t < 1)
    throw new Error(`tf.gatherND() expects the input to be rank 1 or higher, but the rank was ${t}.`);
  if (s < 1)
    throw new Error(`tf.gatherND() expects the indices to be rank 1 or higher, but the rank was ${s}.`);
  if (e.dtype !== "int32")
    throw new Error(`tf.gatherND() expects the indices to be int32 type, but the dtype was ${e.dtype}.`);
  if (e.shape[s - 1] > t)
    throw new Error(`index innermost dimension length must be <= tensor rank; saw: ${e.shape[s - 1]} vs. ${t}`);
  if (T(n.shape) === 0)
    throw new Error(`Requested more than 0 entries, but input is empty. Input shape: ${n.shape}.`);
  const o = e.shape, r = o[o.length - 1];
  let i = 1;
  for (let d = 0; d < o.length - 1; ++d)
    i *= o[d];
  const a = n.shape, c = o.slice();
  c.pop();
  let l = 1;
  for (let d = r; d < t; ++d)
    l *= a[d], c.push(a[d]);
  const u = [
    ...Q(n.shape).map((d) => d / l),
    1
  ].slice(0, r);
  return [c, i, l, u];
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const _s = -2, hf = -1;
function ff(n, e, t) {
  const s = n.shape.length;
  N(s === e.length, () => `Error in slice${s}D: Length of begin ${e} must match the rank of the array (${s}).`), N(s === t.length, () => `Error in slice${s}D: Length of size ${t} must match the rank of the array (${s}).`);
  for (let o = 0; o < s; ++o)
    N(e[o] + t[o] <= n.shape[o], () => `Error in slice${s}D: begin[${o}] + size[${o}] (${e[o] + t[o]}) would overflow input.shape[${o}] (${n.shape[o]})`);
}
function pf(n, e, t) {
  const s = [];
  for (let o = 0; o < n.length; o++)
    s[o] = Math.ceil((e[o] - n[o]) / t[o]);
  return s;
}
function yi(n, e, t) {
  let s = t.length;
  for (let o = 0; o < t.length; o++)
    if (t[o] > 1) {
      s = o;
      break;
    }
  for (let o = s + 1; o < t.length; o++)
    if (e[o] > 0 || t[o] !== n[o])
      return !1;
  return !0;
}
function vi(n, e) {
  let t = n.length > 0 ? n[n.length - 1] : 1;
  for (let s = 0; s < n.length - 1; s++)
    t += n[s] * e[s];
  return t;
}
function mf(n, e, t) {
  let s;
  const o = n.shape.length;
  typeof e == "number" ? s = [e, ...new Array(o - 1).fill(0)] : e.length < o ? s = e.concat(new Array(o - e.length).fill(0)) : s = e.slice(), s.forEach((i) => {
    N(i !== -1, () => "slice() does not support negative begin indexing.");
  });
  let r;
  return t == null ? r = new Array(o).fill(-1) : typeof t == "number" ? r = [t, ...new Array(o - 1).fill(-1)] : t.length < o ? r = t.concat(new Array(o - t.length).fill(-1)) : r = t, r = r.map((i, a) => i >= 0 ? i : (N(i === -1, () => `Negative size values should be exactly -1 but got ${i} for the slice() size at index ${a}.`), n.shape[a] - s[a])), [s, r];
}
function gf(n, e, t, s, o, r, i, a, c) {
  let l;
  if (s == null ? (l = new Array(e.length), l.fill(1)) : l = s, i != null && i & i - 1)
    throw new Error("Multiple ellipses in slice is not allowed.");
  let u = !1;
  const d = {
    dims: l.length,
    numAddAxisAfterEllipsis: 0,
    begin: e.slice(),
    end: t.slice(),
    strides: l.slice(),
    beginMask: o,
    endMask: r,
    ellipsisMask: i,
    newAxisMask: a,
    shrinkAxisMask: c
  };
  for (let b = 0; b < d.dims; b++)
    u && 1 << b & a && d.numAddAxisAfterEllipsis++, 1 << b & i && (u = !0);
  u || (d.ellipsisMask |= 1 << d.dims, d.dims++);
  const h = {
    dims: n.length,
    beginMask: 0,
    endMask: 0,
    beginValid: !1,
    endValid: !1
  };
  xf(d, h);
  let f = !0, p = !0, x = !0;
  const g = [], m = [];
  for (let b = 0; b < n.length; ++b) {
    if (h.strides[b] === 0)
      throw Error(`strides[${b}] must be non-zero`);
    const w = !!(h.shrinkAxisMask & 1 << b), v = n[b];
    if (v === -1) {
      g.push(w ? 1 : -1);
      continue;
    }
    const E = [h.beginMask & 1 << b, h.endMask & 1 << b], R = [
      h.strides[b] > 0 ? 0 : -1,
      h.strides[b] > 0 ? v : v - 1
    ];
    if (w && h.strides[b] <= 0)
      throw Error("only stride 1 allowed on non-range indexing.");
    x = x && h.strides[b] === 1;
    const $ = !!(h.beginMask & 1 << b && h.endMask & 1 << b);
    if (h.beginValid && h.endValid) {
      if (w) {
        const B = h.begin[b] < 0 ? v + h.begin[b] : h.begin[b];
        if (h.begin[b] = B, h.end[b] = h.begin[b] + 1, B < 0 || B >= v)
          throw Error(`slice index ${h.begin[b]} of dimension ${b} out of bounds.`);
      } else
        h.begin[b] = Wo(h.begin[b], 0, h.strides[b], v, E, R), h.end[b] = Wo(h.end[b], 1, h.strides[b], v, E, R);
      const L = h.strides[b] === 1 && h.begin[b] === 0 && h.end[b] === v;
      f = f && L, p = p && (b === 0 && h.strides[b] === 1 || L);
    } else
      f = f && h.strides[b] === 1 && $, p = p && (b === 0 && h.strides[b] === 1 || $);
    let F, O = !1;
    if (h.beginValid && h.endValid ? (F = h.end[b] - h.begin[b], O = !0) : w ? (F = 1, O = !0) : $ && v >= 0 && (h.strides[b] < 0 ? F = -v : F = v, O = !0), O) {
      let L;
      F === 0 || F < 0 != h.strides[b] < 0 ? L = 0 : L = Math.trunc(F / h.strides[b]) + (F % h.strides[b] !== 0 ? 1 : 0), g.push(L);
    } else
      g.push(-1);
  }
  for (let b = 0; b < h.finalShapeGatherIndices.length; ++b) {
    const w = h.finalShapeGatherIndices[b];
    w >= 0 ? m.push(g[w]) : w === _s && m.push(1);
  }
  return {
    finalShapeSparse: m.filter((b, w) => h.finalShapeGatherIndices[w] !== _s),
    finalShape: m,
    isIdentity: f,
    sliceDim0: p,
    isSimpleSlice: x,
    begin: h.begin,
    end: h.end,
    strides: h.strides
  };
}
function xf(n, e) {
  e.beginMask = 0, e.endMask = 0, e.shrinkAxisMask = 0;
  let t = 0;
  e.beginValid = n.begin != null, e.endValid = n.end != null, e.begin = new Array(e.dims), e.end = new Array(e.dims), e.strides = new Array(e.dims), e.finalShapeGatherIndices = [], e.finalShapeGatherIndicesSparse = [], e.inputShapeGatherIndicesSparse = new Array(e.dims);
  for (let s = 0; s < n.dims; s++)
    if (1 << s & n.ellipsisMask) {
      const o = Math.min(e.dims - (n.dims - s) + 1 + n.numAddAxisAfterEllipsis, e.dims);
      for (; t < o; t++)
        e.begin[t] = 0, e.end[t] = 0, e.strides[t] = 1, e.beginMask |= 1 << t, e.endMask |= 1 << t, e.finalShapeGatherIndices.push(t), e.finalShapeGatherIndicesSparse.push(-1), e.inputShapeGatherIndicesSparse[t] = s;
    } else if (1 << s & n.newAxisMask)
      e.finalShapeGatherIndices.push(_s), e.finalShapeGatherIndicesSparse.push(-1);
    else {
      if (t === e.begin.length)
        throw Error(`Index out of range using input dim ${t}; input has only ${e.dims} dims, ${e.begin.length}.`);
      n.begin != null && (e.begin[t] = n.begin[s]), n.end != null && (e.end[t] = n.end[s]), e.strides[t] = n.strides[s], n.beginMask & 1 << s && (e.beginMask |= 1 << t), n.endMask & 1 << s && (e.endMask |= 1 << t), n.shrinkAxisMask & 1 << s ? (e.finalShapeGatherIndices.push(hf), e.finalShapeGatherIndicesSparse.push(-1), e.shrinkAxisMask |= 1 << t) : (e.finalShapeGatherIndices.push(t), e.finalShapeGatherIndicesSparse.push(s)), e.inputShapeGatherIndicesSparse[t] = s, t++;
    }
}
function Wo(n, e, t, s, o, r) {
  if (o[e])
    return t > 0 ? r[e] : r[e + 1 & 1];
  {
    const i = n < 0 ? s + n : n;
    return i < r[0] ? r[0] : i > r[1] ? r[1] : i;
  }
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Cf = typeof requestAnimationFrame < "u" ? requestAnimationFrame : typeof setImmediate < "u" ? setImmediate : (n) => n();
function bf() {
  return new Promise((n) => Cf(() => n()));
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function $i(n, e) {
  const t = n[0].length;
  n.forEach((o, r) => {
    N(o.length === t, () => `Error in concat${t}D: rank of tensors[${r}] must be the same as the rank of the rest (${t})`);
  }), N(e >= 0 && e < t, () => `Error in concat${t}D: axis must be between 0 and ${t - 1}.`);
  const s = n[0];
  n.forEach((o, r) => {
    for (let i = 0; i < t; i++)
      N(i === e || o[i] === s[i], () => `Error in concat${t}D: Shape of tensors[${r}] (${o}) does not match the shape of the rest (${s}) along the non-concatenated axis ${r}.`);
  });
}
function bt(n, e) {
  const t = n[0].slice();
  for (let s = 1; s < n.length; s++)
    t[e] += n[s][e];
  return t;
}
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
var Oe;
(function(n) {
  n[n.FIRST_DIM_SIZE = 0] = "FIRST_DIM_SIZE", n[n.VALUE_ROWIDS = 1] = "VALUE_ROWIDS", n[n.ROW_LENGTHS = 2] = "ROW_LENGTHS", n[n.ROW_SPLITS = 3] = "ROW_SPLITS", n[n.ROW_LIMITS = 4] = "ROW_LIMITS", n[n.ROW_STARTS = 5] = "ROW_STARTS";
})(Oe || (Oe = {}));
function Si(n, e, t) {
  let s = new Array();
  if (t == null && e == null)
    return s;
  if (e == null)
    for (; s.length < n + t.length; )
      s.push(-1);
  else
    s = e.slice();
  if (t == null)
    return s;
  if (n + t.length !== s.length)
    throw new Error(`rt input.shape and shape=${e} are incompatible: rt input.rank = ${n + t.length}, but shape.rank = ${s.length}`);
  for (let o = 1; o < t.length; ++o) {
    const r = t[o], i = s[s.length - t.length + o], a = s[i];
    if (r >= 0)
      if (a >= 0) {
        if (a !== r)
          throw new Error(`rt input.shape and shape=${e} are incompatible: rt input.shape[${o + n}] = ${r} but shape[${o + n}] = ${a}`);
      } else
        s[i] = r;
  }
  return s;
}
function Ii(n) {
  const e = {
    FIRST_DIM_SIZE: Oe.FIRST_DIM_SIZE,
    VALUE_ROWIDS: Oe.VALUE_ROWIDS,
    ROW_LENGTHS: Oe.ROW_LENGTHS,
    ROW_SPLITS: Oe.ROW_SPLITS,
    ROW_LIMITS: Oe.ROW_LIMITS,
    ROW_STARTS: Oe.ROW_STARTS
  }, t = [];
  for (const s of n)
    if (s in e)
      t.push(e[s]);
    else
      break;
  return t;
}
function Ri(n) {
  return n.length === 0 ? 0 : n[0] === Oe.FIRST_DIM_SIZE ? n.length - 1 : n.length;
}
function Ti(n, e) {
  if (n == null || e == null)
    return;
  const t = n.length, s = e.length;
  if (t >= s)
    throw new Error(`defaultValue.shape=${n} and ragged tensor flatValues.shape=${e}, are incompatible: defaultValue.rank = ${t} must be less than ragged tensor input flatValues.rank = ${s})`);
  for (let o = 0; o < Math.min(t, s - 1); ++o) {
    const r = n[o], i = e[o + 1];
    if (r >= 0 && i >= 0 && r !== 1 && r !== i)
      throw new Error(`defaultValue.shape=${n}, and ragged tensor input flatValues.shape=${e} are incompatible: defaultValue.shape[${o - n.length}] = ${r} but ragged tensor input.flatValues.shape[${o - n.length}] = ${i}`);
  }
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const oo = 30;
function es(n) {
  return n <= oo ? n : ys(n, Math.floor(Math.sqrt(n)));
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ei(n, e, t) {
  const s = t * (typeof n == "number" ? n : n[0]), o = e * (typeof n == "number" ? n : n[1]);
  return [s, o];
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ro(n, e, t, s = !0) {
  let o = [];
  if (s)
    o = o.concat(e.slice(0)), o.push(n[0] / t), o = o.concat(n.slice(1));
  else {
    o = o.concat(n[0]);
    const r = e.length;
    for (let i = 0; i < r; ++i)
      o = o.concat([n[i + 1] / e[i], e[i]]);
    o = o.concat(n.slice(r + 1));
  }
  return o;
}
function io(n, e, t = !0) {
  const s = [];
  if (t) {
    s.push(e);
    for (let o = e + 1; o < n; ++o)
      o <= 2 * e ? (s.push(o), s.push(o - (e + 1))) : s.push(o);
  } else {
    const o = [], r = [];
    for (let i = 1; i < n; ++i)
      i >= e * 2 + 1 || i % 2 === 1 ? r.push(i) : o.push(i);
    s.push(...o), s.push(0), s.push(...r);
  }
  return s;
}
function ao(n, e, t, s = !0) {
  const o = [];
  s ? o.push(n[0] / t) : o.push(n[0] * t);
  for (let r = 1; r < n.length; ++r)
    r <= e.length ? s ? o.push(e[r - 1] * n[r]) : o.push(n[r] / e[r - 1]) : o.push(n[r]);
  return o;
}
function Ni(n, e) {
  const t = [0];
  for (let s = 0; s < e; ++s)
    t.push(n[s][0]);
  return t;
}
function ki(n, e, t) {
  const s = n.slice(0, 1);
  for (let o = 0; o < t; ++o)
    s.push(n[o + 1] - e[o][0] - e[o][1]);
  return s;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ai = 1.7580993408473768, Fi = 1.0507009873554805;
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Di = 0.3275911, Oi = 0.254829592, Pi = -0.284496736, _i = 1.421413741, Li = -1.453152027, Bi = 1.061405429;
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ls(n, e) {
  if (n.length !== e.length)
    throw new Error(`Cannot merge real and imag arrays of different lengths. real:${n.length}, imag: ${e.length}.`);
  const t = new Float32Array(n.length * 2);
  for (let s = 0; s < t.length; s += 2)
    t[s] = n[s / 2], t[s + 1] = e[s / 2];
  return t;
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const hs = "->", wf = /->/g, Go = ",", zo = "...";
function Mi(n, e) {
  n = n.replace(/\s/g, "");
  const t = (n.length - n.replace(wf, "").length) / hs.length;
  if (t < 1)
    throw new Error("Equations without an arrow are not supported.");
  if (t > 1)
    throw new Error(`Equation must contain exactly one arrow ("${hs}").`);
  const [s, o] = n.split(hs);
  N(s.indexOf(zo) === -1, () => `The ellipsis notation ("${zo}") is not supported yet.`);
  const r = s.split(Go), i = r.length;
  if (e !== i)
    throw new Error(`Expected ${i} input tensors, received ${e}`);
  if (i > 2)
    throw new Error("Support for more than 2 input tensors is not implemented yet.");
  const a = [];
  for (let h = 0; h < o.length; ++h) {
    const f = o[h];
    if (!r.some((p) => p.indexOf(f) !== -1))
      throw new Error(`Output subscripts contain the label ${f} not present in the input subscripts.`);
    a.indexOf(f) === -1 && a.push(f);
  }
  for (let h = 0; h < s.length; ++h) {
    const f = s[h];
    a.indexOf(f) === -1 && f !== Go && a.push(f);
  }
  const c = new Array(r.length);
  for (let h = 0; h < i; ++h) {
    if (new Set(r[h].split("")).size !== r[h].length)
      throw new Error(`Found duplicate axes in input component ${r[h]}. Support for duplicate axes in input is not implemented yet.`);
    c[h] = [];
    for (let f = 0; f < r[h].length; ++f)
      c[h].push(a.indexOf(r[h][f]));
  }
  const l = a.length, u = o.length, d = [];
  for (let h = u; h < l; ++h)
    d.push(h);
  return { allDims: a, summedDims: d, idDims: c };
}
function Vi(n, e) {
  let t = new Array(n);
  t.fill(-1);
  for (let o = 0; o < e.length; ++o)
    t[e[o]] = o;
  const s = [];
  for (let o = 0; o < n; ++o)
    t[o] === -1 && s.push(o);
  return t = t.filter((o) => o !== -1), { permutationIndices: t, expandDims: s };
}
function Ui(n, e, t) {
  const s = new Array(n);
  for (let o = 0; o < t.length; ++o) {
    const r = t[o].shape;
    for (let i = 0; i < e[o].length; ++i)
      s[e[o][i]] === void 0 ? s[e[o][i]] = r[i] : N(s[e[o][i]] === r[i], () => `Expected dimension ${s[e[o][i]]} at axis ${i} of input shaped ${JSON.stringify(r)}, but got dimension ${r[i]}`);
  }
}
function Wi(n, e) {
  const t = n, s = [];
  let o = 0;
  n.length === 0 && t.push(-1), o = n.length + 1;
  for (let i = 0; i < o; ++i)
    s.push([]);
  const r = [];
  for (let i = 0; i < t.length; ++i) {
    const a = t[i], c = yf(e, a);
    for (const l of c)
      r.indexOf(l) === -1 && (s[i].push(l), r.push(l));
  }
  return { path: t, steps: s };
}
function Gi(n) {
  return n.every((e, t) => e === t);
}
function yf(n, e) {
  const t = [];
  for (let s = 0; s < n.length; ++s)
    (n[s].length === 0 || n[s].indexOf(e) !== -1 || e === -1) && t.push(s);
  return t;
}
function zi(n, e, t = 0) {
  let s = [];
  if (typeof e == "number")
    N(n.shape[t] % e === 0, () => "Number of splits must evenly divide the axis."), s = new Array(e).fill(n.shape[t] / e);
  else {
    const o = e.reduce((i, a) => (a === -1 && (i += 1), i), 0);
    N(o <= 1, () => "There should be only one negative value in split array.");
    const r = e.indexOf(-1);
    if (r !== -1) {
      const i = e.reduce((a, c) => c > 0 ? a + c : a);
      e[r] = n.shape[t] - i;
    }
    N(n.shape[t] === e.reduce((i, a) => i + a), () => "The sum of sizes must match the size of the axis dimension."), s = e;
  }
  return s;
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Hi(n) {
  return `Received SparseTensor with denseShape[0] = 0 but
  indices.shape[0] = ${n}`;
}
function Xi(n, e) {
  return `indices(${n}, 0) is invalid: ${e} < 0`;
}
function qi(n, e, t) {
  return `indices(${n}, 0) is invalid: ${e} >= ${t}`;
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ji(n, e) {
  return `only one output dimension may be -1, not both ${n} and ${e}`;
}
function Ki(n, e) {
  return `size ${n} must be non-negative, not ${e}`;
}
function Yi() {
  return "reshape cannot infer the missing input size for an empty tensor unless all specified input sizes are non-zero";
}
function Qi(n, e) {
  const t = T(n), s = T(e);
  return `Input to reshape is a SparseTensor with ${t}
  dense values, but the requested shape requires a multiple of ${s}. inputShape=${n} outputShape= ${e}`;
}
function Zi(n, e) {
  const t = T(n), s = T(e);
  return `Input to reshape is a tensor with ${t} dense values, but the requested shape has ${s}. inputShape=${n} outputShape=${e}`;
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Bs() {
  return "segment ids must be >= 0";
}
function Ji() {
  return "segment ids are not increasing";
}
function ea(n, e) {
  return `Segment id ${n} out of range [0, ${e}), possibly because segmentIds input is not sorted.`;
}
function ta(n, e, t) {
  return `Bad: indices[${n}] == ${e} out of range [0, ${t})`;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function vf(n, e) {
  let t = !1, s;
  for (n <= oo ? (s = n, t = !0) : s = ys(n, Math.floor(Math.sqrt(n))); !t; )
    s > e || s === n ? t = !0 : s = ys(n, s + 1);
  return s;
}
function $f(n, e, t) {
  const s = [], o = n.length;
  for (let r = 0; r < o; r++)
    r !== e ? s.push(n[r]) : s.push(t);
  return s;
}
function Sf(n, e, t, s) {
  const o = e.shape.length, r = n.shape.length;
  if (s !== 0 && (s < -o || s > o))
    throw new Error(`Expect batchDims in the range of [-${o}, ${o}], but got ${s}`);
  if (s < 0 && (s += o), s > r)
    throw new Error(`batchDims (${s}) must be less than rank(x) (
    ${r}).`);
  if (t < s)
    throw new Error(`batchDims (${s}) must be less than or equal to axis (${t}).`);
  for (let d = 0; d < s; ++d)
    if (n.shape[d] !== e.shape[d])
      throw new Error(`x.shape[${d}]: ${n.shape[d]} should be equal to indices.shape[${d}]: ${e.shape[d]}.`);
  const i = n.shape[t], a = [];
  let c = 1, l = 1, u = 1;
  for (let d = 0; d < s; ++d)
    a.push(n.shape[d]), c *= n.shape[d];
  for (let d = s; d < t; d++)
    a.push(n.shape[d]), l *= n.shape[d];
  for (let d = s; d < o; d++)
    a.push(e.shape[d]);
  for (let d = t + 1; d < r; d++)
    a.push(n.shape[d]), u *= n.shape[d];
  return { batchSize: c, sliceSize: u, outerSize: l, dimSize: i, outputShape: a };
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Gt(n) {
  try {
    return n.map((e) => Vt(e));
  } catch (e) {
    throw new Error(`Failed to decode encoded string bytes into utf-8, error: ${e}`);
  }
}
function na(n) {
  return n.map((e) => ht(e));
}
const If = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  ERF_A1: Oi,
  ERF_A2: Pi,
  ERF_A3: _i,
  ERF_A4: Li,
  ERF_A5: Bi,
  ERF_P: Di,
  PARALLELIZE_THRESHOLD: oo,
  get RowPartitionType() {
    return Oe;
  },
  SELU_SCALE: Fi,
  SELU_SCALEALPHA: Ai,
  assertAndGetBroadcastShape: ie,
  assertAxesAreInnerMostDims: Me,
  assertParamsConsistent: $i,
  axesAreInnerMostDims: eo,
  calculateShapes: Jn,
  checkEinsumDimSizes: Ui,
  combineLocations: xi,
  combineRaggedTensorToTensorShapes: Si,
  computeConv2DInfo: Be,
  computeConv3DInfo: bn,
  computeDefaultPad: Js,
  computeDilation2DInfo: mi,
  computeOptimalWindowSize: es,
  computeOutAndReduceShapes: He,
  computeOutShape: bt,
  computePool2DInfo: qt,
  computePool3DInfo: Cn,
  convertConv2DDataFormat: Kt,
  decodeEinsumEquation: Mi,
  eitherStridesOrDilationsAreOne: jt,
  expandShapeToKeepDim: qe,
  fromStringArrayToUint8: na,
  fromUint8ToStringArray: Gt,
  getAxesPermutation: Ee,
  getBroadcastDims: Gn,
  getEinsumComputePath: Wi,
  getEinsumPermutation: Vi,
  getImageCenter: Ei,
  getInnerMostAxes: Ne,
  getPermuted: io,
  getRaggedRank: Ri,
  getReshaped: ro,
  getReshapedPermuted: ao,
  getRowPartitionTypesHelper: Ii,
  getSliceBeginCoords: Ni,
  getSliceSize: ki,
  getSparseFillEmptyRowsIndicesDenseShapeMismatch: Hi,
  getSparseFillEmptyRowsNegativeIndexErrorMessage: Xi,
  getSparseFillEmptyRowsOutOfRangeIndexErrorMessage: qi,
  getSparseReshapeEmptyTensorZeroOutputDimErrorMessage: Yi,
  getSparseReshapeInputOutputMismatchErrorMessage: Zi,
  getSparseReshapeInputOutputMultipleErrorMessage: Qi,
  getSparseReshapeMultipleNegativeOneOutputDimErrorMessage: ji,
  getSparseReshapeNegativeOutputDimErrorMessage: Ki,
  getSparseSegmentReductionIndicesOutOfRangeErrorMessage: ta,
  getSparseSegmentReductionNegativeSegmentIdsErrorMessage: Bs,
  getSparseSegmentReductionNonIncreasingSegmentIdsErrorMessage: Ji,
  getSparseSegmentReductionSegmentIdOutOfRangeErrorMessage: ea,
  getUndoAxesPermutation: to,
  isIdentityPermutation: Gi,
  mergeRealAndImagArrays: Ls,
  prepareAndValidate: wi,
  prepareSplitSize: zi,
  tupleValuesAreOne: Os,
  upcastType: ze,
  validateDefaultValueShape: Ti,
  warn: Pe
}, Symbol.toStringTag, { value: "Module" }));
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
ef();
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const lt = {}, Tn = {
  alpha: !1,
  antialias: !1,
  premultipliedAlpha: !1,
  preserveDrawingBuffer: !1,
  depth: !1,
  stencil: !1,
  failIfMajorPerformanceCaveat: !0
};
function Rf(n, e) {
  lt[n] = e;
}
function _e(n, e) {
  if (!(n in lt) || e != null) {
    const s = Ef(n, e);
    if (s !== null)
      lt[n] = s;
    else
      return console.log("Could not get context for WebGL version", n), null;
  }
  const t = lt[n];
  return t == null || t.isContextLost() ? (delete lt[n], _e(n)) : (t.disable(t.DEPTH_TEST), t.disable(t.STENCIL_TEST), t.disable(t.BLEND), t.disable(t.DITHER), t.disable(t.POLYGON_OFFSET_FILL), t.disable(t.SAMPLE_COVERAGE), t.enable(t.SCISSOR_TEST), t.enable(t.CULL_FACE), t.cullFace(t.BACK), lt[n]);
}
function Tf(n) {
  if (!y().getBool("IS_SAFARI") && typeof OffscreenCanvas < "u" && n === 2)
    return new OffscreenCanvas(300, 150);
  if (typeof document < "u")
    return document.createElement("canvas");
  throw new Error("Cannot create a canvas in this context");
}
function Ef(n, e) {
  if (n !== 1 && n !== 2)
    throw new Error("Cannot get WebGL rendering context, WebGL is disabled.");
  const t = e ?? Tf(n);
  return t.addEventListener("webglcontextlost", (s) => {
    s.preventDefault(), delete lt[n];
  }, !1), y().getBool("SOFTWARE_WEBGL_ENABLED") && (Tn.failIfMajorPerformanceCaveat = !1), n === 1 ? t.getContext("webgl", Tn) || t.getContext("experimental-webgl", Tn) : t.getContext("webgl2", Tn);
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
var hn;
(function(n) {
  n[n.DENSE = 0] = "DENSE", n[n.SHARED_BATCH = 1] = "SHARED_BATCH";
})(hn || (hn = {}));
var xe;
(function(n) {
  n[n.RENDER = 0] = "RENDER", n[n.UPLOAD = 1] = "UPLOAD", n[n.PIXELS = 2] = "PIXELS", n[n.DOWNLOAD = 3] = "DOWNLOAD";
})(xe || (xe = {}));
var Y;
(function(n) {
  n[n.UNPACKED_FLOAT16 = 0] = "UNPACKED_FLOAT16", n[n.UNPACKED_FLOAT32 = 1] = "UNPACKED_FLOAT32", n[n.PACKED_4X1_UNSIGNED_BYTE = 2] = "PACKED_4X1_UNSIGNED_BYTE", n[n.PACKED_2X2_FLOAT32 = 3] = "PACKED_2X2_FLOAT32", n[n.PACKED_2X2_FLOAT16 = 4] = "PACKED_2X2_FLOAT16";
})(Y || (Y = {}));
function wn(n, e) {
  return [e, n];
}
function Nf(n, e) {
  return n * e;
}
function En(n) {
  const e = T(n), t = Math.ceil(e / 4);
  return bs(t);
}
function Yt(n, e) {
  return [
    Math.max(1, Math.ceil(e / 2)),
    Math.max(1, Math.ceil(n / 2))
  ];
}
function kf(n, e) {
  const [t, s] = Yt(n, e);
  return t * s * 4;
}
function co(n, e) {
  const t = n;
  let s, o, r, i, a, c, l, u, d, h;
  return y().getNumber("WEBGL_VERSION") === 2 ? (s = t.R32F, o = t.R16F, r = t.RGBA16F, i = t.RGBA32F, a = t.RED, l = 4, u = 1, d = t.HALF_FLOAT, h = t.FLOAT, c = t.RGBA8) : (s = n.RGBA, o = n.RGBA, r = n.RGBA, i = t.RGBA, a = n.RGBA, l = 4, u = 4, d = e != null ? e.HALF_FLOAT_OES : null, h = n.FLOAT, c = n.RGBA), {
    internalFormatFloat: s,
    internalFormatHalfFloat: o,
    internalFormatPackedHalfFloat: r,
    internalFormatPackedFloat: i,
    textureFormatFloat: a,
    downloadTextureFormat: c,
    downloadUnpackNumChannels: l,
    defaultNumChannels: u,
    textureTypeHalfFloat: d,
    textureTypeFloat: h
  };
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function k(n, e) {
  const t = e();
  return y().getBool("DEBUG") && Af(n), t;
}
function Af(n) {
  const e = n.getError();
  if (e !== n.NO_ERROR)
    throw new Error("WebGL Error: " + Pf(n, e));
}
const Ff = 596e-10, Df = 65504;
function Of(n) {
  return !!(y().getBool("WEBGL_RENDER_FLOAT32_ENABLED") || n === 0 || Ff < Math.abs(n) && Math.abs(n) < Df);
}
function Pf(n, e) {
  switch (e) {
    case n.NO_ERROR:
      return "NO_ERROR";
    case n.INVALID_ENUM:
      return "INVALID_ENUM";
    case n.INVALID_VALUE:
      return "INVALID_VALUE";
    case n.INVALID_OPERATION:
      return "INVALID_OPERATION";
    case n.INVALID_FRAMEBUFFER_OPERATION:
      return "INVALID_FRAMEBUFFER_OPERATION";
    case n.OUT_OF_MEMORY:
      return "OUT_OF_MEMORY";
    case n.CONTEXT_LOST_WEBGL:
      return "CONTEXT_LOST_WEBGL";
    default:
      return `Unknown error code ${e}`;
  }
}
function Nn(n, e) {
  return je(n, () => n.getExtension(e), 'Extension "' + e + '" not supported on this browser.');
}
function _f(n, e) {
  const t = je(n, () => n.createShader(n.VERTEX_SHADER), "Unable to create vertex WebGLShader.");
  if (k(n, () => n.shaderSource(t, e)), k(n, () => n.compileShader(t)), n.getShaderParameter(t, n.COMPILE_STATUS) === !1)
    throw console.log(n.getShaderInfoLog(t)), new Error("Failed to compile vertex shader.");
  return t;
}
function Lf(n, e) {
  const t = je(n, () => n.createShader(n.FRAGMENT_SHADER), "Unable to create fragment WebGLShader.");
  if (k(n, () => n.shaderSource(t, e)), k(n, () => n.compileShader(t)), y().get("ENGINE_COMPILE_ONLY"))
    return t;
  if (n.getShaderParameter(t, n.COMPILE_STATUS) === !1)
    throw sa(e, n.getShaderInfoLog(t)), new Error("Failed to compile fragment shader.");
  return t;
}
const Bf = /ERROR: [0-9]+:([0-9]+):/g;
function sa(n, e) {
  const t = Bf.exec(e);
  if (t == null) {
    console.log(`Couldn't parse line number in error: ${e}`), console.log(n);
    return;
  }
  const s = +t[1], o = n.split(`
`), r = o.length.toString().length + 2, i = o.map((d, h) => _t((h + 1).toString(), r) + d);
  let a = 0;
  for (let d = 0; d < i.length; d++)
    a = Math.max(i[d].length, a);
  const c = i.slice(0, s - 1), l = i.slice(s - 1, s), u = i.slice(s);
  console.log(c.join(`
`)), console.log(e.split(`
`)[0]), console.log(`%c ${_t(l[0], a)}`, "border:1px solid red; background-color:#e3d2d2; color:#a61717"), console.log(u.join(`
`));
}
function Mf(n) {
  return je(n, () => n.createProgram(), "Unable to create WebGLProgram.");
}
function Vf(n, e) {
  if (k(n, () => n.linkProgram(e)), !y().get("ENGINE_COMPILE_ONLY") && n.getProgramParameter(e, n.LINK_STATUS) === !1)
    throw console.log(n.getProgramInfoLog(e)), new Error("Failed to link vertex and fragment shaders.");
}
function fs(n, e) {
  if (k(n, () => n.validateProgram(e)), n.getProgramParameter(e, n.VALIDATE_STATUS) === !1)
    throw console.log(n.getProgramInfoLog(e)), new Error("Shader program validation failed.");
}
function Uf(n, e) {
  const t = je(n, () => n.createBuffer(), "Unable to create WebGLBuffer");
  return k(n, () => n.bindBuffer(n.ARRAY_BUFFER, t)), k(n, () => n.bufferData(n.ARRAY_BUFFER, e, n.STATIC_DRAW)), t;
}
function Wf(n, e) {
  const t = je(n, () => n.createBuffer(), "Unable to create WebGLBuffer");
  return k(n, () => n.bindBuffer(n.ELEMENT_ARRAY_BUFFER, t)), k(n, () => n.bufferData(n.ELEMENT_ARRAY_BUFFER, e, n.STATIC_DRAW)), t;
}
function Gf(n) {
  return je(n, () => n.createTexture(), "Unable to create WebGLTexture.");
}
function zf(n, e) {
  const t = y().getNumber("WEBGL_MAX_TEXTURE_SIZE");
  if (n <= 0 || e <= 0) {
    const s = `[${n}x${e}]`;
    throw new Error("Requested texture size " + s + " is invalid.");
  }
  if (n > t || e > t) {
    const s = `[${n}x${e}]`, o = `[${t}x${t}]`;
    throw new Error("Requested texture size " + s + " greater than WebGL maximum on this browser / GPU " + o + ".");
  }
}
function Hf(n) {
  return je(n, () => n.createFramebuffer(), "Unable to create WebGLFramebuffer.");
}
function Ho(n, e, t, s, o, r, i) {
  const a = n.getAttribLocation(e, t);
  return a === -1 ? !1 : (k(n, () => n.bindBuffer(n.ARRAY_BUFFER, s)), k(n, () => n.vertexAttribPointer(a, o, n.FLOAT, !1, r, i)), k(n, () => n.enableVertexAttribArray(a)), !0);
}
function Xf(n, e, t) {
  Qf(n, t), k(n, () => n.activeTexture(n.TEXTURE0 + t)), k(n, () => n.bindTexture(n.TEXTURE_2D, e));
}
function qf(n, e, t) {
  return je(n, () => n.getUniformLocation(e, t), 'uniform "' + t + '" not present in program.');
}
function jf(n, e, t) {
  return n.getUniformLocation(e, t);
}
function Kf(n, e, t, s) {
  k(n, () => Xf(n, e, s)), k(n, () => n.uniform1i(t, s));
}
function ps(n, e, t) {
  k(n, () => n.bindFramebuffer(n.FRAMEBUFFER, t)), k(n, () => n.framebufferTexture2D(n.FRAMEBUFFER, n.COLOR_ATTACHMENT0, n.TEXTURE_2D, e, 0));
}
function Xo(n, e) {
  k(n, () => n.bindFramebuffer(n.FRAMEBUFFER, e)), k(n, () => n.framebufferTexture2D(n.FRAMEBUFFER, n.COLOR_ATTACHMENT0, n.TEXTURE_2D, null, 0));
}
function kn(n) {
  const e = n.checkFramebufferStatus(n.FRAMEBUFFER);
  if (e !== n.FRAMEBUFFER_COMPLETE)
    throw new Error("Error binding framebuffer: " + Yf(n, e));
}
function Yf(n, e) {
  switch (e) {
    case n.FRAMEBUFFER_INCOMPLETE_ATTACHMENT:
      return "FRAMEBUFFER_INCOMPLETE_ATTACHMENT";
    case n.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT:
      return "FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT";
    case n.FRAMEBUFFER_INCOMPLETE_DIMENSIONS:
      return "FRAMEBUFFER_INCOMPLETE_DIMENSIONS";
    case n.FRAMEBUFFER_UNSUPPORTED:
      return "FRAMEBUFFER_UNSUPPORTED";
    default:
      return `unknown error ${e}`;
  }
}
function je(n, e, t) {
  const s = k(n, () => e());
  if (s == null)
    throw new Error(t);
  return s;
}
function Qf(n, e) {
  const t = n.MAX_COMBINED_TEXTURE_IMAGE_UNITS - 1, s = e + n.TEXTURE0;
  if (s < n.TEXTURE0 || s > t) {
    const o = `[gl.TEXTURE0, gl.TEXTURE${t}]`;
    throw new Error(`textureUnit must be in ${o}.`);
  }
}
function zt(n, e = 2) {
  return T(n.slice(0, n.length - e));
}
function Ht(n) {
  if (n.length === 0)
    throw Error("Cannot get rows and columns of an empty shape array.");
  return [
    n.length > 1 ? n[n.length - 2] : 1,
    n[n.length - 1]
  ];
}
function An(n) {
  let e = [1, 1, 1];
  return n.length === 0 || n.length === 1 && n[0] === 1 || (e = [zt(n), ...Ht(n)]), e;
}
function Zf(n, e = !1) {
  let t = y().getNumber("WEBGL_MAX_TEXTURE_SIZE"), s = y().getNumber("WEBGL_MAX_SIZE_FOR_NARROW_TEXTURE");
  s === 1 / 0 && y().getBool("WEBGL_AUTO_SQUARIFY_NARROW_TEXTURE_SHAPE") && (s = t / 2), e && (t = t * 2, s = s * 2, n = n.map((a, c) => c >= n.length - 2 ? Gs(n[c]) : n[c]), n.length === 1 && (n = [2, n[0]])), n.length !== 2 && (n = yt(n).newShape);
  let o = T(n), r = null;
  n.length <= 1 && o <= t ? r = [1, o] : n.length === 2 && n[0] <= t && n[1] <= t ? r = n : n.length === 3 && n[0] * n[1] <= t && n[2] <= t ? r = [n[0] * n[1], n[2]] : n.length === 3 && n[0] <= t && n[1] * n[2] <= t ? r = [n[0], n[1] * n[2]] : n.length === 4 && n[0] * n[1] * n[2] <= t && n[3] <= t ? r = [n[0] * n[1] * n[2], n[3]] : n.length === 4 && n[0] <= t && n[1] * n[2] * n[3] <= t && (r = [n[0], n[1] * n[2] * n[3]]);
  const i = r != null && Math.max(...r) > s && Math.min(...r) <= (e ? 2 : 1) && Math.min(...r) > 0;
  if (r == null || i)
    if (e) {
      const a = zt(n);
      let c = 2, l = 2;
      n.length && ([c, l] = Ht(n)), o = a * (c / 2) * (l / 2), r = bs(o).map((u) => u * 2);
    } else
      r = bs(o);
  return r;
}
function Fn(n) {
  return n % 2 === 0;
}
function zn(n, e) {
  if (n = n.slice(-2), e = e.slice(-2), Z(n, e) || !n.length || !e.length || n[0] === 0 || n[1] === 0 || e[0] === 0 || e[1] === 0)
    return !0;
  if (n.length !== e.length) {
    const t = n[n.length - 1], s = e[e.length - 1];
    if (t === s || Fn(t) && Fn(s) && (n[0] === 1 || e[0] === 1))
      return !0;
  }
  return n[1] === e[1] && Fn(n[0]) && Fn(e[0]);
}
let ms, gs;
function Jf(n) {
  if (ms == null) {
    const e = _e(n);
    ms = e.getParameter(e.MAX_TEXTURE_SIZE);
  }
  return ms;
}
function ep(n) {
  if (gs == null) {
    const e = _e(n);
    gs = e.getParameter(e.MAX_TEXTURE_IMAGE_UNITS);
  }
  return Math.min(16, gs);
}
function tp(n) {
  if (n === 0)
    return 0;
  let e;
  const t = _e(n);
  return Re(t, "EXT_disjoint_timer_query_webgl2") && n === 2 ? e = 2 : Re(t, "EXT_disjoint_timer_query") ? e = 1 : e = 0, e;
}
function Re(n, e) {
  return n.getExtension(e) != null;
}
function qo(n) {
  try {
    if (_e(n) != null)
      return !0;
  } catch (e) {
    return console.log("Error when getting WebGL context: ", e), !1;
  }
  return !1;
}
function np(n) {
  if (n === 0)
    return !1;
  const e = _e(n);
  if (n === 1) {
    if (!Re(e, "OES_texture_float"))
      return !1;
  } else if (!Re(e, "EXT_color_buffer_float"))
    return !1;
  return Ms(e);
}
function sp(n) {
  if (n === 0)
    return !1;
  const e = _e(n);
  if (n === 1) {
    if (!Re(e, "OES_texture_float") || !Re(e, "WEBGL_color_buffer_float"))
      return !1;
  } else {
    if (Re(e, "EXT_color_buffer_float"))
      return Ms(e);
    const s = "EXT_color_buffer_half_float";
    if (Re(e, s)) {
      const o = e.getExtension(s);
      return op(e, o);
    }
    return !1;
  }
  return Ms(e);
}
function Ms(n) {
  const e = co(n), t = n.createTexture();
  n.bindTexture(n.TEXTURE_2D, t), n.texImage2D(n.TEXTURE_2D, 0, e.internalFormatFloat, 1, 1, 0, e.textureFormatFloat, e.textureTypeFloat, null);
  const r = n.createFramebuffer();
  n.bindFramebuffer(n.FRAMEBUFFER, r), n.framebufferTexture2D(n.FRAMEBUFFER, n.COLOR_ATTACHMENT0, n.TEXTURE_2D, t, 0);
  const i = n.checkFramebufferStatus(n.FRAMEBUFFER) === n.FRAMEBUFFER_COMPLETE;
  return n.bindTexture(n.TEXTURE_2D, null), n.bindFramebuffer(n.FRAMEBUFFER, null), n.deleteTexture(t), n.deleteFramebuffer(r), i;
}
function op(n, e) {
  const t = co(n, e), s = n.createTexture();
  n.bindTexture(n.TEXTURE_2D, s), n.texImage2D(n.TEXTURE_2D, 0, t.internalFormatHalfFloat, 1, 1, 0, t.textureFormatFloat, t.textureTypeHalfFloat, null);
  const i = n.createFramebuffer();
  n.bindFramebuffer(n.FRAMEBUFFER, i), n.framebufferTexture2D(n.FRAMEBUFFER, n.COLOR_ATTACHMENT0, n.TEXTURE_2D, s, 0);
  const a = n.checkFramebufferStatus(n.FRAMEBUFFER) === n.FRAMEBUFFER_COMPLETE;
  return n.bindTexture(n.TEXTURE_2D, null), n.bindFramebuffer(n.FRAMEBUFFER, null), n.deleteTexture(s), n.deleteFramebuffer(i), a;
}
function rp(n) {
  return n !== 2 ? !1 : _e(n).fenceSync != null;
}
function yn(n, e) {
  Array.isArray(n) || (n = [n]), n.forEach((t) => {
    t != null && N(t.dtype !== "complex64", () => `${e} does not support complex64 tensors in the WebGL backend.`);
  });
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const A = y();
A.registerFlag("HAS_WEBGL", () => A.getNumber("WEBGL_VERSION") > 0);
A.registerFlag("WEBGL_VERSION", () => qo(2) ? 2 : qo(1) ? 1 : 0);
A.registerFlag("WEBGL_CHECK_NUMERICAL_PROBLEMS", () => !1);
A.registerFlag("WEBGL_BUFFER_SUPPORTED", () => A.get("WEBGL_VERSION") === 2);
A.registerFlag("WEBGL_CPU_FORWARD", () => !0);
A.registerFlag("WEBGL_FORCE_F16_TEXTURES", () => !1);
A.registerFlag("WEBGL_PACK", () => A.getBool("HAS_WEBGL"));
A.registerFlag("WEBGL_PACK_NORMALIZATION", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_PACK_CLIP", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_PACK_DEPTHWISECONV", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_PACK_BINARY_OPERATIONS", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_PACK_UNARY_OPERATIONS", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_PACK_ARRAY_OPERATIONS", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_PACK_IMAGE_OPERATIONS", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_PACK_REDUCE", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_LAZILY_UNPACK", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_CONV_IM2COL", () => A.getBool("WEBGL_PACK"));
A.registerFlag("WEBGL_MAX_TEXTURE_SIZE", () => Jf(A.getNumber("WEBGL_VERSION")));
A.registerFlag("WEBGL_MAX_TEXTURES_IN_SHADER", () => ep(A.getNumber("WEBGL_VERSION")));
A.registerFlag("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION", () => {
  const n = A.getNumber("WEBGL_VERSION");
  return n === 0 ? 0 : tp(n);
});
A.registerFlag("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_RELIABLE", () => A.getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION") > 0 && !oi());
A.registerFlag("WEBGL_RENDER_FLOAT32_CAPABLE", () => np(A.getNumber("WEBGL_VERSION")));
A.registerFlag("WEBGL_RENDER_FLOAT32_ENABLED", () => A.getBool("WEBGL_FORCE_F16_TEXTURES") ? !1 : A.getBool("WEBGL_RENDER_FLOAT32_CAPABLE"));
A.registerFlag("WEBGL_DOWNLOAD_FLOAT_ENABLED", () => sp(A.getNumber("WEBGL_VERSION")));
A.registerFlag("WEBGL_FENCE_API_ENABLED", () => rp(A.getNumber("WEBGL_VERSION")));
A.registerFlag("WEBGL_SIZE_UPLOAD_UNIFORM", () => A.getBool("WEBGL_RENDER_FLOAT32_ENABLED") ? 4 : 0);
A.registerFlag("WEBGL_DELETE_TEXTURE_THRESHOLD", () => -1, (n) => {
  if (n < 0 && n !== -1)
    throw new Error(`WEBGL_DELETE_TEXTURE_THRESHOLD must be -1 (indicating never delete) or at least 0, but got ${n}.`);
});
A.registerFlag("WEBGL_FLUSH_THRESHOLD", () => oi() ? 1 : -1, (n) => {
  if (n < 0 && n !== -1)
    throw new Error(`WEBGL_FLUSH_THRESHOLD must be -1 (indicating never manual flush) or at least 0, but got ${n}.`);
});
A.registerFlag("CPU_HANDOFF_SIZE_THRESHOLD", () => 128);
A.registerFlag("WEBGL_USE_SHAPES_UNIFORMS", () => !1);
A.registerFlag("TOPK_LAST_DIM_CPU_HANDOFF_SIZE_THRESHOLD", () => 1e5);
A.registerFlag("TOPK_K_CPU_HANDOFF_THRESHOLD", () => 128);
A.registerFlag("WEBGL_EXP_CONV", () => !1);
A.registerFlag("SOFTWARE_WEBGL_ENABLED", () => A.getBool("IS_TEST"));
A.registerFlag("WEBGL_MAX_SIZE_FOR_NARROW_TEXTURE", () => 1 / 0);
A.registerFlag("WEBGL_AUTO_SQUARIFY_NARROW_TEXTURE_SHAPE", () => !1);
A.registerFlag("WEBGL2_ISNAN_CUSTOM", () => !1);
A.registerFlag("ENGINE_COMPILE_ONLY", () => !1);
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function le() {
  let n, e, t, s, o, r, i, a, c, l;
  return y().getNumber("WEBGL_VERSION") === 2 ? (n = "#version 300 es", e = "in", t = "out", s = "in", o = "texture", r = "outputColor", i = "out vec4 outputColor;", a = y().getBool("WEBGL2_ISNAN_CUSTOM") ? `
      bool isnan_custom(float val) {
        uint floatToUint = floatBitsToUint(val);
        return (floatToUint & 0x7fffffffu) > 0x7f800000u;
      }

      bvec4 isnan_custom(vec4 val) {
        return bvec4(isnan_custom(val.x),
          isnan_custom(val.y), isnan_custom(val.z), isnan_custom(val.w));
      }

      #define isnan(value) isnan_custom(value)
    ` : "", c = "", l = `
      #define round(value) newRound(value)
      int newRound(float value) {
        return int(floor(value + 0.5));
      }

      ivec4 newRound(vec4 value) {
        return ivec4(floor(value + vec4(0.5)));
      }
    `) : (n = "", e = "attribute", t = "varying", s = "varying", o = "texture2D", r = "gl_FragColor", i = "", a = `
      #define isnan(value) isnan_custom(value)
      bool isnan_custom(float val) {
        return (val > 0. || val < 1. || val == 0.) ? false : true;
      }
      bvec4 isnan_custom(vec4 val) {
        return bvec4(isnan(val.x), isnan(val.y), isnan(val.z), isnan(val.w));
      }
    `, c = `
      uniform float INFINITY;

      bool isinf(float val) {
        return abs(val) == INFINITY;
      }
      bvec4 isinf(vec4 val) {
        return equal(abs(val), vec4(INFINITY));
      }
    `, l = `
      int round(float value) {
        return int(floor(value + 0.5));
      }

      ivec4 round(vec4 value) {
        return ivec4(floor(value + vec4(0.5)));
      }
    `), {
    version: n,
    attribute: e,
    varyingVs: t,
    varyingFs: s,
    texture2D: o,
    output: r,
    defineOutput: i,
    defineSpecialNaN: a,
    defineSpecialInf: c,
    defineRound: l
  };
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Rt(n, e, t = "index") {
  const s = Q(e);
  return s.map((o, r) => {
    const i = `int ${n[r]} = ${t} / ${o}`, a = r === s.length - 1 ? `int ${n[r + 1]} = ${t} - ${n[r]} * ${o}` : `index -= ${n[r]} * ${o}`;
    return `${i}; ${a};`;
  }).join("");
}
function ts(n, e, t = "index") {
  const s = Q(e);
  return s.map((o, r) => {
    const i = `int ${n[r]} = ${t} / outShapeStrides[${r}]`, a = r === s.length - 1 ? `int ${n[r + 1]} = ${t} - ${n[r]} * outShapeStrides[${r}]` : `index -= ${n[r]} * outShapeStrides[${r}]`;
    return `${i}; ${a};`;
  }).join("");
}
function ip(n, e) {
  const t = n.length, s = n.map((r) => `${e}[${r}]`), o = new Array(t - 1);
  o[t - 2] = s[t - 1];
  for (let r = t - 3; r >= 0; --r)
    o[r] = `(${o[r + 1]} * ${s[r + 1]})`;
  return o;
}
function ap(n, e, t = "index") {
  const s = n.map((r, i) => i), o = ip(s, e);
  return o.map((r, i) => {
    const a = `int ${n[i]} = ${t} / ${o[i]}`, c = i === o.length - 1 ? `int ${n[i + 1]} = ${t} - ${n[i]} * ${o[i]}` : `index -= ${n[i]} * ${o[i]}`;
    return `${a}; ${c};`;
  }).join("");
}
function lo(n) {
  const e = Q(n).map((t) => t.toString());
  return `
  int getFlatIndex(ivec3 coords) {
    return coords.x * ${e[0]} + coords.y * ${e[1]} + coords.z;
  }
`;
}
function uo() {
  return `
  int getFlatIndex(ivec3 coords) {
    return coords.x * outShapeStrides[0] + coords.y * outShapeStrides[1] + coords.z;
  }
`;
}
const oa = `
  const float FLOAT_MAX = 1.70141184e38;
  const float FLOAT_MIN = 1.17549435e-38;

  lowp vec4 encode_float(highp float v) {
    if (isnan(v)) {
      return vec4(255, 255, 255, 255);
    }

    highp float av = abs(v);

    if(av < FLOAT_MIN) {
      return vec4(0.0, 0.0, 0.0, 0.0);
    } else if(v > FLOAT_MAX) {
      return vec4(0.0, 0.0, 128.0, 127.0) / 255.0;
    } else if(v < -FLOAT_MAX) {
      return vec4(0.0, 0.0,  128.0, 255.0) / 255.0;
    }

    highp vec4 c = vec4(0,0,0,0);

    highp float e = floor(log2(av));
    highp float m = exp2(fract(log2(av))) - 1.0;

    c[2] = floor(128.0 * m);
    m -= c[2] / 128.0;
    c[1] = floor(32768.0 * m);
    m -= c[1] / 32768.0;
    c[0] = floor(8388608.0 * m);

    highp float ebias = e + 127.0;
    c[3] = floor(ebias / 2.0);
    ebias -= c[3] * 2.0;
    c[2] += floor(ebias) * 128.0;

    c[3] += 128.0 * step(0.0, -v);

    return c / 255.0;
  }
`;
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const { getBroadcastDims: ra } = If;
function cp(n, e, t) {
  const s = [];
  if (n.forEach((f) => {
    const p = T(f.shapeInfo.logicalShape);
    if (f.shapeInfo.isUniform ? s.push(`uniform float ${f.name}${p > 1 ? `[${p}]` : ""};`) : (s.push(`uniform sampler2D ${f.name};`), s.push(`uniform int offset${f.name};`)), t.enableShapeUniforms) {
      const { uniformShape: x } = ho(t.packedInputs, f.shapeInfo.logicalShape, f.shapeInfo.texShape);
      switch (x.length) {
        case 1:
          s.push(`uniform int ${f.name}Shape;`);
          break;
        case 2:
          s.push(`uniform ivec2 ${f.name}Shape;`);
          break;
        case 3:
          s.push(`uniform ivec3 ${f.name}Shape;`);
          break;
        case 4:
          s.push(`uniform ivec4 ${f.name}Shape;`);
          break;
      }
      s.push(`uniform ivec2 ${f.name}TexShape;`);
    }
  }), t.enableShapeUniforms) {
    switch (e.logicalShape.length) {
      case 1:
        s.push("uniform int outShape;");
        break;
      case 2:
        s.push("uniform ivec2 outShape;"), s.push("uniform int outShapeStrides;");
        break;
      case 3:
        s.push("uniform ivec3 outShape;"), s.push("uniform ivec2 outShapeStrides;");
        break;
      case 4:
        s.push("uniform ivec4 outShape;"), s.push("uniform ivec3 outShapeStrides;");
        break;
    }
    s.push("uniform ivec2 outTexShape;");
  }
  t.customUniforms && t.customUniforms.forEach((f) => {
    s.push(`uniform ${f.type} ${f.name}${f.arrayIndex ? `[${f.arrayIndex}]` : ""};`);
  });
  const o = s.join(`
`), r = n.map((f) => lp(f, e, t.packedInputs, t.enableShapeUniforms)).join(`
`), i = e.texShape, a = le(), c = hp(a);
  let l, u, d = mp(a);
  return e.isPacked ? (l = up(e.logicalShape, i, t.enableShapeUniforms), u = pp(a)) : (l = dp(e.logicalShape, i, t.enableShapeUniforms), u = fp(a)), t.packedInputs && (d += bp), [
    d,
    c,
    u,
    o,
    l,
    r,
    t.userCode
  ].join(`
`);
}
function Qt(n, e = !1) {
  const t = n.shapeInfo.logicalShape;
  switch (t.length) {
    case 0:
      return Ap(n, e);
    case 1:
      return Dp(n, e);
    case 2:
      return Pp(n, e);
    case 3:
      return Lp(n, e);
    case 4:
      return Mp(n, e);
    case 5:
      return Vp(n);
    case 6:
      return Up(n);
    default:
      throw new Error(`${t.length}-D input sampling is not yet supported`);
  }
}
function ia(n, e) {
  switch (n.shapeInfo.logicalShape.length) {
    case 0:
      return kp(n);
    case 1:
      return Fp(n, e);
    case 2:
      return Op(n, e);
    case 3:
      return _p(n, e);
    default:
      return Bp(n, e);
  }
}
function lp(n, e, t = !1, s) {
  let o = "";
  t ? o += ia(n, s) : o += Qt(n, s);
  const r = n.shapeInfo.logicalShape, i = e.logicalShape;
  return r.length <= i.length && (t ? o += Wp(n, e) : o += Gp(n, e)), o;
}
function up(n, e, t) {
  switch (n.length) {
    case 0:
      return aa();
    case 1:
      return wp(n, e, t);
    case 2:
      return Ep(n, e, t);
    case 3:
      return vp(n, e, t);
    default:
      return Sp(n, e, t);
  }
}
function dp(n, e, t) {
  switch (n.length) {
    case 0:
      return aa();
    case 1:
      return yp(n, e, t);
    case 2:
      return Np(n, e, t);
    case 3:
      return $p(n, e, t);
    case 4:
      return Ip(n, e, t);
    case 5:
      return Rp(n, e);
    case 6:
      return Tp(n, e);
    default:
      throw new Error(`${n.length}-D output sampling is not yet supported`);
  }
}
function hp(n) {
  return `
    float sampleTexture(sampler2D textureSampler, vec2 uv) {
      return ${n.texture2D}(textureSampler, uv).r;
    }
  `;
}
function fp(n) {
  return `
    void setOutput(float val) {
      ${n.output} = vec4(val, 0, 0, 0);
    }
  `;
}
function pp(n) {
  return `
    void setOutput(vec4 val) {
      ${n.output} = val;
    }
  `;
}
function mp(n) {
  return `${n.version}
    precision highp float;
    precision highp int;
    precision highp sampler2D;
    ${n.varyingFs} vec2 resultUV;
    ${n.defineOutput}
    const vec2 halfCR = vec2(0.5, 0.5);

    struct ivec5
    {
      int x;
      int y;
      int z;
      int w;
      int u;
    };

    struct ivec6
    {
      int x;
      int y;
      int z;
      int w;
      int u;
      int v;
    };

    uniform float NAN;
    ${n.defineSpecialNaN}
    ${n.defineSpecialInf}
    ${n.defineRound}

    int imod(int x, int y) {
      return x - y * (x / y);
    }

    int idiv(int a, int b, float sign) {
      int res = a / b;
      int mod = imod(a, b);
      if (sign < 0. && mod != 0) {
        res -= 1;
      }
      return res;
    }

    //Based on the work of Dave Hoskins
    //https://www.shadertoy.com/view/4djSRW
    #define HASHSCALE1 443.8975
    float random(float seed){
      vec2 p = resultUV * seed;
      vec3 p3  = fract(vec3(p.xyx) * HASHSCALE1);
      p3 += dot(p3, p3.yzx + 19.19);
      return fract((p3.x + p3.y) * p3.z);
    }

    ${gp}
    ${xp}
    ${Cp}
  `;
}
const gp = `
vec2 uvFromFlat(int texNumR, int texNumC, int index) {
  int texR = index / texNumC;
  int texC = index - texR * texNumC;
  return (vec2(texC, texR) + halfCR) / vec2(texNumC, texNumR);
}
vec2 packedUVfrom1D(int texNumR, int texNumC, int index) {
  int texelIndex = index / 2;
  int texR = texelIndex / texNumC;
  int texC = texelIndex - texR * texNumC;
  return (vec2(texC, texR) + halfCR) / vec2(texNumC, texNumR);
}
`, xp = `
vec2 packedUVfrom2D(int texelsInLogicalRow, int texNumR,
  int texNumC, int row, int col) {
  int texelIndex = (row / 2) * texelsInLogicalRow + (col / 2);
  int texR = texelIndex / texNumC;
  int texC = texelIndex - texR * texNumC;
  return (vec2(texC, texR) + halfCR) / vec2(texNumC, texNumR);
}
`, Cp = `
vec2 packedUVfrom3D(int texNumR, int texNumC,
    int texelsInBatch, int texelsInLogicalRow, int b,
    int row, int col) {
  int index = b * texelsInBatch + (row / 2) * texelsInLogicalRow + (col / 2);
  int texR = index / texNumC;
  int texC = index - texR * texNumC;
  return (vec2(texC, texR) + halfCR) / vec2(texNumC, texNumR);
}
`, bp = `
  float getChannel(vec4 frag, vec2 innerDims) {
    vec2 modCoord = mod(innerDims, 2.);
    return modCoord.x == 0. ?
      (modCoord.y == 0. ? frag.r : frag.g) :
      (modCoord.y == 0. ? frag.b : frag.a);
  }
  float getChannel(vec4 frag, int dim) {
    float modCoord = mod(float(dim), 2.);
    return modCoord == 0. ? frag.r : frag.g;
  }
`;
function aa() {
  return `
    int getOutputCoords() {
      return 0;
    }
  `;
}
function wp(n, e, t) {
  const s = [Math.ceil(e[0] / 2), Math.ceil(e[1] / 2)];
  return s[0] === 1 ? t ? `
      int getOutputCoords() {
        return 2 * int(resultUV.x * ceil(float(outTexShape[1]) / 2.0));
      }
    ` : `
      int getOutputCoords() {
        return 2 * int(resultUV.x * ${s[1]}.0);
      }
    ` : s[1] === 1 ? t ? `
      int getOutputCoords() {
        return 2 * int(resultUV.y * ceil(float(outTexShape[0]) / 2.0));
      }
    ` : `
      int getOutputCoords() {
        return 2 * int(resultUV.y * ${s[0]}.0);
      }
    ` : t ? `
    int getOutputCoords() {
      ivec2 packedTexShape = ivec2(ceil(float(outTexShape[0]) / 2.0), ceil(float(outTexShape[1]) / 2.0));
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(packedTexShape[0], packedTexShape[1]));
      return 2 * (resTexRC.x * packedTexShape[1] + resTexRC.y);
    }
  ` : `
    int getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(${s[0]}, ${s[1]}));
      return 2 * (resTexRC.x * ${s[1]} + resTexRC.y);
    }
  `;
}
function yp(n, e, t) {
  return e[0] === 1 ? t ? `
      int getOutputCoords() {
        return int(resultUV.x * float(outTexShape[1]));
      }
    ` : `
      int getOutputCoords() {
        return int(resultUV.x * ${e[1]}.0);
      }
    ` : e[1] === 1 ? t ? `
      int getOutputCoords() {
        return int(resultUV.y * float(outTexShape[0]));
      }
    ` : `
      int getOutputCoords() {
        return int(resultUV.y * ${e[0]}.0);
      }
    ` : t ? `
    int getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(outTexShape[0], outTexShape[1]));
      return resTexRC.x * outTexShape[1] + resTexRC.y;
    }
  ` : `
    int getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(${e[0]}, ${e[1]}));
      return resTexRC.x * ${e[1]} + resTexRC.y;
    }
  `;
}
function vp(n, e, t) {
  if (t)
    return `
    ivec3 getOutputCoords() {
      ivec2 packedTexShape = ivec2(ceil(float(outTexShape[0]) / 2.0), ceil(float(outTexShape[1]) / 2.0));
      int texelsInLogicalRow = int(ceil(float(outShape[2]) / 2.0));
      int texelsInBatch = texelsInLogicalRow * int(ceil(float(outShape[1]) / 2.0));
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(packedTexShape[0], packedTexShape[1]));
      int index = resTexRC.x * packedTexShape[1] + resTexRC.y;

      int b = index / texelsInBatch;
      index -= b * texelsInBatch;

      int r = 2 * (index / texelsInLogicalRow);
      int c = imod(index, texelsInLogicalRow) * 2;

      return ivec3(b, r, c);
    }
  `;
  const s = [Math.ceil(e[0] / 2), Math.ceil(e[1] / 2)], o = Math.ceil(n[2] / 2), r = o * Math.ceil(n[1] / 2);
  return `
    ivec3 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(${s[0]}, ${s[1]}));
      int index = resTexRC.x * ${s[1]} + resTexRC.y;

      int b = index / ${r};
      index -= b * ${r};

      int r = 2 * (index / ${o});
      int c = imod(index, ${o}) * 2;

      return ivec3(b, r, c);
    }
  `;
}
function $p(n, e, t) {
  if (t)
    return `
  ivec3 getOutputCoords() {
    ivec2 resTexRC = ivec2(resultUV.yx *
                           vec2(outTexShape[0], outTexShape[1]));
    int index = resTexRC.x * outTexShape[1] + resTexRC.y;
    ${ts(["r", "c", "d"], n)}
    return ivec3(r, c, d);
  }
`;
  const s = Rt(["r", "c", "d"], n);
  return `
    ivec3 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(${e[0]}, ${e[1]}));
      int index = resTexRC.x * ${e[1]} + resTexRC.y;
      ${s}
      return ivec3(r, c, d);
    }
  `;
}
function Sp(n, e, t) {
  if (t)
    return `
    ivec4 getOutputCoords() {
      ivec2 packedTexShape = ivec2(ceil(float(outTexShape[0]) / 2.0), ceil(float(outTexShape[1]) / 2.0));
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(packedTexShape[0], packedTexShape[1]));
      int index = resTexRC.x * packedTexShape[1] + resTexRC.y;

      int texelsInLogicalRow = int(ceil(float(outShape[3]) / 2.0));
      int texelsInBatch = texelsInLogicalRow * int(ceil(float(outShape[2]) / 2.0));
      int texelsInBatchN = texelsInBatch * outShape[1];

      int b2 = index / texelsInBatchN;
      index -= b2 * texelsInBatchN;

      int b = index / texelsInBatch;
      index -= b * texelsInBatch;

      int r = 2 * (index / texelsInLogicalRow);
      int c = imod(index, texelsInLogicalRow) * 2;

      return ivec4(b2, b, r, c);
    }
  `;
  const s = [Math.ceil(e[0] / 2), Math.ceil(e[1] / 2)], o = Math.ceil(n[n.length - 1] / 2), r = o * Math.ceil(n[n.length - 2] / 2);
  let i = r, a = "", c = "b, r, c";
  for (let l = 2; l < n.length - 1; l++)
    i *= n[n.length - l - 1], a = `
      int b${l} = index / ${i};
      index -= b${l} * ${i};
    ` + a, c = `b${l}, ` + c;
  return `
    ivec${n.length} getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(${s[0]}, ${s[1]}));
      int index = resTexRC.x * ${s[1]} + resTexRC.y;

      ${a}

      int b = index / ${r};
      index -= b * ${r};

      int r = 2 * (index / ${o});
      int c = imod(index, ${o}) * 2;

      return ivec${n.length}(${c});
    }
  `;
}
function Ip(n, e, t) {
  if (t)
    return `
    ivec4 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
        vec2(outTexShape[0], outTexShape[1]));
      int index = resTexRC.x * outTexShape[1] + resTexRC.y;
      ${ts(["r", "c", "d", "d2"], n)}
      return ivec4(r, c, d, d2);
    }
  `;
  const s = Rt(["r", "c", "d", "d2"], n);
  return `
    ivec4 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
        vec2(${e[0]}, ${e[1]}));
      int index = resTexRC.x * ${e[1]} + resTexRC.y;
      ${s}
      return ivec4(r, c, d, d2);
    }
  `;
}
function Rp(n, e) {
  const t = Rt(["r", "c", "d", "d2", "d3"], n);
  return `
    ivec5 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx * vec2(${e[0]},
                             ${e[1]}));

      int index = resTexRC.x * ${e[1]} + resTexRC.y;

      ${t}

      ivec5 outShape = ivec5(r, c, d, d2, d3);
      return outShape;
    }
  `;
}
function Tp(n, e) {
  const t = Rt(["r", "c", "d", "d2", "d3", "d4"], n);
  return `
    ivec6 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
        vec2(${e[0]}, ${e[1]}));
      int index = resTexRC.x * ${e[1]} + resTexRC.y;

      ${t}

      ivec6 result = ivec6(r, c, d, d2, d3, d4);
      return result;
    }
  `;
}
function Ep(n, e, t) {
  const s = [Math.ceil(e[0] / 2), Math.ceil(e[1] / 2)];
  if (Z(n, e))
    return t ? `
      ivec2 getOutputCoords() {
        ivec2 packedTexShape = ivec2(ceil(float(outTexShape[0]) / 2.0), ceil(float(outTexShape[1]) / 2.0));
        return 2 * ivec2(resultUV.yx * vec2(packedTexShape[0], packedTexShape[1]));
      }
    ` : `
      ivec2 getOutputCoords() {
        return 2 * ivec2(resultUV.yx * vec2(${s[0]}, ${s[1]}));
      }
    `;
  const o = Math.ceil(n[1] / 2);
  return t ? `
    ivec2 getOutputCoords() {
      ivec2 packedTexShape = ivec2(ceil(float(outTexShape[0]) / 2.0), ceil(float(outTexShape[1]) / 2.0));
      int texelsInLogicalRow = int(ceil(float(outShape[1]) / 2.0));
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(packedTexShape[0], packedTexShape[1]));

      int index = resTexRC.x * packedTexShape[1] + resTexRC.y;
      int r = 2 * (index / texelsInLogicalRow);
      int c = imod(index, texelsInLogicalRow) * 2;

      return ivec2(r, c);
    }
  ` : `
    ivec2 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(${s[0]}, ${s[1]}));

      int index = resTexRC.x * ${s[1]} + resTexRC.y;
      int r = 2 * (index / ${o});
      int c = imod(index, ${o}) * 2;

      return ivec2(r, c);
    }
  `;
}
function Np(n, e, t) {
  return Z(n, e) ? t ? `
      ivec2 getOutputCoords() {
        return ivec2(resultUV.yx * vec2(outTexShape[0], outTexShape[1]));
      }
    ` : `
      ivec2 getOutputCoords() {
        return ivec2(resultUV.yx * vec2(${e[0]}, ${e[1]}));
      }
    ` : n[1] === 1 ? t ? `
      ivec2 getOutputCoords() {
        ivec2 resTexRC = ivec2(resultUV.yx *
                               vec2(outTexShape[0], outTexShape[1]));
        int index = resTexRC.x * outTexShape[1] + resTexRC.y;
        return ivec2(index, 0);
      }
    ` : `
      ivec2 getOutputCoords() {
        ivec2 resTexRC = ivec2(resultUV.yx *
                               vec2(${e[0]}, ${e[1]}));
        int index = resTexRC.x * ${e[1]} + resTexRC.y;
        return ivec2(index, 0);
      }
    ` : n[0] === 1 ? t ? `
      ivec2 getOutputCoords() {
        ivec2 resTexRC = ivec2(resultUV.yx *
                               vec2(outTexShape[0], outTexShape[1]));
        int index = resTexRC.x * outTexShape[1] + resTexRC.y;
        return ivec2(0, index);
      }
    ` : `
      ivec2 getOutputCoords() {
        ivec2 resTexRC = ivec2(resultUV.yx *
                               vec2(${e[0]}, ${e[1]}));
        int index = resTexRC.x * ${e[1]} + resTexRC.y;
        return ivec2(0, index);
      }
    ` : t ? `
    ivec2 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(outTexShape[0], outTexShape[1]));
      int index = resTexRC.x * outTexShape[1] + resTexRC.y;
      int r = index / outShape[1];
      int c = index - r * outShape[1];
      return ivec2(r, c);
    }
  ` : `
    ivec2 getOutputCoords() {
      ivec2 resTexRC = ivec2(resultUV.yx *
                             vec2(${e[0]}, ${e[1]}));
      int index = resTexRC.x * ${e[1]} + resTexRC.y;
      int r = index / ${n[1]};
      int c = index - r * ${n[1]};
      return ivec2(r, c);
    }
  `;
}
function Tt(n) {
  return `offset${n}`;
}
function kp(n) {
  const e = n.name, t = "get" + e.charAt(0).toUpperCase() + e.slice(1), s = le();
  return `
    vec4 ${t}() {
      return ${s.texture2D}(${e}, halfCR);
    }
  `;
}
function Ap(n, e) {
  const t = n.name, s = "get" + t.charAt(0).toUpperCase() + t.slice(1);
  if (n.shapeInfo.isUniform)
    return `float ${s}() {return ${t};}`;
  const [o, r] = n.shapeInfo.texShape;
  if (o === 1 && r === 1)
    return `
      float ${s}() {
        return sampleTexture(${t}, halfCR);
      }
    `;
  const i = Tt(t);
  if (e)
    return `
    float ${s}() {
      vec2 uv = uvFromFlat(${t}TexShape[0], ${t}TexShape[1], ${i});
      return sampleTexture(${t}, uv);
    }
  `;
  const [a, c] = n.shapeInfo.texShape;
  return `
    float ${s}() {
      vec2 uv = uvFromFlat(${a}, ${c}, ${i});
      return sampleTexture(${t}, uv);
    }
  `;
}
function Fp(n, e) {
  const t = n.name, s = "get" + t.charAt(0).toUpperCase() + t.slice(1), o = n.shapeInfo.texShape, r = le();
  if (e)
    return `
    vec4 ${s}(int index) {
      ivec2 packedTexShape = ivec2(ceil(float(${t}TexShape[0]) / 2.0), ceil(float(${t}TexShape[1]) / 2.0));
      vec2 uv = packedUVfrom1D(
        packedTexShape[0], packedTexShape[1], index);
      return ${r.texture2D}(${t}, uv);
    }
  `;
  const i = [Math.ceil(o[0] / 2), Math.ceil(o[1] / 2)];
  return `
    vec4 ${s}(int index) {
      vec2 uv = packedUVfrom1D(
        ${i[0]}, ${i[1]}, index);
      return ${r.texture2D}(${t}, uv);
    }
  `;
}
function Dp(n, e) {
  const t = n.name, s = "get" + t.charAt(0).toUpperCase() + t.slice(1);
  if (n.shapeInfo.isUniform)
    return `
      float ${s}(int index) {
        ${Zt(n)}
      }
    `;
  const o = n.shapeInfo.texShape, r = o[0], i = o[1];
  if (i === 1 && r === 1)
    return `
      float ${s}(int index) {
        return sampleTexture(${t}, halfCR);
      }
    `;
  const a = Tt(t);
  return i === 1 ? e ? `
      float ${s}(int index) {
        vec2 uv = vec2(0.5, (float(index + ${a}) + 0.5) / float(${t}TexShape[0]));
        return sampleTexture(${t}, uv);
      }
    ` : `
      float ${s}(int index) {
        vec2 uv = vec2(0.5, (float(index + ${a}) + 0.5) / ${r}.0);
        return sampleTexture(${t}, uv);
      }
    ` : r === 1 ? e ? `
      float ${s}(int index) {
        vec2 uv = vec2((float(index + ${a}) + 0.5) / float(${t}TexShape[1]), 0.5);
        return sampleTexture(${t}, uv);
      }
    ` : `
      float ${s}(int index) {
        vec2 uv = vec2((float(index + ${a}) + 0.5) / ${i}.0, 0.5);
        return sampleTexture(${t}, uv);
      }
    ` : e ? `
    float ${s}(int index) {
      vec2 uv = uvFromFlat(${t}TexShape[0], ${t}TexShape[1], index + ${a});
      return sampleTexture(${t}, uv);
    }
  ` : `
    float ${s}(int index) {
      vec2 uv = uvFromFlat(${r}, ${i}, index + ${a});
      return sampleTexture(${t}, uv);
    }
  `;
}
function Op(n, e) {
  const t = n.shapeInfo.logicalShape, s = n.name, o = "get" + s.charAt(0).toUpperCase() + s.slice(1), r = n.shapeInfo.texShape, i = r[0], a = r[1], c = le();
  if (r != null && Z(t, r))
    return e ? `
      vec4 ${o}(int row, int col) {
        vec2 uv = (vec2(col, row) + halfCR) / vec2(${s}TexShape[1], ${s}TexShape[0]);

        return ${c.texture2D}(${s}, uv);
      }
    ` : `
      vec4 ${o}(int row, int col) {
        vec2 uv = (vec2(col, row) + halfCR) / vec2(${a}.0, ${i}.0);

        return ${c.texture2D}(${s}, uv);
      }
    `;
  if (e)
    return `
    vec4 ${o}(int row, int col) {
      ivec2 packedTexShape = ivec2(ceil(float(${s}TexShape[0]) / 2.0), ceil(float(${s}TexShape[1]) / 2.0));
      int valuesPerRow = int(ceil(float(${s}Shape[1]) / 2.0));
      vec2 uv = packedUVfrom2D(valuesPerRow, packedTexShape[0], packedTexShape[1], row, col);
      return ${c.texture2D}(${s}, uv);
    }
  `;
  const l = [Math.ceil(r[0] / 2), Math.ceil(r[1] / 2)], u = Math.ceil(t[1] / 2);
  return `
    vec4 ${o}(int row, int col) {
      vec2 uv = packedUVfrom2D(${u}, ${l[0]}, ${l[1]}, row, col);
      return ${c.texture2D}(${s}, uv);
    }
  `;
}
function Pp(n, e) {
  const t = n.shapeInfo.logicalShape, s = n.name, o = "get" + s.charAt(0).toUpperCase() + s.slice(1), r = n.shapeInfo.texShape;
  if (r != null && Z(t, r)) {
    if (e)
      return `
      float ${o}(int row, int col) {
        vec2 uv = (vec2(col, row) + halfCR) / vec2(${s}TexShape[1], ${s}TexShape[0]);
        return sampleTexture(${s}, uv);
      }
    `;
    const h = r[0], f = r[1];
    return `
    float ${o}(int row, int col) {
      vec2 uv = (vec2(col, row) + halfCR) / vec2(${f}.0, ${h}.0);
      return sampleTexture(${s}, uv);
    }
  `;
  }
  const { newShape: i, keptDims: a } = yt(t), c = i;
  if (c.length < t.length) {
    const h = Jt(n, c), f = ["row", "col"];
    return `
      ${Qt(h, e)}
      float ${o}(int row, int col) {
        return ${o}(${en(f, a)});
      }
    `;
  }
  if (n.shapeInfo.isUniform)
    return `
      float ${o}(int row, int col) {
        int index = round(dot(vec2(row, col), vec2(${t[1]}, 1)));
        ${Zt(n)}
      }
    `;
  const l = r[0], u = r[1], d = Tt(s);
  return u === 1 ? e ? `
      float ${o}(int row, int col) {
        float index = dot(vec3(row, col, ${d}), vec3(${s}Shape[1], 1, 1));
        vec2 uv = vec2(0.5, (index + 0.5) / float(${s}TexShape[0]));
        return sampleTexture(${s}, uv);
      }
    ` : `
    float ${o}(int row, int col) {
      float index = dot(vec3(row, col, ${d}), vec3(${t[1]}, 1, 1));
      vec2 uv = vec2(0.5, (index + 0.5) / ${l}.0);
      return sampleTexture(${s}, uv);
    }
  ` : l === 1 ? e ? `
      float ${o}(int row, int col) {
        float index = dot(vec3(row, col, ${d}), vec3(${s}Shape[1], 1, 1));
        vec2 uv = vec2((index + 0.5) / float(${s}TexShape[1]), 0.5);
        return sampleTexture(${s}, uv);
      }
    ` : `
    float ${o}(int row, int col) {
      float index = dot(vec3(row, col, ${d}), vec3(${t[1]}, 1, 1));
      vec2 uv = vec2((index + 0.5) / ${u}.0, 0.5);
      return sampleTexture(${s}, uv);
    }
  ` : e ? `
      float ${o}(int row, int col) {
        // Explicitly use integer operations as dot() only works on floats.
        int index = row * ${s}Shape[1] + col + ${d};
        vec2 uv = uvFromFlat(${s}TexShape[0], ${s}TexShape[1], index);
        return sampleTexture(${s}, uv);
      }
    ` : `
  float ${o}(int row, int col) {
    // Explicitly use integer operations as dot() only works on floats.
    int index = row * ${t[1]} + col + ${d};
    vec2 uv = uvFromFlat(${l}, ${u}, index);
    return sampleTexture(${s}, uv);
  }
`;
}
function _p(n, e) {
  const t = n.shapeInfo.logicalShape, s = n.name, o = "get" + s.charAt(0).toUpperCase() + s.slice(1), r = n.shapeInfo.texShape, i = [Math.ceil(r[0] / 2), Math.ceil(r[1] / 2)];
  if (t[0] === 1) {
    const h = t.slice(1), f = [1, 2], p = Jt(n, h), x = ["b", "row", "col"];
    return `
        ${ia(p, e)}
        vec4 ${o}(int b, int row, int col) {
          return ${o}(${en(x, f)});
        }
      `;
  }
  const a = le();
  if (e)
    return `
    vec4 ${o}(int b, int row, int col) {
      ivec2 packedTexShape = ivec2(ceil(float(${s}TexShape[0]) / 2.0), ceil(float(${s}TexShape[1]) / 2.0));
      int valuesPerRow = int(ceil(float(${s}Shape[2]) / 2.0));
      int texelsInBatch = valuesPerRow * int(ceil(float(${s}Shape[1]) / 2.0));
      vec2 uv = packedUVfrom3D(
        packedTexShape[0], packedTexShape[1], texelsInBatch, valuesPerRow, b, row, col);
      return ${a.texture2D}(${s}, uv);
    }
  `;
  const c = i[0], l = i[1], u = Math.ceil(t[2] / 2), d = u * Math.ceil(t[1] / 2);
  return `
    vec4 ${o}(int b, int row, int col) {
      vec2 uv = packedUVfrom3D(
        ${c}, ${l}, ${d}, ${u}, b, row, col);
      return ${a.texture2D}(${s}, uv);
    }
  `;
}
function Lp(n, e) {
  const t = n.shapeInfo.logicalShape, s = n.name, o = "get" + s.charAt(0).toUpperCase() + s.slice(1), r = t[1] * t[2], i = t[2], { newShape: a, keptDims: c } = yt(t), l = a;
  if (l.length < t.length) {
    const x = Jt(n, l), g = ["row", "col", "depth"];
    return `
        ${Qt(x, e)}
        float ${o}(int row, int col, int depth) {
          return ${o}(${en(g, c)});
        }
      `;
  }
  if (n.shapeInfo.isUniform)
    return `
      float ${o}(int row, int col, int depth) {
        int index = round(dot(vec3(row, col, depth),
                          vec3(${r}, ${i}, 1)));
        ${Zt(n)}
      }
    `;
  const u = n.shapeInfo.texShape, d = u[0], h = u[1], f = n.shapeInfo.flatOffset;
  if (h === r && f == null)
    return e ? `
      float ${o}(int row, int col, int depth) {
        int stride1 = ${s}Shape[2];
        float texR = float(row);
        float texC = dot(vec2(col, depth), vec2(stride1, 1));
        vec2 uv = (vec2(texC, texR) + halfCR) /
                   vec2(${s}TexShape[1], ${s}TexShape[0]);
        return sampleTexture(${s}, uv);
      }
    ` : `
        float ${o}(int row, int col, int depth) {
          float texR = float(row);
          float texC = dot(vec2(col, depth), vec2(${i}, 1));
          vec2 uv = (vec2(texC, texR) + halfCR) /
                     vec2(${h}.0, ${d}.0);
          return sampleTexture(${s}, uv);
        }
      `;
  if (h === i && f == null)
    return e ? `
      float ${o}(int row, int col, int depth) {
        float texR = dot(vec2(row, col), vec2(${s}Shape[1], 1));
        float texC = float(depth);
        vec2 uv = (vec2(texC, texR) + halfCR) / vec2(${s}TexShape[1], ${s}TexShape[0]);
        return sampleTexture(${s}, uv);
      }
    ` : `
    float ${o}(int row, int col, int depth) {
      float texR = dot(vec2(row, col), vec2(${t[1]}, 1));
      float texC = float(depth);
      vec2 uv = (vec2(texC, texR) + halfCR) / vec2(${h}.0, ${d}.0);
      return sampleTexture(${s}, uv);
    }
  `;
  const p = Tt(s);
  return e ? `
    float ${o}(int row, int col, int depth) {
      // Explicitly use integer operations as dot() only works on floats.
      int stride0 = ${s}Shape[1] * ${s}Shape[2];
      int stride1 = ${s}Shape[2];
      int index = row * stride0 + col * stride1 + depth + ${p};
      vec2 uv = uvFromFlat(${s}TexShape[0], ${s}TexShape[1], index);
      return sampleTexture(${s}, uv);
    }
    ` : `
      float ${o}(int row, int col, int depth) {
        // Explicitly use integer operations as dot() only works on floats.
        int index = row * ${r} + col * ${i} + depth + ${p};
        vec2 uv = uvFromFlat(${d}, ${h}, index);
        return sampleTexture(${s}, uv);
      }
  `;
}
function Bp(n, e) {
  const t = n.name, s = "get" + t.charAt(0).toUpperCase() + t.slice(1), o = le();
  if (e)
    return `
    vec4 ${s}(int b2, int b, int row, int col) {
      int valuesPerRow = int(ceil(float(${t}Shape[3]) / 2.0));
      int texelsInBatch = valuesPerRow * int(ceil(float(${t}Shape[2]) / 2.0));
      int index = b * texelsInBatch + (row / 2) * valuesPerRow + (col / 2);
      texelsInBatch *= ${t}Shape[1];
      index = b2 * texelsInBatch + index;
      ivec2 packedTexShape = ivec2(ceil(float(${t}TexShape[0]) / 2.0), ceil(float(${t}TexShape[1]) / 2.0));
      int texR = index / packedTexShape[1];
      int texC = index - texR * packedTexShape[1];
      vec2 uv = (vec2(texC, texR) + halfCR) / vec2(packedTexShape[1], packedTexShape[0]); return ${o.texture2D}(${t}, uv);
    }
  `;
  const r = n.shapeInfo.logicalShape, i = r.length, a = n.shapeInfo.texShape, c = [Math.ceil(a[0] / 2), Math.ceil(a[1] / 2)], l = c[0], u = c[1], d = Math.ceil(r[i - 1] / 2);
  let h = d * Math.ceil(r[i - 2] / 2), f = "int b, int row, int col", p = `b * ${h} + (row / 2) * ${d} + (col / 2)`;
  for (let x = 2; x < i - 1; x++)
    f = `int b${x}, ` + f, h *= r[i - x - 1], p = `b${x} * ${h} + ` + p;
  return `
    vec4 ${s}(${f}) {
      int index = ${p};
      int texR = index / ${u};
      int texC = index - texR * ${u};
      vec2 uv = (vec2(texC, texR) + halfCR) / vec2(${u}, ${l});
      return ${o.texture2D}(${t}, uv);
    }
  `;
}
function Mp(n, e) {
  const t = n.shapeInfo.logicalShape, s = n.name, o = "get" + s.charAt(0).toUpperCase() + s.slice(1), r = t[3], i = t[2] * r, a = t[1] * i, { newShape: c, keptDims: l } = yt(t);
  if (c.length < t.length) {
    const C = Jt(n, c), b = ["row", "col", "depth", "depth2"];
    return `
      ${Qt(C, e)}
      float ${o}(int row, int col, int depth, int depth2) {
        return ${o}(${en(b, l)});
      }
    `;
  }
  if (n.shapeInfo.isUniform)
    return `
      float ${o}(int row, int col, int depth, int depth2) {
        int index = round(dot(vec4(row, col, depth, depth2),
                          vec4(${a}, ${i}, ${r}, 1)));
        ${Zt(n)}
      }
    `;
  const u = n.shapeInfo.flatOffset, d = n.shapeInfo.texShape, h = d[0], f = d[1], p = `int stride2 = ${s}Shape[3];`, x = `int stride1 = ${s}Shape[2] * stride2;`, g = `int stride0 = ${s}Shape[1] * stride1;`;
  if (f === a && u == null)
    return e ? `
      float ${o}(int row, int col, int depth, int depth2) {
        ${p}
        ${x}
        float texR = float(row);
        float texC =
            dot(vec3(col, depth, depth2),
                vec3(stride1, stride2, 1));
        vec2 uv = (vec2(texC, texR) + halfCR) /
                   vec2(${s}TexShape[1], ${s}TexShape[0]);
        return sampleTexture(${s}, uv);
      }
    ` : `
      float ${o}(int row, int col, int depth, int depth2) {
        float texR = float(row);
        float texC =
            dot(vec3(col, depth, depth2),
                vec3(${i}, ${r}, 1));
        vec2 uv = (vec2(texC, texR) + halfCR) /
                   vec2(${f}.0, ${h}.0);
        return sampleTexture(${s}, uv);
      }
    `;
  if (f === r && u == null)
    return e ? `
      float ${o}(int row, int col, int depth, int depth2) {
        float texR = dot(vec3(row, col, depth),
                         vec3(${s}Shape[1] * ${s}Shape[2], ${s}Shape[2], 1));
        float texC = float(depth2);
        vec2 uv = (vec2(texC, texR) + halfCR) /
                  vec2(${s}TexShape[1], ${s}TexShape[0]);
        return sampleTexture(${s}, uv);
      }
    ` : `
      float ${o}(int row, int col, int depth, int depth2) {
        float texR = dot(vec3(row, col, depth),
                         vec3(${t[1] * t[2]}, ${t[2]}, 1));
        float texC = float(depth2);
        vec2 uv = (vec2(texC, texR) + halfCR) /
                  vec2(${f}.0, ${h}.0);
        return sampleTexture(${s}, uv);
      }
    `;
  const m = Tt(s);
  return e ? `
    float ${o}(int row, int col, int depth, int depth2) {
      // Explicitly use integer operations as dot() only works on floats.
      ${p}
      ${x}
      ${g}
      int index = row * stride0 + col * stride1 +
          depth * stride2 + depth2;
      vec2 uv = uvFromFlat(${s}TexShape[0], ${s}TexShape[1], index + ${m});
      return sampleTexture(${s}, uv);
    }
  ` : `
    float ${o}(int row, int col, int depth, int depth2) {
      // Explicitly use integer operations as dot() only works on floats.
      int index = row * ${a} + col * ${i} +
          depth * ${r} + depth2;
      vec2 uv = uvFromFlat(${h}, ${f}, index + ${m});
      return sampleTexture(${s}, uv);
    }
  `;
}
function Vp(n) {
  const e = n.shapeInfo.logicalShape, t = n.name, s = "get" + t.charAt(0).toUpperCase() + t.slice(1), o = e[4], r = e[3] * o, i = e[2] * r, a = e[1] * i, { newShape: c, keptDims: l } = yt(e);
  if (c.length < e.length) {
    const x = Jt(n, c), g = ["row", "col", "depth", "depth2", "depth3"];
    return `
      ${Qt(x)}
      float ${s}(int row, int col, int depth, int depth2, int depth3) {
        return ${s}(${en(g, l)});
      }
    `;
  }
  if (n.shapeInfo.isUniform)
    return `
      float ${s}(int row, int col, int depth, int depth2, int depth3) {
        float index = dot(
          vec4(row, col, depth, depth2),
          vec4(${a}, ${i}, ${r}, ${o})) +
          depth3;
        ${Zt(n)}
      }
    `;
  const u = n.shapeInfo.flatOffset, d = n.shapeInfo.texShape, h = d[0], f = d[1];
  if (f === a && u == null)
    return `
      float ${s}(int row, int col, int depth, int depth2, int depth3) {
        int texR = row;
        float texC = dot(vec4(col, depth, depth2, depth3),
                         vec4(${i}, ${r}, ${o}, 1));
        vec2 uv = (vec2(texC, texR) + halfCR) /
                   vec2(${f}.0, ${h}.0);
        return sampleTexture(${t}, uv);
      }
    `;
  if (f === o && u == null)
    return `
      float ${s}(int row, int col, int depth, int depth2, int depth3) {
        float texR = dot(
          vec4(row, col, depth, depth2),
          vec4(${e[1] * e[2] * e[3]},
               ${e[2] * e[3]}, ${e[3]}, 1));
        int texC = depth3;
        vec2 uv = (vec2(texC, texR) + halfCR) /
                  vec2(${f}.0, ${h}.0);
        return sampleTexture(${t}, uv);
      }
    `;
  const p = Tt(t);
  return `
    float ${s}(int row, int col, int depth, int depth2, int depth3) {
      // Explicitly use integer operations as dot() only works on floats.
      int index = row * ${a} + col * ${i} + depth * ${r} +
          depth2 * ${o} + depth3 + ${p};
      vec2 uv = uvFromFlat(${h}, ${f}, index);
      return sampleTexture(${t}, uv);
    }
  `;
}
function Up(n) {
  const e = n.shapeInfo.logicalShape, t = n.name, s = "get" + t.charAt(0).toUpperCase() + t.slice(1), { newShape: o, keptDims: r } = yt(e);
  if (o.length < e.length) {
    const g = Jt(n, o), m = ["row", "col", "depth", "depth2", "depth3", "depth4"];
    return `
      ${Qt(g)}
      float ${s}(int row, int col, int depth,
                    int depth2, int depth3, int depth4) {
        return ${s}(${en(m, r)});
      }
    `;
  }
  const i = e[5], a = e[4] * i, c = e[3] * a, l = e[2] * c, u = e[1] * l;
  if (n.shapeInfo.isUniform)
    return `
      float ${s}(int row, int col, int depth,
                  int depth2, int depth3, int depth4) {
        int index = round(dot(
          vec4(row, col, depth, depth2),
          vec4(${u}, ${l}, ${c}, ${a})) +
          dot(
            vec2(depth3, depth4),
            vec2(${i}, 1)));
        ${Zt(n)}
      }
    `;
  const d = n.shapeInfo.flatOffset, h = n.shapeInfo.texShape, f = h[0], p = h[1];
  if (p === u && d == null)
    return `
      float ${s}(int row, int col, int depth,
                    int depth2, int depth3, int depth4) {
        int texR = row;
        float texC = dot(vec4(col, depth, depth2, depth3),
          vec4(${l}, ${c}, ${a}, ${i})) +
               float(depth4);
        vec2 uv = (vec2(texC, texR) + halfCR) /
                   vec2(${p}.0, ${f}.0);
        return sampleTexture(${t}, uv);
      }
    `;
  if (p === i && d == null)
    return `
      float ${s}(int row, int col, int depth,
                    int depth2, int depth3, int depth4) {
        float texR = dot(vec4(row, col, depth, depth2),
          vec4(${e[1] * e[2] * e[3] * e[4]},
               ${e[2] * e[3] * e[4]},
               ${e[3] * e[4]},
               ${e[4]})) + float(depth3);
        int texC = depth4;
        vec2 uv = (vec2(texC, texR) + halfCR) /
                  vec2(${p}.0, ${f}.0);
        return sampleTexture(${t}, uv);
      }
    `;
  const x = Tt(t);
  return `
    float ${s}(int row, int col, int depth,
                  int depth2, int depth3, int depth4) {
      // Explicitly use integer operations as dot() only works on floats.
      int index = row * ${u} + col * ${l} + depth * ${c} +
          depth2 * ${a} + depth3 * ${i} + depth4 + ${x};
      vec2 uv = uvFromFlat(${f}, ${p}, index);
      return sampleTexture(${t}, uv);
    }
  `;
}
function Zt(n) {
  const e = n.name, t = T(n.shapeInfo.logicalShape);
  return t < 2 ? `return ${e};` : `
    for (int i = 0; i < ${t}; i++) {
      if (i == index) {
        return ${e}[i];
      }
    }
  `;
}
function Wp(n, e) {
  const t = n.name, s = t.charAt(0).toUpperCase() + t.slice(1), o = "get" + s + "AtOutCoords", r = n.shapeInfo.logicalShape.length, i = e.logicalShape.length, a = ra(n.shapeInfo.logicalShape, e.logicalShape), c = V(i), l = i - r;
  let u;
  const d = ["x", "y", "z", "w", "u", "v"];
  r === 0 ? u = "" : i < 2 && a.length >= 1 ? u = "coords = 0;" : u = a.map((C) => `coords.${d[C + l]} = 0;`).join(`
`);
  let h = "";
  i < 2 && r > 0 ? h = "coords" : h = n.shapeInfo.logicalShape.map((C, b) => `coords.${d[b + l]}`).join(", ");
  let f = "return outputValue;";
  const x = T(n.shapeInfo.logicalShape) === 1, m = T(e.logicalShape) === 1;
  if (r === 1 && !x && !m)
    f = `
      return vec4(outputValue.xy, outputValue.xy);
    `;
  else if (x && !m)
    i === 1 ? f = `
        return vec4(outputValue.x, outputValue.x, 0., 0.);
      ` : f = `
        return vec4(outputValue.x);
      `;
  else if (a.length) {
    const C = r - 2, b = r - 1;
    a.indexOf(C) > -1 && a.indexOf(b) > -1 ? f = "return vec4(outputValue.x);" : a.indexOf(C) > -1 ? f = "return vec4(outputValue.x, outputValue.y, outputValue.x, outputValue.y);" : a.indexOf(b) > -1 && (f = "return vec4(outputValue.xx, outputValue.zz);");
  }
  return `
    vec4 ${o}() {
      ${c} coords = getOutputCoords();
      ${u}
      vec4 outputValue = get${s}(${h});
      ${f}
    }
  `;
}
function Gp(n, e) {
  const t = n.name, s = t.charAt(0).toUpperCase() + t.slice(1), o = "get" + s + "AtOutCoords", r = e.texShape, i = n.shapeInfo.texShape, a = n.shapeInfo.logicalShape.length, c = e.logicalShape.length;
  if (!n.shapeInfo.isUniform && a === c && n.shapeInfo.flatOffset == null && Z(i, r))
    return `
      float ${o}() {
        return sampleTexture(${t}, resultUV);
      }
    `;
  const l = V(c), u = ra(n.shapeInfo.logicalShape, e.logicalShape), d = c - a;
  let h;
  const f = ["x", "y", "z", "w", "u", "v"];
  a === 0 ? h = "" : c < 2 && u.length >= 1 ? h = "coords = 0;" : h = u.map((x) => `coords.${f[x + d]} = 0;`).join(`
`);
  let p = "";
  return c < 2 && a > 0 ? p = "coords" : p = n.shapeInfo.logicalShape.map((x, g) => `coords.${f[g + d]}`).join(", "), `
    float ${o}() {
      ${l} coords = getOutputCoords();
      ${h}
      return get${s}(${p});
    }
  `;
}
function V(n) {
  if (n <= 1)
    return "int";
  if (n === 2)
    return "ivec2";
  if (n === 3)
    return "ivec3";
  if (n === 4)
    return "ivec4";
  if (n === 5)
    return "ivec5";
  if (n === 6)
    return "ivec6";
  throw Error(`GPU for rank ${n} is not yet supported`);
}
function ho(n, e, t) {
  const { newShape: s, keptDims: o } = yt(e), r = e.length, i = n && r === 3 && e[0] === 1, a = i ? e.slice(1) : s, c = !n && r > 1 && !Z(e, t) && s.length < r || i;
  return { useSqueezeShape: c, uniformShape: c ? a : e, keptDims: o };
}
function Jt(n, e) {
  const t = JSON.parse(JSON.stringify(n));
  return t.shapeInfo.logicalShape = e, t;
}
function en(n, e) {
  return e.map((t) => n[t]).join(", ");
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function zp(n, e, t, s) {
  const o = t.map((u, d) => {
    const h = {
      logicalShape: u.shape,
      texShape: u.isUniform ? null : u.texData.texShape,
      isUniform: u.isUniform,
      isPacked: u.isUniform ? !1 : u.texData.isPacked,
      flatOffset: null
    };
    return u.texData != null && u.texData.slice != null && u.texData.slice.flatOffset > 0 && (h.flatOffset = u.texData.slice.flatOffset), { name: e.variableNames[d], shapeInfo: h };
  }), r = o.map((u) => u.shapeInfo), i = {
    logicalShape: s.shape,
    texShape: s.texData.texShape,
    isUniform: !1,
    isPacked: s.texData.isPacked,
    flatOffset: null
  }, a = cp(o, i, e), c = Lf(n.gl, a), l = n.createProgram(c);
  return y().get("ENGINE_COMPILE_ONLY") ? {
    program: e,
    fragmentShader: c,
    source: a,
    webGLProgram: l,
    inShapeInfos: r,
    outShapeInfo: i,
    variablesLocations: null,
    customUniformLocations: null,
    infLoc: null,
    nanLoc: null,
    outShapeLocation: null,
    outShapeStridesLocation: null,
    outTexShapeLocation: null
  } : (n.buildVao(l), Object.assign({
    program: e,
    fragmentShader: c,
    source: a,
    webGLProgram: l,
    inShapeInfos: r,
    outShapeInfo: i
  }, ca(n, e, l)));
}
function ca(n, e, t) {
  const s = [], o = [];
  let r, i, a, c = null, l = null;
  l = n.getUniformLocation(t, "NAN", !1), y().getNumber("WEBGL_VERSION") === 1 && (c = n.getUniformLocation(t, "INFINITY", !1));
  const u = !1;
  for (const d of e.variableNames) {
    const h = {
      name: d,
      uniform: n.getUniformLocation(t, d, u),
      offset: n.getUniformLocation(t, `offset${d}`, u)
    };
    e.enableShapeUniforms && (h.shape = n.getUniformLocation(t, `${d}Shape`, u), h.texShape = n.getUniformLocation(t, `${d}TexShape`, u)), s.push(h);
  }
  if (e.enableShapeUniforms && (r = n.getUniformLocation(t, "outShape", u), a = n.getUniformLocation(t, "outShapeStrides", u), i = n.getUniformLocation(t, "outTexShape", u)), e.customUniforms)
    for (const d of e.customUniforms)
      o.push(n.getUniformLocation(t, d.name, u));
  return {
    variablesLocations: s,
    customUniformLocations: o,
    infLoc: c,
    nanLoc: l,
    outShapeLocation: r,
    outShapeStridesLocation: a,
    outTexShapeLocation: i
  };
}
function jo(n, e) {
  if (n.length !== e.length)
    throw Error(`Binary was compiled with ${n.length} inputs, but was executed with ${e.length} inputs`);
  n.forEach((t, s) => {
    const o = t.logicalShape, r = e[s], i = r.shape;
    if (!Z(o, i))
      throw Error(`Binary was compiled with different shapes than the current args. Shapes ${o} and ${i} must match`);
    if (t.isUniform && r.isUniform)
      return;
    const a = t.texShape, c = r.isUniform ? null : r.texData.texShape;
    if (!Z(a, c))
      throw Error(`Binary was compiled with different texture shapes than the current args. Shape ${a} and ${c} must match`);
  });
}
function Hp(n, e, t, s, o) {
  e.program.enableShapeUniforms || (jo(e.inShapeInfos, t), jo([e.outShapeInfo], [s]));
  const r = s.texData.texture, i = s.texData.texShape;
  s.texData.isPacked ? n.setOutputPackedMatrixTexture(r.texture, i[0], i[1]) : n.setOutputMatrixTexture(r.texture, i[0], i[1]), n.setProgram(e.webGLProgram), n.bindVertexArray(e.webGLProgram.vao), y().getNumber("WEBGL_VERSION") === 1 && e.infLoc !== null && n.gl.uniform1f(e.infLoc, 1 / 0), e.nanLoc !== null && n.gl.uniform1f(e.nanLoc, NaN);
  for (let c = 0; c < t.length; ++c) {
    const l = t[c], { uniform: u, offset: d, shape: h, texShape: f } = e.variablesLocations[c];
    if (h) {
      const { uniformShape: p } = ho(e.program.packedInputs, l.shape, l.texData.texShape);
      switch (p.length) {
        case 1:
          n.gl.uniform1iv(h, new Int32Array(p));
          break;
        case 2:
          n.gl.uniform2iv(h, new Int32Array(p));
          break;
        case 3:
          n.gl.uniform3iv(h, new Int32Array(p));
          break;
        case 4:
          n.gl.uniform4iv(h, new Int32Array(p));
          break;
      }
    }
    if (f && n.gl.uniform2i(f, l.texData.texShape[0], l.texData.texShape[1]), u != null) {
      if (l.isUniform) {
        if (T(l.shape) < 2)
          n.gl.uniform1f(u, l.uniformValues[0]);
        else {
          let p = l.uniformValues;
          p instanceof Float32Array || (p = new Float32Array(p)), n.gl.uniform1fv(u, p);
        }
        continue;
      }
      l.texData.slice != null && d != null && n.gl.uniform1i(d, l.texData.slice.flatOffset), n.setInputMatrixTexture(l.texData.texture.texture, u, c);
    }
  }
  const a = e.outShapeLocation;
  if (a)
    switch (s.shape.length) {
      case 1:
        n.gl.uniform1iv(a, new Int32Array(s.shape));
        break;
      case 2:
        n.gl.uniform2iv(a, new Int32Array(s.shape));
        break;
      case 3:
        n.gl.uniform3iv(a, new Int32Array(s.shape));
        break;
      case 4:
        n.gl.uniform4iv(a, new Int32Array(s.shape));
        break;
    }
  if (e.outShapeStridesLocation) {
    const c = Q(s.shape);
    switch (s.shape.length) {
      case 2:
        n.gl.uniform1iv(e.outShapeStridesLocation, new Int32Array(c));
        break;
      case 3:
        n.gl.uniform2iv(e.outShapeStridesLocation, new Int32Array(c));
        break;
      case 4:
        n.gl.uniform3iv(e.outShapeStridesLocation, new Int32Array(c));
        break;
    }
  }
  if (e.outTexShapeLocation && n.gl.uniform2i(e.outTexShapeLocation, s.texData.texShape[0], s.texData.texShape[1]), e.program.customUniforms && o)
    for (let c = 0; c < e.program.customUniforms.length; ++c) {
      const l = e.program.customUniforms[c], u = e.customUniformLocations[c], d = o[c];
      if (l.type === "float")
        n.gl.uniform1fv(u, d);
      else if (l.type === "vec2")
        n.gl.uniform2fv(u, d);
      else if (l.type === "vec3")
        n.gl.uniform3fv(u, d);
      else if (l.type === "vec4")
        n.gl.uniform4fv(u, d);
      else if (l.type === "int")
        n.gl.uniform1iv(u, d);
      else if (l.type === "ivec2")
        n.gl.uniform2iv(u, d);
      else if (l.type === "ivec3")
        n.gl.uniform3iv(u, d);
      else if (l.type === "ivec4")
        n.gl.uniform4iv(u, d);
      else
        throw Error(`uniform type ${l.type} is not supported yet.`);
    }
  n.executeProgram();
}
function Xp(n, e, t) {
  let s = "";
  e.concat(t).forEach((i) => {
    const a = i.texData != null && i.texData.slice != null && i.texData.slice.flatOffset > 0;
    if (n.enableShapeUniforms && !i.isUniform) {
      const c = i.texData.texShape, { useSqueezeShape: l, uniformShape: u, keptDims: d } = ho(n.packedInputs, i.shape, c);
      let h = "", f = "", p = "";
      if (u.length === 1 && n.packedInputs) {
        const v = [Math.ceil(c[0] / 2), Math.ceil(c[1] / 2)];
        h = `${v[0] > 1}_${v[1] > 1}`;
      } else if (u.length === 2 && !n.packedInputs)
        f = `${u[0] > 1}_${u[1] > 1}`;
      else if (u.length > 2 && !n.packedInputs) {
        const v = Q(u);
        p = `${v[0] === c[1]}_${v[v.length - 1] === c[1]}`;
      }
      const x = i.shape.length, g = u.length === 2 && Z(i.shape, c), m = T(i.shape) === 1, C = Gn(i.shape, t.shape), b = !n.packedInputs && x === t.shape.length && Z(c, t.texData.texShape), w = n.packedInputs || u.length > 2 ? "" : `${c[0] > 1}_${c[1] > 1}`;
      s += `${x}_${b}_${l ? d : ""}_${u.length}_${m}_${C}_${g}_${h}_${f}_${p}_${w}_${a}`;
    } else {
      const c = i.isUniform ? "uniform" : i.texData.texShape;
      s += `${i.shape}_${c}_${a}`;
    }
  });
  const o = n.userCode;
  let r = n.constructor.name;
  return r += "_" + s + "_" + o + `${y().getNumber("WEBGL_VERSION")}`, r;
}
function ne(n) {
  return y().getBool("WEBGL_USE_SHAPES_UNIFORMS") && n <= 4;
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class qp {
  constructor(e) {
    this.variableNames = ["A"], this.packedInputs = !1, this.packedOutput = !0, this.outPackingScheme = hn.DENSE, this.customUniforms = [{ name: "texShape", type: "ivec2" }];
    const t = le();
    this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length), this.userCode = `
      ivec3 outCoordsFromFlatIndex(int index) {
        ${this.enableShapeUniforms ? ts(["r", "c", "d"], e) : Rt(["r", "c", "d"], e)}
        return ivec3(r, c, d);
      }

      void main() {
        ivec2 resTexRC = ivec2(resultUV.yx * vec2(texShape[0], texShape[1]));
        int index = 4 * (resTexRC.x * texShape[1] + resTexRC.y);

        vec4 result = vec4(0.);

        for (int i=0; i<4; i++) {
          int flatIndex = index + i;
          ivec3 rc = outCoordsFromFlatIndex(flatIndex);
          result[i] = getA(rc.x, rc.y, rc.z);
        }

        ${t.output} = result;
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class jp {
  constructor(e) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0, this.outPackingScheme = hn.DENSE, this.customUniforms = [{ name: "texShape", type: "ivec2" }];
    const t = le();
    this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length), this.userCode = `
      ivec3 outCoordsFromFlatIndex(int index) {
        ${this.enableShapeUniforms ? ts(["r", "c", "d"], e) : Rt(["r", "c", "d"], e)}
        return ivec3(r, c, d);
      }

      void main() {
        ivec2 resTexRC = ivec2(resultUV.yx * vec2(texShape[0], texShape[1]));
        int index = 4 * (resTexRC.x * texShape[1] + resTexRC.y);

        vec4 result = vec4(0.);

        for (int i=0; i<4; i++) {
          int flatIndex = index + i;
          ivec3 rc = outCoordsFromFlatIndex(flatIndex);
          result[i] = getChannel(getA(rc.x, rc.y, rc.z), vec2(rc.y, rc.z));
        }

        ${t.output} = result;
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Kp {
  constructor(e) {
    this.variableNames = ["A"], this.outTexUsage = xe.DOWNLOAD;
    const t = le();
    this.outputShape = e, this.userCode = `
      ${oa}

      void main() {
        float x = getAAtOutCoords();
        ${t.output} = encode_float(x);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Yp {
  constructor(e) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !1, this.outTexUsage = xe.DOWNLOAD;
    const t = le();
    this.outputShape = e, this.userCode = `
      ${oa}

      void main() {
        ivec3 coords = getOutputCoords();
        float x = getChannel(getAAtOutCoords(), vec2(coords.y, coords.z));
        ${t.output} = encode_float(x);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Qp = {
  R: 0,
  G: 1,
  B: 2,
  A: 3
};
class Ko {
  constructor(e, t = !1, s = "RGBA") {
    this.variableNames = ["A"], this.customUniforms = [{ name: "texShape", type: "ivec2" }];
    const o = le();
    this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length);
    let r = "result";
    t && (r = "floor(result * 255. + 0.5)");
    let i = "";
    for (let a = 0; a < s.length; a++) {
      const c = s[a];
      i += `
          if(offset == ${a}) {
            result = values[${Qp[c]}];
          }`;
    }
    this.userCode = `
      ${this.enableShapeUniforms ? uo() : lo(e)}

      void main() {
        ivec3 coords = getOutputCoords();
        int flatIndex = getFlatIndex(coords);
        float result = 0.;
        int offset = imod(flatIndex, ${s.length});

        flatIndex = idiv(flatIndex, ${s.length}, 1.);

        int r = flatIndex / texShape[1];
        if (r < texShape[0]) {
          int c = imod(flatIndex, texShape[1]);
          vec2 uv = (vec2(c, r) + halfCR) / vec2(texShape[1], texShape[0]);
          vec4 values = ${o.texture2D}(A, uv);
          ${i}
        }
        ${o.output} = vec4(${r}, 0., 0., 0.);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Zp {
  constructor(e, t = !1) {
    this.variableNames = ["A"], this.packedInputs = !1, this.packedOutput = !0, this.customUniforms = [{ name: "texShape", type: "ivec2" }];
    const s = le();
    this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length);
    let o = "", r = "result";
    t && (r = "floor(result * 255. + 0.5)");
    for (let i = 0; i <= 1; i++)
      for (let a = 0; a <= 1; a++) {
        const c = i * 2 + a;
        o += `
          localCoords = coords;
          if(localCoords[2] + ${a} < ${this.enableShapeUniforms ? "outShape[2]" : `${e[2]}`}) {
          localCoords[2] += ${a};
          if (localCoords[1] + ${i} < ${this.enableShapeUniforms ? "outShape[1]" : `${e[1]}`}) {
            localCoords[1] += ${i};

            flatIndex = getFlatIndex(localCoords);
            offset = imod(flatIndex, 4);

            flatIndex = idiv(flatIndex, 4, 1.);

            int r = flatIndex / texShape[1];
            int c = imod(flatIndex, texShape[1]);
            vec2 uv = (vec2(c, r) + halfCR) / vec2(texShape[1], texShape[0]);
            values = ${s.texture2D}(A, uv);

            if (offset == 0) {
              result[${c}] = values[0];
            } else if (offset == 1) {
              result[${c}] = values[1];
            } else if (offset == 2) {
              result[${c}] = values[2];
            } else {
              result[${c}] = values[3];
            }
          }
        }
        `;
      }
    this.userCode = `
        ${this.enableShapeUniforms ? uo() : lo(e)}

        void main() {
          ivec3 coords = getOutputCoords();

          vec4 result = vec4(0.);
          int flatIndex, r, c, offset;
          ivec3 localCoords;
          vec2 uv;
          vec4 values;

          ${o}

          ${s.output} = ${r};
        }
    `;
  }
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Jp(n) {
  const e = le(), t = `${e.version}
    precision highp float;
    ${e.attribute} vec3 clipSpacePos;
    ${e.attribute} vec2 uv;
    ${e.varyingVs} vec2 resultUV;

    void main() {
      gl_Position = vec4(clipSpacePos, 1);
      resultUV = uv;
    }`;
  return _f(n, t);
}
function em(n) {
  const e = new Float32Array([-1, 1, 0, 0, 1, -1, -1, 0, 0, 0, 1, 1, 0, 1, 1, 1, -1, 0, 1, 0]);
  return Uf(n, e);
}
function tm(n) {
  const e = new Uint16Array([0, 1, 2, 2, 1, 3]);
  return Wf(n, e);
}
function vn(n, e, t, s, o, r) {
  zf(e, t);
  const i = Gf(n), a = n.TEXTURE_2D;
  return k(n, () => n.bindTexture(a, i)), k(n, () => n.texParameteri(a, n.TEXTURE_WRAP_S, n.CLAMP_TO_EDGE)), k(n, () => n.texParameteri(a, n.TEXTURE_WRAP_T, n.CLAMP_TO_EDGE)), k(n, () => n.texParameteri(a, n.TEXTURE_MIN_FILTER, n.NEAREST)), k(n, () => n.texParameteri(a, n.TEXTURE_MAG_FILTER, n.NEAREST)), y().getNumber("WEBGL_VERSION") === 1 ? k(n, () => n.texImage2D(a, 0, s, e, t, 0, o, r, null)) : k(n, () => n.texStorage2D(a, 1, s, e, t)), k(n, () => n.bindTexture(n.TEXTURE_2D, null)), { texture: i, texShape: [t, e] };
}
function la(n) {
  return n.internalFormatFloat;
}
function nm(n, e, t, s) {
  const [o, r] = wn(e, t);
  return vn(n, o, r, la(s), s.textureFormatFloat, n.FLOAT);
}
function ua(n) {
  return n.internalFormatHalfFloat;
}
function sm(n, e, t, s) {
  const [o, r] = wn(e, t);
  return vn(n, o, r, ua(s), s.textureFormatFloat, s.textureTypeHalfFloat);
}
function da(n) {
  return n.downloadTextureFormat;
}
function om(n, e, t, s) {
  const [o, r] = wn(e, t);
  return vn(n, o, r, da(s), n.RGBA, n.UNSIGNED_BYTE);
}
function ha(n) {
  return n.internalFormatPackedFloat;
}
function rm(n, e, t, s) {
  const [o, r] = Yt(e, t);
  return vn(n, o, r, ha(s), n.RGBA, n.FLOAT);
}
function fa(n) {
  return n.internalFormatPackedHalfFloat;
}
function im(n, e, t, s) {
  const [o, r] = Yt(e, t);
  return vn(n, o, r, fa(s), n.RGBA, s.textureTypeHalfFloat);
}
function am(n, e, t) {
  return k(n, () => n.bindBuffer(n.ARRAY_BUFFER, t)), Ho(n, e, "clipSpacePos", t, 3, 20, 0) && Ho(n, e, "uv", t, 2, 20, 12);
}
function cm(n, e, t, s, o, r) {
  k(n, () => n.bindTexture(n.TEXTURE_2D, e));
  let i, a, c;
  o instanceof Uint8Array ? (i = new Uint8Array(t * s * 4), a = n.UNSIGNED_BYTE, c = n.RGBA) : (i = new Float32Array(t * s * 4), a = n.FLOAT, c = r.internalFormatPackedFloat), i.set(o), y().getNumber("WEBGL_VERSION") === 2 ? k(n, () => n.texSubImage2D(n.TEXTURE_2D, 0, 0, 0, t, s, n.RGBA, a, i)) : k(n, () => n.texImage2D(n.TEXTURE_2D, 0, c, t, s, 0, n.RGBA, a, i)), k(n, () => n.bindTexture(n.TEXTURE_2D, null));
}
function lm(n, e, t) {
  k(n, () => n.bindTexture(n.TEXTURE_2D, e)), t.data instanceof Uint8Array ? y().getNumber("WEBGL_VERSION") === 2 ? k(n, () => n.texSubImage2D(n.TEXTURE_2D, 0, 0, 0, t.width, t.height, n.RGBA, n.UNSIGNED_BYTE, t.data)) : k(n, () => n.texImage2D(n.TEXTURE_2D, 0, n.RGBA, t.width, t.height, 0, n.RGBA, n.UNSIGNED_BYTE, t.data)) : y().getNumber("WEBGL_VERSION") === 2 ? k(n, () => n.texSubImage2D(n.TEXTURE_2D, 0, 0, 0, n.RGBA, n.UNSIGNED_BYTE, t)) : k(n, () => n.texImage2D(n.TEXTURE_2D, 0, n.RGBA, n.RGBA, n.UNSIGNED_BYTE, t)), k(n, () => n.bindTexture(n.TEXTURE_2D, null));
}
function um(n, e, t, s) {
  const o = n.createBuffer();
  k(n, () => n.bindBuffer(n.PIXEL_PACK_BUFFER, o));
  const a = 4 * 4 * e * t;
  return k(n, () => n.bufferData(n.PIXEL_PACK_BUFFER, a, n.STREAM_READ)), k(n, () => n.readPixels(0, 0, t, e, n.RGBA, n.FLOAT, 0)), k(n, () => n.bindBuffer(n.PIXEL_PACK_BUFFER, null)), o;
}
function dm(n, e, t) {
  const s = n, o = new Float32Array(t);
  return s.bindBuffer(s.PIXEL_PACK_BUFFER, e), s.getBufferSubData(s.PIXEL_PACK_BUFFER, 0, o), s.bindBuffer(s.PIXEL_PACK_BUFFER, null), o;
}
function hm(n, e, t, s) {
  const [o, r] = wn(e, t), i = 4, a = new Uint8Array(Nf(e * t, i));
  return k(n, () => n.readPixels(0, 0, o, r, s.downloadTextureFormat, n.UNSIGNED_BYTE, a)), new Float32Array(a.buffer);
}
function fm(n, e, t, s, o, r, i, a) {
  const c = n, l = new Float32Array(kf(r, i));
  return c.bindBuffer(c.PIXEL_PACK_BUFFER, e), c.getBufferSubData(c.PIXEL_PACK_BUFFER, 0, l), c.bindBuffer(c.PIXEL_PACK_BUFFER, null), l;
}
function pm(n, e, t) {
  const s = new Float32Array(e * t * 4);
  return k(n, () => n.readPixels(0, 0, t, e, n.RGBA, n.FLOAT, s)), s;
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class xs {
  constructor(e) {
    this.outputTexture = null, this.program = null, this.disposed = !1, this.itemsToPoll = [];
    const t = y().getNumber("WEBGL_VERSION");
    if (e != null ? (this.gl = e, Rf(t, e)) : this.gl = _e(t), e = this.gl, y().getNumber("WEBGL_VERSION") === 2) {
      const r = e;
      this.createVertexArray = () => k(r, () => r.createVertexArray()), this.bindVertexArray = (i) => k(r, () => r.bindVertexArray(i)), this.deleteVertexArray = (i) => k(r, () => r.deleteVertexArray(i)), this.getVertexArray = () => k(r, () => r.getParameter(r.VERTEX_ARRAY_BINDING));
    } else if (e != null) {
      const r = e.getExtension("OES_vertex_array_object");
      if (r == null)
        throw new Error("All WebGL1 implementations are expected to offer OES_vertex_array_object.");
      this.createVertexArray = () => k(e, () => r.createVertexArrayOES()), this.bindVertexArray = (i) => k(e, () => r.bindVertexArrayOES(i)), this.deleteVertexArray = (i) => k(e, () => r.deleteVertexArrayOES(i)), this.getVertexArray = () => k(e, () => e.getParameter(r.VERTEX_ARRAY_BINDING_OES));
    }
    let s = "WEBGL_color_buffer_float";
    const o = "EXT_color_buffer_half_float";
    if (this.parallelCompilationExtension = this.gl.getExtension("KHR_parallel_shader_compile"), y().getNumber("WEBGL_VERSION") === 1) {
      const r = "OES_texture_float", i = "OES_texture_half_float";
      if (this.textureFloatExtension = Nn(this.gl, r), Re(this.gl, i))
        this.textureHalfFloatExtension = Nn(this.gl, i);
      else if (y().get("WEBGL_FORCE_F16_TEXTURES"))
        throw new Error("GL context does not support half float textures, yet the environment flag WEBGL_FORCE_F16_TEXTURES is set to true.");
      if (this.colorBufferFloatExtension = this.gl.getExtension(s), Re(this.gl, o))
        this.colorBufferHalfFloatExtension = Nn(this.gl, o);
      else if (y().get("WEBGL_FORCE_F16_TEXTURES"))
        throw new Error("GL context does not support color renderable half floats, yet the environment flag WEBGL_FORCE_F16_TEXTURES is set to true.");
    } else if (s = "EXT_color_buffer_float", Re(this.gl, s))
      this.colorBufferFloatExtension = this.gl.getExtension(s);
    else if (Re(this.gl, o))
      this.colorBufferHalfFloatExtension = this.gl.getExtension(o);
    else
      throw new Error("GL context does not support color renderable floats");
    this.vertexBuffer = em(this.gl), this.indexBuffer = tm(this.gl), this.framebuffer = Hf(this.gl), this.textureConfig = co(this.gl, this.textureHalfFloatExtension);
  }
  get debug() {
    return y().getBool("DEBUG");
  }
  dispose() {
    if (this.disposed)
      return;
    this.program != null && console.warn("Disposing a GPGPUContext that still has a bound WebGLProgram. This is probably a resource leak, delete the program with GPGPUContext.deleteProgram before disposing."), this.outputTexture != null && console.warn("Disposing a GPGPUContext that still has a bound output matrix texture.  This is probably a resource leak, delete the output matrix texture with GPGPUContext.deleteMatrixTexture before disposing.");
    const e = this.gl;
    k(e, () => e.finish()), k(e, () => e.bindFramebuffer(e.FRAMEBUFFER, null)), k(e, () => e.deleteFramebuffer(this.framebuffer)), k(e, () => e.bindBuffer(e.ARRAY_BUFFER, null)), k(e, () => e.bindBuffer(e.ELEMENT_ARRAY_BUFFER, null)), k(e, () => e.deleteBuffer(this.indexBuffer)), this.disposed = !0;
  }
  createFloat32MatrixTexture(e, t) {
    return this.throwIfDisposed(), nm(this.gl, e, t, this.textureConfig);
  }
  createFloat16MatrixTexture(e, t) {
    return this.throwIfDisposed(), sm(this.gl, e, t, this.textureConfig);
  }
  createUnsignedBytesMatrixTexture(e, t) {
    return this.throwIfDisposed(), om(this.gl, e, t, this.textureConfig);
  }
  uploadPixelDataToTexture(e, t) {
    this.throwIfDisposed(), lm(this.gl, e, t);
  }
  uploadDenseMatrixToTexture(e, t, s, o) {
    this.throwIfDisposed(), cm(this.gl, e, t, s, o, this.textureConfig);
  }
  createFloat16PackedMatrixTexture(e, t) {
    return this.throwIfDisposed(), im(this.gl, e, t, this.textureConfig);
  }
  createPackedMatrixTexture(e, t) {
    return this.throwIfDisposed(), rm(this.gl, e, t, this.textureConfig);
  }
  deleteMatrixTexture(e) {
    this.throwIfDisposed(), this.outputTexture === e && (Xo(this.gl, this.framebuffer), this.outputTexture = null), k(this.gl, () => this.gl.deleteTexture(e));
  }
  downloadByteEncodedFloatMatrixFromOutputTexture(e, t, s) {
    return this.downloadMatrixDriver(e, () => hm(this.gl, t, s, this.textureConfig));
  }
  downloadPackedMatrixFromBuffer(e, t, s, o, r, i) {
    return fm(this.gl, e, t, s, o, r, i, this.textureConfig);
  }
  downloadFloat32MatrixFromBuffer(e, t) {
    return dm(this.gl, e, t);
  }
  createBufferFromTexture(e, t, s) {
    this.bindTextureToFrameBuffer(e);
    const o = um(this.gl, t, s, this.textureConfig);
    return this.unbindTextureToFrameBuffer(), o;
  }
  createAndWaitForFence() {
    const e = this.createFence(this.gl);
    return this.pollFence(e);
  }
  createFence(e) {
    let t, s;
    if (y().getBool("WEBGL_FENCE_API_ENABLED")) {
      const o = e, r = o.fenceSync(o.SYNC_GPU_COMMANDS_COMPLETE, 0);
      e.flush(), s = () => {
        const i = o.clientWaitSync(r, 0, 0);
        return i === o.ALREADY_SIGNALED || i === o.CONDITION_SATISFIED;
      }, t = r;
    } else y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION") > 0 ? (t = this.beginQuery(), this.endQuery(), s = () => this.isQueryAvailable(t, y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION"))) : s = () => !0;
    return { query: t, isFencePassed: s };
  }
  downloadMatrixFromPackedTexture(e, t, s) {
    return this.downloadMatrixDriver(e, () => pm(this.gl, t, s));
  }
  createProgram(e) {
    this.throwIfDisposed();
    const t = this.gl;
    this.vertexShader == null && (this.vertexShader = Jp(t));
    const s = Mf(t);
    k(t, () => t.attachShader(s, this.vertexShader)), k(t, () => t.attachShader(s, e)), Vf(t, s);
    const o = Object.assign(s, { vao: this.createVertexArray() });
    return this.debug && fs(t, o), o;
  }
  buildVao(e) {
    this.setProgram(e), this.bindVertexArray(e.vao);
    const t = this.gl;
    k(t, () => t.bindBuffer(t.ELEMENT_ARRAY_BUFFER, this.indexBuffer)), am(t, e, this.vertexBuffer);
  }
  deleteProgram(e) {
    this.throwIfDisposed(), e === this.program && (this.program = null), e != null && (k(this.gl, () => this.gl.deleteProgram(e)), this.deleteVertexArray(e.vao));
  }
  setProgram(e) {
    this.throwIfDisposed(), this.program = e, this.program != null && this.debug && fs(this.gl, this.program), k(this.gl, () => this.gl.useProgram(e));
  }
  getUniformLocation(e, t, s = !0) {
    return this.throwIfDisposed(), s ? qf(this.gl, e, t) : jf(this.gl, e, t);
  }
  getAttributeLocation(e, t) {
    return this.throwIfDisposed(), k(this.gl, () => this.gl.getAttribLocation(e, t));
  }
  getUniformLocationNoThrow(e, t) {
    return this.throwIfDisposed(), this.gl.getUniformLocation(e, t);
  }
  setInputMatrixTexture(e, t, s) {
    this.throwIfDisposed(), this.throwIfNoProgram(), Kf(this.gl, e, t, s);
  }
  setOutputMatrixTexture(e, t, s) {
    this.setOutputMatrixTextureDriver(e, s, t);
  }
  setOutputPackedMatrixTexture(e, t, s) {
    this.throwIfDisposed();
    const [o, r] = Yt(t, s);
    this.setOutputMatrixTextureDriver(e, o, r);
  }
  setOutputMatrixWriteRegion(e, t, s, o) {
    this.setOutputMatrixWriteRegionDriver(s, e, o, t);
  }
  setOutputPackedMatrixWriteRegion(e, t, s, o) {
    throw new Error("setOutputPackedMatrixWriteRegion not implemented.");
  }
  debugValidate() {
    this.program != null && fs(this.gl, this.program), kn(this.gl);
  }
  executeProgram() {
    this.throwIfDisposed(), this.throwIfNoProgram();
    const e = this.gl;
    if (this.debug) {
      const t = this.getVertexArray();
      console.assert(t === this.program.vao, "VAO changed between setProgram and executeProgram!"), this.debugValidate();
    }
    k(e, () => e.drawElements(e.TRIANGLES, 6, e.UNSIGNED_SHORT, 0));
  }
  blockUntilAllProgramsCompleted() {
    this.throwIfDisposed(), k(this.gl, () => this.gl.finish());
  }
  getQueryTimerExtension() {
    return this.disjointQueryTimerExtension == null && (this.disjointQueryTimerExtension = Nn(this.gl, y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION") === 2 ? "EXT_disjoint_timer_query_webgl2" : "EXT_disjoint_timer_query")), this.disjointQueryTimerExtension;
  }
  getQueryTimerExtensionWebGL2() {
    return this.getQueryTimerExtension();
  }
  getQueryTimerExtensionWebGL1() {
    return this.getQueryTimerExtension();
  }
  beginQuery() {
    if (y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION") === 2) {
      const s = this.gl, o = this.getQueryTimerExtensionWebGL2(), r = s.createQuery();
      return s.beginQuery(o.TIME_ELAPSED_EXT, r), r;
    }
    const e = this.getQueryTimerExtensionWebGL1(), t = e.createQueryEXT();
    return e.beginQueryEXT(e.TIME_ELAPSED_EXT, t), t;
  }
  endQuery() {
    if (y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION") === 2) {
      const t = this.gl, s = this.getQueryTimerExtensionWebGL2();
      t.endQuery(s.TIME_ELAPSED_EXT);
      return;
    }
    const e = this.getQueryTimerExtensionWebGL1();
    e.endQueryEXT(e.TIME_ELAPSED_EXT);
  }
  async waitForQueryAndGetTime(e) {
    return await bo(() => this.disposed || // while testing contexts are created / disposed
    // in rapid succession, so without this check we
    // may poll for the query timer indefinitely
    this.isQueryAvailable(e, y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION"))), this.getQueryTime(e, y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_VERSION"));
  }
  getQueryTime(e, t) {
    if (t === 0)
      return null;
    if (t === 2) {
      const s = this.gl;
      return s.getQueryParameter(e, s.QUERY_RESULT) / 1e6;
    } else {
      const s = this.getQueryTimerExtensionWebGL1();
      return s.getQueryObjectEXT(e, s.QUERY_RESULT_EXT) / 1e6;
    }
  }
  isQueryAvailable(e, t) {
    if (t === 0)
      return !0;
    if (t === 2) {
      const s = this.gl, o = this.getQueryTimerExtensionWebGL2(), r = s.getQueryParameter(e, s.QUERY_RESULT_AVAILABLE);
      return this.disjoint == null && (this.disjoint = this.gl.getParameter(o.GPU_DISJOINT_EXT)), r && !this.disjoint;
    } else {
      const s = this.getQueryTimerExtensionWebGL1(), o = s.getQueryObjectEXT(e, s.QUERY_RESULT_AVAILABLE_EXT);
      return this.disjoint == null && (this.disjoint = this.gl.getParameter(s.GPU_DISJOINT_EXT)), o && !this.disjoint;
    }
  }
  pollFence(e) {
    return new Promise((t) => {
      this.addItemToPoll(() => e.isFencePassed(), () => t());
    });
  }
  pollItems() {
    const e = mm(this.itemsToPoll.map((t) => t.isDoneFn));
    for (let t = 0; t <= e; ++t) {
      const { resolveFn: s } = this.itemsToPoll[t];
      s();
    }
    this.itemsToPoll = this.itemsToPoll.slice(e + 1);
  }
  addItemToPoll(e, t) {
    if (this.itemsToPoll.push({ isDoneFn: e, resolveFn: t }), this.itemsToPoll.length > 1)
      return;
    let s;
    "setTimeoutCustom" in y().platform && (s = y().platform.setTimeoutCustom.bind(y().platform)), bo(() => (this.pollItems(), this.itemsToPoll.length === 0), () => 0, null, s);
  }
  bindTextureToFrameBuffer(e) {
    this.throwIfDisposed(), ps(this.gl, e, this.framebuffer), this.debug && kn(this.gl);
  }
  unbindTextureToFrameBuffer() {
    this.outputTexture != null ? (ps(this.gl, this.outputTexture, this.framebuffer), this.debug && kn(this.gl)) : Xo(this.gl, this.framebuffer);
  }
  downloadMatrixDriver(e, t) {
    this.bindTextureToFrameBuffer(e);
    const s = t();
    return this.unbindTextureToFrameBuffer(), s;
  }
  setOutputMatrixTextureDriver(e, t, s) {
    this.throwIfDisposed();
    const o = this.gl;
    ps(o, e, this.framebuffer), this.debug && kn(o), this.outputTexture = e, k(o, () => o.viewport(0, 0, t, s)), k(o, () => o.scissor(0, 0, t, s));
  }
  setOutputMatrixWriteRegionDriver(e, t, s, o) {
    this.throwIfDisposed(), k(this.gl, () => this.gl.scissor(e, t, s, o));
  }
  throwIfDisposed() {
    if (this.disposed)
      throw new Error("Attempted to use disposed GPGPUContext.");
  }
  throwIfNoProgram() {
    if (this.program == null)
      throw new Error("No GPU program is currently set.");
  }
}
function mm(n) {
  let e = 0;
  for (; e < n.length && n[e](); ++e)
    ;
  return e - 1;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function gm(n) {
  const e = new Float32Array(n.length);
  for (let t = 0; t < n.length; ++t)
    e[t] = Math.abs(n[t]);
  return e;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function be(n) {
  return (e, t, s, o, r) => {
    const i = ie(e, t), a = i.length, c = Q(i), l = T(i), u = pt(r, l), d = e.length, h = t.length, f = Q(e), p = Q(t), x = Gn(e, i), g = Gn(t, i);
    if (x.length + g.length === 0)
      for (let m = 0; m < u.length; ++m)
        u[m] = n(s[m % s.length], o[m % o.length]);
    else
      for (let m = 0; m < u.length; ++m) {
        const C = zs(m, a, c), b = C.slice(-d);
        x.forEach((R) => b[R] = 0);
        const w = vs(b, d, f), v = C.slice(-h);
        g.forEach((R) => v[R] = 0);
        const E = vs(v, h, p);
        u[m] = n(s[w], o[E]);
      }
    return [u, i];
  };
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function xm(n, e, t, s) {
  if (s === "int32") {
    const o = Int32Array.from(n);
    return [e, "int32", o];
  }
  if (s === "bool") {
    const o = Qn([0], t), [r, i] = be((a, c) => a !== c ? 1 : 0)(e, [], n, o, "bool");
    return [i, "bool", r];
  }
  throw new Error(`Error in Cast: failed to cast ${t} to ${s}`);
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Cm = be((n, e) => n + e);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function bm(n, e, t, s, o) {
  const r = T(s), i = nt(o, t);
  for (let a = 0; a < n.length; a++) {
    const c = n[a];
    if (c < 0)
      throw new Error("Input x must be non-negative!");
    c >= o || (r > 0 ? i[c] += e[a] : i[c] += 1);
  }
  return i;
}
function wm(n, e, t, s = !1) {
  const o = n.shape[0], r = n.shape[1], i = J([o, t], e.dtype);
  for (let a = 0; a < o; a++)
    for (let c = 0; c < r; c++) {
      const l = n.get(a, c);
      if (l < 0)
        throw new Error("Input x must be non-negative!");
      l >= t || (s ? i.set(1, a, l) : e.size > 0 ? i.set(i.get(a, l) + e.get(a, c), a, l) : i.set(i.get(a, l) + 1, a, l));
    }
  return i;
}
/**
 * @license
 * Copyright 2023 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ym = be((n, e) => n & e);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ke(n) {
  return (e, t, s) => {
    const o = q(t, e.length);
    for (let r = 0; r < e.length; ++r)
      o[r] = n(e[r], s);
    return o;
  };
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const vm = Ke((n) => Math.ceil(n));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function $m(n, e, t, s) {
  const o = q(t, T(e));
  if (s && t !== "string") {
    let r = 0;
    n.forEach((i) => {
      const a = T(i.shape);
      o.set(i.vals, r), r += a;
    });
  } else {
    let r = 0;
    n.forEach((i) => {
      const a = t === "string" ? Gt(i.vals) : i.vals;
      let c = 0;
      for (let l = 0; l < i.shape[0]; ++l) {
        const u = l * e[1] + r;
        for (let d = 0; d < i.shape[1]; ++d)
          o[u + d] = a[c++];
      }
      r += i.shape[1];
    });
  }
  return o;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Sm = be((n, e) => n === e ? 1 : 0);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Im = Ke((n) => Math.exp(n));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Rm = Ke((n) => Math.expm1(n));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Tm = Ke((n) => Math.floor(n));
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Em(n, e, t, s, o, r, i, a, c) {
  const l = J([s, r], t);
  for (let u = 0; u < s; u++) {
    const d = [];
    let h = 0;
    for (let f = 0; f < o; f++) {
      const p = n[u * o + f];
      h += p * i[f], d.push(p);
    }
    if (h < 0 || h >= c / r)
      throw new Error(`Invalid indices: ${d} does not index into ${a}`);
    for (let f = 0; f < r; f++)
      l.values[u * r + f] = e.get(...e.indexToLoc(h * r + f));
  }
  return l;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Nm(n, e, t) {
  const s = J(t, n.dtype);
  for (let o = 0; o < s.size; ++o) {
    const i = s.indexToLoc(o).slice(), a = i[0], c = i[2], l = e.locToIndex([a, c]);
    i[2] = e.values[l];
    const u = n.locToIndex(i);
    0 <= u && u < n.values.length && (s.values[o] = n.values[u]);
  }
  return s;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const km = be((n, e) => n > e ? 1 : 0);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Am = be((n, e) => n >= e ? 1 : 0);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Fm = be((n, e) => n < e ? 1 : 0);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Dm = be((n, e) => n <= e ? 1 : 0);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Om(n, e, t) {
  const s = (e - n) / (t - 1), o = nt(t, "float32");
  o[0] = n;
  for (let r = 1; r < o.length; r++)
    o[r] = o[r - 1] + s;
  return o;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Pm = Ke((n) => Math.log(n));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function _m(n, e, t, s) {
  const o = pt(s, T(t));
  for (let r = 0; r < o.length; ++r) {
    const i = r * e;
    let a = n[i];
    for (let c = 0; c < e; ++c) {
      const l = n[i + c];
      (Number.isNaN(l) || l > a) && (a = l);
    }
    o[r] = a;
  }
  return o;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Lm = be((n, e) => Math.max(n, e));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Bm = be((n, e) => Math.min(n, e));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const pa = be((n, e) => n * e);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Mm(n, e, t) {
  const s = Xt(-1, t);
  return pa([], e, s, n, t);
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Vm = be((n, e) => n !== e ? 1 : 0);
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Um(n, e, t, s, o) {
  const r = e.length, i = T(e), a = Q(e), c = Q(o), l = pt(t, T(o));
  for (let u = 0; u < i; ++u) {
    const d = zs(u, r, a), h = new Array(d.length);
    for (let p = 0; p < h.length; p++)
      h[p] = d[s[p]];
    const f = vs(h, r, c);
    l[f] = n[u];
  }
  return l;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Wm(n, e, t, s) {
  const [o, r] = He(n, s), i = ze(e, "int32"), a = nt(T(o), i), c = T(r);
  for (let l = 0; l < a.length; ++l) {
    const u = l * c;
    let d = 1;
    for (let h = 0; h < c; ++h)
      d *= t[u + h];
    a[l] = d;
  }
  return { outVals: a, outShape: o, outDtype: i };
}
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Gm(n, e, t) {
  n.forEach((s, o) => {
    if (s < 0 || s >= t) {
      const r = zs(o, e.length, Q(e)).join(",");
      throw new Error(`indices[${r}] = ${s} is not in [0, ${t})`);
    }
  });
}
function zm(n, e) {
  for (let t = 0; t < n.length; ++t) {
    const s = n[t], o = t === n.length - 1 ? e : n[t + 1].length;
    if (s.length === 0)
      throw new Error("Ragged splits may not be empty");
    if (s[0] < 0)
      throw new Error("Ragged splits must be non-negative");
    if (s[s.length - 1] > o)
      throw new Error("Ragged splits must not point past values");
    for (let r = 1; r < s.length; ++r)
      if (s[r - 1] > s[r])
        throw new Error("Ragged splits must be sorted in ascending order");
  }
}
function Hm(n, e, t, s) {
  const o = [];
  let r = 0;
  const i = e.length - 1 + t.length, a = new Array(i).fill(null).map(() => [0]);
  zm(t, s);
  let c = 1;
  for (let l = 0; l < e.length - 1; ++l) {
    c *= e[l];
    const u = e[l + 1];
    for (let d = 1; d < c + 1; ++d)
      a[l].push(d * u);
  }
  for (let l = 0; l < n.length; ++l) {
    let u = n[l], d = n[l] + 1;
    for (let h = 0; h < t.length; ++h) {
      const f = t[h], p = h + e.length - 1;
      if (p >= 0) {
        const x = a[p], g = x[x.length - 1] - f[u];
        for (let m = u; m < d; ++m)
          a[p].push(f[m + 1] + g);
      }
      u = f[u], d = f[d];
    }
    d !== u && (o.push([u, d]), r += d - u);
  }
  return { outSplits: a, valueSlices: o, numValues: r };
}
function Xm(n) {
  const e = [];
  for (let t = 0; t < n.length; ++t) {
    const s = n[t].length, o = q("int32", s);
    e.push(o), n[t].forEach((r, i) => o[i] = r);
  }
  return e;
}
function Yo(n, e) {
  const t = n.slice(0, e);
  for (; t.length < e; )
    t.push(1);
  for (let s = e; s < n.length; s++)
    t[e - 1] *= n[s];
  return t;
}
function qm(n, e, t, s, o, r) {
  const i = Yo(e, 2)[1], a = Yo(r, 2)[1];
  let c = 0;
  for (const l of t)
    for (let u = l[0]; u < l[1]; ++u) {
      for (let d = 0; d < s; ++d)
        o[c * a + d] = n[u * i + d];
      ++c;
    }
}
function jm(n, e, t, s, o) {
  const r = e.slice();
  r[0] = o;
  const i = q(t, T(r)), a = n.length, c = a === 0 ? 0 : a / e[0];
  return qm(n, e, s, c, i, r), [i, r];
}
function Km(n, e, t, s, o, r, i, a) {
  if (n.length === 0)
    throw new Error("paramsNestedSplits must be non empty");
  if (e[0].length === 0)
    throw new Error("Split tensors must not be scalars");
  const c = e[0][0] - 1;
  if (Gm(r, i, c), s.length === 0)
    throw new Error("params.rank must be nonzero");
  const l = s[0], { outSplits: u, valueSlices: d, numValues: h } = Hm(r, i, n, l), f = Xm(u), p = jm(t, s, o, d, h);
  return [f, p[0], p[1]];
}
/**
 * @license
 * Copyright 2022 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Qo = 2147483647;
function Ym(n, e, t, s, o, r, i) {
  if (e.length > 1)
    throw new Error("starts must be a scalar or vector");
  if (o.length > 1)
    throw new Error("limits must be a scalar or vector");
  if (i.length > 1)
    throw new Error("deltas must be a scalar or vector");
  const a = e.length === 0, c = o.length === 0, l = i.length === 0, u = [];
  a || u.push(e[0]), c || u.push(o[0]), l || u.push(i[0]);
  for (let g = 1; g < u.length; ++g)
    if (u[g] !== u[g - 1])
      throw new Error("starts, limits, and deltas must have the same shape");
  const d = u.length === 0 ? 1 : u[0], h = q("int32", d + 1);
  h[0] = 0;
  for (let g = 0; g < d; ++g) {
    const m = a ? n[0] : n[g], C = c ? s[0] : s[g], b = l ? r[0] : r[g];
    if (b === 0)
      throw new Error("Requires delta != 0");
    let w;
    if (b > 0 && C < m || b < 0 && C > m)
      w = 0;
    else if (w = Math.ceil(Math.abs((C - m) / b)), w > Qo)
      throw new Error(`Requires ((limit - start) / delta) <= ${Qo}`);
    h[g + 1] = h[g] + w;
  }
  const f = h[d], p = q(t, f);
  let x = 0;
  for (let g = 0; g < d; ++g) {
    const m = h[g + 1] - h[g];
    let C = a ? n[0] : n[g];
    const b = l ? r[0] : r[g];
    for (let w = 0; w < m; ++w)
      p[x++] = C, C += b;
  }
  return [h, p];
}
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
var ye = Oe;
class Hn {
  constructor(e, t, s, o, r, i, a, c, l, u) {
    this.shape = e, this.shapeShape = t, this.values = s, this.valuesShape = o, this.valuesDType = r, this.defaultValue = i, this.defaultValueShape = a, this.rowPartitionValues = c, this.rowPartitionValuesShapes = l, this.rowPartitionTypes = Ii(u), this.raggedRank = Ri(this.rowPartitionTypes);
  }
  getRowPartitionTypeByDimension(e) {
    return this.rowPartitionTypes[0] === ye.FIRST_DIM_SIZE ? this.rowPartitionTypes[e + 1] : this.rowPartitionTypes[e];
  }
  // Returns the relationship between dimension and dimension + 1.
  getRowPartitionTensor(e) {
    return this.rowPartitionTypes[0] === ye.FIRST_DIM_SIZE ? this.rowPartitionValues[e + 1] : this.rowPartitionValues[e];
  }
  getMaxWidth(e) {
    const t = this.getRowPartitionTensor(e - 1);
    switch (this.getRowPartitionTypeByDimension(e - 1)) {
      case ye.VALUE_ROWIDS:
        return Hn.getMaxWidthValueRowID(t);
      case ye.ROW_SPLITS:
        return Hn.getMaxWidthRowSplit(t);
      default:
        throw new Error(`Cannot handle partition type ${ye[this.getRowPartitionTypeByDimension(e - 1)]}`);
    }
  }
  static getMaxWidthRowSplit(e) {
    const t = e.length;
    if (t === 0 || t === 1)
      return 0;
    let s = 0;
    for (let o = 0; o < t - 1; ++o) {
      const r = e[o + 1] - e[o];
      r > s && (s = r);
    }
    return s;
  }
  static getMaxWidthValueRowID(e) {
    const t = e.length;
    if (t === 0)
      return 0;
    let s = 0, o = e[0], r = 0;
    for (let i = 1; i < t; ++i) {
      const a = e[i];
      a !== o && (o = a, r = Math.max(i - s, r), s = i);
    }
    return Math.max(t - s, r);
  }
  tensorShapeFromTensor(e, t, s = !0) {
    if (t.length === 0) {
      if (e[0] === -1)
        return [];
      throw new Error("The only valid scalar shape tensor is the fully unknown shape specified as -1.");
    }
    return Jo(e, s);
  }
  calculateOutputSize(e) {
    const t = this.valuesShape, s = this.defaultValueShape;
    Ti(s, t);
    const o = this.tensorShapeFromTensor(this.shape, this.shapeShape), i = Si(this.raggedRank, o, t);
    i[0] < 0 && (i[0] = e);
    for (let a = 1; a <= this.raggedRank; ++a)
      i[a] < 0 && (i[a] = this.getMaxWidth(a));
    return i;
  }
  /**
   * The outputIndex represents the index in the output tensor
   * where the first element of a particular dimension would be written.
   * If it is -1, it indicates that the index is out of scope.
   * Example, given firstDimension = 10, firstDimensionOutput = 6,
   * and outputIndexMultiplier = 100:
   * result = [0 100 200 300 400 500 -1 -1 -1 -1]
   * If firstDimensionOutput = 11 instead, then:
   * result = [0 100 200 300 400 500 600 700 800 900]
   */
  calculateFirstParentOutputIndex(e, t, s) {
    const o = Math.min(e, s), r = [];
    let i = 0;
    for (let a = 0; a < o; ++a, i += t)
      r.push(i);
    for (let a = o; a < e; ++a)
      r.push(-1);
    return N(r.length === e, () => "Final length of result must be equal to firstDimension."), r;
  }
  calculateOutputIndexRowSplit(e, t, s, o) {
    const r = e.length, i = [];
    for (let a = 0; a < r - 1; ++a) {
      const c = e[a + 1] - e[a];
      let l = Math.min(o, c), u = t[a];
      u === -1 && (l = 0);
      for (let d = 0; d < l; ++d)
        i.push(u), u += s;
      for (let d = 0; d < c - l; ++d)
        i.push(-1);
    }
    if (r > 0 && i.length !== e[r - 1])
      throw new Error("Invalid row split size.");
    return i;
  }
  // Calculate the output index of the first element of a list.
  // The parentOutputIndex is the same computation for the previous list.
  // -1 indicates an element or list that is out of range.
  // The outputIndexMultiplier is the number of output indices one moves
  // forward for each column.
  // E.g., given:
  // valueRowIds:[0 1 2 2 2 3 5 5 6]
  // parentOutputIndex:[1000 1100 2000 2100 -1 3000 4000]
  // outputIndexMultiplier: 10
  // outputSize: 2
  // You get:
  // result = [1000 1100 2000 2010 -1 2100 -1 -1 3000]
  // result[0] = parentOutputIndex[valueRowIds[0]]
  // result[1] = parentOutputIndex[valueRowIds[1]]
  // result[2] = parentOutputIndex[valueRowIds[2]]
  // result[3] = parentOutputIndex[valueRowIds[2] + 10]
  // result[4] = -1 because it is the third element the size is 2.
  // result[5] = parentOutputIndex[valueRowIds[3]]
  // result[6] = -1 because parentOutputIndex[valueRowIds[6]] == -1
  // result[7] = -1 because parentOutputIndex[valueRowIds[6]] == -1
  // result[8] = parentOutputIndex[valueRowIds[7]]
  calculateOutputIndexValueRowID(e, t, s, o) {
    const r = e.length, i = [];
    if (r === 0)
      return [];
    let a = 0, c = e[0];
    if (c >= t.length)
      throw new Error(`Got currentValueRowId=${c}, which is not less than ${t.length}`);
    let l = t[c];
    i.push(l);
    for (let u = 1; u < r; ++u) {
      const d = e[u];
      if (d === c)
        l >= 0 && (++a, a < o ? l += s : l = -1);
      else {
        if (a = 0, c = d, d >= t.length)
          throw new Error(`Got nextValueRowId=${d} which is not less than ${t.length}`);
        l = t[d];
      }
      i.push(l);
    }
    if (i.length !== e.length)
      throw new Error("Invalid row ids.");
    return i;
  }
  calculateOutputIndex(e, t, s, o) {
    const r = this.getRowPartitionTensor(e), i = this.getRowPartitionTypeByDimension(e);
    switch (i) {
      case ye.VALUE_ROWIDS:
        return this.calculateOutputIndexValueRowID(r, t, s, o);
      case ye.ROW_SPLITS:
        if (r.length - 1 > t.length)
          throw new Error(`Row partition size is greater than output size: ${r.length - 1} > ${t.length}`);
        return this.calculateOutputIndexRowSplit(r, t, s, o);
      default:
        throw new Error(`Unsupported partition type: ${ye[i]}`);
    }
  }
  getFirstDimensionSize() {
    const e = this.rowPartitionValues[0];
    if (this.rowPartitionTypes.length === 0)
      throw new Error("No row_partition_types given.");
    const t = this.rowPartitionTypes[0];
    switch (t) {
      case ye.FIRST_DIM_SIZE:
        return e[0];
      case ye.VALUE_ROWIDS:
        throw new Error("Cannot handle VALUE_ROWIDS in first dimension.");
      case ye.ROW_SPLITS:
        return this.rowPartitionValuesShapes[0][0] - 1;
      default:
        throw new Error(`Cannot handle type ${ye[t]}`);
    }
  }
  compute() {
    if (this.rowPartitionValues[0].length <= 0)
      throw new Error("Invalid first partition input. Tensor requires at least one element.");
    const t = this.getFirstDimensionSize(), s = this.calculateOutputSize(t), o = new Array(this.raggedRank + 1);
    o[o.length - 1] = 1;
    for (let c = o.length - 2; c >= 0; --c)
      o[c] = o[c + 1] * s[c + 1];
    const r = Jo(s, !1), i = q(this.valuesDType, T(r));
    if (o[0] * s[0] > 0) {
      let c = this.calculateFirstParentOutputIndex(t, o[0], s[0]);
      for (let l = 1; l <= this.raggedRank; ++l)
        c = this.calculateOutputIndex(l - 1, c, o[l], s[l]);
      this.setOutput(this.raggedRank, c, i, r);
    }
    return [r, i];
  }
  setOutput(e, t, s, o) {
    if (s.length === 0)
      return;
    const r = this.values, i = s;
    let a = o.slice();
    a = a.slice(e + 1);
    const c = T(a), l = t.length;
    let u = this.defaultValue;
    if (u.length !== c && u.length !== 1) {
      const p = this.defaultValueShape;
      H(() => {
        const x = gi(u, p);
        u = $h(x, a).dataSync();
      });
    }
    let d = 0, h = 0, f = 0;
    for (let p = 0; p <= l; ++p) {
      let x = p < l ? t[p] : -1;
      if (x === f) {
        ++f;
        continue;
      }
      if (h < f) {
        const g = r.subarray(d * c), m = i.subarray(h * c), C = (f - h) * c;
        Zo(m, g, C);
      }
      if (p >= l) {
        const g = s.length;
        x = Math.floor(g / c);
      }
      if (x > f)
        if (this.defaultValue.length === 1)
          i.subarray(f * c, x * c).fill(this.defaultValue[0]), f = x;
        else
          for (; x > f; ) {
            const g = i.slice(f * c);
            Zo(g, u, c), ++f;
          }
      x < 0 ? (d = p + 1, h = f) : (d = p, h = f, f = h + 1);
    }
  }
}
function Zo(n, e, t) {
  for (let s = 0; s < t; s++)
    n[s] = e[s];
}
function Jo(n, e) {
  const t = [];
  for (let s of n) {
    if (s < 0) {
      if (!e)
        throw new Error(`Dimension ${s} must be >= 0`);
      if (s < -1)
        throw new Error(`Dimension ${s} must be >= -1`);
      s = -1;
    }
    t.push(s);
  }
  return t;
}
function Qm(n, e, t, s, o, r, i, a, c, l) {
  return new Hn(n, e, t, s, o, r, i, a, c, l).compute();
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Zm(n, e, t, s) {
  const o = n === e, r = n < e && t < 0, i = e < n && t > 1;
  if (o || r || i)
    return nt(0, s);
  const a = Math.abs(Math.ceil((e - n) / t)), c = nt(a, s);
  e < n && t === 1 && (t = -1), c[0] = n;
  for (let l = 1; l < c.length; l++)
    c[l] = c[l - 1] + t;
  return c;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Jm = Ke((n) => 1 / Math.sqrt(n));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function eg(n, e, t, s, o, r, i, a, c, l) {
  const u = [s / o, o], d = n.values, h = e.values;
  if (s === 0)
    return J(t, e.dtype);
  const f = c instanceof Vn ? c : J(u, e.dtype);
  typeof c == "string" || typeof c == "number" ? f.values.fill(c) : typeof c == "boolean" && f.values.fill(+c);
  for (let p = 0; p < r; p++) {
    const x = [];
    let g = 0;
    for (let m = 0; m < i; m++) {
      const C = d[p * i + m];
      x.push(C), g += C * a[m];
    }
    if (g < 0 || g >= s / o)
      throw new Error(`Invalid indices: ${x} does not index into ${t}`);
    for (let m = 0; m < o; m++)
      f.values[g * o + m] = e.rank === 0 ? h[0] : h[p * o + m];
  }
  return f;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const tg = Ke((n) => 1 / (1 + Math.exp(-n)));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ng(n, e, t, s, o) {
  const r = yi(s, e, t), i = T(t), a = Q(s);
  if (r) {
    const d = vi(e, a);
    return o === "string" ? n.slice(d, d + i) : n.subarray(d, d + i);
  }
  const c = o === "string" ? Gt(n) : n, l = J(s, o, c), u = J(t, o);
  for (let d = 0; d < u.size; ++d) {
    const h = u.indexToLoc(d), f = h.map((p, x) => p + e[x]);
    u.set(l.get(...f), ...h);
  }
  return o === "string" ? na(u.values) : u.values;
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function sg(n, e, t, s, o, r, i) {
  const a = e[0], c = r[0], l = new Array(c), u = new Array(a), d = e[1];
  if (c === 0) {
    if (a !== 0)
      throw new Error(Hi(a));
    const g = q(t, 0), m = q(o, 0);
    return [
      g,
      [0, d],
      m,
      l,
      u
    ];
  }
  let h = !0, f = 0;
  const p = new Array(c).fill(0);
  for (let g = 0; g < a; ++g) {
    const m = n[g * d];
    if (m < 0)
      throw new Error(Xi(g, m));
    if (m >= c)
      throw new Error(qi(g, m, c));
    ++p[m], h = h && m >= f, f = m;
  }
  let x = !0;
  for (let g = 0; g < c; ++g) {
    const m = p[g] === 0;
    l[g] = m, x = x && !m, p[g] = Math.max(p[g], 1), g > 0 && (p[g] += p[g - 1]);
  }
  if (x && h) {
    const g = n, m = s;
    for (let C = 0; C < a; ++C)
      u[C] = C;
    return [
      g,
      [a, d],
      m,
      l,
      u
    ];
  } else {
    const g = p[c - 1], m = q(t, g * d), C = q(o, g), b = new Array(c).fill(0);
    for (let w = 0; w < a; ++w) {
      const v = n[w * d], E = b[v], R = (v === 0 ? 0 : p[v - 1]) + E;
      b[v]++;
      for (let $ = 0; $ < d; ++$)
        m[R * d + $] = n[w * d + $];
      C[R] = s[w], u[w] = R;
    }
    for (let w = 0; w < c; ++w)
      if (b[w] === 0) {
        const E = w === 0 ? 0 : p[w - 1];
        m[E * d + 0] = w;
        for (let R = 1; R < d; ++R)
          m[E * d + R] = 0;
        C[E] = i;
      }
    return [
      m,
      [g, d],
      C,
      l,
      u
    ];
  }
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function og(n, e, t, s, o) {
  const r = T(s), i = e[0], a = o.length, c = [];
  let l = 1, u = -1;
  for (let g = 0; g < a; ++g) {
    const m = o[g];
    if (m === -1) {
      if (u !== -1)
        throw new Error(ji(u, g));
      u = g, c.push(1);
    } else {
      if (m < 0)
        throw new Error(Ki(g, m));
      l *= m, c.push(m);
    }
  }
  if (u !== -1) {
    if (l <= 0)
      throw new Error(Yi());
    const g = Math.trunc(r / l);
    if (l * g !== r)
      throw new Error(Qi(s, c));
    c[u] = g;
  }
  if (T(c) !== r)
    throw new Error(Zi(s, c));
  const h = s.length, f = [];
  if (h > 0) {
    f[h - 1] = 1;
    for (let g = h - 2; g >= 0; --g)
      f[g] = f[g + 1] * s[g + 1];
  }
  const p = [];
  if (a > 0) {
    p[a - 1] = 1;
    for (let g = a - 2; g >= 0; --g)
      p[g] = p[g + 1] * c[g + 1];
  }
  const x = q(t, i * a);
  for (let g = 0; g < i; ++g) {
    let m = 0;
    for (let C = 0; C < h; ++C)
      m += n[g * h + C] * f[C];
    for (let C = 0; C < a; ++C)
      x[g * a + C] = Math.trunc(m / p[C]), m %= p[C];
  }
  return [x, [i, a], c];
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function rg(n, e, t, s, o, r = !1, i = 0) {
  const a = s.length, c = [e[0], n.length / e[0]], l = c[1], d = a > 0 ? o[a - 1] + 1 : 0;
  if (d < 0)
    throw new Error(Bs());
  const h = e.slice();
  h[0] = d;
  const f = h.reduce((b, w) => b * w, 1), p = q(t, f);
  if (a === 0)
    return d > 0 && p.fill(i), [p, h];
  if (d <= 0)
    throw new Error(Bs());
  let x = 0, g = 1, m = 0, C = o[x];
  for (; ; ) {
    let b = 0;
    if (g < a) {
      if (b = o[g], C === b) {
        ++g;
        continue;
      }
      if (C >= b)
        throw new Error(Ji());
    }
    if (C < 0 || C >= d)
      throw new Error(ea(C, d));
    C > m && p.fill(i, m * l, C * l);
    for (let w = x; w < g; ++w) {
      const v = s[w];
      if (v < 0 || v >= c[0])
        throw new Error(ta(w, s[w], c[0]));
      for (let E = 0; E < l; E++)
        p[C * l + E] += n[v * l + E];
    }
    if (r)
      for (let w = 0; w < l; w++)
        p[C * l + w] /= g - x;
    if (x = g, ++g, m = C + 1, C = b, g > a)
      break;
  }
  return m < d && p.fill(i, m * l, d * l), [p, h];
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ig = Ke((n) => Math.sqrt(n));
/**
 * @license
 * Copyright 2023 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ag = Ke((n, e) => {
  const { pattern: t, replaceGlobal: s, rewrite: o } = e;
  return n.replace(new RegExp(t, s ? "g" : ""), o);
});
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function cg(n, e, t, s) {
  const o = J(n, e.dtype);
  for (let r = 0; r < o.size; r++) {
    const i = o.indexToLoc(r), a = new Array(i.length);
    for (let c = 0; c < a.length; c++)
      a[c] = i[c] * t[c] + s[c];
    o.set(e.get(...a), ...i);
  }
  return o;
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class lg {
  constructor(e, t, s, o, r, i) {
    this.separator = ht(e), this.nGramWidths = t, this.leftPad = ht(s), this.rightPad = ht(o), this.padWidth = r, this.preserveShort = i;
  }
  getPadWidth(e) {
    return Math.min(this.padWidth < 0 ? e - 1 : this.padWidth, e - 1);
  }
  getNumNGrams(e, t) {
    const s = this.getPadWidth(t);
    return Math.max(0, e + 2 * s - t + 1);
  }
  createNGrams(e, t, s, o, r, i) {
    for (let a = 0; a < r; ++a) {
      const c = this.getPadWidth(i), l = Math.max(0, c - a), u = Math.max(0, c - (r - (a + 1))), d = i - (l + u), h = t + (l > 0 ? 0 : a - c);
      let f = 0;
      f += l * this.leftPad.length;
      for (let C = 0; C < d; ++C)
        f += e[h + C].length;
      f += u * this.rightPad.length;
      const p = l + u + d - 1;
      f += p * this.separator.length, s[o + a] = new Uint8Array(f);
      const x = s[o + a];
      let g = 0;
      const m = (C) => C.forEach((b) => x[g++] = b);
      for (let C = 0; C < l; ++C)
        m(this.leftPad), m(this.separator);
      for (let C = 0; C < d - 1; ++C)
        m(e[h + C]), m(this.separator);
      if (d > 0) {
        m(e[h + d - 1]);
        for (let C = 0; C < u; ++C)
          m(this.separator), m(this.rightPad);
      } else {
        for (let C = 0; C < u - 1; ++C)
          m(this.rightPad), m(this.separator);
        m(this.rightPad);
      }
    }
  }
  // Data and splits together form the definition of the ragged tensor,
  // where data is 1 dimensional and contains the values of the tensor
  // and splits denotes the indices at which each row starts.
  compute(e, t) {
    const s = e.length, o = t.length;
    if (o > 0) {
      let c = t[0];
      if (c !== 0)
        throw new Error(`First split value must be 0, got ${c}`);
      for (let l = 1; l < o; ++l) {
        let u = t[l] >= c;
        if (u = u && t[l] <= s, !u)
          throw new Error(`Invalid split value ${t[l]}, must be in [${c}, ${s}]`);
        c = t[l];
      }
      if (c !== s)
        throw new Error(`Last split value must be data size. Expected ${s}, got ${c}`);
    }
    const r = o - 1, i = q("int32", o);
    if (s === 0 || o === 0) {
      const c = new Array(s);
      for (let l = 0; l <= r; ++l)
        i[l] = 0;
      return [c, i];
    }
    i[0] = 0;
    for (let c = 1; c <= r; ++c) {
      const l = t[c] - t[c - 1];
      let u = 0;
      this.nGramWidths.forEach((d) => {
        u += this.getNumNGrams(l, d);
      }), this.preserveShort && l > 0 && u === 0 && (u = 1), i[c] = i[c - 1] + u;
    }
    const a = new Array(i[r]);
    for (let c = 0; c < r; ++c) {
      const l = t[c];
      let u = i[c];
      if (this.nGramWidths.forEach((d) => {
        const h = t[c + 1] - t[c], f = this.getNumNGrams(h, d);
        this.createNGrams(e, l, a, u, f, d), u += f;
      }), this.preserveShort && u === i[c]) {
        const d = t[c + 1] - t[c];
        if (d === 0)
          continue;
        const h = d + 2 * this.padWidth;
        this.createNGrams(e, l, a, u, 1, h);
      }
    }
    return [a, i];
  }
}
function ug(n, e, t, s, o, r, i, a) {
  return new lg(t, s, o, r, i, a).compute(n, e);
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function dg(n, e, t, s) {
  if (!n.length)
    return;
  if (e.length === 0) {
    for (let r = 0; r < n.length; ++r)
      s.push(n.subarray(r, r + 1));
    return;
  }
  if (e.length === 1) {
    const r = e[0];
    let i = n.indexOf(r);
    for (; i !== -1; ) {
      const a = n.subarray(0, i);
      (!t || a.length !== 0) && s.push(a), n = n.subarray(i + 1), i = n.indexOf(r);
    }
    (!t || n.length !== 0) && s.push(n);
    return;
  }
  let o = 0;
  for (let r = 0; r < n.length + 1; r++)
    if (r === n.length || e.indexOf(n[r]) !== -1) {
      const i = n.subarray(o, r);
      (!t || i.length !== 0) && s.push(i), o = r + 1;
    }
}
function hg(n, e, t) {
  const s = n.length, o = [];
  let r = 0, i = 0;
  const a = new Array(s);
  for (let h = 0; h < s; ++h) {
    const f = o.length;
    dg(n[h], e, t, o);
    const p = o.length - f;
    a[h] = p, r += p, i = Math.max(i, p);
  }
  const c = q("int32", r * 2), l = new Array(r), u = [s, i];
  let d = 0;
  for (let h = 0; h < s; ++h)
    for (let f = 0; f < a[h]; ++f)
      c[d * 2] = h, c[d * 2 + 1] = f, l[d] = o[d], ++d;
  return [c, l, u];
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function fg(n, e) {
  const t = q("int32", n.length);
  for (let s = 0; s < n.length; ++s)
    t[s] = gd(n[s]).modulo(e).getLowBitsUnsigned();
  return t;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const pg = be((n, e) => n - e);
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function mg(n, e) {
  const t = new Array(n.rank);
  for (let o = 0; o < t.length; o++)
    t[o] = n.shape[o] * e[o];
  const s = J(t, n.dtype);
  for (let o = 0; o < s.values.length; ++o) {
    const r = s.indexToLoc(o), i = new Array(n.rank);
    for (let c = 0; c < i.length; c++)
      i[c] = r[c] % n.shape[c];
    const a = n.locToIndex(i);
    s.values[o] = n.values[a];
  }
  return s;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ln = (n, e) => {
  const t = e.value - n.value;
  return t === 0 ? n.index - e.index : t;
};
function ma(n, e, t = 0, s = n.length - 1) {
  for (; s > t; ) {
    if (s - t > 600) {
      const a = s - t + 1, c = e - t + 1, l = Math.log(a), u = 0.5 * Math.exp(2 * l / 3), d = 0.5 * Math.sqrt(l * u * (a - u) / a) * Math.sign(c - a / 2), h = Math.max(t, Math.floor(e - c * u / a + d)), f = Math.min(s, Math.floor(e + (a - c) * u / a + d));
      ma(n, e, h, f);
    }
    const o = n[e];
    let r = t, i = s;
    for (on(n, t, e), ln(n[s], o) > 0 && on(n, t, s); r < i; ) {
      for (on(n, r, i), r++, i--; ln(n[r], o) < 0; )
        r = r + 1;
      for (; ln(n[i], o) > 0; )
        i = i - 1;
    }
    ln(n[t], o) === 0 ? on(n, t, i) : (i = i + 1, on(n, i, s)), i <= e && (t = i + 1), e <= i && (s = i - 1);
  }
}
function gg(n, e, t, s, o) {
  const r = e[e.length - 1], [i, a] = [n.length / r, r], c = pt(t, i * s), l = pt("int32", i * s);
  for (let d = 0; d < i; d++) {
    const h = d * a, f = n.subarray(h, h + a);
    let p = new Array(f.length);
    f.forEach((C, b) => p[b] = { value: C, index: b }), s < p.length && (ma(p, s), p = p.slice(0, s)), o && p.sort(ln);
    const x = d * s, g = c.subarray(x, x + s), m = l.subarray(x, x + s);
    for (let C = 0; C < s; C++)
      g[C] = p[C].value, m[C] = p[C].index;
  }
  const u = e.slice();
  return u[u.length - 1] = s, [
    J(u, t, c),
    J(u, "int32", l)
  ];
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function xg(n, e, t, s) {
  const o = de(e, t)[0], r = [1, t[0], 1];
  for (let p = 0; p < o; p++)
    r[0] *= t[p];
  r[1] = t[o];
  for (let p = o + 1; p < t.length; p++)
    r[2] *= t[p];
  const i = /* @__PURE__ */ new Map(), a = new Int32Array(t[o]), c = new Vn(r, s, n), l = [], u = r[0] === 1 && r[2] === 1;
  for (let p = 0; p < t[o]; p++) {
    let x;
    if (u)
      x = n[p].toString();
    else {
      const m = [];
      for (let C = 0; C < r[0]; C++)
        for (let b = 0; b < r[2]; b++)
          m.push(c.get(C, p, b));
      x = m.join(",");
    }
    const g = i.get(x);
    if (g != null)
      a[p] = g;
    else {
      const m = i.size;
      i.set(x, m), a[p] = m, l.push(p);
    }
  }
  const d = r.slice();
  d[1] = i.size;
  const h = new Vn(d, s);
  l.forEach((p, x) => {
    for (let g = 0; g < r[0]; g++)
      for (let m = 0; m < r[2]; m++)
        h.set(c.get(g, p, m), g, x, m);
  });
  const f = t.slice();
  return f[o] = d[1], {
    outputValues: h.values,
    outputShape: f,
    indices: a
  };
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Cg = /* @__PURE__ */ Object.freeze(/* @__PURE__ */ Object.defineProperty({
  __proto__: null,
  addImpl: Cm,
  bincountImpl: bm,
  bincountReduceImpl: wm,
  bitwiseAndImpl: ym,
  castImpl: xm,
  ceilImpl: vm,
  concatImpl: $m,
  equalImpl: Sm,
  expImpl: Im,
  expm1Impl: Rm,
  floorImpl: Tm,
  gatherNdImpl: Em,
  gatherV2Impl: Nm,
  greaterEqualImpl: Am,
  greaterImpl: km,
  lessEqualImpl: Dm,
  lessImpl: Fm,
  linSpaceImpl: Om,
  logImpl: Pm,
  maxImpl: _m,
  maximumImpl: Lm,
  minimumImpl: Bm,
  multiplyImpl: pa,
  negImpl: Mm,
  notEqualImpl: Vm,
  prodImpl: Wm,
  raggedGatherImpl: Km,
  raggedRangeImpl: Ym,
  raggedTensorToTensorImpl: Qm,
  rangeImpl: Zm,
  rsqrtImpl: Jm,
  scatterImpl: eg,
  sigmoidImpl: tg,
  simpleAbsImpl: gm,
  sliceImpl: ng,
  sparseFillEmptyRowsImpl: sg,
  sparseReshapeImpl: og,
  sparseSegmentReductionImpl: rg,
  sqrtImpl: ig,
  staticRegexReplaceImpl: ag,
  stridedSliceImpl: cg,
  stringNGramsImpl: ug,
  stringSplitImpl: hg,
  stringToHashBucketFastImpl: fg,
  subImpl: pg,
  tileImpl: mg,
  topKImpl: gg,
  transposeImpl: Um,
  uniqueImpl: xg
}, Symbol.toStringTag, { value: "Module" }));
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const { addImpl: bg, bincountImpl: ga, bincountReduceImpl: wg, bitwiseAndImpl: yg, castImpl: vg, ceilImpl: $g, concatImpl: Sg, equalImpl: Ig, expImpl: Rg, expm1Impl: Tg, floorImpl: Eg, gatherNdImpl: Ng, gatherV2Impl: kg, greaterImpl: Ag, greaterEqualImpl: Fg, lessImpl: Dg, lessEqualImpl: Og, linSpaceImpl: Pg, logImpl: _g, maxImpl: Lg, maximumImpl: Bg, minimumImpl: Mg, multiplyImpl: Vg, negImpl: Ug, notEqualImpl: Wg, prodImpl: Gg, raggedGatherImpl: zg, raggedRangeImpl: Hg, raggedTensorToTensorImpl: Xg, rangeImpl: qg, rsqrtImpl: jg, scatterImpl: Kg, sigmoidImpl: Yg, simpleAbsImpl: xa, sliceImpl: Qg, sparseFillEmptyRowsImpl: Zg, sparseReshapeImpl: Jg, sparseSegmentReductionImpl: Ca, sqrtImpl: ex, staticRegexReplaceImpl: tx, stridedSliceImpl: nx, stringNGramsImpl: sx, stringSplitImpl: ox, stringToHashBucketFastImpl: rx, subImpl: ix, tileImpl: ax, topKImpl: cx, transposeImpl: fo, uniqueImpl: lx } = Cg;
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ba(n, e) {
  return ["x", "y", "z", "w", "u", "v"].slice(0, e).map((t) => `${n}.${t}`);
}
function re(n, e) {
  return e === 1 ? [n] : ba(n, e);
}
function ux(n, e) {
  if (n === 1)
    return "rc";
  let t = "";
  for (let s = 0; s < n; s++)
    t += e[s], s < n - 1 && (t += ",");
  return t;
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class dx {
  constructor(e) {
    if (this.variableNames = ["A"], this.packedInputs = !1, this.packedOutput = !0, this.outputShape = e, this.rank = e.length, this.enableShapeUniforms = ne(this.outputShape.length), this.rank === 0)
      this.userCode = `
        void main() {
          setOutput(vec4(getA(), 0., 0., 0.));
        }
      `;
    else {
      const t = re("rc", this.rank), s = V(this.rank), o = this.getOutOfBoundsCondition(t), r = this.getSetup(t), i = this.getOutput(t);
      this.userCode = `
        void main() {
          ${s} rc = getOutputCoords();

          if(${o}) {
            setOutput(vec4(0));
          } else {
            ${r}

            setOutput(vec4(${i}));
          }
        }
      `;
    }
  }
  getSourceCoordsArr(e) {
    const t = [];
    for (let s = 0; s <= 1; s++)
      for (let o = 0; o <= 1; o++) {
        let r = `${s === 0 ? "r" : "rp1"}, ${o === 0 ? "c" : "cp1"}`;
        for (let i = 2; i < this.rank; i++)
          r = `${e[e.length - 1 - i]},` + r;
        t.push(r);
      }
    return t;
  }
  getOutOfBoundsCondition(e) {
    if (this.rank === 1)
      return `rc > ${this.enableShapeUniforms ? "outShape" : this.outputShape[0]}`;
    let t = "";
    for (let s = this.rank - 2; s < this.rank; s++)
      t += `${e[s]} >= ${this.enableShapeUniforms ? `outShape[${s}]` : this.outputShape[s]}`, s < this.rank - 1 && (t += "||");
    return t;
  }
  getSetup(e) {
    if (this.rank === 1)
      return "";
    const t = e.slice(-2), s = this.enableShapeUniforms ? `outShape[${this.rank} - 1]` : this.outputShape[this.rank - 1], o = this.enableShapeUniforms ? `outShape[${this.rank} - 2]` : this.outputShape[this.rank - 2];
    return `
      int r = ${t[0]};
      int c = ${t[1]};
      int rp1 = r + 1;
      int cp1 = c + 1;

      bool cEdge = cp1 >= ${s};
      bool rEdge = rp1 >= ${o};
    `;
  }
  getOutput(e) {
    const t = this.getSourceCoordsArr(e);
    return this.rank === 1 ? `getA(rc), (rc + 1 >= ${this.enableShapeUniforms ? "outShape" : this.outputShape[0]} ? 0. : getA(rc + 1)), 0, 0` : `getA(${t[0]}),
            cEdge ? 0. : getA(${t[1]}),
            rEdge ? 0. : getA(${t[2]}),
            rEdge || cEdge ? 0. : getA(${t[3]})`;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class wa {
  constructor(e, t) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0, this.customUniforms = [{ name: "inputShape", type: "ivec3" }], this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length);
    let s = "";
    for (let o = 0; o < 4; o++) {
      let r = "thisRC = rc;";
      o % 2 === 1 && (r += "thisRC.z += 1;"), o > 1 && (r += "thisRC.y += 1;"), s += `
        ${r}
        ${o > 0 ? "if(thisRC.y < rows && thisRC.z < cols){" : ""}
          int flatIndex = getFlatIndex(thisRC);

          ivec3 inputRC = inputCoordsFromReshapedOutCoords(flatIndex);
          vec2 inputRCInnerDims = vec2(float(inputRC.y),float(inputRC.z));

          result[${o}] =
            getChannel(getA(inputRC.x, inputRC.y, inputRC.z), inputRCInnerDims);
        ${o > 0 ? "}" : ""}
      `;
    }
    this.userCode = `
      ${hx(t, this.enableShapeUniforms)}
      ${this.enableShapeUniforms ? uo() : lo(e)}

      void main() {
        ivec3 rc = getOutputCoords();

        vec4 result = vec4(0.);

        ivec3 thisRC;
        int rows = ${this.enableShapeUniforms ? "outShape[1]" : e[1]};
        int cols = ${this.enableShapeUniforms ? "outShape[2]" : e[2]};

        ${s}

        setOutput(result);
      }
    `;
  }
}
function hx(n, e) {
  return `
    ivec3 inputCoordsFromReshapedOutCoords(int index) {
      ${e ? ap(["r", "c", "d"], "inputShape") : Rt(["r", "c", "d"], n)}
      return ivec3(r, c, d);
    }
  `;
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class fx {
  constructor(e) {
    this.gpgpu = e, this.numUsedTextures = 0, this.numFreeTextures = 0, this._numBytesAllocated = 0, this._numBytesFree = 0, this.freeTextures = {}, this.usedTextures = {}, this.logEnabled = !1;
  }
  acquireTexture(e, t, s) {
    const o = tr(t, s), r = nr(e, o, s);
    r in this.freeTextures || (this.freeTextures[r] = []), r in this.usedTextures || (this.usedTextures[r] = []);
    const i = er(e, o, this.gpgpu.gl, this.gpgpu.textureConfig, s);
    if (this.freeTextures[r].length > 0) {
      this.numFreeTextures--, this.numUsedTextures++, this._numBytesFree -= i, this.log();
      const c = this.freeTextures[r].pop();
      return this.usedTextures[r].push(c), c;
    }
    let a;
    return o === Y.PACKED_2X2_FLOAT32 ? a = this.gpgpu.createPackedMatrixTexture(e[0], e[1]) : o === Y.PACKED_2X2_FLOAT16 ? a = this.gpgpu.createFloat16PackedMatrixTexture(e[0], e[1]) : o === Y.UNPACKED_FLOAT32 ? a = this.gpgpu.createFloat32MatrixTexture(e[0], e[1]) : o === Y.UNPACKED_FLOAT16 ? a = this.gpgpu.createFloat16MatrixTexture(e[0], e[1]) : o === Y.PACKED_4X1_UNSIGNED_BYTE && (a = this.gpgpu.createUnsignedBytesMatrixTexture(e[0], e[1])), this.usedTextures[r].push(a), this.numUsedTextures++, this._numBytesAllocated += i, this.log(), a;
  }
  releaseTexture(e, t, s, o) {
    if (this.freeTextures == null)
      return;
    const r = tr(s, o), i = nr(t, r, o);
    i in this.freeTextures || (this.freeTextures[i] = []);
    const a = er(t, r, this.gpgpu.gl, this.gpgpu.textureConfig, o), c = y().get("WEBGL_DELETE_TEXTURE_THRESHOLD");
    c !== -1 && this._numBytesAllocated > c ? (this.gpgpu.deleteMatrixTexture(e.texture), this._numBytesAllocated -= a) : (this.freeTextures[i].push(e), this.numFreeTextures++, this._numBytesFree += a), this.numUsedTextures--;
    const l = this.usedTextures[i], u = l && l.indexOf(e);
    if (u == null || u < 0)
      throw new Error("Cannot release a texture that was never provided by this texture manager");
    l[u] = l[l.length - 1], l.pop(), this.log();
  }
  log() {
    if (!this.logEnabled)
      return;
    const e = this.numFreeTextures + this.numUsedTextures;
    console.log("Free/Used", `${this.numFreeTextures} / ${this.numUsedTextures}`, `(${e})`);
    const t = this._numBytesFree / this._numBytesAllocated;
    console.log(`Bytes allocated: ${this._numBytesAllocated}`), console.log(`Bytes unused: ${this._numBytesFree} (${Math.round(100 * t)}%)`);
  }
  get numBytesAllocated() {
    return this._numBytesAllocated;
  }
  get numBytesFree() {
    return this._numBytesFree;
  }
  getNumUsedTextures() {
    return this.numUsedTextures;
  }
  getNumFreeTextures() {
    return this.numFreeTextures;
  }
  dispose() {
    if (this.freeTextures != null) {
      for (const e in this.freeTextures)
        this.freeTextures[e].forEach((t) => {
          this.gpgpu.deleteMatrixTexture(t.texture);
        });
      for (const e in this.usedTextures)
        this.usedTextures[e].forEach((t) => {
          this.gpgpu.deleteMatrixTexture(t.texture);
        });
      this.freeTextures = null, this.usedTextures = null, this.numUsedTextures = 0, this.numFreeTextures = 0, this._numBytesAllocated = 0, this._numBytesFree = 0;
    }
  }
}
function px(n, e) {
  const t = n;
  if (e === t.R32F)
    return 4;
  if (e === t.R16F)
    return 2;
  if (e === t.RGBA32F)
    return 16;
  if (e === n.RGBA)
    return 16;
  if (e === t.RGBA16F)
    return 8;
  if (e === t.RGBA8)
    return 4;
  throw new Error(`Unknown internal format ${e}`);
}
function er(n, e, t, s, o) {
  const r = mx(e, s);
  let i;
  if (o) {
    const [c, l] = Yt(n[0], n[1]);
    i = c * l;
  } else {
    const [c, l] = wn(n[0], n[1]);
    i = c * l;
  }
  const a = px(t, r);
  return i * a;
}
function mx(n, e) {
  switch (n) {
    case Y.PACKED_2X2_FLOAT32:
      return ha(e);
    case Y.PACKED_2X2_FLOAT16:
      return fa(e);
    case Y.UNPACKED_FLOAT32:
      return la(e);
    case Y.UNPACKED_FLOAT16:
      return ua(e);
    case Y.PACKED_4X1_UNSIGNED_BYTE:
      return da(e);
    default:
      throw new Error(`Unknown physical texture type ${n}`);
  }
}
function gx(n) {
  return y().getBool("WEBGL_RENDER_FLOAT32_ENABLED") ? n ? Y.PACKED_2X2_FLOAT32 : Y.UNPACKED_FLOAT32 : n ? Y.PACKED_2X2_FLOAT16 : Y.UNPACKED_FLOAT16;
}
function tr(n, e) {
  if (n === xe.UPLOAD)
    return Y.PACKED_2X2_FLOAT32;
  if (n === xe.RENDER || n == null)
    return gx(e);
  if (n === xe.DOWNLOAD || n === xe.PIXELS)
    return Y.PACKED_4X1_UNSIGNED_BYTE;
  throw new Error(`Unknown logical texture type ${n}`);
}
function nr(n, e, t) {
  return `${n[0]}_${n[1]}_${e}_${t}`;
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Ue {
  constructor(e, t) {
    this.variableNames = ["A"], this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length), this.userCode = `
      float unaryOperation(float x) {
        ${t}
      }

      void main() {
        float x = getAAtOutCoords();
        float y = unaryOperation(x);

        setOutput(y);
      }
    `;
  }
}
const ke = "if (isnan(x)) return x;", xx = "return x;", sr = "return abs(x);", Cx = "return (x >= 0.0) ? x : (exp(x) - 1.0);", bx = ke + `
  return (x < 0.0) ? 0.0 : x;
`, wx = ke + `
  return (x < 0.0) ? 0.0 : min(6.0, x);
`, Ze = "return x;", yx = "return 1.0 / (1.0 + exp(-1.0 * x));";
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const vx = "return x;", $x = `
  vec4 result;

  result.r = (x.r >= 0.0) ? x.r : (exp(x.r) - 1.0);
  result.g = (x.g >= 0.0) ? x.g : (exp(x.g) - 1.0);
  result.b = (x.b >= 0.0) ? x.b : (exp(x.b) - 1.0);
  result.a = (x.a >= 0.0) ? x.a : (exp(x.a) - 1.0);

  return result;
`, Sx = `
  vec4 result = x * vec4(greaterThanEqual(x, vec4(0.0)));
  bvec4 isNaN = isnan(x);

  result.r = isNaN.r ? x.r : result.r;
  result.g = isNaN.g ? x.g : result.g;
  result.b = isNaN.b ? x.b : result.b;
  result.a = isNaN.a ? x.a : result.a;

  return result;
`, Ix = `
  vec4 result = min(x, vec4(6.)) * vec4(greaterThanEqual(x, vec4(0.0)));
  bvec4 isNaN = isnan(x);

  result.r = isNaN.r ? x.r : result.r;
  result.g = isNaN.g ? x.g : result.g;
  result.b = isNaN.b ? x.b : result.b;
  result.a = isNaN.a ? x.a : result.a;

  return result;
`, Rx = "return 1.0 / (1.0 + exp(-1.0 * x));";
class et {
  constructor(e, t) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0, this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length), this.userCode = `
      vec4 unaryOperation(vec4 x) {
        ${t}
      }

      void main() {
        vec4 x = getAAtOutCoords();
        vec4 y = unaryOperation(x);

        setOutput(y);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Tx {
  constructor(e) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !1, this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length);
    const t = e.length, s = re("rc", t), o = V(t), r = ux(t, s), i = s.slice(-2), a = t <= 1 ? "rc" : `vec2(${i.join(",")})`;
    this.userCode = `
      void main() {
        ${o} rc = getOutputCoords();
        vec4 packedInput = getA(${r});

        setOutput(getChannel(packedInput, ${a}));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ex = Dh, Nx = 1e-7, kx = 1e-4, Dn = {};
function Ax(n) {
  return n in Dn || (Dn[n] = {}), Dn[n];
}
const Fx = y().getNumber("CPU_HANDOFF_SIZE_THRESHOLD"), Dx = 600;
function Ox() {
  return y().global.screen == null ? 1024 : y().global.screen.height * y().global.screen.width * window.devicePixelRatio * Dx / 1024 / 1024;
}
class ns extends vr {
  nextDataId() {
    return ns.nextDataId++;
  }
  constructor(e) {
    if (super(), this.pendingRead = /* @__PURE__ */ new WeakMap(), this.pendingDisposal = /* @__PURE__ */ new WeakSet(), this.dataRefCount = /* @__PURE__ */ new WeakMap(), this.numBytesInGPU = 0, this.uploadWaitMs = 0, this.downloadWaitMs = 0, this.lastGlFlushTime = 0, this.warnedAboutMemory = !1, this.pendingDeletes = 0, this.disposed = !1, !y().getBool("HAS_WEBGL"))
      throw new Error("WebGL is not supported on this device");
    let t;
    if (e != null) {
      if (e instanceof xs)
        t = e;
      else {
        const s = _e(y().getNumber("WEBGL_VERSION"), e);
        t = new xs(s);
      }
      this.binaryCache = {}, this.gpgpuCreatedLocally = !1;
    } else {
      const s = _e(y().getNumber("WEBGL_VERSION"));
      t = new xs(s), this.binaryCache = Ax(y().getNumber("WEBGL_VERSION")), this.gpgpuCreatedLocally = !0;
    }
    this.gpgpu = t, this.canvas = this.gpgpu.gl.canvas, this.textureManager = new fx(this.gpgpu), this.numMBBeforeWarning = Ox(), this.texData = new ec(this, Qe());
  }
  numDataIds() {
    return this.texData.numDataIds() - this.pendingDeletes;
  }
  // Writes a new entry to the data store with a WebGL texture, and registers it
  // to the texture manager.
  writeTexture(e, t, s, o, r, i) {
    const a = this.makeTensorInfo(t, s), c = this.texData.get(a.dataId);
    c.isPacked = !1, c.texture = { texture: e, texShape: [o, r] }, c.texShape = [o, r];
    const l = An(t), u = new Ko(l, !1, i), d = this.runWebGLProgram(u, [a], s, [[o, r]]);
    return d.shape = t, c.texture = null, this.disposeIntermediateTensorInfo(a), d.dataId;
  }
  write(e, t, s) {
    if ((y().getBool("WEBGL_CHECK_NUMERICAL_PROBLEMS") || y().getBool("DEBUG")) && this.checkNumericalProblems(e), s === "complex64" && e != null)
      throw new Error("Cannot write to a complex64 dtype. Please use tf.complex(real, imag).");
    const o = { id: this.nextDataId() };
    return this.texData.set(o, { shape: t, dtype: s, values: e, usage: xe.UPLOAD, refCount: 1 }), o;
  }
  /** Return refCount of a `TensorData`. */
  refCount(e) {
    return this.texData.has(e) ? this.texData.get(e).refCount : 0;
  }
  /** Increase refCount of a `TextureData`. */
  incRef(e) {
    const t = this.texData.get(e);
    t.refCount++;
  }
  /** Decrease refCount of a `TextureData`. */
  decRef(e) {
    if (this.texData.has(e)) {
      const t = this.texData.get(e);
      t.refCount--;
    }
  }
  move(e, t, s, o, r) {
    if (y().getBool("DEBUG") && this.checkNumericalProblems(t), o === "complex64")
      throw new Error("Cannot write to a complex64 dtype. Please use tf.complex(real, imag).");
    this.texData.set(e, { shape: s, dtype: o, values: t, usage: xe.UPLOAD, refCount: r });
  }
  disposeIntermediateTensorInfo(e) {
    this.disposeData(e.dataId);
  }
  readSync(e) {
    const t = this.texData.get(e), { values: s, dtype: o, complexTensorInfos: r, slice: i, shape: a, isPacked: c } = t;
    if (i != null) {
      let h;
      c ? h = new et(a, Ze) : h = new Ue(a, Ze);
      const f = this.runWebGLProgram(h, [{ dataId: e, shape: a, dtype: o }], o), p = this.readSync(f.dataId);
      return this.disposeIntermediateTensorInfo(f), p;
    }
    if (s != null)
      return this.convertAndCacheOnCPU(e);
    if (o === "string")
      return s;
    const l = this.activeTimers != null;
    let u;
    l && (u = Fe());
    let d;
    if (o === "complex64") {
      const h = this.readSync(r.real.dataId), f = this.readSync(r.imag.dataId);
      d = Ls(h, f);
    } else
      d = this.getValuesFromTexture(e);
    return l && (this.downloadWaitMs += Fe() - u), this.convertAndCacheOnCPU(e, d);
  }
  async read(e) {
    if (this.pendingRead.has(e)) {
      const p = this.pendingRead.get(e);
      return new Promise((x) => p.push(x));
    }
    const t = this.texData.get(e), { values: s, shape: o, slice: r, dtype: i, complexTensorInfos: a, isPacked: c } = t;
    if (r != null) {
      let p;
      c ? p = new et(o, Ze) : p = new Ue(o, Ze);
      const x = this.runWebGLProgram(p, [{ dataId: e, shape: o, dtype: i }], i), g = this.read(x.dataId);
      return this.disposeIntermediateTensorInfo(x), g;
    }
    if (s != null)
      return this.convertAndCacheOnCPU(e);
    if (y().getBool("DEBUG") && !y().getBool("WEBGL_DOWNLOAD_FLOAT_ENABLED") && y().getNumber("WEBGL_VERSION") === 2)
      throw new Error("tensor.data() with WEBGL_DOWNLOAD_FLOAT_ENABLED=false and WEBGL_VERSION=2 not yet supported.");
    let l = null, u;
    if (i !== "complex64" && y().get("WEBGL_BUFFER_SUPPORTED")) {
      u = this.decode(e);
      const p = this.texData.get(u.dataId);
      l = this.gpgpu.createBufferFromTexture(p.texture.texture, ...En(o));
    }
    this.pendingRead.set(e, []), i !== "complex64" && await this.gpgpu.createAndWaitForFence();
    let d;
    if (i === "complex64") {
      const p = await Promise.all([
        this.read(a.real.dataId),
        this.read(a.imag.dataId)
      ]), x = p[0], g = p[1];
      d = Ls(x, g);
    } else if (l == null)
      d = this.getValuesFromTexture(e);
    else {
      const p = T(o);
      d = this.gpgpu.downloadFloat32MatrixFromBuffer(l, p);
    }
    if (u != null && this.disposeIntermediateTensorInfo(u), l != null) {
      const p = this.gpgpu.gl;
      k(p, () => p.deleteBuffer(l));
    }
    const h = this.convertAndCacheOnCPU(e, d), f = this.pendingRead.get(e);
    return this.pendingRead.delete(e), f.forEach((p) => p(h)), this.pendingDisposal.has(e) && (this.pendingDisposal.delete(e), this.disposeData(e) && Qe().removeDataId(e, this), this.pendingDeletes--), h;
  }
  /**
   * Read tensor to a new texture that is densely packed for ease of use.
   * @param dataId The source tensor.
   * @param options
   *     customTexShape: Optional. If set, will use the user defined texture
   *     shape to create the texture.
   */
  readToGPU(e, t = {}) {
    const s = this.texData.get(e), { values: o, shape: r, slice: i, dtype: a, isPacked: c, texture: l } = s;
    if (a === "complex64")
      throw new Error("Does not support reading texture for complex64 dtype.");
    if (i != null) {
      let f;
      c ? f = new et(r, Ze) : f = new Ue(r, Ze);
      const p = this.runWebGLProgram(f, [{ dataId: e, shape: r, dtype: a }], a), x = this.readToGPU(p, t);
      return this.disposeIntermediateTensorInfo(p), x;
    }
    if (l == null)
      throw o != null ? new Error("Data is not on GPU but on CPU.") : new Error("There is no data on GPU or CPU.");
    const u = this.decode(e, t.customTexShape), d = Qe().makeTensorFromTensorInfo(u), h = this.texData.get(u.dataId);
    return Object.assign({ tensorRef: d }, h.texture);
  }
  bufferSync(e) {
    const t = this.readSync(e.dataId);
    if (e.dtype === "string")
      try {
        const s = t.map((o) => Vt(o));
        return J(e.shape, e.dtype, s);
      } catch {
        throw new Error("Failed to decode encoded string bytes into utf-8");
      }
    return J(e.shape, e.dtype, t);
  }
  checkNumericalProblems(e) {
    if (e != null)
      for (let t = 0; t < e.length; t++) {
        const s = e[t];
        if (!Of(s))
          throw y().getBool("WEBGL_RENDER_FLOAT32_CAPABLE") ? Error(`The value ${s} cannot be represented with your current settings. Consider enabling float32 rendering: 'tf.env().set('WEBGL_RENDER_FLOAT32_ENABLED', true);'`) : Error(`The value ${s} cannot be represented on this device.`);
      }
  }
  getValuesFromTexture(e) {
    const { shape: t, dtype: s, isPacked: o } = this.texData.get(e), r = T(t);
    if (y().getBool("WEBGL_DOWNLOAD_FLOAT_ENABLED")) {
      const h = this.decode(e), f = this.texData.get(h.dataId), p = this.gpgpu.downloadMatrixFromPackedTexture(f.texture.texture, ...En(t)).subarray(0, r);
      return this.disposeIntermediateTensorInfo(h), p;
    }
    const i = y().getBool("WEBGL_PACK") && o === !0, a = i ? An(t) : t, c = i ? new Yp(a) : new Kp(a), l = this.runWebGLProgram(c, [{ shape: a, dtype: s, dataId: e }], "float32"), u = this.texData.get(l.dataId), d = this.gpgpu.downloadByteEncodedFloatMatrixFromOutputTexture(u.texture.texture, u.texShape[0], u.texShape[1]).subarray(0, r);
    return this.disposeIntermediateTensorInfo(l), d;
  }
  timerAvailable() {
    return y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_RELIABLE") > 0;
  }
  time(e) {
    const t = this.activeTimers, s = [];
    let o = !1;
    this.programTimersStack == null ? (this.programTimersStack = s, o = !0) : this.activeTimers.push(s), this.activeTimers = s, e();
    const r = mt(this.activeTimers.map((c) => c.query)).filter((c) => c != null), i = mt(this.activeTimers.map((c) => c.name)).filter((c) => c != null);
    this.activeTimers = t, o && (this.programTimersStack = null);
    const a = {
      uploadWaitMs: this.uploadWaitMs,
      downloadWaitMs: this.downloadWaitMs,
      kernelMs: null,
      wallMs: null
      // will be filled by the engine
    };
    return (async () => {
      if (y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_RELIABLE") > 0) {
        const c = await Promise.all(r);
        a.kernelMs = tc(c), a.getExtraProfileInfo = () => c.map((l, u) => ({ name: i[u], ms: l })).map((l) => `${l.name}: ${l.ms}`).join(", ");
      } else
        a.kernelMs = {
          error: "WebGL query timers are not supported in this environment."
        };
      return this.uploadWaitMs = 0, this.downloadWaitMs = 0, a;
    })();
  }
  memory() {
    return {
      unreliable: !1,
      numBytesInGPU: this.numBytesInGPU,
      numBytesInGPUAllocated: this.textureManager.numBytesAllocated,
      numBytesInGPUFree: this.textureManager.numBytesFree
    };
  }
  startTimer() {
    return y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_RELIABLE") > 0 ? this.gpgpu.beginQuery() : { startMs: Fe(), endMs: null };
  }
  endTimer(e) {
    return y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_RELIABLE") > 0 ? (this.gpgpu.endQuery(), e) : (e.endMs = Fe(), e);
  }
  async getQueryTime(e) {
    if (y().getNumber("WEBGL_DISJOINT_QUERY_TIMER_EXTENSION_RELIABLE") > 0)
      return this.gpgpu.waitForQueryAndGetTime(e);
    const t = e;
    return t.endMs - t.startMs;
  }
  /**
   * Decrease the RefCount on the dataId and dispose the memory if the dataId
   * has 0 refCount. If there are pending read on the data, the disposal would
   * added to the pending delete queue. Return true if the dataId is removed
   * from backend or the backend does not contain the dataId, false if the
   * dataId is not removed. Memory may or may not be released even when dataId
   * is removed, which also depends on dataRefCount, see `releaseGPU`.
   * @param dataId
   * @oaram force Optional, remove the data regardless of refCount
   */
  disposeData(e, t = !1) {
    if (this.pendingDisposal.has(e))
      return !1;
    if (!this.texData.has(e))
      return !0;
    if (t ? this.texData.get(e).refCount = 0 : this.texData.get(e).refCount--, !t && this.texData.get(e).refCount > 0)
      return !1;
    if (this.pendingRead.has(e))
      return this.pendingDisposal.add(e), this.pendingDeletes++, !1;
    this.releaseGPUData(e);
    const { complexTensorInfos: s } = this.texData.get(e);
    return s != null && (this.disposeData(s.real.dataId, t), this.disposeData(s.imag.dataId, t)), this.texData.delete(e), !0;
  }
  releaseGPUData(e) {
    const { texture: t, dtype: s, texShape: o, usage: r, isPacked: i, slice: a } = this.texData.get(e), c = a && a.origDataId || e, l = this.dataRefCount.get(c);
    l > 1 ? this.dataRefCount.set(c, l - 1) : (this.dataRefCount.delete(c), t != null && (this.numBytesInGPU -= this.computeBytes(o, s), this.textureManager.releaseTexture(t, o, r, i)));
    const u = this.texData.get(e);
    u.texture = null, u.texShape = null, u.isPacked = !1, u.slice = null;
  }
  getTexture(e) {
    return this.uploadToGPU(e), this.texData.get(e).texture.texture;
  }
  /**
   * Returns internal information for the specific data bucket. Used in unit
   * tests.
   */
  getDataInfo(e) {
    return this.texData.get(e);
  }
  /*
  Tests whether all the inputs to an op are small and on the CPU. This heuristic
  determines when it would be faster to execute a kernel on the CPU. WebGL
  kernels opt into running this check and forwarding when appropriate.
  TODO(https://github.com/tensorflow/tfjs/issues/872): Develop a more
  sustainable strategy for optimizing backend execution of ops.
   */
  shouldExecuteOnCPU(e, t = Fx) {
    return y().getBool("WEBGL_CPU_FORWARD") && e.every((s) => this.texData.get(s.dataId).texture == null && T(s.shape) < t);
  }
  getGPGPUContext() {
    return this.gpgpu;
  }
  where(e) {
    Pe("tf.where() in webgl locks the UI thread. Call tf.whereAsync() instead");
    const t = e.dataSync();
    return Ex(e.shape, t);
  }
  packedUnaryOp(e, t, s) {
    const o = new et(e.shape, t), r = this.compileAndRun(o, [e], s);
    return Qe().makeTensorFromTensorInfo(r);
  }
  // TODO(msoulanille) remove this once the backend has been modularized
  // a copy is needed here to break a circular dependency.
  // Also remove the op from unary_op.
  abs(e) {
    if (this.shouldExecuteOnCPU([e]) && e.dtype !== "complex64") {
      const o = xa(this.texData.get(e.dataId).values);
      return this.makeOutput(e.shape, e.dtype, o);
    }
    if (y().getBool("WEBGL_PACK_UNARY_OPERATIONS"))
      return this.packedUnaryOp(e, sr, e.dtype);
    const t = new Ue(e.shape, sr), s = this.compileAndRun(t, [e]);
    return Qe().makeTensorFromTensorInfo(s);
  }
  makeTensorInfo(e, t, s) {
    let o;
    if (t === "string" && s != null && s.length > 0 && Kn(s[0])) {
      const r = s.map((i) => ht(i));
      o = this.write(r, e, t);
    } else
      o = this.write(s, e, t);
    return this.texData.get(o).usage = null, { dataId: o, shape: e, dtype: t };
  }
  makeOutput(e, t, s) {
    return Qe().makeTensorFromTensorInfo(this.makeTensorInfo(e, t, s), this);
  }
  unpackTensor(e) {
    const t = new Tx(e.shape);
    return this.runWebGLProgram(t, [e], e.dtype);
  }
  packTensor(e) {
    const t = new dx(e.shape);
    return this.runWebGLProgram(t, [e], e.dtype, null, !0);
  }
  packedReshape(e, t) {
    const s = [
      zt(e.shape),
      ...Ht(e.shape)
    ], o = {
      dtype: e.dtype,
      shape: s,
      dataId: e.dataId
    }, r = [
      zt(t),
      ...Ht(t)
    ], i = new wa(r, s), a = !0, c = [s], l = this.runWebGLProgram(i, [o], e.dtype, c, a);
    return { dataId: l.dataId, shape: t, dtype: l.dtype };
  }
  decode(e, t) {
    const s = this.texData.get(e), { isPacked: o, shape: r, dtype: i } = s;
    if (t != null) {
      const h = T(r), f = t[0] * t[1] * 4;
      N(h <= f, () => "customTexShape is too small. Row * Column * 4 should be equal or larger than the size of the tensor data.");
    }
    const a = An(r);
    let c;
    o ? c = new jp(a) : c = new qp(a);
    const l = !0, u = [t ?? En(a)], d = this.runWebGLProgram(c, [{ shape: a, dtype: i, dataId: e }], i, u, l, t);
    return { dtype: i, shape: r, dataId: d.dataId };
  }
  runWebGLProgram(e, t, s, o, r = !1, i) {
    const a = this.makeTensorInfo(e.outputShape, s), c = this.texData.get(a.dataId);
    if (e.packedOutput && (c.isPacked = !0), e.outPackingScheme === hn.DENSE) {
      const m = i ?? En(e.outputShape);
      c.texShape = m.map((C) => C * 2);
    }
    if (e.outTexUsage != null && (c.usage = e.outTexUsage), T(a.shape) === 0)
      return c.values = pt(a.dtype, 0), a;
    const l = [], u = t.map((m) => {
      if (m.dtype === "complex64")
        throw new Error("GPGPUProgram does not support complex64 input. For complex64 dtypes, please separate the program into real and imaginary parts.");
      let C = this.texData.get(m.dataId);
      if (C.texture == null) {
        if (!e.packedInputs && T(m.shape) <= y().getNumber("WEBGL_SIZE_UPLOAD_UNIFORM"))
          return {
            shape: m.shape,
            texData: null,
            isUniform: !0,
            uniformValues: C.values
          };
        e.packedInputs && (C.isPacked = !0, C.shape = m.shape);
      }
      if (this.uploadToGPU(m.dataId), !!C.isPacked != !!e.packedInputs)
        m = C.isPacked ? this.unpackTensor(m) : this.packTensor(m), l.push(m), C = this.texData.get(m.dataId);
      else if (C.isPacked && !zn(C.shape, m.shape)) {
        const b = m, w = m.shape;
        m.shape = C.shape, m = this.packedReshape(m, w), l.push(m), C = this.texData.get(m.dataId), b.shape = w;
      }
      return { shape: m.shape, texData: C, isUniform: !1 };
    });
    this.uploadToGPU(a.dataId);
    const d = { shape: a.shape, texData: c, isUniform: !1 }, h = Xp(e, u, d), f = this.getAndSaveBinary(h, () => zp(this.gpgpu, e, u, d)), p = this.activeTimers != null;
    let x;
    p && (x = this.startTimer()), y().get("ENGINE_COMPILE_ONLY") || Hp(this.gpgpu, f, u, d, o), l.forEach((m) => this.disposeIntermediateTensorInfo(m)), p && (x = this.endTimer(x), this.activeTimers.push({ name: e.constructor.name, query: this.getQueryTime(x) }));
    const g = y().get("WEBGL_FLUSH_THRESHOLD");
    if (g > 0) {
      const m = Fe();
      m - this.lastGlFlushTime > g && (this.gpgpu.gl.flush(), this.lastGlFlushTime = m);
    }
    if (!y().getBool("WEBGL_LAZILY_UNPACK") && c.isPacked && r === !1) {
      const m = this.unpackTensor(a);
      return this.disposeIntermediateTensorInfo(a), m;
    }
    return a;
  }
  compileAndRun(e, t, s, o, r = !1) {
    return s = s || t[0].dtype, this.runWebGLProgram(e, t, s, o, r);
  }
  getAndSaveBinary(e, t) {
    return e in this.binaryCache || (this.binaryCache[e] = t()), this.binaryCache[e];
  }
  getTextureManager() {
    return this.textureManager;
  }
  dispose() {
    this.disposed || (y().getBool("IS_TEST") || Object.keys(this.binaryCache).forEach((t) => {
      this.gpgpu.deleteProgram(this.binaryCache[t].webGLProgram), delete this.binaryCache[t];
    }), this.textureManager.dispose(), this.canvas != null && typeof HTMLCanvasElement < "u" && this.canvas instanceof HTMLCanvasElement ? this.canvas.remove() : this.canvas = null, this.gpgpuCreatedLocally && (this.gpgpu.program = null, this.gpgpu.dispose()), this.disposed = !0);
  }
  floatPrecision() {
    return this.floatPrecisionValue == null && (this.floatPrecisionValue = H(() => {
      if (!y().get("WEBGL_RENDER_FLOAT32_ENABLED")) {
        const e = y().getBool("DEBUG");
        y().set("DEBUG", !1);
        const t = this.abs(st(1e-8)).dataSync()[0];
        if (y().set("DEBUG", e), t > 0)
          return 32;
      }
      return 16;
    })), this.floatPrecisionValue;
  }
  /** Returns the smallest representable number.  */
  epsilon() {
    return this.floatPrecision() === 32 ? Nx : kx;
  }
  uploadToGPU(e) {
    const t = this.texData.get(e), { shape: s, dtype: o, values: r, texture: i, usage: a, isPacked: c } = t;
    if (i != null)
      return;
    const l = this.activeTimers != null;
    let u;
    l && (u = Fe());
    let d = t.texShape;
    if (d == null && (d = Zf(s, c), t.texShape = d), r != null) {
      const h = An(s);
      let f, p = d[1], x = d[0];
      const g = r instanceof Uint8Array || r instanceof Uint8ClampedArray;
      (c || !g) && ([p, x] = Yt(d[0], d[1])), c ? f = new Zp(h, g) : f = new Ko(h, g);
      const m = g ? [x, p] : d, C = this.makeTensorInfo(m, o), b = this.texData.get(C.dataId);
      g ? b.usage = xe.PIXELS : b.usage = xe.UPLOAD, b.texShape = m, this.gpgpu.uploadDenseMatrixToTexture(this.getTexture(C.dataId), p, x, r);
      const w = [[x, p]], E = this.runWebGLProgram(f, [C], o, w, !0), R = this.texData.get(E.dataId);
      t.texShape = R.texShape, t.isPacked = R.isPacked, t.usage = R.usage, y().get("ENGINE_COMPILE_ONLY") ? this.disposeData(E.dataId) : (t.texture = R.texture, t.values = null, this.texData.delete(E.dataId)), this.disposeIntermediateTensorInfo(C), l && (this.uploadWaitMs += Fe() - u);
    } else {
      const h = this.acquireTexture(d, a, o, c);
      t.texture = h;
    }
  }
  convertAndCacheOnCPU(e, t) {
    const s = this.texData.get(e), { dtype: o } = s;
    return t != null && (s.values = Px(t, o)), s.values;
  }
  acquireTexture(e, t, s, o) {
    if (this.numBytesInGPU += this.computeBytes(e, s), !this.warnedAboutMemory && this.numBytesInGPU > this.numMBBeforeWarning * 1024 * 1024) {
      const r = (this.numBytesInGPU / 1024 / 1024).toFixed(2);
      this.warnedAboutMemory = !0, console.warn(`High memory usage in GPU: ${r} MB, most likely due to a memory leak`);
    }
    return this.textureManager.acquireTexture(e, t, o);
  }
  computeBytes(e, t) {
    return e[0] * e[1] * Ln(t);
  }
  checkCompileCompletion() {
    for (const [, e] of Object.entries(this.binaryCache))
      this.checkCompletion_(e);
  }
  async checkCompileCompletionAsync() {
    const e = [];
    if (this.gpgpu.parallelCompilationExtension) {
      for (const [, t] of Object.entries(this.binaryCache))
        e.push(this.checkCompletionAsync_(t));
      return Promise.all(e);
    } else {
      for (const [, t] of Object.entries(this.binaryCache)) {
        const s = new Promise((o) => {
          try {
            this.checkCompletion_(t), o(!0);
          } catch (r) {
            throw r;
          }
        });
        e.push(s);
      }
      return Promise.all(e);
    }
  }
  async checkCompletionAsync_(e) {
    return this.gpgpu.gl.getProgramParameter(e.webGLProgram, this.gpgpu.parallelCompilationExtension.COMPLETION_STATUS_KHR) ? this.checkCompletion_(e) : (await bf(), this.checkCompletionAsync_(e));
  }
  checkCompletion_(e) {
    if (this.gpgpu.gl.getProgramParameter(e.webGLProgram, this.gpgpu.gl.LINK_STATUS) === !1)
      throw console.log(this.gpgpu.gl.getProgramInfoLog(e.webGLProgram)), this.gpgpu.gl.getShaderParameter(e.fragmentShader, this.gpgpu.gl.COMPILE_STATUS) === !1 ? (sa(e.source, this.gpgpu.gl.getShaderInfoLog(e.fragmentShader)), new Error("Failed to compile fragment shader.")) : new Error("Failed to link vertex and fragment shaders.");
    return !0;
  }
  getUniformLocations() {
    for (const e of Object.values(this.binaryCache)) {
      this.gpgpu.buildVao(e.webGLProgram);
      const { variablesLocations: t, customUniformLocations: s, infLoc: o, nanLoc: r, outShapeLocation: i, outShapeStridesLocation: a, outTexShapeLocation: c } = ca(this.gpgpu, e.program, e.webGLProgram);
      e.variablesLocations = t, e.customUniformLocations = s, e.infLoc = o, e.nanLoc = r, e.outShapeLocation = i, e.outShapeStridesLocation = a, e.outTexShapeLocation = c;
    }
  }
  /**
   * Create a TF.js tensor out of an existing WebGL texture. A new texture will
   * be created.
   */
  createTensorFromGPUData(e, t, s) {
    e.channels = e.channels || "RGBA";
    const { texture: o, height: r, width: i, channels: a } = e, c = Qe().backend;
    if (!c.gpgpu.gl.isTexture(o))
      throw new Error("The texture is invalid. Also, please make sure the texture and the TFJS WebGL backend are using the same canvas. If you want to use your own custom canvas, you have to create and use the custom TFJS WebGL backend created from the canvas through 'new tf.MathBackendWebGL(customCanvas)'.");
    const l = c.writeTexture(o, t, s, r, i, a);
    return Qe().makeTensorFromDataId(l, t, s, c);
  }
}
ns.nextDataId = 0;
function Px(n, e) {
  if (e === "float32" || e === "complex64")
    return n;
  if (e === "int32" || e === "bool") {
    const t = e === "int32" ? new Int32Array(n.length) : new Uint8Array(n.length);
    for (let s = 0; s < t.length; ++s)
      t[s] = Math.round(n[s]);
    return t;
  } else
    throw new Error(`Unknown dtype ${e}`);
}
/**
 * @license
 * Copyright 2020 Google Inc. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
ri() && lh(
  "webgl",
  () => new ns(),
  2
  /* priority */
);
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const po = `
  if (isnan(a)) return a;
  if (isnan(b)) return b;
`;
class wt {
  constructor(e, t, s) {
    this.variableNames = ["A", "B"], this.outputShape = ie(t, s), this.enableShapeUniforms = ne(this.outputShape.length), this.userCode = `
      float binaryOperation(float a, float b) {
        ${e}
      }

      void main() {
        float a = getAAtOutCoords();
        float b = getBAtOutCoords();
        setOutput(binaryOperation(a, b));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Et = `
  result.r = isNaN.r ? NAN : result.r;
  result.g = isNaN.g ? NAN : result.g;
  result.b = isNaN.b ? NAN : result.b;
  result.a = isNaN.a ? NAN : result.a;
`;
class tn {
  constructor(e, t, s, o = !1) {
    this.variableNames = ["A", "B"], this.supportsBroadcasting = !0, this.packedInputs = !0, this.packedOutput = !0, this.outputShape = ie(t, s);
    const r = this.outputShape.length;
    this.enableShapeUniforms = ne(r);
    let i = "";
    if (o)
      if (r === 0 || T(this.outputShape) === 1)
        i = `
          result.y = 0.;
          result.z = 0.;
          result.w = 0.;
        `;
      else if (i = `
          ${V(r)} coords = getOutputCoords();
        `, r === 1)
        this.enableShapeUniforms ? i += `
            result.y = (coords + 1) >= outShape ? 0. : result.y;
            result.z = 0.;
            result.w = 0.;
          ` : i += `
            result.y = (coords + 1) >= ${this.outputShape[0]} ? 0. : result.y;
            result.z = 0.;
            result.w = 0.;
          `;
      else {
        const c = re("coords", r);
        this.enableShapeUniforms ? i += `
            bool nextRowOutOfBounds =
              (${c[r - 2]} + 1) >= outShape[${r} - 2];
            bool nextColOutOfBounds =
              (${c[r - 1]} + 1) >= outShape[${r} - 1];
            result.y = nextColOutOfBounds ? 0. : result.y;
            result.z = nextRowOutOfBounds ? 0. : result.z;
            result.w = nextColOutOfBounds || nextRowOutOfBounds ? 0. : result.w;
          ` : i += `
            bool nextRowOutOfBounds =
              (${c[r - 2]} + 1) >= ${this.outputShape[r - 2]};
            bool nextColOutOfBounds =
              (${c[r - 1]} + 1) >= ${this.outputShape[r - 1]};
            result.y = nextColOutOfBounds ? 0. : result.y;
            result.z = nextRowOutOfBounds ? 0. : result.z;
            result.w = nextColOutOfBounds || nextRowOutOfBounds ? 0. : result.w;
          `;
      }
    this.userCode = `
      vec4 binaryOperation(vec4 a, vec4 b) {
        ${e}
      }

      void main() {
        vec4 a = getAAtOutCoords();
        vec4 b = getBAtOutCoords();

        vec4 result = binaryOperation(a, b);
        ${i}

        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function me(n) {
  const { inputs: e, backend: t } = n, { x: s } = e;
  return t.incRef(s.dataId), { dataId: s.dataId, shape: s.shape, dtype: s.dtype };
}
const _x = {
  kernelName: Ks,
  backendName: "webgl",
  kernelFunc: me
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ot(n) {
  const { inputs: e, backend: t } = n, { real: s, imag: o } = e, r = t.makeTensorInfo(s.shape, "complex64"), i = t.texData.get(r.dataId), a = me({ inputs: { x: s }, backend: t }), c = me({ inputs: { x: o }, backend: t });
  return i.complexTensorInfos = { real: a, imag: c }, r;
}
const Lx = {
  kernelName: Nr,
  backendName: "webgl",
  kernelFunc: ot
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ya = "return (a < 0.) ? b * a : a;", va = `
  vec4 aLessThanZero = vec4(lessThan(a, vec4(0.)));
  return (aLessThanZero * (b * a)) + ((vec4(1.0) - aLessThanZero) * a);
`;
function Bx(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { alpha: r } = s, i = t.makeTensorInfo([], "float32", Xt(r, "float32")), a = y().getBool("WEBGL_PACK_BINARY_OPERATIONS") ? new tn(va, o.shape, i.shape) : new wt(ya, o.shape, i.shape), c = t.runWebGLProgram(a, [o, i], "float32");
  return t.disposeIntermediateTensorInfo(i), c;
}
const Mx = {
  kernelName: Il,
  backendName: "webgl",
  kernelFunc: Bx
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const $a = "return (a < 0.) ? b * a : a;", Sa = `
  vec4 aLessThanZero = vec4(lessThan(a, vec4(0.)));
  return (aLessThanZero * (b * a)) + ((vec4(1.0) - aLessThanZero) * a);
`;
function Vx(n) {
  const { inputs: e, backend: t } = n, { x: s, alpha: o } = e, r = y().getBool("WEBGL_PACK_BINARY_OPERATIONS") ? new tn(Sa, s.shape, o.shape) : new wt($a, s.shape, o.shape);
  return t.runWebGLProgram(r, [s, o], "float32");
}
const Ux = {
  kernelName: su,
  backendName: "webgl",
  kernelFunc: Vx
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const nn = "if (isnan(x)) return x;";
function _({ opSnippet: n, packedOpSnippet: e, cpuKernelImpl: t, dtype: s }) {
  return ({ inputs: o, backend: r }) => {
    const { x: i } = o, a = r, c = s || i.dtype;
    if (a.shouldExecuteOnCPU([i]) && t != null) {
      const d = a.texData.get(i.dataId), h = t(d.values, c);
      return a.makeTensorInfo(i.shape, c, h);
    }
    const l = y().getBool("WEBGL_PACK_UNARY_OPERATIONS") && e != null;
    let u;
    return l ? u = new et(i.shape, e) : u = new Ue(i.shape, n), a.runWebGLProgram(u, [i], c);
  };
}
function ee({ opSnippet: n, packedOpSnippet: e, checkOutOfBounds: t = !1, supportsComplex: s = !1, cpuKernelImpl: o, dtype: r }) {
  return ({ inputs: i, backend: a }) => {
    const { a: c, b: l } = i, u = a;
    if (s && c.dtype === "complex64") {
      const p = u.texData.get(c.dataId), x = u.texData.get(l.dataId), [g, m] = [
        [p.complexTensorInfos.real, x.complexTensorInfos.real],
        [p.complexTensorInfos.imag, x.complexTensorInfos.imag]
      ].map((b) => {
        const [w, v] = b, E = {
          dataId: w.dataId,
          dtype: w.dtype,
          shape: c.shape
        }, R = {
          dataId: v.dataId,
          dtype: v.dtype,
          shape: l.shape
        }, $ = new wt(n, c.shape, l.shape);
        return u.runWebGLProgram($, [E, R], ze(w.dtype, v.dtype));
      }), C = ot({ inputs: { real: g, imag: m }, backend: u });
      return u.disposeIntermediateTensorInfo(g), u.disposeIntermediateTensorInfo(m), C;
    }
    const d = r || ze(c.dtype, l.dtype);
    if ((c.dtype === "string" || l.dtype === "string" || u.shouldExecuteOnCPU([c, l])) && o != null) {
      const p = u.texData.get(c.dataId).values, x = u.texData.get(l.dataId).values, g = c.dtype === "string" ? (
        // tslint:disable-next-line: no-any
        Gt(p)
      ) : p, m = c.dtype === "string" ? (
        // tslint:disable-next-line: no-any
        Gt(x)
      ) : x, [C, b] = o(c.shape, l.shape, g, m, d), w = u.makeTensorInfo(b, d), v = u.texData.get(w.dataId);
      return v.values = C, w;
    }
    const h = y().getBool("WEBGL_PACK_BINARY_OPERATIONS") && e != null;
    let f;
    return h ? f = new tn(e, c.shape, l.shape, t) : f = new wt(n, c.shape, l.shape), u.runWebGLProgram(f, [c, l], d);
  };
}
function fn(n, e = !1) {
  if (n === "linear")
    return e ? vx : xx;
  if (n === "relu")
    return e ? Sx : bx;
  if (n === "elu")
    return e ? $x : Cx;
  if (n === "relu6")
    return e ? Ix : wx;
  if (n === "prelu")
    return e ? Sa : $a;
  if (n === "leakyrelu")
    return e ? va : ya;
  if (n === "sigmoid")
    return e ? Rx : yx;
  throw new Error(`Activation ${n} has not been implemented for the WebGL backend.`);
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Ia {
  constructor(e, t, s, o = !1, r = !1, i = !1, a = null, c = !1, l = !1) {
    this.variableNames = ["matrixA", "matrixB"], this.packedInputs = !0, this.packedOutput = !0, this.outputShape = s, this.enableShapeUniforms = ne(this.outputShape.length);
    const u = o ? e[1] : e[2], d = Math.ceil(u / 2), h = o ? "i * 2, rc.y" : "rc.y, i * 2", f = r ? "rc.z, i * 2" : "i * 2, rc.z", p = o ? ["a.xxyy", "a.zzww"] : ["a.xxzz", "a.yyww"], x = r ? ["b.xzxz", "b.ywyw"] : ["b.xyxy", "b.zwzw"];
    let g = "", m = "";
    a && (c ? g = `vec4 activation(vec4 a) {
          vec4 b = getPreluActivationWeightsAtOutCoords();
          ${a}
        }` : l ? g = `vec4 activation(vec4 a) {
          vec4 b = getLeakyreluAlphaAtOutCoords();
          ${a}
        }` : g = `vec4 activation(vec4 x) {
          ${a}
        }`, m = "result = activation(result);");
    const C = i ? "result += getBiasAtOutCoords();" : "";
    i && this.variableNames.push("bias"), c && this.variableNames.push("preluActivationWeights"), l && this.variableNames.push("leakyreluAlpha");
    let b = "rc.x", w = "rc.x";
    e[0] < t[0] ? b = `imod(rc.x, ${e[0]})` : t[0] < e[0] && (w = `imod(rc.x, ${t[0]})`), this.userCode = `
      ${g}
      // Don't use uniform for sharedDimensionPacked for performance.
      const float sharedDimension = ${d}.0;

      vec4 dot2x2ARowBCol(ivec3 rc) {
        vec4 result = vec4(0);
        int batchA = ${b};
        int batchB = ${w};
        for (int i = 0; i < ${d}; i++) {
          vec4 a = getMatrixA(batchA, ${h});
          vec4 b = getMatrixB(batchB, ${f});

          // These swizzled products need to be separately added.
          // See: https://github.com/tensorflow/tfjs/issues/1735
          result += (${p[0]} * ${x[0]});
          result += (${p[1]} * ${x[1]});
        }
        return result;
      }

      void main() {
        ivec3 rc = getOutputCoords();
        vec4 result = dot2x2ARowBCol(rc);

        ${C}

        ${m}

        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const or = {
  REAL: "return areal * breal - aimag * bimag;",
  IMAG: "return areal * bimag + aimag * breal;"
};
class rr {
  constructor(e, t, s) {
    this.variableNames = ["AReal", "AImag", "BReal", "BImag"], this.outputShape = ie(t, s), this.userCode = `
      float binaryOpComplex(
          float areal, float aimag, float breal, float bimag) {
        ${e}
      }

      void main() {
        float areal = getARealAtOutCoords();
        float aimag = getAImagAtOutCoords();
        float breal = getBRealAtOutCoords();
        float bimag = getBImagAtOutCoords();
        setOutput(binaryOpComplex(areal, aimag, breal, bimag));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ir = "return a * b;";
function mo(n) {
  const { inputs: e, backend: t } = n, { a: s, b: o } = e, r = ze(s.dtype, o.dtype);
  if (s.dtype === "complex64") {
    const a = t.texData.get(s.dataId), c = t.texData.get(o.dataId), l = new rr(or.REAL, s.shape, o.shape), u = new rr(or.IMAG, s.shape, o.shape), d = [
      {
        dataId: a.complexTensorInfos.real.dataId,
        dtype: a.complexTensorInfos.real.dtype,
        shape: s.shape
      },
      {
        dataId: a.complexTensorInfos.imag.dataId,
        dtype: a.complexTensorInfos.imag.dtype,
        shape: s.shape
      },
      {
        dataId: c.complexTensorInfos.real.dataId,
        dtype: c.complexTensorInfos.real.dtype,
        shape: o.shape
      },
      {
        dataId: c.complexTensorInfos.imag.dataId,
        dtype: c.complexTensorInfos.imag.dtype,
        shape: o.shape
      }
    ], h = t.runWebGLProgram(l, d, "float32"), f = t.runWebGLProgram(u, d, "float32"), p = ot({ inputs: { real: h, imag: f }, backend: t });
    return t.disposeIntermediateTensorInfo(h), t.disposeIntermediateTensorInfo(f), p;
  }
  if (t.shouldExecuteOnCPU([s, o])) {
    const a = t.texData.get(s.dataId), c = t.texData.get(o.dataId), [l, u] = Vg(s.shape, o.shape, a.values, c.values, r), d = t.makeTensorInfo(u, r), h = t.texData.get(d.dataId);
    return h.values = l, d;
  }
  let i;
  return y().getBool("WEBGL_PACK_BINARY_OPERATIONS") ? i = new tn(ir, s.shape, o.shape) : i = new wt(ir, s.shape, o.shape), t.runWebGLProgram(i, [s, o], r);
}
const Wx = {
  kernelName: Pr,
  backendName: "webgl",
  kernelFunc: mo
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Gx(n, e, t) {
  const s = [
    zt(n.shape),
    ...Ht(n.shape)
  ], o = {
    dtype: n.dtype,
    shape: s,
    dataId: n.dataId
  }, r = [
    zt(e),
    ...Ht(e)
  ], i = new wa(r, s), a = !0, c = [s], l = t.runWebGLProgram(i, [o], n.dtype, c, a);
  return { dataId: l.dataId, shape: e, dtype: l.dtype };
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function S(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { shape: r } = s, i = t, a = T(o.shape), c = nc(r, a), l = T(c);
  N(a === l, () => `The new shape (${c}) has ${l} elements and the old shape (${o.shape}) has ${a} elements. The new shape and old shape must have the same number of elements.`);
  const u = i.texData.get(o.dataId);
  return u.isPacked && !zn(o.shape, c) && !(u.texture !== null && zn(u.shape, c)) ? Gx(o, c, i) : (i.incRef(o.dataId), { dataId: o.dataId, shape: c, dtype: o.dtype });
}
const zx = {
  kernelName: Lr,
  backendName: "webgl",
  kernelFunc: S
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class ar {
  constructor(e, t) {
    this.variableNames = ["x"];
    const { windowSize: s, batchSize: o, inSize: r, outSize: i } = e;
    this.outputShape = [o, i];
    const a = Math.floor(s / 4) * 4, c = s % 4;
    let l = "sumValue += dot(values, ones);";
    if (t != null) {
      const d = 1 / t;
      l = `sumValue += dot(values * ${Sr(d) ? d.toPrecision(2) : d}, ones);`;
    }
    let u = "";
    r % s > 0 && (u = `
        if (inIdx < 0 || inIdx >= ${r}) {
          return 0.0;
        }
      `), this.userCode = `
      const vec4 ones = vec4(1.0, 1.0, 1.0, 1.0);

      float getValue(int batch, int inIdx) {
        ${u}
        return getX(batch, inIdx);
      }

      void main() {
        ivec2 coords = getOutputCoords();
        int batch = coords[0];
        int outIdx = coords[1];
        int inOffset = outIdx * ${s};

        float sumValue = 0.0;

        for (int i = 0; i < ${a}; i += 4) {
          int inIdx = inOffset + i;
          vec4 values = vec4(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1),
            getValue(batch, inIdx + 2),
            getValue(batch, inIdx + 3)
          );

          ${l}
        }

        int inIdx = inOffset + ${a};
        if (${c === 1}) {
          vec4 values = vec4(getValue(batch, inIdx), 0.0, 0.0, 0.0);

          ${l}
        } else if (${c === 2}) {
          vec4 values = vec4(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1), 0.0, 0.0);

          ${l}
        } else if (${c === 3}) {
          vec4 values = vec4(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1),
            getValue(batch, inIdx + 2), 0.0);

          ${l}
        }
        setOutput(sumValue);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Hx {
  constructor(e, t) {
    this.variableNames = ["x"];
    const { windowSize: s, batchSize: o, inSize: r, outSize: i } = e;
    this.outputShape = [o, i];
    let a = "0.0", c = "";
    t === "prod" ? a = "1.0" : t === "min" ? (a = "1.0 / 1e-20", c = "min") : t === "max" && (a = "-1.0 / 1e-20", c = "max");
    let l = `${t}(${t}(${t}(minMaxValue[0], minMaxValue[1]), minMaxValue[2]), minMaxValue[3])`;
    t === "sum" ? l = "sumValue" : t === "prod" ? l = "prodValue" : t === "all" ? l = "allValue" : t === "any" && (l = "anyValue");
    const u = Math.floor(s / 4) * 4, d = s % 4;
    let h = `
      if (${t === "sum"}) {
        sumValue += dot(values, ones);
      } else if (${t === "prod"}) {
        vec2 tmp = vec2(values[0], values[1]) * vec2(values[2], values[3]);
        prodValue *= tmp[0] * tmp[1];
      } else {
        minMaxValue = ${c}(values, minMaxValue);
        if (${t === "min"} || ${t === "max"}) {
          minMaxValue = ${c}(values, minMaxValue);
          bvec4 isNaN = isnan(values);
          if (isNaN.r || isNaN.g || isNaN.b || isNaN.a) {
            minMaxValue = vec4(NAN);
          }
        }
      }
    `, f = "vec4";
    t === "all" ? (a = "1.0", h = `
        bool reducedAllValue = all(values);
        float floatedReducedAllValue = float(reducedAllValue);
        allValue = float(allValue >= 1.0 && floatedReducedAllValue >= 1.0);
      `, f = "bvec4") : t === "any" && (a = "0.0", h = `
        bool reducedAnyValue = any(values);
        float floatedReducedAnyValue = float(reducedAnyValue);
        anyValue = float(anyValue >= 1.0 || floatedReducedAnyValue >= 1.0);
      `, f = "bvec4");
    let p = "";
    r % s > 0 && (p = `
        if (inIdx < 0 || inIdx >= ${r}) {
          return initializationValue;
        }
      `), this.userCode = `
      const float initializationValue = ${a};
      const vec4 ones = vec4(1.0, 1.0, 1.0, 1.0);

      float getValue(int batch, int inIdx) {
        ${p}
        return getX(batch, inIdx);
      }

      void main() {
        ivec2 coords = getOutputCoords();
        int batch = coords[0];
        int outIdx = coords[1];
        int inOffset = outIdx * ${s};

        vec4 minMaxValue = vec4(${a});
        float prodValue = 1.0;
        float sumValue = 0.0;
        float allValue = 1.0;
        float anyValue = 0.0;

        for (int i = 0; i < ${u}; i += 4) {
          int inIdx = inOffset + i;
          ${f} values = ${f}(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1),
            getValue(batch, inIdx + 2),
            getValue(batch, inIdx + 3)
          );

          ${h}
        }

        int inIdx = inOffset + ${u};
        if (${d === 1}) {
          ${f} values = ${f}(
            getValue(batch, inIdx),
            initializationValue,
            initializationValue,
            initializationValue
          );

          ${h}
        } else if (${d === 2}) {
          ${f} values = ${f}(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1),
            initializationValue,
            initializationValue
          );

          ${h}
        } else if (${d === 3}) {
          ${f} values = ${f}(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1),
            getValue(batch, inIdx + 2),
            initializationValue
          );

          ${h}
        }
        setOutput(${l});
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Xx(n) {
  const e = [];
  for (; e.length === 0 || e[e.length - 1].outSize !== 1; ) {
    const t = e.length ? e[e.length - 1].outSize : n[1], s = es(t);
    e.push({
      inSize: t,
      windowSize: s,
      outSize: Math.ceil(t / s)
    });
  }
  return e;
}
function Nt(n, e, t, s) {
  const o = Xx(n.shape);
  let r = n;
  for (let i = 0; i < o.length; i++) {
    const { inSize: a, windowSize: c, outSize: l } = o[i];
    let u, d;
    t === "mean" ? u = i === 0 ? new ar({ windowSize: c, inSize: a, batchSize: n.shape[0], outSize: l }, a) : new ar({ windowSize: c, inSize: a, batchSize: n.shape[0], outSize: l }) : u = new Hx({ windowSize: c, inSize: a, batchSize: n.shape[0], outSize: l }, t), d = r, r = s.runWebGLProgram(u, [r], e), d.dataId !== n.dataId && s.disposeIntermediateTensorInfo(d);
  }
  return r;
}
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class qx {
  constructor(e, t) {
    this.variableNames = ["A"];
    const s = new Array(e.length);
    for (let i = 0; i < s.length; i++)
      s[i] = e[t[i]];
    this.outputShape = s, this.rank = s.length;
    const o = V(this.rank), r = jx(t);
    this.userCode = `
    void main() {
      ${o} resRC = getOutputCoords();
      setOutput(getA(${r}));
    }
    `;
  }
}
function jx(n) {
  const e = n.length;
  if (e > 6)
    throw Error(`Transpose for rank ${e} is not yet supported`);
  const t = ["resRC.x", "resRC.y", "resRC.z", "resRC.w", "resRC.u", "resRC.v"], s = new Array(e);
  for (let o = 0; o < n.length; o++)
    s[n[o]] = t[o];
  return s.join();
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Kx {
  constructor(e, t) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0;
    const s = new Array(e.length);
    for (let u = 0; u < s.length; u++)
      s[u] = e[t[u]];
    if (this.outputShape = s, this.rank = s.length, this.rank > 6)
      throw Error(`Packed transpose for rank ${this.rank} is not yet supported.`);
    const o = V(this.rank), r = ba("rc", this.rank), i = new Array(this.rank);
    for (let u = 0; u < t.length; u++)
      i[t[u]] = r[u];
    const a = `vec2(${i.slice(-2).join()})`, c = `++${r[this.rank - 1]} < ${s[this.rank - 1]}`, l = `getChannel(getA(${i.join()}), ${a})`;
    this.userCode = `
    void main() {
      ${o} rc = getOutputCoords();
      vec4 result = vec4(0.);
      result[0] = ${l};
      if(${c}) {
        result[1] = ${l};
      }
      --${r[this.rank - 1]};
      if(++${r[this.rank - 2]} < ${s[this.rank - 2]}) {
        result[2] = ${l};
        if(${c}) {
          result[3] = ${l};
        }
      }
      setOutput(result);
    }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ss(n, e, t) {
  const s = y().getBool("WEBGL_PACK_ARRAY_OPERATIONS") ? new Kx(n.shape, e) : new qx(n.shape, e);
  return t.runWebGLProgram(s, [n], n.dtype);
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Yx(n, e, t, s) {
  const o = e, r = n.shape.length, i = de(o, n.shape);
  let a = i;
  const c = Ee(a, r), l = c != null;
  let u = n;
  l && (u = ss(n, c, s), a = Ne(a.length, r)), Me("sum", a, r);
  const [d, h] = He(u.shape, a);
  let f = d;
  t && (f = qe(d, i));
  const p = T(h), g = T(n.shape) / p, m = S({ inputs: { x: u }, attrs: { shape: [g, p] }, backend: s }), C = Qs(n.dtype), b = Nt(m, C, "sum", s), w = S({ inputs: { x: b }, attrs: { shape: f }, backend: s });
  return s.disposeIntermediateTensorInfo(m), s.disposeIntermediateTensorInfo(b), l && s.disposeIntermediateTensorInfo(u), w;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function os(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r, keepDims: i } = s;
  return Yx(o, r, i, t);
}
const Qx = {
  kernelName: Au,
  backendName: "webgl",
  kernelFunc: os
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ae(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { perm: r } = s, i = t, a = o.shape.length, c = new Array(a);
  for (let u = 0; u < c.length; u++)
    c[u] = o.shape[r[u]];
  let l;
  if (i.shouldExecuteOnCPU([o])) {
    const d = i.texData.get(o.dataId).values, h = fo(d, o.shape, o.dtype, r, c);
    l = i.makeTensorInfo(c, o.dtype);
    const f = i.texData.get(l.dataId);
    f.values = h;
  } else
    l = ss(o, r, i);
  return l;
}
const Zx = {
  kernelName: Qu,
  backendName: "webgl",
  kernelFunc: ae
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ra = 1e3;
function Xn({ a: n, b: e, transposeA: t, transposeB: s, backend: o, bias: r = null, preluActivationWeights: i = null, leakyreluAlpha: a = 0, activation: c = null }) {
  const l = n.shape.length, u = e.shape.length, d = t ? n.shape[l - 2] : n.shape[l - 1], h = s ? e.shape[u - 1] : e.shape[u - 2], f = t ? n.shape[l - 1] : n.shape[l - 2], p = s ? e.shape[u - 2] : e.shape[u - 1], x = n.shape.slice(0, -2), g = e.shape.slice(0, -2), m = T(x), C = T(g), w = ie(n.shape.slice(0, -2), e.shape.slice(0, -2)).concat([f, p]);
  N(d === h, () => `Error in matMul: inner shapes (${d}) and (${h}) of Tensors with shapes ${n.shape} and ${e.shape} and transposeA=${t} and transposeB=${s} must match.`);
  const v = t ? [m, d, f] : [m, f, d], E = s ? [C, p, h] : [C, h, p], R = S({ inputs: { x: n }, backend: o, attrs: { shape: v } }), $ = S({ inputs: { x: e }, backend: o, attrs: { shape: E } }), F = [R, $], O = Math.max(m, C), L = t ? R.shape[1] : R.shape[2], B = r != null, he = i != null, j = c === "leakyrelu", te = c != null ? fn(c, !0) : null, we = B || he || j || te != null;
  let Ae;
  if ((f === 1 || p === 1) && L > Ra && we === !1) {
    let Ye = R, kt = $;
    t && (Ye = ae({ inputs: { x: R }, backend: o, attrs: { perm: [0, 2, 1] } }), F.push(Ye)), s && (kt = ae({ inputs: { x: $ }, backend: o, attrs: { perm: [0, 2, 1] } }), F.push(kt));
    const At = p !== 1, In = p === 1;
    let is = Ye;
    At && (is = S({
      inputs: { x: Ye },
      backend: o,
      attrs: { shape: [O, L, 1] }
    }), F.push(is));
    const Ya = p === 1 ? 2 : 1;
    let as = kt;
    In && (as = S({
      inputs: { x: kt },
      backend: o,
      attrs: { shape: [O, 1, L] }
    }), F.push(as));
    const Co = mo({ inputs: { a: is, b: as }, backend: o });
    Ae = os({ inputs: { x: Co }, backend: o, attrs: { axis: Ya, keepDims: !0 } }), F.push(Co);
  } else {
    const Ye = ze(n.dtype, e.dtype), kt = new Ia(v, E, [O, f, p], t, s, B, te, he, j), At = [R, $];
    if (r != null && At.push(r), he && At.push(i), j) {
      const In = o.makeTensorInfo([], "float32", Xt(a, "float32"));
      At.push(In), F.push(In);
    }
    Ae = o.runWebGLProgram(kt, At, Ye);
  }
  const se = S({ inputs: { x: Ae }, backend: o, attrs: { shape: w } });
  F.push(Ae);
  for (const Ye of F)
    o.disposeIntermediateTensorInfo(Ye);
  return se;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Jx(n) {
  const { inputs: e, backend: t, attrs: s } = n, { a: o, b: r, bias: i, preluActivationWeights: a } = e, { transposeA: c, transposeB: l, activation: u, leakyreluAlpha: d } = s;
  return Xn({
    a: o,
    b: r,
    transposeA: c,
    transposeB: l,
    backend: t,
    bias: i,
    preluActivationWeights: a,
    leakyreluAlpha: d,
    activation: u
  });
}
const e0 = {
  kernelName: od,
  backendName: "webgl",
  kernelFunc: Jx
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const cr = "return abs(x);";
function t0(n) {
  const { inputs: e, backend: t } = n, { x: s } = e;
  if (t.shouldExecuteOnCPU([s]) && s.dtype !== "complex64") {
    const r = t.texData.get(s.dataId), i = xa(r.values);
    return t.makeTensorInfo(s.shape, s.dtype, i);
  }
  let o;
  return y().getBool("WEBGL_PACK_UNARY_OPERATIONS") ? o = new et(s.shape, cr) : o = new Ue(s.shape, cr), t.runWebGLProgram(o, [s], s.dtype);
}
const n0 = {
  kernelName: Er,
  backendName: "webgl",
  kernelFunc: t0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const s0 = ke + `
  if (abs(x) > 1.) {
    return NAN;
  }
  return acos(x);
`, o0 = _({ opSnippet: s0 }), r0 = {
  kernelName: gc,
  backendName: "webgl",
  kernelFunc: o0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const i0 = ke + `
  if (x < 1.0) return NAN;
return log(x + sqrt(x * x - 1.0));`, a0 = _({ opSnippet: i0 }), c0 = {
  kernelName: xc,
  backendName: "webgl",
  kernelFunc: a0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const lr = "return a + b;", l0 = ee({
  opSnippet: lr,
  packedOpSnippet: lr,
  supportsComplex: !0,
  cpuKernelImpl: bg
}), u0 = {
  kernelName: qs,
  backendName: "webgl",
  kernelFunc: l0
};
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class d0 {
  constructor(e, t) {
    this.outputShape = [], this.outputShape = e, this.variableNames = t.map((r, i) => `T${i}`);
    const s = [];
    this.variableNames.forEach((r) => {
      s.push(`float v${r} = get${r}AtOutCoords();`);
    });
    const o = this.variableNames.map((r) => `v${r}`).join(" + ");
    this.userCode = `
      void main() {
        ${s.join(`
        `)}

        float result = ${o};
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class h0 {
  constructor(e, t) {
    this.outputShape = [], this.packedInputs = !0, this.packedOutput = !0, this.outputShape = e, this.variableNames = t.map((r, i) => `T${i}`);
    const s = [];
    this.variableNames.forEach((r) => {
      s.push(`vec4 v${r} = get${r}AtOutCoords();`);
    });
    const o = this.variableNames.map((r) => `v${r}`).join(" + ");
    this.userCode = `
      void main() {
        ${s.join(`
        `)}

        vec4 result = ${o};
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function _n(n) {
  const { inputs: e, backend: t } = n, s = e;
  if (s.length === 1)
    return me({ inputs: { x: s[0] }, backend: t });
  if (s.length > y().get("WEBGL_MAX_TEXTURES_IN_SHADER")) {
    const c = Math.floor(s.length / 2), l = _n({ inputs: s.slice(0, c), backend: t }), u = _n({ inputs: s.slice(c), backend: t });
    return _n({ inputs: [l, u], backend: t });
  }
  const o = s.map((c) => c.dtype).reduce((c, l) => ze(c, l)), r = s.map((c) => c.shape), a = y().getBool("WEBGL_PACK") ? new h0(s[0].shape, r) : new d0(s[0].shape, r);
  return t.runWebGLProgram(a, s, o);
}
const f0 = {
  kernelName: Cc,
  backendName: "webgl",
  kernelFunc: _n
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function p0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r, keepDims: i } = s, a = o.shape.length, c = de(r, o.shape);
  let l = c;
  const u = Ee(l, a);
  let d = o;
  u != null && (d = ae({ inputs: { x: o }, backend: t, attrs: { perm: u } }), l = Ne(l.length, a)), Me("all", l, a);
  const [h, f] = He(d.shape, l), p = T(f), x = S({ inputs: { x: d }, backend: t, attrs: { shape: [-1, p] } }), g = Nt(x, x.dtype, "all", t);
  let m;
  if (i) {
    const C = qe(h, c);
    m = S({ inputs: { x: g }, backend: t, attrs: { shape: C } });
  } else
    m = S({ inputs: { x: g }, backend: t, attrs: { shape: h } });
  return t.disposeIntermediateTensorInfo(x), t.disposeIntermediateTensorInfo(g), u != null && t.disposeIntermediateTensorInfo(d), m;
}
const m0 = {
  kernelName: bc,
  backendName: "webgl",
  kernelFunc: p0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function g0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r, keepDims: i } = s, a = o.shape.length, c = de(r, o.shape);
  let l = c;
  const u = Ee(l, a);
  let d = o;
  u != null && (d = ae({ inputs: { x: o }, backend: t, attrs: { perm: u } }), l = Ne(l.length, a)), Me("any", l, a);
  const [h, f] = He(d.shape, l), p = T(f), x = S({ inputs: { x: d }, backend: t, attrs: { shape: [-1, p] } }), g = Nt(x, x.dtype, "any", t);
  let m;
  if (i) {
    const C = qe(h, c);
    m = S({ inputs: { x: g }, backend: t, attrs: { shape: C } });
  } else
    m = S({ inputs: { x: g }, backend: t, attrs: { shape: h } });
  return t.disposeIntermediateTensorInfo(x), t.disposeIntermediateTensorInfo(g), u != null && t.disposeIntermediateTensorInfo(d), m;
}
const x0 = {
  kernelName: wc,
  backendName: "webgl",
  kernelFunc: g0
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class C0 {
  constructor(e, t, s) {
    this.variableNames = ["A"];
    const { windowSize: o, batchSize: r, outSize: i } = e;
    s || this.variableNames.push("bestIndicesA"), this.outputShape = [r, i];
    const a = t === "max" ? ">" : "<", c = s ? "inOffset + i;" : "round(getBestIndicesA(batch, inOffset + i));";
    this.userCode = `
      void main() {
        ivec2 coords = getOutputCoords();
        int batch = coords[0];
        int outIdx = coords[1];
        int inOffset = outIdx * ${o};

        int bestIndex = inOffset;
        float bestValue = getA(batch, bestIndex);

        for (int i = 0; i < ${o}; i++) {
          int inIdx = ${c};
          float candidate = getA(batch, inIdx);
          if (candidate ${a} bestValue) {
            bestValue = candidate;
            bestIndex = inIdx;
          }
        }
        setOutput(float(bestIndex));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class b0 {
  constructor(e, t, s, o) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0, N(e.length > 2, () => `Packed arg${s.charAt(0).toUpperCase() + s.slice(1)} supports only inputs with rank above 2.`);
    const r = e[e.length - 1], i = Math.ceil(r / t);
    this.outputShape = e.slice(0, -1), i > 1 && this.outputShape.push(i), o || this.variableNames.push("bestIndicesA");
    const a = this.outputShape, c = a.length, l = V(c), u = re("coords", c);
    let d, h;
    if (i === 1) {
      h = c + 1;
      const $ = V(h);
      d = `
        ${$} sourceLocR = ${$}(${u.join()}, 0);
        ++${u[c - 1]};
        ${$} sourceLocG = ${$}(${u.join()}, 0);
        ++${u[c - 2]};
        ${$} sourceLocA = ${$}(${u.join()}, 0);
        --${u[c - 1]};
        ${$} sourceLocB = ${$}(${u.join()}, 0);
        --${u[c - 2]};`;
    } else
      h = c, d = `
        ${l} sourceLocR = coords;
        ++${u[c - 1]};
        ${l} sourceLocG = coords;
        ++${u[c - 2]};
        ${l} sourceLocA = coords;
        --${u[c - 1]};
        ${l} sourceLocB = coords;
        --${u[c - 2]};`;
    const f = ["x", "y", "z", "w", "u", "v"].slice(0, h), p = "." + f[h - 1], x = f.map(($) => "int " + $), g = re("sourceLocR", h - 1).concat("inIdx.r"), m = re("sourceLocG", h - 1).concat("inIdx.g"), C = re("sourceLocB", h - 1).concat("inIdx.b"), b = re("sourceLocA", h - 1).concat("inIdx.a"), w = s === "max" ? "greaterThan" : "lessThan", v = o ? "" : `
          inIdx = round(vec4(getBestIndicesAChannel(${g.join()}),
                             getBestIndicesAChannel(${m.join()}),
                             getBestIndicesAChannel(${C.join()}),
                             getBestIndicesAChannel(${b.join()})));`, E = `vec4(
            getAChannel(${g.join()}),
            hasNextCol ? getAChannel(${m.join()}) : 0.,
            hasNextRow ? getAChannel(${C.join()}) : 0.,
            hasNextRow && hasNextCol ? getAChannel(${b.join()}) : 0.)`, R = o ? "" : `
      float getBestIndicesAChannel(${x.join()}) {
        return getChannel(getBestIndicesA(${f.join()}),
                                          vec2(${f.slice(-2).join()}));
      }`;
    this.userCode = `
      float getAChannel(${x.join()}) {
        return getChannel(getA(${f.join()}),
                               vec2(${f.slice(-2).join()}));
      }
      ${R}
      void main() {
        ${l} coords = getOutputCoords();
        bool hasNextCol = ${u[c - 1]} < ${a[c - 1] - 1};
        bool hasNextRow = ${u[c - 2]} < ${a[c - 2] - 1};
        ${d}
        ivec4 srcIdx = ivec4(sourceLocR${p}, sourceLocG${p},
          sourceLocB${p}, sourceLocA${p}) * ${t};
        ivec4 inIdx = srcIdx;
        vec4 bestIndex = vec4(inIdx);
        vec4 bestValue = ${E};

        for (int i = 0; i < ${t}; i++) {
          inIdx = srcIdx;
          ${v}
          vec4 candidate = ${E};
          bvec4 nan = isnan(candidate);
          bvec4 replace = bvec4(
            vec4(${w}(candidate, bestValue)) * (vec4(1.0) - vec4(nan)));

          bestValue = vec4(replace.x  ? candidate.x : bestValue.x,
                           replace.y  ? candidate.y : bestValue.y,
                           replace.z  ? candidate.z : bestValue.z,
                           replace.w  ? candidate.w : bestValue.w);
          bestIndex = mix(bestIndex, vec4(inIdx), vec4(replace));
          srcIdx++;
        }
        setOutput(bestIndex);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ta(n, e, t, s = null) {
  let o = e.shape[0], r = e.shape[1];
  s != null && (o = s.shape[0], r = s.shape[1]);
  const i = es(r), a = { windowSize: i, inSize: r, batchSize: o, outSize: Math.ceil(r / i) }, c = new C0(a, t, s == null), l = [e];
  s != null && l.push(s);
  const u = n.runWebGLProgram(c, l, "int32");
  if (u.shape[1] === 1)
    return u;
  const d = Ta(n, e, t, u);
  return n.disposeIntermediateTensorInfo(u), d;
}
function Ea(n, e, t, s = null) {
  const o = s != null ? s.shape : e.shape, r = o[o.length - 1], i = es(r), a = new b0(o, i, t, s == null), c = s == null ? [e] : [e, s], l = n.runWebGLProgram(a, c, "int32");
  if (l.shape.length === e.shape.length) {
    const u = Ea(n, e, t, l);
    return n.disposeIntermediateTensorInfo(l), u;
  }
  return l;
}
function Na(n, e, t, s) {
  const o = [t];
  if (Me("arg" + s.charAt(0).toUpperCase() + s.slice(1), o, e.shape.length), !y().getBool("WEBGL_PACK_REDUCE") || e.shape.length <= 2) {
    const r = [], i = n.texData.get(e.dataId), a = i !== null && i.isPacked;
    let c = e;
    a && (c = n.unpackTensor(e), r.push(c));
    const [l, u] = He(c.shape, o), d = T(u), h = S({ inputs: { x: c }, backend: n, attrs: { shape: [-1, d] } });
    r.push(h);
    const f = Ta(n, h, s);
    r.push(f);
    const p = S({ inputs: { x: f }, backend: n, attrs: { shape: l } });
    return r.forEach((x) => n.disposeIntermediateTensorInfo(x)), p;
  }
  return Ea(n, e, s);
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function w0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r } = s;
  let i = de(r, o.shape);
  const a = Ee(i, o.shape.length);
  let c = o;
  const l = [];
  a != null && (c = ae({ inputs: { x: o }, backend: t, attrs: { perm: a } }), l.push(c), i = Ne(i.length, c.shape.length)), Me("argMax", [i[0]], c.shape.length);
  const u = Na(t, c, i[0], "max");
  return l.forEach((d) => t.disposeIntermediateTensorInfo(d)), u;
}
const y0 = {
  kernelName: yc,
  backendName: "webgl",
  kernelFunc: w0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function v0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r } = s;
  let i = de(r, o.shape);
  const a = Ee(i, o.shape.length);
  let c = o;
  const l = [];
  a != null && (c = ae({ inputs: { x: o }, backend: t, attrs: { perm: a } }), l.push(c), i = Ne(i.length, c.shape.length)), Me("argMin", [i[0]], c.shape.length);
  const u = Na(t, c, i[0], "min");
  return l.forEach((d) => t.disposeIntermediateTensorInfo(d)), u;
}
const $0 = {
  kernelName: vc,
  backendName: "webgl",
  kernelFunc: v0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const S0 = ke + `
  if (abs(x) > 1.) {
    return NAN;
  }
  return asin(x);
`, I0 = _({ opSnippet: S0 }), R0 = {
  kernelName: $c,
  backendName: "webgl",
  kernelFunc: I0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const T0 = ke + "return log(x + sqrt(x * x + 1.0));", E0 = _({ opSnippet: T0 }), N0 = {
  kernelName: Sc,
  backendName: "webgl",
  kernelFunc: E0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const k0 = ke + `
  return atan(x);
`, A0 = _({ opSnippet: k0 }), F0 = {
  kernelName: Ic,
  backendName: "webgl",
  kernelFunc: A0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const D0 = po + `
  return atan(a, b);
`, O0 = `
  vec4 result = atan(a, b);
  bvec4 isNaNA = isnan(a);
  bvec4 isNaNB = isnan(b);
  bvec4 isNaN = bvec4(isNaNA.x || isNaNB.x, isNaNA.y || isNaNB.y, isNaNA.z || isNaNB.z, isNaNA.w || isNaNB.w);
  ` + Et + `
  return result;
`, P0 = ee({ opSnippet: D0, packedOpSnippet: O0 }), _0 = {
  kernelName: Tc,
  backendName: "webgl",
  kernelFunc: P0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const L0 = ke + `
  if ((x < -1.0) || (x > 1.0)) return NAN;
return (log(1.0 + x) - log(1.0 - x)) / 2.0;`, B0 = _({ opSnippet: L0 }), M0 = {
  kernelName: Rc,
  backendName: "webgl",
  kernelFunc: B0
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class pn {
  constructor(e, t, s, o = !1, r = !1) {
    if (this.variableNames = ["x"], t === "avg" && s)
      throw new Error("Cannot compute positions for average pool.");
    const i = e.filterWidth, a = e.strideHeight, c = e.strideWidth, l = e.dilationHeight, u = e.dilationWidth, d = e.effectiveFilterHeight, h = e.effectiveFilterWidth, f = e.padInfo.top, p = e.padInfo.left;
    this.outputShape = e.outShape;
    const x = t === "avg", g = `((batch  * ${e.inHeight} + xR) * ${e.inWidth} + xC) * ${e.inChannels} + d`, m = `(xR * ${e.inWidth} + xC) * ${e.inChannels} + d`;
    let C = "0.0";
    if (x || (C = "-1.0 / 1e-20"), s) {
      const $ = ">=";
      this.userCode = `
        const ivec2 strides = ivec2(${a}, ${c});
        const ivec2 pads = ivec2(${f}, ${p});

        void main() {
          ivec4 coords = getOutputCoords();
          int batch = coords[0];
          int d = coords[3];

          ivec2 xRCCorner = coords.yz * strides - pads;
          int xRCorner = xRCCorner.x;
          int xCCorner = xRCCorner.y;

          // max/min x(?, ?, d) to get y(yR, yC, d).
          // ? = to be determined
          float minMaxValue = 0.0;
          float minMaxValueFound = 0.0;
          int minMaxPosition = 0;
          float avgValue = 0.0;

          for (int wR = 0; wR < ${d};
              wR += ${l}) {
            int xR = xRCorner + wR;

            if (xR < 0 || xR >= ${e.inHeight}) {
              continue;
            }

            for (int wC = 0; wC < ${h};
                wC += ${u}) {
              int xC = xCCorner + wC;

              if (xC < 0 || xC >= ${e.inWidth}) {
                continue;
              }

              float value = getX(batch, xR, xC, d);

              // If a min / max value has already been found, use it. If not,
              // use the current value.
              float currMinMaxValue = mix(
                  value, minMaxValue, minMaxValueFound);
              if (value ${$} currMinMaxValue) {
                minMaxValue = value;
                minMaxValueFound = 1.0;
                minMaxPosition = ${o ? r ? g : m : `wR * ${h} + wC`};
              }
            }
          }
          setOutput(float(minMaxPosition));
        }
      `;
      return;
    }
    const b = "max";
    let w = `${t}(${t}(${t}(minMaxValue[0], minMaxValue[1]), minMaxValue[2]), minMaxValue[3])`;
    t === "avg" && (w = "avgValue / max(count, 1.0)");
    const v = Math.floor(i / 4) * 4, E = i % 4, R = `
      if (${x}) {
        avgValue += dot(values, ones);
      } else {
        minMaxValue = ${b}(values, minMaxValue);
      }
    `;
    this.userCode = `
      const ivec2 strides = ivec2(${a}, ${c});
      const ivec2 pads = ivec2(${f}, ${p});
      const float initializationValue = ${C};
      const vec4 ones = vec4(1.0, 1.0, 1.0, 1.0);

      float count = 0.0;

      float getValue(int batch, int xR, int xC, int d) {
        if (xC < 0 || xC >= ${e.inWidth}) {
          return initializationValue;
        }
        count += 1.0;
        return getX(batch, xR, xC, d);
      }

      void main() {
        ivec4 coords = getOutputCoords();
        int batch = coords[0];
        int d = coords[3];

        ivec2 xRCCorner = coords.yz * strides - pads;
        int xRCorner = xRCCorner.x;
        int xCCorner = xRCCorner.y;

        // max/min x(?, ?, d) to get y(yR, yC, d).
        // ? = to be determined
        vec4 minMaxValue = vec4(${C});
        float avgValue = 0.0;
        count = 0.0;

        for (int wR = 0; wR < ${d};
            wR += ${l}) {
          int xR = xRCorner + wR;

          if (xR < 0 || xR >= ${e.inHeight}) {
            continue;
          }

          for (int wC = 0; wC < ${v}; wC += 4) {
            int xC = xCCorner + wC * ${u};

            vec4 values = vec4(
              getValue(batch, xR, xC, d),
              getValue(batch, xR, xC + ${u}, d),
              getValue(batch, xR, xC + 2 * ${u}, d),
              getValue(batch, xR, xC + 3 * ${u}, d)
            );

            ${R}
          }

          int xC = xCCorner + ${v};
          if (${E === 1}) {
            vec4 values = vec4(
              getValue(batch, xR, xC, d),
              initializationValue,
              initializationValue,
              initializationValue
            );

            ${R}
          } else if (${E === 2}) {
            vec4 values = vec4(
              getValue(batch, xR, xC, d),
              getValue(batch, xR, xC + ${u}, d),
              initializationValue,
              initializationValue
            );

            ${R}
          } else if (${E === 3}) {
            vec4 values = vec4(
              getValue(batch, xR, xC, d),
              getValue(batch, xR, xC + ${u}, d),
              getValue(batch, xR, xC + 2 * ${u}, d),
              initializationValue
            );

            ${R}
          }
        }
        setOutput(${w});
      }
    `;
  }
}
class go {
  constructor(e, t, s, o = !1, r = !1) {
    if (this.variableNames = ["x"], t === "avg" && s)
      throw new Error("Cannot compute positions for average pool.");
    const i = e.filterWidth, a = e.strideDepth, c = e.strideHeight, l = e.strideWidth, u = e.dilationDepth, d = e.dilationHeight, h = e.dilationWidth, f = e.effectiveFilterDepth, p = e.effectiveFilterHeight, x = e.effectiveFilterWidth, g = e.padInfo.front, m = e.padInfo.top, C = e.padInfo.left;
    this.outputShape = e.outShape;
    const b = t === "avg";
    let w = "0.0";
    if (b || (w = "-1.0 / 1e-20"), s) {
      const O = ">=";
      this.userCode = `
        const ivec3 strides =
            ivec3(${a}, ${c}, ${l});
        const ivec3 pads = ivec3(${g}, ${m}, ${C});

        void main() {
          ivec5 coords = getOutputCoords();
          int batch = coords.x;
          int ch = coords.u;

          ivec3 xCorner = ivec3(coords.y, coords.z, coords.w) * strides - pads;
          int xDCorner = xCorner.x;
          int xRCorner = xCorner.y;
          int xCCorner = xCorner.z;

          // max/min x(?, ?, ?, ch) to get y(yD, yR, yC, ch).
          // ? = to be determined
          float minMaxValue = 0.0;
          float minMaxValueFound = 0.0;
          int minMaxPosition = 0;

          for (int wD = 0; wD < ${f};
              wD += ${u}) {
            int xD = xDCorner + wD;

            if (xD < 0 || xD >= ${e.inDepth}) {
              continue;
            }

            for (int wR = 0; wR < ${p};
                wR += ${d}) {
              int xR = xRCorner + wR;

              if (xR < 0 || xR >= ${e.inHeight}) {
                continue;
              }

              for (int wC = 0; wC < ${x};
                  wC += ${h}) {
                int xC = xCCorner + wC;

                if (xC < 0 || xC >= ${e.inWidth}) {
                  continue;
                }

                float value = getX(batch, xD, xR, xC, ch);

                // If a min / max value has already been found, use it. If not,
                // use the current value.
                float currMinMaxValue = mix(
                    value, minMaxValue, minMaxValueFound);
                if (value ${O} currMinMaxValue) {
                  minMaxValue = value;
                  minMaxValueFound = 1.0;
                  minMaxPosition = ${o ? r ? `(((batch * ${e.inDepth} + xD) * ${e.inHeight} + xR) * ${e.inWidth} + xC) * ${e.inChannels} + ch` : `((xD * ${e.inHeight} + xR) * ${e.inWidth} + xC) * ${e.inChannels} + ch` : `wD * ${p} * ${x} +
                      wR * ${x} + wC`};
                }
              }
            }
          }
          setOutput(float(minMaxPosition));
        }
      `;
      return;
    }
    const v = "max";
    let E = `${t}(${t}(${t}(minMaxValue[0], minMaxValue[1]), minMaxValue[2]), minMaxValue[3])`;
    t === "avg" && (E = "avgValue / max(count, 1.0)");
    const R = Math.floor(i / 4) * 4, $ = i % 4, F = `
      if (${b}) {
        avgValue += dot(values, ones);
      } else {
        minMaxValue = ${v}(values, minMaxValue);
      }
    `;
    this.userCode = `
      const ivec3 strides =
        ivec3(${a}, ${c}, ${l});
      const ivec3 pads = ivec3(${g}, ${m}, ${C});
      const float initializationValue = ${w};
      const vec4 ones = vec4(1.0, 1.0, 1.0, 1.0);

      float count = 0.0;

      float getValue(int batch, int xD, int xR, int xC, int ch) {
        if (xC < 0 || xC >= ${e.inWidth}) {
          return initializationValue;
        }
        count += 1.0;
        return getX(batch, xD, xR, xC, ch);
      }

      void main() {
        ivec5 coords = getOutputCoords();
        int batch = coords.x;
        int ch = coords.u;

        ivec3 xCorner = ivec3(coords.y, coords.z, coords.w) * strides - pads;
        int xDCorner = xCorner.x;
        int xRCorner = xCorner.y;
        int xCCorner = xCorner.z;

        // max/min x(?, ?, ?, d) to get y(yD, yR, yC, ch).
        // ? = to be determined
        vec4 minMaxValue = vec4(${w});
        float avgValue = 0.0;
        count = 0.0;

        for (int wD = 0; wD < ${f};
            wD += ${u}) {
          int xD = xDCorner + wD;

          if (xD < 0 || xD >= ${e.inDepth}) {
            continue;
          }

          for (int wR = 0; wR < ${p};
            wR += ${d}) {
            int xR = xRCorner + wR;

            if (xR < 0 || xR >= ${e.inHeight}) {
              continue;
            }

            for (int wC = 0; wC < ${R}; wC += 4) {
              int xC = xCCorner + wC * ${h};

              vec4 values = vec4(
                getValue(batch, xD, xR, xC, ch),
                getValue(batch, xD, xR, xC + ${h}, ch),
                getValue(batch, xD, xR, xC + 2 * ${h}, ch),
                getValue(batch, xD, xR, xC + 3 * ${h}, ch)
              );

              ${F}
            }

            int xC = xCCorner + ${R};
            if (${$ === 1}) {
              vec4 values = vec4(
                getValue(batch, xD, xR, xC, ch),
                initializationValue,
                initializationValue,
                initializationValue
              );

              ${F}
            } else if (${$ === 2}) {
              vec4 values = vec4(
                getValue(batch, xD, xR, xC, ch),
                getValue(batch, xD, xR, xC + ${h}, ch),
                initializationValue,
                initializationValue
              );

              ${F}
            } else if (${$ === 3}) {
              vec4 values = vec4(
                getValue(batch, xD, xR, xC, ch),
                getValue(batch, xD, xR, xC + ${h}, ch),
                getValue(batch, xD, xR, xC + 2 * ${h}, ch),
                initializationValue
              );

              ${F}
            }
          }
        }
        setOutput(${E});
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function V0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e;
  yn(o, "avgPool");
  const { filterSize: r, strides: i, pad: a, dimRoundingMode: c } = s, l = 1;
  N(jt(i, l), () => `Error in avgPool: Either strides or dilations must be 1. Got strides ${i} and dilations '${l}'`);
  const u = qt(o.shape, r, i, l, a, c);
  if (u.filterWidth === 1 && u.filterHeight === 1 && Z(u.inShape, u.outShape))
    return me({ inputs: { x: o }, backend: t });
  const d = new pn(u, "avg", !1);
  return t.runWebGLProgram(d, [o], "float32");
}
const U0 = {
  kernelName: Ec,
  backendName: "webgl",
  kernelFunc: V0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function W0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { filterSize: r, strides: i, pad: a, dimRoundingMode: c, dataFormat: l } = s, u = [1, 1, 1], d = Cn(o.shape, r, i, u, a, c, l), h = new go(d, "avg", !1);
  return t.runWebGLProgram(h, [o], "float32");
}
const G0 = {
  kernelName: kc,
  backendName: "webgl",
  kernelFunc: W0
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class z0 {
  constructor(e) {
    this.variableNames = ["dy"], this.outputShape = e.inShape;
    const t = e.filterHeight, s = e.filterWidth, o = e.strideHeight, r = e.strideWidth, i = e.dilationHeight, a = e.dilationWidth, c = e.effectiveFilterHeight, l = e.effectiveFilterWidth, u = c - 1 - e.padInfo.top, d = l - 1 - e.padInfo.left, h = 1 / (t * s);
    this.userCode = `
      const ivec2 pads = ivec2(${u}, ${d});
      const float avgMultiplier = float(${h});

      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int d = coords[3];

        ivec2 dyRCCorner = coords.yz - pads;
        int dyRCorner = dyRCCorner.x;
        int dyCCorner = dyRCCorner.y;

        // Convolve dy(?, ?, d) with pos mask(:, :, d) to get dx(xR, xC, d).
        // ? = to be determined. : = across all values in that axis.
        float dotProd = 0.0;
        for (int wR = 0; wR < ${c};
            wR += ${i}) {
          float dyR = float(dyRCorner + wR) / ${o}.0;

          if (dyR < 0.0 || dyR >= ${e.outHeight}.0 || fract(dyR) > 0.0) {
            continue;
          }
          int idyR = int(dyR);

          for (int wC = 0; wC < ${l};
            wC+= ${a}) {
            float dyC = float(dyCCorner + wC) / ${r}.0;

            if (dyC < 0.0 || dyC >= ${e.outWidth}.0 ||
                fract(dyC) > 0.0) {
              continue;
            }
            int idyC = int(dyC);

            float dyValue = getDy(b, idyR, idyC, d);

            dotProd += dyValue * avgMultiplier;
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
class H0 {
  constructor(e) {
    this.variableNames = ["dy"], this.outputShape = e.inShape;
    const t = e.filterDepth, s = e.filterHeight, o = e.filterWidth, r = e.strideDepth, i = e.strideHeight, a = e.strideWidth, c = e.dilationDepth, l = e.dilationHeight, u = e.dilationWidth, d = e.effectiveFilterDepth, h = e.effectiveFilterHeight, f = e.effectiveFilterWidth, p = d - 1 - e.padInfo.front, x = h - 1 - e.padInfo.top, g = f - 1 - e.padInfo.left, m = 1 / (t * s * o);
    this.userCode = `
      const ivec3 pads = ivec3(${p}, ${x}, ${g});
      const float avgMultiplier = float(${m});

      void main() {
        ivec5 coords = getOutputCoords();
        int batch = coords.x;
        int ch = coords.u;

        ivec3 dyCorner = ivec3(coords.y, coords.z, coords.w) - pads;
        int dyDCorner = dyCorner.x;
        int dyRCorner = dyCorner.y;
        int dyCCorner = dyCorner.z;

        // Convolve dy(?, ?, ?, d) with pos mask(:, :, :, ch) to get
        // dx(xD, xR, xC, ch).
        // ? = to be determined. : = across all values in that axis.
        float dotProd = 0.0;

        for (int wD = 0; wD < ${d};
            wD += ${c}) {
          float dyD = float(dyDCorner + wD) / ${r}.0;

          if (dyD < 0.0 || dyD >= ${e.outDepth}.0 || fract(dyD) > 0.0) {
            continue;
          }
          int idyD = int(dyD);

          for (int wR = 0; wR < ${h};
              wR += ${l}) {
            float dyR = float(dyRCorner + wR) / ${i}.0;

            if (dyR < 0.0 || dyR >= ${e.outHeight}.0 ||
                fract(dyR) > 0.0) {
              continue;
            }
            int idyR = int(dyR);

            for (int wC = 0; wC < ${f};
                wC += ${u}) {
              float dyC = float(dyCCorner + wC) / ${a}.0;

              if (dyC < 0.0 || dyC >= ${e.outWidth}.0 ||
                  fract(dyC) > 0.0) {
                continue;
              }
              int idyC = int(dyC);

              float dyValue = getDy(batch, idyD, idyR, idyC, ch);

              dotProd += dyValue * avgMultiplier;
            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function X0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { dy: o, input: r } = e, i = r, { filterSize: a, strides: c, pad: l, dimRoundingMode: u } = s, d = [1, 1, 1], h = Cn(i.shape, a, c, d, l, u), f = new H0(h);
  return t.runWebGLProgram(f, [o], i.dtype);
}
const q0 = {
  kernelName: Ac,
  backendName: "webgl",
  kernelFunc: X0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function j0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { dy: o, input: r } = e, i = r;
  yn([o, r], "avgPoolGrad");
  const { filterSize: a, strides: c, pad: l } = s, u = qt(i.shape, a, c, 1, l), d = new z0(u);
  return t.runWebGLProgram(d, [o], i.dtype);
}
const K0 = {
  kernelName: Nc,
  backendName: "webgl",
  kernelFunc: j0
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Y0(n) {
  const { inputs: e, backend: t, attrs: s } = n, { a: o, b: r } = e, { transposeA: i, transposeB: a } = s;
  return Xn({ a: o, b: r, transposeA: i, transposeB: a, backend: t });
}
const Q0 = {
  kernelName: Fc,
  backendName: "webgl",
  kernelFunc: Y0
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Z0 {
  constructor(e, t, s, o, r, i) {
    this.outputShape = [], this.variableNames = ["x", "mean", "variance"], ie(e, t), ie(e, s);
    let a = "0.0";
    o != null && (ie(e, o), this.variableNames.push("offset"), a = "getOffsetAtOutCoords()");
    let c = "1.0";
    r != null && (ie(e, r), this.variableNames.push("scale"), c = "getScaleAtOutCoords()"), this.outputShape = e, this.userCode = `
      void main() {
        float x = getXAtOutCoords();
        float mean = getMeanAtOutCoords();
        float variance = getVarianceAtOutCoords();
        float offset = ${a};
        float scale = ${c};
        float inv = scale * inversesqrt(variance + float(${i}));
        setOutput(dot(vec3(x, -mean, offset), vec3(inv, inv, 1)));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class J0 {
  constructor(e, t, s, o, r, i) {
    this.packedInputs = !0, this.packedOutput = !0, this.variableNames = ["x", "mean", "variance"], ie(e, t), ie(e, s);
    let a = "vec4(0.0)";
    o != null && (ie(e, o), this.variableNames.push("offset"), a = "getOffsetAtOutCoords()");
    let c = "vec4(1.0)";
    r != null && (ie(e, r), this.variableNames.push("scale"), c = "getScaleAtOutCoords()"), this.outputShape = e, this.userCode = `
      void main() {
        vec4 offset = ${a};
        vec4 scale = ${c};

        vec4 x = getXAtOutCoords();
        vec4 mean = getMeanAtOutCoords();
        vec4 variance = getVarianceAtOutCoords();

        vec4 inv = scale * inversesqrt(variance + vec4(${i}));

        setOutput((x - mean) * inv + offset);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const eC = ({ inputs: n, backend: e, attrs: t }) => {
  const { x: s, mean: o, variance: r, offset: i, scale: a } = n;
  N(o.shape.length === r.shape.length, () => "Batch normalization gradient requires mean and variance to have equal ranks."), N(i == null || o.shape.length === i.shape.length, () => "Batch normalization gradient requires mean and offset to have equal ranks."), N(a == null || o.shape.length === a.shape.length, () => "Batch normalization gradient requires mean and scale to have equal ranks.");
  let { varianceEpsilon: c } = t;
  c == null && (c = 1e-3);
  const l = [s, o, r];
  let u = null;
  i != null && (u = i.shape, l.push(i));
  let d = null;
  a != null && (d = a.shape, l.push(a));
  const h = y().getBool("WEBGL_PACK_NORMALIZATION") ? new J0(s.shape, o.shape, r.shape, u, d, c) : new Z0(s.shape, o.shape, r.shape, u, d, c);
  return e.runWebGLProgram(h, l, l[0].dtype);
}, tC = {
  kernelName: ml,
  backendName: "webgl",
  kernelFunc: eC
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class nC {
  constructor(e) {
    this.variableNames = ["source"], this.outputShape = e, this.rank = e.length;
    const t = V(this.rank);
    this.customUniforms = [{ name: "start", arrayIndex: this.rank, type: "int" }];
    const s = sC(this.rank);
    let o;
    const r = e.map((i, a) => `sourceLoc.${Vs[a]} = start[${a}] + coords.${Vs[a]};`);
    o = `
        ${t} sourceLoc;
        ${t} coords = getOutputCoords();
        ${r.join(`
`)}
      `, this.userCode = `
      void main() {
        ${o}
        setOutput(getSource(${s}));
      }
    `;
  }
}
const Vs = ["x", "y", "z", "w", "u", "v"];
function sC(n) {
  if (n === 1)
    return "sourceLoc";
  if (n <= 6)
    return Vs.slice(0, n).map((e) => "sourceLoc." + e).join(",");
  throw Error(`Slicing for rank ${n} is not yet supported`);
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class oC {
  constructor(e) {
    this.variableNames = ["source"], this.packedInputs = !0, this.packedOutput = !0, this.outputShape = e, this.rank = e.length, this.customUniforms = [{ name: "start", arrayIndex: this.rank, type: "int" }];
    const t = V(this.rank), s = re("coords", this.rank), o = re("sourceLoc", this.rank), r = this.rank === 1 ? "sourceLoc" : `vec2(${o.slice(-2).join()})`, i = `getChannel(getSource(${o.join()}), ${r})`, a = `
      result.x = ${i};
      if (++${s[this.rank - 1]} < ${e[this.rank - 1]}) {
        ++${o[this.rank - 1]};
        result.y = ${i};
        --${o[this.rank - 1]};
      }
    `, c = this.rank === 1 ? "" : `
      --${s[this.rank - 1]};
      if (++${s[this.rank - 2]} < ${e[this.rank - 2]}) {
        ++${o[this.rank - 2]};
        result.z = ${i};
        if (++${s[this.rank - 1]} < ${e[this.rank - 1]}) {
          ++${o[this.rank - 1]};
          result.w = ${i};
        }
      }
    `, l = this.rank <= 4 ? `sourceLoc = coords +
            ${t}(${e.map((u, d) => `start[${d}]`).join()});` : e.map((u, d) => `${o[d]} = ${s[d]} + start[${d}];`).join(`
`);
    this.userCode = `
      void main() {
        ${t} coords = getOutputCoords();
        ${t} sourceLoc;
        ${l}
        vec4 result = vec4(0.);
        ${a}
        ${c}
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function rC(n, e, t, s) {
  const o = s.texData.get(n.dataId), r = s.makeTensorInfo(t, n.dtype), i = s.texData.get(r.dataId);
  Object.assign(i, o), i.refCount = 1, i.shape = t, i.dtype = n.dtype;
  let a = vi(e, Q(n.shape));
  o.slice && (a += o.slice.flatOffset), i.slice = {
    flatOffset: a,
    // Point to the original dataId, which is used to do ref counting.
    origDataId: o.slice && o.slice.origDataId || n.dataId
  };
  const c = s.dataRefCount.get(i.slice.origDataId) || 1;
  return s.dataRefCount.set(i.slice.origDataId, c + 1), r;
}
function sn(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { begin: r, size: i } = s, [a, c] = mf(o, r, i);
  if (ff(o, a, c), T(c) === 0)
    return t.makeTensorInfo(c, o.dtype, []);
  if (t.shouldExecuteOnCPU([o]) || o.dtype === "string") {
    const d = t.texData.get(o.dataId), h = Qg(d.values, a, c, o.shape, o.dtype);
    return t.makeTensorInfo(c, o.dtype, h);
  }
  const { isPacked: l } = t.texData.get(o.dataId), u = yi(o.shape, a, c);
  if (l || !u) {
    const d = y().getBool("WEBGL_PACK_ARRAY_OPERATIONS") ? new oC(c) : new nC(c), h = [a];
    return t.runWebGLProgram(d, [o], o.dtype, h);
  }
  return t.uploadToGPU(o.dataId), rC(o, a, c, t);
}
const iC = {
  kernelName: Iu,
  backendName: "webgl",
  kernelFunc: sn
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const aC = (n) => {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { blockShape: r, crops: i } = s;
  N(o.shape.length <= 4, () => "batchToSpaceND for rank > 4 with a WebGL backend not implemented yet");
  const a = r.reduce((C, b) => C * b), c = ro(o.shape, r, a), l = io(c.length, r.length), u = ao(o.shape, r, a), d = Ni(i, r.length), h = ki(u, i, r.length), f = [], p = S({ inputs: { x: o }, backend: t, attrs: { shape: c } }), x = ae({ inputs: { x: p }, backend: t, attrs: { perm: l } }), g = S({
    inputs: { x },
    backend: t,
    attrs: { shape: u }
  }), m = sn({
    inputs: { x: g },
    backend: t,
    attrs: { begin: d, size: h }
  });
  return f.push(p), f.push(x), f.push(g), f.forEach((C) => t.disposeIntermediateTensorInfo(C)), m;
}, cC = {
  kernelName: Dc,
  backendName: "webgl",
  kernelFunc: aC
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function lC(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, weights: r } = e, { size: i } = s, a = t.readSync(o.dataId), c = t.readSync(r.dataId), l = ga(a, c, r.dtype, r.shape, i);
  return t.makeTensorInfo([i], r.dtype, l);
}
const uC = {
  kernelName: Oc,
  backendName: "webgl",
  kernelFunc: lC
};
/**
 * @license
 * Copyright 2023 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const dC = `
  int r = int(a.r) & int(b.r);
  int g = int(a.g) & int(b.g);
  int rb = int(a.b) & int(b.b);
  int ra = int(a.a) & int(b.a);
  return vec4(r, g, rb, ra);
`, hC = `
  return float(int(a.r) & int(b.r));
`;
function fC(n) {
  const { inputs: e, backend: t } = n, { a: s, b: o } = e, r = y().getBool("WEBGL_PACK_BINARY_OPERATIONS"), i = y().getNumber("WEBGL_VERSION");
  if (t.shouldExecuteOnCPU([s, o]) || i === 1) {
    const c = t.texData.get(s.dataId).values, l = t.texData.get(o.dataId).values, [u, d] = yg(s.shape, o.shape, c, l, s.dtype), h = t.makeTensorInfo(d, s.dtype), f = t.texData.get(h.dataId);
    return f.values = u, h;
  }
  let a;
  return r ? a = new tn(dC, s.shape, o.shape, !1) : a = new wt(hC, s.shape, o.shape), t.runWebGLProgram(a, [s, o], s.dtype);
}
const pC = {
  kernelName: Pc,
  backendName: "webgl",
  kernelFunc: fC
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function mC(n) {
  const { inputs: e, backend: t } = n, { s0: s, s1: o } = e, r = t.readSync(s.dataId), i = t.readSync(o.dataId), a = ie(Array.from(r), Array.from(i));
  return t.makeTensorInfo([a.length], "int32", Int32Array.from(a));
}
const gC = {
  kernelName: _c,
  backendName: "webgl",
  kernelFunc: mC
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const xC = "return float(a != b);", ka = ee({ opSnippet: xC, cpuKernelImpl: Wg, dtype: "bool" }), CC = {
  kernelName: Kl,
  backendName: "webgl",
  kernelFunc: ka
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function $n(n) {
  const { inputs: e, backend: t } = n, { input: s } = e, o = t.texData.get(s.dataId);
  return me({ inputs: { x: o.complexTensorInfos.real }, backend: t });
}
const bC = {
  kernelName: lu,
  backendName: "webgl",
  kernelFunc: $n
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const wC = "return float(int(x));";
function yC(n, e) {
  const t = new Ue(n.shape, wC), s = e.runWebGLProgram(t, [n], "int32");
  return { dataId: s.dataId, shape: s.shape, dtype: s.dtype };
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Us(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { dtype: r } = s;
  if (r === "complex64") {
    if (o.dtype === "complex64")
      return me({ inputs: { x: o }, backend: t });
    const i = Ps(o.shape), a = Us({ inputs: { x: o }, backend: t, attrs: { dtype: "float32" } }), c = ot({ inputs: { real: a, imag: i }, backend: t });
    return i.dispose(), t.disposeIntermediateTensorInfo(a), c;
  }
  if (o.dtype === "complex64") {
    const i = $n({ inputs: { input: o }, backend: t }), a = Us({ inputs: { x: i }, backend: t, attrs: { dtype: r } });
    return t.disposeIntermediateTensorInfo(i), a;
  }
  if (!rc(o.dtype, r)) {
    const i = me({ inputs: { x: o }, backend: t });
    return { dataId: i.dataId, shape: i.shape, dtype: r };
  }
  if (t.shouldExecuteOnCPU([o])) {
    const i = t.texData.get(o.dataId).values, [a, c, l] = vg(i, o.shape, o.dtype, r);
    return t.makeTensorInfo(a, c, l);
  }
  if (r === "int32")
    return yC(o, t);
  if (r === "bool") {
    const i = t.makeTensorInfo([], "bool", pt("bool", 1)), c = ka({ inputs: { a: o, b: i }, backend: t });
    return t.disposeIntermediateTensorInfo(i), c;
  }
  throw new Error(`Error in Cast: failed to cast ${o.dtype} to ${r}`);
}
const vC = {
  kernelName: js,
  backendName: "webgl",
  kernelFunc: Us
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ur = "return ceil(x);", $C = _({ opSnippet: ur, packedOpSnippet: ur, cpuKernelImpl: $g }), SC = {
  kernelName: Lc,
  backendName: "webgl",
  kernelFunc: $C
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class IC {
  constructor(e) {
    this.variableNames = ["A"], this.customUniforms = [
      { name: "minVal", type: "float" },
      { name: "maxVal", type: "float" }
    ], this.outputShape = e, this.userCode = `

      void main() {
        float value = getAAtOutCoords();
        if (isnan(value)) {
          setOutput(value);
          return;
        }

        setOutput(clamp(value, minVal, maxVal));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class RC {
  constructor(e) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0, this.customUniforms = [
      { name: "minVal", type: "float" },
      { name: "maxVal", type: "float" }
    ], this.outputShape = e, this.userCode = `
      void main() {
        vec4 value = getAAtOutCoords();

        if (any(isnan(value))) {
          setOutput(value);
          return;
        }

        setOutput(clamp(value, vec4(minVal), vec4(maxVal)));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function TC(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { clipValueMin: r, clipValueMax: i } = s;
  let a;
  y().getBool("WEBGL_PACK_CLIP") ? a = new RC(o.shape) : a = new IC(o.shape);
  const c = [[r], [i]];
  return t.runWebGLProgram(a, [o], o.dtype, c);
}
const EC = {
  kernelName: Bc,
  backendName: "webgl",
  kernelFunc: TC
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class NC {
  constructor(e) {
    this.variableNames = ["real", "imag"], this.outputShape = e, this.userCode = `
      void main() {
        float re = abs(getRealAtOutCoords());
        float im = abs(getImagAtOutCoords());
        float mx = max(re, im);

        // sadly the length function in glsl is not underflow-safe
        // (at least not on Intel GPUs). So the safe solution is
        // to ensure underflow-safety in all cases.
        setOutput(
          mx == 0.0 ? 0.0 : mx * length(vec2(1, min(re, im)/mx))
        );
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function dr(n, e) {
  return {
    dataId: e.dataId,
    dtype: e.dtype,
    shape: n.shape
  };
}
function kC(n) {
  const { inputs: e, backend: t } = n, { x: s } = e, o = t.texData.get(s.dataId), r = new NC(s.shape), i = [
    dr(s, o.complexTensorInfos.real),
    dr(s, o.complexTensorInfos.imag)
  ];
  return t.runWebGLProgram(r, i, i[0].dtype);
}
const AC = {
  kernelName: kr,
  backendName: "webgl",
  kernelFunc: kC
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class FC {
  // Concats 2d tensors along axis=1. See comments in MathBackendWebGL.concat().
  constructor(e) {
    this.outputShape = [], this.outputShape = bt(
      e,
      1
      /* axis */
    ), this.variableNames = e.map((i, a) => `T${a}`);
    const t = new Array(e.length - 1);
    t[0] = e[0][1];
    for (let i = 1; i < t.length; i++)
      t[i] = t[i - 1] + e[i][1];
    const s = [`if (yC < ${t[0]}) setOutput(getT0(yR, yC));`];
    for (let i = 1; i < t.length; i++) {
      const a = t[i - 1];
      s.push(`else if (yC < ${t[i]}) setOutput(getT${i}(yR, yC-${a}));`);
    }
    const o = t.length, r = t[t.length - 1];
    s.push(`else setOutput(getT${o}(yR, yC-${r}));`), this.userCode = `
      void main() {
        ivec2 coords = getOutputCoords();
        int yR = coords.x;
        int yC = coords.y;

        ${s.join(`
        `)}
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class DC {
  constructor(e, t) {
    this.packedInputs = !0, this.packedOutput = !0, this.outputShape = [], this.outputShape = bt(e, t);
    const s = this.outputShape, o = s.length, r = V(o), i = re("coords", o), a = ["x", "y", "z", "w", "u", "v"].slice(0, o);
    this.variableNames = e.map((x, g) => `T${g}`);
    const c = new Array(e.length - 1);
    c[0] = e[0][t];
    for (let x = 1; x < c.length; x++)
      c[x] = c[x - 1] + e[x][t];
    const l = a[t], u = a.slice(-2), d = a.join();
    let h = `if (${l} < ${c[0]}) {
        return getChannel(
            getT0(${d}), vec2(${u.join()}));
        }`;
    for (let x = 1; x < c.length; x++) {
      const g = c[x - 1];
      h += `
        if (${l} < ${c[x]}  && ${l} >= ${c[x - 1]}) {
          return getChannel(
            getT${x}(${On(a, l, g)}),
            vec2(${On(u, l, g)}));
        }`;
    }
    const f = c.length, p = c[c.length - 1];
    h += `
        return getChannel(
          getT${f}(${On(a, l, p)}),
          vec2(${On(u, l, p)}));`, this.userCode = `
      float getValue(${a.map((x) => "int " + x)}) {
        ${h}
      }

      void main() {
        ${r} coords = getOutputCoords();
        vec4 result = vec4(getValue(${i}), 0., 0., 0.);

        ${i[o - 1]} = ${i[o - 1]} + 1;
        if (${i[o - 1]} < ${s[o - 1]}) {
          result.g = getValue(${i});
        }

        ${i[o - 2]} = ${i[o - 2]} + 1;
        if (${i[o - 2]} < ${s[o - 2]}) {
          result.a = getValue(${i});
        }

        ${i[o - 1]} = ${i[o - 1]} - 1;
        if (${i[o - 2]} < ${s[o - 2]} &&
            ${i[o - 1]} < ${s[o - 1]}) {
          result.b = getValue(${i});
        }
        setOutput(result);
      }
    `;
  }
}
function On(n, e, t) {
  const s = n.indexOf(e);
  return n.map((r, i) => i === s ? `${r} - ${t}` : r).join();
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function rs(n) {
  const { inputs: e, backend: t } = n, { input: s } = e, o = t.texData.get(s.dataId);
  return me({ inputs: { x: o.complexTensorInfos.imag }, backend: t });
}
const OC = {
  kernelName: yl,
  backendName: "webgl",
  kernelFunc: rs
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function un(n, e, t) {
  const s = n[0].dtype;
  if (s === "complex64") {
    const f = n.map((C) => $n({ inputs: { input: C }, backend: t })), p = n.map((C) => rs({ inputs: { input: C }, backend: t })), x = un(f, e, t), g = un(p, e, t), m = ot({ inputs: { real: x, imag: g }, backend: t });
    return f.forEach((C) => t.disposeIntermediateTensorInfo(C)), p.forEach((C) => t.disposeIntermediateTensorInfo(C)), t.disposeIntermediateTensorInfo(x), t.disposeIntermediateTensorInfo(g), m;
  }
  let o = t.shouldExecuteOnCPU(n);
  if (s === "string" && (o = !0), o) {
    const f = n.map((w) => {
      const E = [-1, T(w.shape.slice(e))];
      return S({ inputs: { x: w }, backend: t, attrs: { shape: E } });
    }), p = f.map((w) => ({ vals: t.readSync(w.dataId), shape: w.shape })), x = bt(
      f.map((w) => w.shape),
      1
      /* axis */
    ), g = f[0].shape[0] === 1, m = Sg(p, x, s, g), C = bt(n.map((w) => w.shape), e), b = t.makeTensorInfo(C, s, m);
    return f.forEach((w) => t.disposeIntermediateTensorInfo(w)), b;
  }
  const r = n.filter((f) => T(f.shape) > 0), i = y().getBool("WEBGL_PACK_ARRAY_OPERATIONS") && r[0].shape.length > 1;
  if (r.length === 1) {
    const f = i ? new Ue(n[0].shape, Ze) : new et(n[0].shape, Ze);
    return t.runWebGLProgram(f, n, s);
  }
  const a = y().getNumber("WEBGL_MAX_TEXTURES_IN_SHADER");
  if (r.length > a) {
    const f = [];
    for (let x = 0; x < r.length; x += a) {
      const g = r.slice(x, x + a);
      f.push(un(g, e, t));
    }
    const p = un(f, e, t);
    for (const x of f)
      t.disposeIntermediateTensorInfo(x);
    return p;
  }
  if (i) {
    const f = new DC(r.map((p) => p.shape), e);
    return t.runWebGLProgram(f, r, s);
  }
  const { tensors2D: c, outShape: l } = PC(r, e, t), u = new FC(c.map((f) => f.shape)), d = t.runWebGLProgram(u, c, s);
  c.forEach((f) => t.disposeIntermediateTensorInfo(f));
  const h = S({ inputs: { x: d }, attrs: { shape: l }, backend: t });
  return t.disposeIntermediateTensorInfo(d), h;
}
function PC(n, e, t) {
  const s = bt(n.map((r) => r.shape), e);
  return { tensors2D: n.map((r) => S({
    inputs: { x: r },
    attrs: { shape: [-1, T(r.shape.slice(e))] },
    backend: t
  })), outShape: s };
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Aa(n) {
  const { inputs: e, backend: t, attrs: s } = n, { axis: o } = s, r = de(o, e[0].shape)[0], i = e.map((l) => l.shape);
  $i(i, r);
  const a = bt(e.map((l) => l.shape), r);
  if (T(a) === 0)
    return t.makeTensorInfo(a, e[0].dtype, []);
  const c = e.filter((l) => T(l.shape) > 0);
  return c.length === 1 ? me({ inputs: { x: c[0] }, backend: t }) : un(c, r, t);
}
const _C = {
  kernelName: Mc,
  backendName: "webgl",
  kernelFunc: Aa
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Fa {
  constructor(e, t = !1, s = null, o = !1, r = !1) {
    this.variableNames = ["x", "W"], this.outputShape = e.outShape;
    const i = e.padInfo.top, a = e.padInfo.left, c = e.strideHeight, l = e.strideWidth, u = e.dilationHeight, d = e.dilationWidth, h = e.filterHeight, f = e.filterWidth, p = Math.floor(e.inChannels / 4) * 4, x = e.inChannels % 4, g = e.dataFormat === "channelsLast", m = g ? 1 : 2, C = g ? 2 : 3, b = g ? 3 : 1;
    let w = "", v = "";
    s && (o ? w = `float activation(float a) {
          float b = getPreluActivationWeightsAtOutCoords();
          ${s}
        }` : r ? w = `float activation(float a) {
          float b = getLeakyreluAlphaAtOutCoords();
          ${s}
        }` : w = `
          float activation(float x) {
            ${s}
          }
        `, v = "result = activation(result);");
    const E = t ? "result += getBiasAtOutCoords();" : "";
    t && this.variableNames.push("bias"), o && this.variableNames.push("preluActivationWeights"), r && this.variableNames.push("leakyreluAlpha"), this.userCode = `
      ${w}

      const ivec2 strides = ivec2(${c}, ${l});
      const ivec2 pads = ivec2(${i}, ${a});

      void main() {
        ivec4 coords = getOutputCoords();
        int batch = coords[0];
        int d2 = coords[${b}];

        ivec2 xRCCorner =
            ivec2(coords[${m}], coords[${C}]) * strides - pads;
        int xRCorner = xRCCorner.x;
        int xCCorner = xRCCorner.y;

        // Convolve x(?, ?, d1) with w(:, :, d1, d2) to get y(yR, yC, d2).
        // ? = to be determined. : = across all values in that axis.
        float dotProd = 0.0;
        for (int wR = 0; wR < ${h}; wR++) {
          int xR = xRCorner + wR * ${u};

          if (xR < 0 || xR >= ${e.inHeight}) {
            continue;
          }

          for (int wC = 0; wC < ${f}; wC++) {
            int xC = xCCorner + wC * ${d};

            if (xC < 0 || xC >= ${e.inWidth}) {
              continue;
            }

            for (int d1 = 0; d1 < ${p}; d1 += 4) {
              vec4 wValues = vec4(
                getW(wR, wC, d1, d2),
                getW(wR, wC, d1 + 1, d2),
                getW(wR, wC, d1 + 2, d2),
                getW(wR, wC, d1 + 3, d2)
              );

              if (${g}) {
                vec4 xValues = vec4(
                  getX(batch, xR, xC, d1),
                  getX(batch, xR, xC, d1 + 1),
                  getX(batch, xR, xC, d1 + 2),
                  getX(batch, xR, xC, d1 + 3)
                );
                dotProd += dot(xValues, wValues);
              } else {
                vec4 xValues = vec4(
                  getX(batch, d1, xR, xC),
                  getX(batch, d1 + 1, xR, xC),
                  getX(batch, d1 + 2, xR, xC),
                  getX(batch, d1 + 3, xR, xC)
                );
                dotProd += dot(xValues, wValues);
              }
            }

            if (${x === 1}) {

              if (${g}) {
                dotProd +=
                    getX(batch, xR, xC, ${p}) *
                    getW(wR, wC, ${p}, d2);
              } else {
                dotProd +=
                    getX(batch, ${p}, xR, xC) *
                    getW(wR, wC, ${p}, d2);
              }

            } else if (${x === 2}) {
              vec2 wValues = vec2(
                getW(wR, wC, ${p}, d2),
                getW(wR, wC, ${p} + 1, d2)
              );

              if (${g}) {
                vec2 xValues = vec2(
                  getX(batch, xR, xC, ${p}),
                  getX(batch, xR, xC, ${p} + 1)
                );
                dotProd += dot(xValues, wValues);
              } else {
                vec2 xValues = vec2(
                  getX(batch, ${p}, xR, xC),
                  getX(batch, ${p} + 1, xR, xC)
                );
                dotProd += dot(xValues, wValues);
              }

            } else if (${x === 3}) {
              vec3 wValues = vec3(
                getW(wR, wC, ${p}, d2),
                getW(wR, wC, ${p} + 1, d2),
                getW(wR, wC, ${p} + 2, d2)
              );

              if (${g}) {
                vec3 xValues = vec3(
                  getX(batch, xR, xC, ${p}),
                  getX(batch, xR, xC, ${p} + 1),
                  getX(batch, xR, xC, ${p} + 2)
                );
                dotProd += dot(xValues, wValues);
              } else {
                vec3 xValues = vec3(
                  getX(batch, ${p}, xR, xC),
                  getX(batch, ${p} + 1, xR, xC),
                  getX(batch, ${p} + 2, xR, xC)
                );
                dotProd += dot(xValues, wValues);
              }

            }
          }
        }

        float result = dotProd;
        ${E}
        ${v}
        setOutput(result);
      }
    `;
  }
}
class LC {
  constructor(e) {
    this.variableNames = ["x", "W"], this.outputShape = e.outShape;
    const t = e.padInfo.front, s = e.padInfo.top, o = e.padInfo.left, r = e.strideDepth, i = e.strideHeight, a = e.strideWidth, c = e.dilationDepth, l = e.dilationHeight, u = e.dilationWidth, d = e.filterDepth, h = e.filterHeight, f = e.filterWidth, p = Math.floor(e.inChannels / 4) * 4, x = e.inChannels % 4;
    this.userCode = `
      const ivec3 strides = ivec3(${r}, ${i}, ${a});
      const ivec3 pads = ivec3(${t}, ${s}, ${o});

      void main() {
        ivec5 coords = getOutputCoords();
        int batch = coords.x;
        int d2 = coords.u;

        ivec3 xFRCCorner = ivec3(coords.y, coords.z, coords.w) * strides - pads;
        int xFCorner = xFRCCorner.x;
        int xRCorner = xFRCCorner.y;
        int xCCorner = xFRCCorner.z;

        // Convolve x(?, ?, ?, d1) with w(:, :, :, d1, d2) to get
        // y(yF, yR, yC, d2). ? = to be determined. : = across all
        // values in that axis.
        float dotProd = 0.0;
        for (int wF = 0; wF < ${d}; wF++) {
          int xF = xFCorner + wF * ${c};

          if (xF < 0 || xF >= ${e.inDepth}) {
            continue;
          }

          for (int wR = 0; wR < ${h}; wR++) {
            int xR = xRCorner + wR * ${l};

            if (xR < 0 || xR >= ${e.inHeight}) {
              continue;
            }

            for (int wC = 0; wC < ${f}; wC++) {
              int xC = xCCorner + wC * ${u};

              if (xC < 0 || xC >= ${e.inWidth}) {
                continue;
              }

              for (int d1 = 0; d1 < ${p}; d1 += 4) {
                vec4 xValues = vec4(
                  getX(batch, xF, xR, xC, d1),
                  getX(batch, xF, xR, xC, d1 + 1),
                  getX(batch, xF, xR, xC, d1 + 2),
                  getX(batch, xF, xR, xC, d1 + 3)
                );
                vec4 wValues = vec4(
                  getW(wF, wR, wC, d1, d2),
                  getW(wF, wR, wC, d1 + 1, d2),
                  getW(wF, wR, wC, d1 + 2, d2),
                  getW(wF, wR, wC, d1 + 3, d2)
                );

                dotProd += dot(xValues, wValues);
              }

              if (${x === 1}) {
                dotProd +=
                  getX(batch, xF, xR, xC, ${p}) *
                  getW(wF, wR, wC, ${p}, d2);
              } else if (${x === 2}) {
                vec2 xValues = vec2(
                  getX(batch, xF, xR, xC, ${p}),
                  getX(batch, xF, xR, xC, ${p} + 1)
                );
                vec2 wValues = vec2(
                  getW(wF, wR, wC, ${p}, d2),
                  getW(wF, wR, wC, ${p} + 1, d2)
                );
                dotProd += dot(xValues, wValues);
              } else if (${x === 3}) {
                vec3 xValues = vec3(
                  getX(batch, xF, xR, xC, ${p}),
                  getX(batch, xF, xR, xC, ${p} + 1),
                  getX(batch, xF, xR, xC, ${p} + 2)
                );
                vec3 wValues = vec3(
                  getW(wF, wR, wC, ${p}, d2),
                  getW(wF, wR, wC, ${p} + 1, d2),
                  getW(wF, wR, wC, ${p} + 2, d2)
                );
                dotProd += dot(xValues, wValues);
              }
            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Da {
  constructor(e, t = !1, s = null, o = !1, r = !1) {
    this.variableNames = ["x", "W"], this.packedInputs = !0, this.packedOutput = !0, this.customUniforms = [
      { name: "pads", type: "ivec2" },
      { name: "strides", type: "ivec2" },
      { name: "dilations", type: "ivec2" },
      { name: "inDims", type: "ivec2" }
    ], this.outputShape = e.outShape, this.enableShapeUniforms = ne(this.outputShape.length);
    const i = e.padInfo.left, a = e.strideWidth, c = e.dilationWidth, l = e.filterHeight, u = e.filterWidth, d = u;
    let h = `
       int xR; int xC; int xCOffset;
       vec4 wTexel; vec4 previous; vec4 final;`;
    for (let g = 0; g < u; g++)
      h += `
           vec4 xTexelC${g * 2};
           int xTexelC${g * 2}Ready;
           vec4 xTexelC${g * 2 + 1};
           int xTexelC${g * 2 + 1}Ready;
           vec4 xC${g};`;
    h += `
     for (int r = 0; r < ${l}; r++) {
      for (int d1 = 0; d1 < ${e.inChannels}; d1 += 2) {
       `;
    for (let g = 0; g < u; g++)
      h += `
           xTexelC${g * 2} = vec4(0.0);
           xTexelC${g * 2}Ready = 0;
           xTexelC${g * 2 + 1} = vec4(0.0);
           xTexelC${g * 2 + 1}Ready = 0;
           xC${g} = vec4(0.0);`;
    h += `
         xR = xRCorner + r * dilations[0];
         if (xR >=0 && xR < inDims[0]) {
       `;
    for (let g = 0; g < (d + 1) / 2; g++) {
      const m = g * 2;
      if (h += `
           xC = xCCorner + ${m * c};
           `, a === 1) {
        if (m < u && (i % 2 === 1 ? (h += `
                 xCOffset = xC + 1;
                 if (xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${m}Ready == 0) {
                   xTexelC${m} = getX(batch, xR, xCOffset, d1);

                   // Need to manually clear unused channels in case
                   // we're reading from recycled texture.
                   if (xCOffset + 1 >= inDims[1]) {
                     xTexelC${m}.zw = vec2(0.0);
                   }
                   xTexelC${m}Ready = 1;
                 }
               `, c === 1 && m > 0 ? h += `
                 xC${m} = vec4(xTexelC${m - 2}.zw, xTexelC${m}.xy);
                 ` : h += `
                   xCOffset = xC + 1 - 2;

                   if (xCOffset >= 0 && xCOffset < inDims[1]) {
                     previous = getX(batch, xR, xCOffset, d1);

                     // Need to manually clear unused channels in case
                     // we're reading from recycled texture.
                     if (xCOffset + 1 >= inDims[1]) {
                       previous.zw = vec2(0.0);
                     }

                     xC${m} = vec4(previous.zw, xTexelC${m}.xy);
                   } else {
                     xC${m} = vec4(0.0, 0.0, xTexelC${m}.xy);
                   }
                   `) : h += `
                 if (xC >= 0 && xC < inDims[1] && xTexelC${m}Ready == 0) {
                   xTexelC${m} = getX(batch, xR, xC, d1);
                   if (xC + 1 >= inDims[1]) {
                     xTexelC${m}.zw = vec2(0.0);
                   }
                   xTexelC${m}Ready = 1;
                 }

                 xC${m} = xTexelC${m};
                 `, m + 1 < u)) {
          const C = i % 2 === 0 ? Gs(c) : c;
          c % 2 === 0 && i % 2 === 1 || c % 2 !== 0 && i % 2 !== 1 ? (h += `
                   xCOffset = xC + imod(pads[1], 2) + ${C};

                   if (xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${m + 1}Ready == 0) {
                     xTexelC${m + 1} = getX(batch, xR, xCOffset, d1);

                     // Need to manually clear unused channels in case
                     // we're reading from recycled texture.
                     if (xCOffset + 1 >= inDims[1]) {
                       xTexelC${m + 1}.zw = vec2(0.0);
                     }
                     xTexelC${m + 1}Ready = 1;
                   }
                   `, c > 1 ? h += `
                     xCOffset -= 2;
                     if (xCOffset >= 0 && xCOffset < inDims[1]) {
                      previous = getX(batch, xR, xCOffset, d1);
                      xC${m + 1} = vec4(previous.zw, xTexelC${m + 1}.xy);
                     } else {
                      xC${m + 1} = vec4(0.0, 0.0, xTexelC${m + 1}.xy);
                     }
                     ` : h += `
                     xC${m + 1} = vec4(xTexelC${m}.zw, xTexelC${m + 1}.xy);
                     `) : C === 1 ? h += `
                     xC${m + 1} = xTexelC${m};
                     ` : h += `
                     xCOffset = xC + ${C};

                     if (xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${m + 1}Ready == 0) {
                       xTexelC${m + 1} = getX(batch, xR, xCOffset, d1);
                       if (xCOffset + 1 >= inDims[1]) {
                         xTexelC${m + 1}.zw = vec2(0.0);
                       }
                       xTexelC${m + 1}Ready = 1;
                     }

                     xC${m + 1} = xTexelC${m + 1};
                     `;
        }
      } else
        m < u && (i % 2 === 1 ? (h += `
                 xCOffset = xC + 1 - strides[1];
                 if(xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${m}Ready == 0) {
                   xTexelC${m} = getX(batch, xR, xCOffset, d1);
                   // Need to manually clear unused channels in case
                   // we're reading from recycled texture.
                   if (xCOffset + 1 >= inDims[1]) {
                     xTexelC${m}.zw = vec2(0.0);
                   }
                   xTexelC${m}Ready = 1;
                 }

                 if(xC + 1 >= 0 && xC + 1 < inDims[1] && xTexelC${m + 1}Ready == 0) {
                   xTexelC${m + 1} = getX(batch, xR, xC + 1, d1);
                   // Need to manually clear unused channels in case
                   // we're reading from recycled texture.
                   if (xC + 2 >= inDims[1]) {
                     xTexelC${m + 1}.zw = vec2(0.0);
                   }
                   xTexelC${m + 1}Ready = 1;
                 }

                 xC${m} = vec4(xTexelC${m}.zw, xTexelC${m + 1}.zw);
               `, m + 1 < u && (h += `
                   final = vec4(0.0);
                   xCOffset = xC + 1 + strides[1];
                   if(xCOffset >= 0 && xCOffset < inDims[1]) {
                     final = getX(batch, xR, xCOffset, d1);
                   }
                   xC${m + 1} = vec4(xTexelC${m + 1}.xy, final.xy);
                 `)) : (h += `
                 if(xC >= 0 && xC < inDims[1] && xTexelC${m}Ready == 0) {
                   xTexelC${m} = getX(batch, xR, xC, d1);
                   if (xC + 1 >= inDims[1]) {
                     xTexelC${m}.zw = vec2(0.0);
                   }
                   xTexelC${m}Ready = 1;
                 }

                 xCOffset = xC + strides[1];
                 if(xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${m + 1}Ready == 0) {
                   xTexelC${m + 1} = getX(batch, xR, xCOffset, d1);
                   if (xCOffset + 1 >= inDims[1]) {
                     xTexelC${m + 1}.zw = vec2(0.);
                   }
                   xTexelC${m + 1}Ready = 1;
                 }

                 xC${m} = vec4(
                   xTexelC${m}.xy, xTexelC${m + 1}.xy);
               `, m + 1 < u && (h += `
                   xC${m + 1} = vec4(xTexelC${m}.zw, xTexelC${m + 1}.zw);
                 `)));
      m < u && (h += `
             wTexel = getW(r, ${m}, d1, d2);
             dotProd += xC${m}.xxzz * vec4(wTexel.xy, wTexel.xy);
             if(d1 + 1 < ${e.inChannels}) {
               dotProd += xC${m}.yyww * vec4(wTexel.zw, wTexel.zw);
             }
           `, m + 1 < u && (h += `
               wTexel = getW(r, ${m + 1}, d1, d2);
               dotProd += xC${m + 1}.xxzz * vec4(wTexel.xy, wTexel.xy);
               if(d1 + 1 < ${e.inChannels}) {
                 dotProd += xC${m + 1}.yyww * vec4(wTexel.zw, wTexel.zw);
               }
             `));
    }
    h += `
     }
   `, h += `
     }
   `, h += `
     }
   `;
    let f = "", p = "";
    s && (o ? f = `vec4 activation(vec4 a) {
           vec4 b = getPreluActivationWeightsAtOutCoords();
           ${s}
         }` : r ? f = `vec4 activation(vec4 a) {
           vec4 b = getLeakyreluAlphaAtOutCoords();
           ${s}
         }` : f = `vec4 activation(vec4 x) {
           ${s}
         }`, p = "result = activation(result);");
    const x = t ? "result += getBiasAtOutCoords();" : "";
    t && this.variableNames.push("bias"), o && this.variableNames.push("preluActivationWeights"), r && this.variableNames.push("leakyreluAlpha"), this.userCode = `
       ${f}

       void main() {
         ivec4 coords = getOutputCoords();
         int batch = coords.x;
         ivec2 xRCCorner = coords.yz * strides - pads;
         int d2 = coords.w;
         int xRCorner = xRCCorner.x;
         int xCCorner = xRCCorner.y;

         //intialize dotProd with a small epsilon seems to reduce GPU accuracy loss.
         vec4 dotProd = vec4(0.000000000000001);

         ${h}

         vec4 result = dotProd - vec4(0.000000000000001);
         ${x}
         ${p}
         setOutput(result);
       }
     `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class BC {
  constructor(e, t) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0, this.customUniforms = [
      { name: "inputShape", type: "ivec4" },
      { name: "pad", type: "ivec2" },
      { name: "stride", type: "ivec2" },
      { name: "dilation", type: "ivec2" },
      { name: "inChannels", type: "int" },
      { name: "itemsPerBlockRow", type: "int" },
      { name: "outWidth", type: "int" }
    ], this.outputShape = e, this.enableShapeUniforms = ne(this.outputShape.length);
    const { dataFormat: s } = t, o = le(), r = s === "channelsLast", i = r ? 1 : 2, a = r ? 2 : 3, c = this.enableShapeUniforms ? "if(blockIndex < outShape[2] && pos < outShape[1]) {" : `if(blockIndex < ${e[2]} && pos < ${e[1]}) {`;
    let l = "";
    for (let u = 0; u <= 1; u++)
      for (let d = 0; d <= 1; d++)
        l += `
          blockIndex = rc.z + ${d};
          pos = rc.y + ${u};

          ${c}
            offsetY = int(blockIndex / outWidth) * stride[0] - pad[0];
            d0 = offsetY + dilation[0] * (pos / itemsPerBlockRow);

            if(d0 < inputShape[${i}] && d0 >= 0) {
              // Use custom imod instead mod. On Intel GPU, mod may generate
              // unexpected value.
              // https://github.com/tensorflow/tfjs/issues/5447
              offsetX = imod(blockIndex, outWidth) * stride[1] - pad[1];
              d1 = offsetX + dilation[1] * (imod(pos, itemsPerBlockRow) /
                  inChannels);

              if(d1 < inputShape[${a}] && d1 >= 0) {

                ch = imod(pos, inChannels);

                if (${r}) {
                  innerDims = vec2(d1, ch);
                  result[${u * 2 + d}] = getChannel(
                    getA(rc.x, d0, int(innerDims.x),
                    int(innerDims.y)), innerDims);
                } else {
                  innerDims = vec2(d0, d1);
                  result[${u * 2 + d}] = getChannel(
                    getA(rc.x, ch, int(innerDims.x),
                    int(innerDims.y)), innerDims);
                }
              }
            }
          }
        `;
    this.userCode = `
      void main() {
        ivec3 rc = getOutputCoords();

        vec4 result = vec4(0);

        int blockIndex, pos, offsetY, d0, offsetX, d1, ch;
        vec2 innerDims;

        ${l}

        ${o.output} = result;
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function qn(n, e) {
  const t = n.length;
  return t >= 3 ? e ? [
    ...n.slice(0, -3),
    n[t - 3] * n[t - 2],
    n[t - 1]
    /* channel */
  ] : [
    ...n.slice(0, -3),
    n[t - 3],
    n[t - 2] * n[t - 1]
    /* height * width */
  ] : !e && t === 1 && n[0] > 1 ? [n[0], 1] : null;
}
function Oa({ x: n, filter: e, convInfo: t, backend: s, bias: o = null, preluActivationWeights: r = null, leakyreluAlpha: i = 0, activation: a = null }) {
  const c = n.shape, l = s.texData.get(n.dataId), u = t.inChannels, d = c[0] * c[1] * c[2], h = t.outChannels, f = t.dataFormat === "channelsLast", p = !1, x = !1;
  let g;
  const m = [];
  if (r != null) {
    const w = qn(r.shape, f);
    w != null && (r = S({
      inputs: { x: r },
      backend: s,
      attrs: { shape: w }
    }), m.push(r));
  }
  if (o != null) {
    const w = qn(o.shape, f);
    w != null && (o = S({ inputs: { x: o }, backend: s, attrs: { shape: w } }), m.push(o));
  }
  if (!((d === 1 || h === 1) && u > Ra) && l.isPacked && f && l.texture != null && c[2] % 2 !== 0 && Z(l.shape.slice(-3), c.slice(-3))) {
    const w = c[0] * c[1] * (c[2] + 1), v = {
      dataId: n.dataId,
      shape: [1, w, t.inChannels],
      dtype: n.dtype
    }, E = l.shape;
    l.shape = l.shape.slice(), l.shape[l.shape.length - 2]++, N(zn(l.shape, v.shape), () => `packed reshape ${l.shape} to ${v.shape} isn't free`);
    const R = S({
      inputs: { x: e },
      backend: s,
      attrs: { shape: [1, t.inChannels, t.outChannels] }
    });
    m.push(R);
    const $ = Xn({
      a: v,
      b: R,
      backend: s,
      transposeA: p,
      transposeB: x,
      bias: o,
      activation: a,
      preluActivationWeights: r,
      leakyreluAlpha: i
    }), F = s.texData.get($.dataId);
    N(F.isPacked, () => "batchMatMul result is expected to be packed"), l.shape = E, F.shape = t.outShape, g = me({ inputs: { x: $ }, backend: s }), g.shape = t.outShape, m.push($);
  } else {
    const w = t.outHeight * t.outWidth, v = S({
      inputs: { x: n },
      backend: s,
      attrs: {
        shape: f ? [t.batchSize, w, t.inChannels] : [t.batchSize, t.inChannels, w]
      }
    }), E = S({
      inputs: { x: e },
      backend: s,
      attrs: { shape: [1, t.inChannels, t.outChannels] }
    }), R = Xn({
      a: f ? v : E,
      b: f ? E : v,
      transposeA: !f,
      transposeB: x,
      backend: s,
      bias: o,
      activation: a,
      preluActivationWeights: r,
      leakyreluAlpha: i
    });
    g = S({ inputs: { x: R }, backend: s, attrs: { shape: t.outShape } }), m.push(v), m.push(E), m.push(R);
  }
  for (const w of m)
    s.disposeIntermediateTensorInfo(w);
  return g;
}
function Pa({ x: n, filter: e, convInfo: t, backend: s, bias: o = null, preluActivationWeights: r = null, leakyreluAlpha: i = 0, activation: a = null }) {
  const { filterWidth: c, filterHeight: l, inChannels: u, outWidth: d, outHeight: h, dataFormat: f } = t, p = f === "channelsLast", x = c * l * u, g = h * d, m = [t.batchSize, x, g], C = !0, b = !1, w = [];
  if (r != null) {
    const se = qn(r.shape, p);
    se != null && (r = S({
      inputs: { x: r },
      backend: s,
      attrs: { shape: se }
    }), w.push(r));
  }
  if (o != null) {
    const se = qn(o.shape, p);
    se != null && (o = S({ inputs: { x: o }, backend: s, attrs: { shape: se } }), w.push(o));
  }
  const v = S({
    inputs: { x: e },
    backend: s,
    attrs: { shape: [1, x, T(e.shape) / x] }
  });
  w.push(v);
  const E = new BC(m, t), R = [
    n.shape,
    [t.padInfo.top, t.padInfo.left],
    [t.strideHeight, t.strideWidth],
    [t.dilationHeight, t.dilationWidth],
    [t.inChannels],
    [t.filterWidth * t.inChannels],
    [t.outWidth]
  ], $ = s.runWebGLProgram(E, [n], "float32", R), F = S({ inputs: { x: $ }, backend: s, attrs: { shape: m } });
  w.push($), w.push(F);
  const O = o != null, L = r != null, B = a === "leakyrelu", he = a ? fn(a, !0) : null, j = new Ia(p ? F.shape : v.shape, p ? v.shape : F.shape, p ? [t.batchSize, g, t.outChannels] : [t.batchSize, t.outChannels, g], C, b, O, he, L, B), te = p ? [F, v] : [v, F];
  if (o && te.push(o), L && te.push(r), B) {
    const se = s.makeTensorInfo([], "float32", Xt(i, "float32"));
    te.push(se), w.push(se);
  }
  const we = s.runWebGLProgram(j, te, "float32"), Ae = S({ inputs: { x: we }, backend: s, attrs: { shape: t.outShape } });
  w.push(we);
  for (const se of w)
    s.disposeIntermediateTensorInfo(se);
  return Ae;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function MC(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, filter: r } = e, { strides: i, pad: a, dataFormat: c, dilations: l, dimRoundingMode: u } = s, d = Kt(c), h = Be(o.shape, r.shape, i, l, a, u, !1, d);
  let f;
  if (h.filterHeight === 1 && h.filterWidth === 1 && h.dilationHeight === 1 && h.dilationWidth === 1 && h.strideHeight === 1 && h.strideWidth === 1 && (h.padInfo.type === "SAME" || h.padInfo.type === "VALID"))
    f = Oa({ x: o, filter: r, convInfo: h, backend: t });
  else if (h.strideWidth <= 2 && d === "channelsLast" && y().getBool("WEBGL_EXP_CONV")) {
    const x = new Da(h), g = [
      [h.padInfo.top, h.padInfo.left],
      [h.strideHeight, h.strideWidth],
      [h.dilationHeight, h.dilationWidth],
      [h.inHeight, h.inWidth]
    ];
    f = t.runWebGLProgram(x, [o, r], "float32", g);
  } else if (y().getBool("WEBGL_CONV_IM2COL"))
    f = Pa({ x: o, filter: r, convInfo: h, backend: t });
  else {
    const x = new Fa(h);
    f = t.runWebGLProgram(x, [o, r], "float32");
  }
  const p = S({ inputs: { x: f }, backend: t, attrs: { shape: h.outShape } });
  return t.disposeIntermediateTensorInfo(f), p;
}
const VC = {
  kernelName: Vc,
  backendName: "webgl",
  kernelFunc: MC
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class UC {
  constructor(e) {
    this.variableNames = ["x", "dy"], this.outputShape = e.filterShape;
    const t = e.strideHeight, s = e.strideWidth, o = e.padInfo.top, r = e.padInfo.left, i = e.dataFormat === "channelsLast";
    this.userCode = `
      void main() {
        ivec4 coords = getOutputCoords();
        int wR = coords.x;
        int wC = coords.y;
        int d1 = coords.z;
        int d2 = coords.w;

        // Convolve x(?, ?, d1) with dy(:, :, d2) to get dw(wR, wC, d1, d2).
        // ? = to be determined. : = across all values in that axis.
        float dotProd = 0.0;

        for (int b = 0; b < ${e.batchSize}; b++) {
          for (int yR = 0; yR < ${e.outHeight}; yR++) {
            int xR = wR + yR * ${t} - ${o};

            if (xR < 0 || xR >= ${e.inHeight}) {
              continue;
            }

            for (int yC = 0; yC < ${e.outWidth}; yC++) {
              int xC = wC + yC * ${s} - ${r};

              if (xC < 0 || xC >= ${e.inWidth}) {
                continue;
              }

              ${i ? `float dyValue = getDy(b, yR, yC, d2);
              float xValue = getX(b, xR, xC, d1);
              dotProd += (xValue * dyValue);` : `float dyValue = getDy(b, d2, yR, yC);
              float xValue = getX(b, d1, xR, xC);
              dotProd += (xValue * dyValue);`}
            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
class WC {
  constructor(e) {
    this.variableNames = ["dy", "W"], this.outputShape = e.inShape;
    const t = e.filterHeight, s = e.filterWidth, o = e.strideHeight, r = e.strideWidth, i = e.dataFormat === "channelsLast", a = t - 1 - e.padInfo.top, c = s - 1 - e.padInfo.left, l = i ? 1 : 2, u = i ? 2 : 3, d = i ? 3 : 1;
    this.userCode = `
      const ivec2 pads = ivec2(${a}, ${c});

      void main() {
        ivec4 coords = getOutputCoords();
        int batch = coords[0];
        int d1 = coords[${d}];

        ivec2 dyCorner = ivec2(coords[${l}], coords[${u}]) - pads;
        int dyRCorner = dyCorner.x;
        int dyCCorner = dyCorner.y;

        // Convolve dy(?, ?, d2) with w(:, :, d1, d2) to compute dx(xR, xC, d1).
        // ? = to be determined. : = across all values in that axis.
        float dotProd = 0.0;
        for (int wR = 0; wR < ${t}; wR++) {
          float dyR = float(dyRCorner + wR) / ${o}.0;

          if (dyR < 0.0 || dyR >= ${e.outHeight}.0 || fract(dyR) > 0.0) {
            continue;
          }
          int idyR = int(dyR);

          int wRPerm = ${t} - 1 - wR;

          for (int wC = 0; wC < ${s}; wC++) {
            float dyC = float(dyCCorner + wC) / ${r}.0;

            if (dyC < 0.0 || dyC >= ${e.outWidth}.0 ||
                fract(dyC) > 0.0) {
              continue;
            }
            int idyC = int(dyC);

            int wCPerm = ${s} - 1 - wC;

            for (int d2 = 0; d2 < ${e.outChannels}; d2++) {

              if (${i}) {
                float xValue = getDy(batch, idyR, idyC, d2);
                float wValue = getW(wRPerm, wCPerm, d1, d2);
                dotProd += xValue * wValue;
              } else {
                float xValue = getDy(batch, d2, idyR, idyC);
                float wValue = getW(wRPerm, wCPerm, d1, d2);
                dotProd += xValue * wValue;
              }

            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
class GC {
  constructor(e) {
    this.variableNames = ["x", "dy"], this.outputShape = e.filterShape;
    const t = e.strideDepth, s = e.strideHeight, o = e.strideWidth, r = e.padInfo.front, i = e.padInfo.top, a = e.padInfo.left;
    this.userCode = `
      void main() {
        ivec5 coords = getOutputCoords();
        int wF = coords.x;
        int wR = coords.y;
        int wC = coords.z;
        int d1 = coords.w;
        int d2 = coords.u;

        float dotProd = 0.0;

        for (int b = 0; b < ${e.batchSize}; b++) {
          for (int yF = 0; yF < ${e.outDepth}; yF++) {
            int xF = wF + yF * ${t} - ${r};

            if (xF < 0 || xF >= ${e.inDepth}) {
              continue;
            }

            for (int yR = 0; yR < ${e.outHeight}; yR++) {
              int xR = wR + yR * ${s} - ${i};

              if (xR < 0 || xR >= ${e.inHeight}) {
                continue;
              }

              for (int yC = 0; yC < ${e.outWidth}; yC++) {
                int xC = wC + yC * ${o} - ${a};

                if (xC < 0 || xC >= ${e.inWidth}) {
                  continue;
                }

                float dyValue = getDy(b, yF, yR, yC, d2);
                float xValue = getX(b, xF, xR, xC, d1);
                dotProd += (xValue * dyValue);
              }
            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
class zC {
  constructor(e) {
    this.variableNames = ["dy", "W"], this.outputShape = e.inShape;
    const t = e.filterDepth, s = e.filterHeight, o = e.filterWidth, r = e.strideDepth, i = e.strideHeight, a = e.strideWidth, c = t - 1 - e.padInfo.front, l = s - 1 - e.padInfo.top, u = o - 1 - e.padInfo.left;
    this.userCode = `
      const ivec3 pads = ivec3(${c}, ${l}, ${u});

      void main() {
        ivec5 coords = getOutputCoords();
        int batch = coords.x;
        int d1 = coords.u;


        ivec3 dyCorner = ivec3(coords.y, coords.z, coords.w) - pads;
        int dyFCorner = dyCorner.x;
        int dyRCorner = dyCorner.y;
        int dyCCorner = dyCorner.z;

        float dotProd = 0.0;
        for (int wF = 0; wF < ${t}; wF++) {
          float dyF = float(dyFCorner + wF) / ${r}.0;

          if (dyF < 0.0 || dyF >= ${e.outDepth}.0 || fract(dyF) > 0.0) {
            continue;
          }
          int idyF = int(dyF);

          int wFPerm = ${t} - 1 - wF;

          for (int wR = 0; wR < ${s}; wR++) {
            float dyR = float(dyRCorner + wR) / ${i}.0;

            if (dyR < 0.0 || dyR >= ${e.outHeight}.0 ||
              fract(dyR) > 0.0) {
              continue;
            }
            int idyR = int(dyR);

            int wRPerm = ${s} - 1 - wR;

            for (int wC = 0; wC < ${o}; wC++) {
              float dyC = float(dyCCorner + wC) / ${a}.0;

              if (dyC < 0.0 || dyC >= ${e.outWidth}.0 ||
                  fract(dyC) > 0.0) {
                continue;
              }
              int idyC = int(dyC);

              int wCPerm = ${o} - 1 - wC;

              for (int d2 = 0; d2 < ${e.outChannels}; d2++) {
                float xValue = getDy(batch, idyF, idyR, idyC, d2);
                float wValue = getW(wFPerm, wRPerm, wCPerm, d1, d2);
                dotProd += xValue * wValue;
              }
            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function HC(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, dy: r } = e, { strides: i, pad: a, dataFormat: c, dimRoundingMode: l, filterShape: u } = s, d = Kt(c), h = Be(o.shape, u, i, 1, a, l, !1, d), f = new UC(h);
  return t.runWebGLProgram(f, [o, r], "float32");
}
const XC = {
  kernelName: Uc,
  backendName: "webgl",
  kernelFunc: HC
};
/**
 * @license
 * Copyright 2023 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class qC {
  constructor(e) {
    this.variableNames = ["dy", "W"], this.packedInputs = !0, this.packedOutput = !0, this.customUniforms = [
      { name: "strides", type: "vec2" }
    ], this.outputShape = e.inShape, this.enableShapeUniforms = ne(this.outputShape.length);
    const t = e.filterHeight, s = e.filterWidth, o = t - 1 - e.padInfo.top, r = s - 1 - e.padInfo.left;
    this.userCode = `
      const ivec2 pads = ivec2(${o}, ${r});

      void main() {
        ivec4 coords = getOutputCoords();
        int batch = coords[0];
        int d1 = coords[3];

        ivec2 dyCorner = ivec2(coords[1], coords[2]) - pads;
        int dyRCorner = dyCorner.x;
        int dyCCorner = dyCorner.y;

        vec4 result = vec4(0.);
        for (int wR = 0; wR < ${t}; wR++) {
          float dyR = float(dyRCorner + wR) / strides[0];
          if (dyR < 0.0 || dyR >= ${e.outHeight}.0 || fract(dyR) > 0.0) {
            continue;
          }
          int idyR = int(dyR);
          int wRPerm = ${t} - 1 - wR;

          for (int wC = 0; wC < ${s}; wC++) {
            int wCPerm = ${s} - 1 - wC;

            float dyC = float(dyCCorner + wC) / strides[1];
            bool idyCVal = (dyC >= 0.0) && (dyC < ${e.outWidth}.0)
              && (fract(dyC) == 0.0);
            int idyC = int(dyC);

            float dyC2 = float(dyCCorner + wC + 1) / strides[1];
            bool idyCVal2 = (dyC2 >= 0.0) && (dyC2 < ${e.outWidth}.0)
              && (fract(dyC2) == 0.0);
            int idyC2 = int(dyC2);

            if (idyCVal && idyCVal2) {
              for (int d2 = 0; d2 < ${e.outChannels}; d2 += 2) {
                vec4 wValue = getW(wRPerm, wCPerm, d1, d2);
                vec4 dySample = getDy(batch, idyR, idyC, d2);
                vec4 dySample2 = (idyC / 2 == idyC2 / 2) ?
                  dySample : getDy(batch, idyR, idyC2, d2);

                vec2 dyValue = mod(float(idyC), 2.) == 0. ?
                  dySample.xy : dySample.zw;
                result.xy += vec2(dot(dyValue, wValue.xy),
                  dot(dyValue, wValue.zw));

                dyValue = mod(float(idyC2), 2.) == 0. ?
                  dySample2.xy : dySample2.zw;
                result.zw += vec2(dot(dyValue, wValue.xy),
                  dot(dyValue, wValue.zw));
              }
            } else if (idyCVal) {
              for (int d2 = 0; d2 < ${e.outChannels}; d2 += 2) {
                vec4 wValue = getW(wRPerm, wCPerm, d1, d2);
                vec4 dySample = getDy(batch, idyR, idyC, d2);
                vec2 dyValue = mod(float(idyC), 2.) == 0. ?
                  dySample.xy : dySample.zw;
                result.xy += vec2(dot(dyValue, wValue.xy),
                  dot(dyValue, wValue.zw));
              }
            } else if (idyCVal2) {
              for (int d2 = 0; d2 < ${e.outChannels}; d2 += 2) {
                vec4 wValue = getW(wRPerm, wCPerm, d1, d2);
                vec4 dySample = getDy(batch, idyR, idyC2, d2);
                vec2 dyValue = mod(float(idyC2), 2.) == 0. ?
                  dySample.xy : dySample.zw;
                result.zw += vec2(dot(dyValue, wValue.xy),
                  dot(dyValue, wValue.zw));
              }
            }
          }
        }
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function jC(n) {
  const { inputs: e, backend: t, attrs: s } = n, { dy: o, filter: r } = e, { inputShape: i, strides: a, pad: c, dataFormat: l, dimRoundingMode: u } = s, d = Kt(l), h = Be(i, r.shape, a, 1, c, u, !1, d);
  if (y().getBool("WEBGL_PACK") && d === "channelsLast") {
    const f = [
      [h.strideHeight, h.strideWidth]
    ], p = new qC(h);
    return t.runWebGLProgram(p, [o, r], "float32", f);
  } else {
    const f = new WC(h);
    return t.runWebGLProgram(f, [o, r], "float32");
  }
}
const KC = {
  kernelName: Wc,
  backendName: "webgl",
  kernelFunc: jC
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function YC(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, filter: r } = e, { strides: i, pad: a, dilations: c } = s, l = bn(o.shape, r.shape, i, c, a), u = new LC(l);
  return t.runWebGLProgram(u, [o, r], "float32");
}
const QC = {
  kernelName: Gc,
  backendName: "webgl",
  kernelFunc: YC
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ZC(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, dy: r } = e, { strides: i, pad: a, filterShape: c } = s, l = bn(o.shape, c, i, 1, a), u = new GC(l);
  return t.runWebGLProgram(u, [o, r], "float32");
}
const JC = {
  kernelName: zc,
  backendName: "webgl",
  kernelFunc: ZC
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function eb(n) {
  const { inputs: e, backend: t, attrs: s } = n, { dy: o, filter: r } = e, { pad: i, strides: a, inputShape: c } = s, l = bn(c, r.shape, a, 1, i), u = new zC(l);
  return t.runWebGLProgram(u, [o, r], "float32");
}
const tb = {
  kernelName: Hc,
  backendName: "webgl",
  kernelFunc: eb
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const nb = nn + `
  return cos(x);
`, sb = `
  vec4 result = cos(x);
  bvec4 isNaN = isnan(x);
  ${Et}
  return result;
`, ob = _({ opSnippet: nb, packedOpSnippet: sb }), rb = {
  kernelName: Xc,
  backendName: "webgl",
  kernelFunc: ob
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ib = `
  float e2x = exp(-x);
  return (e2x + 1.0 / e2x) / 2.0;
`, ab = _({ opSnippet: ib }), cb = {
  kernelName: qc,
  backendName: "webgl",
  kernelFunc: ab
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class lb {
  constructor(e, t, s, o, r) {
    this.variableNames = ["Image", "Boxes", "BoxInd"], this.outputShape = [];
    const [i, a, c, l] = e, [u] = t, [d, h] = s;
    this.outputShape = [u, d, h, l];
    const f = o === "bilinear" ? 1 : 0, [p, x] = [`${a - 1}.0`, `${c - 1}.0`], [g, m, C] = d > 1 ? [
      `${(a - 1) / (d - 1)}`,
      "(y2-y1) * height_ratio",
      `y1*${p} + float(y)*(height_scale)`
    ] : [
      "0.0",
      "0.0",
      `0.5 * (y1+y2) * ${p}`
    ], [b, w, v] = h > 1 ? [
      `${(c - 1) / (h - 1)}`,
      "(x2-x1) * width_ratio",
      `x1*${x} + float(x)*(width_scale)`
    ] : [
      "0.0",
      "0.0",
      `0.5 * (x1+x2) * ${x}`
    ];
    this.userCode = `
      const float height_ratio = float(${g});
      const float width_ratio = float(${b});
      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int y = coords[1];
        int x = coords[2];
        int d = coords[3];

        // get box vals
        float y1 = getBoxes(b,0);
        float x1 = getBoxes(b,1);
        float y2 = getBoxes(b,2);
        float x2 = getBoxes(b,3);

        // get image in batch index
        int bInd = round(getBoxInd(b));
        if(bInd < 0 || bInd >= ${i}) {
          return;
        }

        float height_scale = ${m};
        float width_scale = ${w};

        float in_y = ${C};
        if( in_y < 0.0 || in_y > ${p} ) {
          setOutput(float(${r}));
          return;
        }
        float in_x = ${v};
        if( in_x < 0.0 || in_x > ${x} ) {
          setOutput(float(${r}));
          return;
        }

        vec2 sourceFracIndexCR = vec2(in_x,in_y);
        if(${f} == 1) {
          // Compute the four integer indices.
          ivec2 sourceFloorCR = ivec2(sourceFracIndexCR);
          ivec2 sourceCeilCR = ivec2(ceil(sourceFracIndexCR));

          float topLeft = getImage(b, sourceFloorCR.y, sourceFloorCR.x, d);
          float bottomLeft = getImage(b, sourceCeilCR.y, sourceFloorCR.x, d);
          float topRight = getImage(b, sourceFloorCR.y, sourceCeilCR.x, d);
          float bottomRight = getImage(b, sourceCeilCR.y, sourceCeilCR.x, d);

          vec2 fracCR = sourceFracIndexCR - vec2(sourceFloorCR);

          float top = topLeft + (topRight - topLeft) * fracCR.x;
          float bottom = bottomLeft + (bottomRight - bottomLeft) * fracCR.x;
          float newValue = top + (bottom - top) * fracCR.y;
          setOutput(newValue);
        } else {
          // Compute the coordinators of nearest neighbor point.
          ivec2 sourceNearestCR = ivec2(floor(
            sourceFracIndexCR + vec2(0.5,0.5)));
          float newValue = getImage(b, sourceNearestCR.y, sourceNearestCR.x, d);
          setOutput(newValue);
        }
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ub = (n) => {
  const { inputs: e, backend: t, attrs: s } = n, { image: o, boxes: r, boxInd: i } = e, { cropSize: a, method: c, extrapolationValue: l } = s, u = new lb(o.shape, r.shape, a, c, l);
  return t.runWebGLProgram(u, [o, r, i], "float32");
}, db = {
  kernelName: Yc,
  backendName: "webgl",
  kernelFunc: ub
};
var mn;
(function(n) {
  n.Prod = "*", n.Sum = "+";
})(mn || (mn = {}));
class hr {
  constructor(e, t, s, o) {
    this.op = e, this.outputShape = t, this.variableNames = ["x"], this.customUniforms = [{ name: "index", type: "float" }];
    const r = this.outputShape.length, i = this.op === mn.Prod ? "1.0" : "0.0", a = s ? i : `getX(${fr(r, "coords", this.op)})`, c = this.outputShape[this.outputShape.length - 1];
    let l = "", u = "";
    s ? (l = o ? `end != ${c - 1}` : "end != 0", u = o ? "end + 1" : "end - 1") : (l = o ? `end + pow2 < ${c}` : "end >= pow2", u = o ? "end + pow2" : "end - pow2"), this.userCode = `
      void main() {
        ${V(r)} coords = getOutputCoords();
        int end = ${pr(r, "coords", this.op)};
        float val = ${a};
        int pow2 = int(pow(2.0, index));
        if (${l}) {
          int idx = ${u};
          ${pr(r, "coords", this.op)} = idx;
          val ${this.op}= getX(${fr(r, "coords", this.op)});
        }
        setOutput(val);
      }
    `;
  }
}
function fr(n, e, t) {
  if (n === 1)
    return `${e}`;
  if (n === 2)
    return `${e}.x, ${e}.y`;
  if (n === 3)
    return `${e}.x, ${e}.y, ${e}.z`;
  if (n === 4)
    return `${e}.x, ${e}.y, ${e}.z, ${e}.w`;
  throw new Error(`Cumulative ${t} for rank ${n} is not yet supported`);
}
function pr(n, e, t) {
  if (n === 1)
    return `${e}`;
  if (n === 2)
    return `${e}.y`;
  if (n === 3)
    return `${e}.z`;
  if (n === 4)
    return `${e}.w`;
  throw new Error(`Cumulative ${t} for rank ${n} is not yet supported`);
}
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function _a(n, e, t, s, o, r) {
  const i = e.shape.length, a = Ee([s], i);
  let c = e;
  a != null && (c = ae({ inputs: { x: e }, backend: t, attrs: { perm: a } }));
  const l = Ne(1, i)[0];
  if (l !== i - 1)
    throw new Error(`WebGL cumprod shader expects an inner-most axis=${e.shape.length - 1} but got axis=${s}`);
  const u = c.shape[l];
  let d = me({ inputs: { x: c }, backend: t });
  for (let h = 0; h <= Math.ceil(Math.log2(u)) - 1; h++) {
    const f = new hr(n, c.shape, !1, r), p = [[h]], x = d;
    d = t.runWebGLProgram(f, [d], d.dtype, p), t.disposeIntermediateTensorInfo(x);
  }
  if (o) {
    const h = new hr(n, c.shape, o, r), f = d;
    d = t.runWebGLProgram(h, [d], d.dtype), t.disposeIntermediateTensorInfo(f);
  }
  if (a != null) {
    const h = to(a), f = ae({ inputs: { x: d }, backend: t, attrs: { perm: h } });
    return t.disposeIntermediateTensorInfo(d), t.disposeIntermediateTensorInfo(c), f;
  }
  return d;
}
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function hb(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r, exclusive: i, reverse: a } = s;
  return _a(mn.Prod, o, t, r, i, a);
}
const fb = {
  kernelName: jc,
  backendName: "webgl",
  kernelFunc: hb
};
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function pb(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r, exclusive: i, reverse: a } = s;
  return _a(mn.Sum, o, t, r, i, a);
}
const mb = {
  kernelName: Kc,
  backendName: "webgl",
  kernelFunc: pb
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function gb(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, weights: r } = e, { size: i, binaryOutput: a } = s;
  if (o.shape.length === 1) {
    const c = t.readSync(o.dataId), l = t.readSync(r.dataId), u = ga(c, l, r.dtype, r.shape, i);
    return t.makeTensorInfo([i], r.dtype, u);
  } else if (o.shape.length === 2) {
    const c = t.bufferSync(o), l = t.bufferSync(r), u = wg(c, l, i, a);
    return t.makeTensorInfo(u.shape, r.dtype, u.values);
  }
  throw new Error(`Error in denseBincount: input must be at most rank 2, but got rank${o.shape.length}.`);
}
const xb = {
  kernelName: Qc,
  backendName: "webgl",
  kernelFunc: gb
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Cb {
  constructor(e, t, s) {
    this.variableNames = ["x"], this.outputShape = [], this.outputShape = e, this.blockSize = t, this.dataFormat = s, this.userCode = `
    void main() {
      ivec4 coords = getOutputCoords();
      int b = coords[0];
      int h = ${this.getHeightCoordString()};
      int w = ${this.getWidthCoordString()};
      int d = ${this.getDepthCoordString()};

      int in_h = h / ${t};
      int offset_h = imod(h, ${t});
      int in_w = w / ${t};
      int offset_w = imod(w, ${t});
      int offset_d = (offset_h * ${t} + offset_w) *
        ${this.getOutputDepthSize()};
      int in_d = d + offset_d;

      float result = ${this.getInputSamplingString()};
      setOutput(result);
    }
  `;
  }
  getHeightCoordString() {
    return this.dataFormat === "NHWC" ? "coords[1]" : "coords[2]";
  }
  getWidthCoordString() {
    return this.dataFormat === "NHWC" ? "coords[2]" : "coords[3]";
  }
  getDepthCoordString() {
    return this.dataFormat === "NHWC" ? "coords[3]" : "coords[1]";
  }
  getOutputDepthSize() {
    return this.dataFormat === "NHWC" ? this.outputShape[3] : this.outputShape[1];
  }
  getInputSamplingString() {
    return this.dataFormat === "NHWC" ? "getX(b, in_h, in_w, in_d)" : "getX(b, in_d, in_h, in_w)";
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function bb(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { blockSize: r, dataFormat: i } = s, a = o.shape[0], c = i === "NHWC" ? o.shape[1] : o.shape[2], l = i === "NHWC" ? o.shape[2] : o.shape[3], u = i === "NHWC" ? o.shape[3] : o.shape[1], d = c * r, h = l * r, f = u / (r * r), p = i === "NHWC" ? [a, d, h, f] : [a, f, d, h], x = new Cb(p, r, i);
  return t.runWebGLProgram(x, [o], o.dtype);
}
const wb = {
  kernelName: Zc,
  backendName: "webgl",
  kernelFunc: bb
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class La {
  constructor(e, t = !1, s = null, o = !1, r = !1) {
    this.variableNames = ["x", "W"], this.customUniforms = [
      { name: "pads", type: "ivec2" },
      { name: "strides", type: "ivec2" },
      { name: "dilations", type: "ivec2" },
      { name: "inDims", type: "ivec2" }
    ], this.outputShape = e.outShape, this.enableShapeUniforms = ne(this.outputShape.length);
    const i = e.filterHeight, a = e.filterWidth, c = e.outChannels / e.inChannels;
    let l = "", u = "";
    s && (o ? l = `float activation(float a) {
          float b = getPreluActivationWeightsAtOutCoords();
          ${s}
        }` : r ? l = `float activation(float a) {
          float b = getLeakyreluAlphaAtOutCoords();
          ${s}
        }` : l = `
          float activation(float x) {
            ${s}
          }
        `, u = "result = activation(result);");
    const d = t ? "result += getBiasAtOutCoords();" : "";
    t && this.variableNames.push("bias"), o && this.variableNames.push("preluActivationWeights"), r && this.variableNames.push("leakyreluAlpha"), this.userCode = `
      ${l}

      void main() {
        ivec4 coords = getOutputCoords();
        int batch = coords.x;
        ivec2 xRCCorner = coords.yz * strides - pads;
        int d2 = coords.w;
        int d1 = d2 / ${c};
        int q = d2 - d1 * ${c};

        int xRCorner = xRCCorner.x;
        int xCCorner = xRCCorner.y;

        // Convolve x(?, ?, d1) with w(:, :, d1, q) to get y(yR, yC, d2).
        // ? = to be determined. : = across all values in that axis.
        float dotProd = 0.0;
        // TO DO(dsmilkov): Flatten the two for loops and vec4 the operations.
        for (int wR = 0; wR < ${i}; wR++) {
          int xR = xRCorner + wR * dilations[0];

          if (xR < 0 || xR >= inDims[0]) {
            continue;
          }

          for (int wC = 0; wC < ${a}; wC++) {
            int xC = xCCorner + wC * dilations[1];

            if (xC < 0 || xC >= inDims[1]) {
              continue;
            }

            float xVal = getX(batch, xR, xC, d1);
            float wVal = getW(wR, wC, d1, q);
            dotProd += xVal * wVal;
          }
        }

        float result = dotProd;
        ${d}
        ${u}
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Ba {
  constructor(e, t = !1, s = null, o = !1, r = !1) {
    this.variableNames = ["x", "W"], this.packedInputs = !0, this.packedOutput = !0, this.customUniforms = [
      { name: "pads", type: "ivec2" },
      { name: "strides", type: "ivec2" },
      { name: "dilations", type: "ivec2" },
      { name: "inDims", type: "ivec2" }
    ], this.outputShape = e.outShape, this.enableShapeUniforms = ne(this.outputShape.length);
    const i = e.outChannels / e.inChannels, a = e.padInfo.left, c = e.strideWidth, l = e.dilationWidth, u = e.filterHeight, d = e.filterWidth, h = d;
    let f = `
      int xR; int xC; int xCOffset;
      vec4 wTexel; vec4 previous; vec4 final;`;
    for (let m = 0; m < d; m++)
      f += `
          vec4 xTexelC${m * 2};
          int xTexelC${m * 2}Ready;
          vec4 xTexelC${m * 2 + 1};
          int xTexelC${m * 2 + 1}Ready;
          vec4 xC${m};`;
    f += `
    for (int r = 0; r < ${u}; r++) {
      `;
    for (let m = 0; m < d; m++)
      f += `
          xTexelC${m * 2} = vec4(0.0);
          xTexelC${m * 2}Ready = 0;
          xTexelC${m * 2 + 1} = vec4(0.0);
          xTexelC${m * 2 + 1}Ready = 0;
          xC${m} = vec4(0.0);`;
    f += `
        xR = xRCorner + r * dilations[0];
        if (xR >=0 && xR < inDims[0]) {
      `;
    for (let m = 0; m < (h + 1) / 2; m++) {
      const C = m * 2;
      if (f += `
          xC = xCCorner + ${C * l};
          `, c === 1) {
        if (C < d && (a % 2 === 1 ? (f += `
                xCOffset = xC + 1;
                if (xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${C}Ready == 0) {
                  xTexelC${C} = getX(batch, xR, xCOffset, d1);

                  // Need to manually clear unused channels in case
                  // we're reading from recycled texture.
                  if (xCOffset + 1 >= inDims[1]) {
                    xTexelC${C}.zw = vec2(0.0);
                  }
                  xTexelC${C}Ready = 1;
                }
              `, l === 1 && C > 0 ? f += `
                xC${C} = vec4(xTexelC${C - 2}.zw, xTexelC${C}.xy);
                ` : f += `
                  xCOffset = xC + 1 - 2;

                  if (xCOffset >= 0 && xCOffset < inDims[1]) {
                    previous = getX(batch, xR, xCOffset, d1);

                    // Need to manually clear unused channels in case
                    // we're reading from recycled texture.
                    if (xCOffset + 1 >= inDims[1]) {
                      previous.zw = vec2(0.0);
                    }

                    xC${C} = vec4(previous.zw, xTexelC${C}.xy);
                  } else {
                    xC${C} = vec4(0.0, 0.0, xTexelC${C}.xy);
                  }
                  `) : f += `
                if (xC >= 0 && xC < inDims[1] && xTexelC${C}Ready == 0) {
                  xTexelC${C} = getX(batch, xR, xC, d1);
                  if (xC + 1 >= inDims[1]) {
                    xTexelC${C}.zw = vec2(0.0);
                  }
                  xTexelC${C}Ready = 1;
                }

                xC${C} = xTexelC${C};
                `, C + 1 < d)) {
          const b = a % 2 === 0 ? Gs(l) : l;
          l % 2 === 0 && a % 2 === 1 || l % 2 !== 0 && a % 2 !== 1 ? (f += `
                  xCOffset = xC + imod(pads[1], 2) + ${b};

                  if (xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${C + 1}Ready == 0) {
                    xTexelC${C + 1} = getX(batch, xR, xCOffset, d1);

                    // Need to manually clear unused channels in case
                    // we're reading from recycled texture.
                    if (xCOffset + 1 >= inDims[1]) {
                      xTexelC${C + 1}.zw = vec2(0.0);
                    }
                    xTexelC${C + 1}Ready = 1;
                  }
                  `, l > 1 ? f += `
                    xCOffset -= 2;
                    if (xCOffset >= 0 && xCOffset < inDims[1]) {
                     previous = getX(batch, xR, xCOffset, d1);
                     xC${C + 1} = vec4(previous.zw, xTexelC${C + 1}.xy);
                    } else {
                     xC${C + 1} = vec4(0.0, 0.0, xTexelC${C + 1}.xy);
                    }
                    ` : f += `
                    xC${C + 1} = vec4(xTexelC${C}.zw, xTexelC${C + 1}.xy);
                    `) : b === 1 ? f += `
                    xC${C + 1} = xTexelC${C};
                    ` : f += `
                    xCOffset = xC + ${b};

                    if (xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${C + 1}Ready == 0) {
                      xTexelC${C + 1} = getX(batch, xR, xCOffset, d1);
                      if (xCOffset + 1 >= inDims[1]) {
                        xTexelC${C + 1}.zw = vec2(0.0);
                      }
                      xTexelC${C + 1}Ready = 1;
                    }

                    xC${C + 1} = xTexelC${C + 1};
                    `;
        }
      } else
        C < d && (a % 2 === 1 ? (f += `
                xCOffset = xC + 1 - strides[1];
                if(xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${C}Ready == 0) {
                  xTexelC${C} = getX(batch, xR, xCOffset, d1);
                  // Need to manually clear unused channels in case
                  // we're reading from recycled texture.
                  if (xCOffset + 1 >= inDims[1]) {
                    xTexelC${C}.zw = vec2(0.0);
                  }
                  xTexelC${C}Ready = 1;
                }

                if(xC + 1 >= 0 && xC + 1 < inDims[1] && xTexelC${C + 1}Ready == 0) {
                  xTexelC${C + 1} = getX(batch, xR, xC + 1, d1);
                  // Need to manually clear unused channels in case
                  // we're reading from recycled texture.
                  if (xC + 2 >= inDims[1]) {
                    xTexelC${C + 1}.zw = vec2(0.0);
                  }
                  xTexelC${C + 1}Ready = 1;
                }

                xC${C} = vec4(xTexelC${C}.zw, xTexelC${C + 1}.zw);
              `, C + 1 < d && (f += `
                  final = vec4(0.0);
                  xCOffset = xC + 1 + strides[1];
                  if(xCOffset >= 0 && xCOffset < inDims[1]) {
                    final = getX(batch, xR, xCOffset, d1);
                  }
                  xC${C + 1} = vec4(xTexelC${C + 1}.xy, final.xy);
                `)) : (f += `
                if(xC >= 0 && xC < inDims[1] && xTexelC${C}Ready == 0) {
                  xTexelC${C} = getX(batch, xR, xC, d1);
                  if (xC + 1 >= inDims[1]) {
                    xTexelC${C}.zw = vec2(0.0);
                  }
                  xTexelC${C}Ready = 1;
                }

                xCOffset = xC + strides[1];
                if(xCOffset >= 0 && xCOffset < inDims[1] && xTexelC${C + 1}Ready == 0) {
                  xTexelC${C + 1} = getX(batch, xR, xCOffset, d1);
                  if (xCOffset + 1 >= inDims[1]) {
                    xTexelC${C + 1}.zw = vec2(0.);
                  }
                  xTexelC${C + 1}Ready = 1;
                }

                xC${C} = vec4(
                  xTexelC${C}.xy, xTexelC${C + 1}.xy);
              `, C + 1 < d && (f += `
                  xC${C + 1} = vec4(xTexelC${C}.zw, xTexelC${C + 1}.zw);
                `)));
      C < d && (f += `
            wTexel = getW(r, ${C}, d1, q);
            dotProd += xC${C} * vec4(wTexel.xz, wTexel.xz);
          `, C + 1 < d && (f += `
              wTexel = getW(r, ${C + 1}, d1, q);
              dotProd += xC${C + 1} * vec4(wTexel.xz, wTexel.xz);
            `));
    }
    f += `
    }
  `, f += `
      }
    `;
    let p = "", x = "";
    s && (o ? p = `vec4 activation(vec4 a) {
          vec4 b = getPreluActivationWeightsAtOutCoords();
          ${s}
        }` : r ? p = `vec4 activation(vec4 a) {
          vec4 b = getLeakyreluAlphaAtOutCoords();
          ${s}
        }` : p = `vec4 activation(vec4 x) {
          ${s}
        }`, x = "result = activation(result);");
    const g = t ? "result += getBiasAtOutCoords();" : "";
    t && this.variableNames.push("bias"), o && this.variableNames.push("preluActivationWeights"), r && this.variableNames.push("leakyreluAlpha"), this.userCode = `
      ${p}

      void main() {
        ivec4 coords = getOutputCoords();
        int batch = coords.x;
        ivec2 xRCCorner = coords.yz * strides - pads;
        int d2 = coords.w;
        int d1 = d2 / ${i};
        int q = d2 - d1 * ${i};
        int xRCorner = xRCCorner.x;
        int xCCorner = xRCCorner.y;

        //intialize dotProd with a small epsilon seems to reduce GPU accuracy loss.
        vec4 dotProd = vec4(0.000000000000001);

        ${f}

        vec4 result = dotProd - vec4(0.000000000000001);
        ${g}
        ${x}
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function yb(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, filter: r } = e, { strides: i, pad: a, dilations: c, dimRoundingMode: l } = s;
  let u = c;
  u == null && (u = [1, 1]), N(jt(i, u), () => `Error in depthwiseConv2d: Either strides or dilations must be 1. Got strides ${i} and dilations '${u}'`);
  const d = Be(
    o.shape,
    r.shape,
    i,
    u,
    a,
    l,
    !0
    /* depthwise */
  );
  let h;
  y().getBool("WEBGL_PACK_DEPTHWISECONV") && d.strideWidth <= 2 && d.outChannels / d.inChannels === 1 ? h = new Ba(d) : h = new La(d);
  const f = [
    [d.padInfo.top, d.padInfo.left],
    [d.strideHeight, d.strideWidth],
    [d.dilationHeight, d.dilationWidth],
    [d.inHeight, d.inWidth]
  ];
  return t.runWebGLProgram(h, [o, r], "float32", f);
}
const vb = {
  kernelName: Jc,
  backendName: "webgl",
  kernelFunc: yb
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class $b {
  constructor(e) {
    this.variableNames = ["x", "dy"], this.outputShape = e.filterShape;
    const t = e.strideHeight, s = e.strideWidth, o = e.padInfo.top, r = e.padInfo.left, i = e.outChannels / e.inChannels;
    this.userCode = `
      void main() {
        ivec4 coords = getOutputCoords();
        int wR = coords.x;
        int wC = coords.y;
        int d1 = coords.z;
        int dm = coords.w;
        int d2 = d1 * ${i} + dm;

        float dotProd = 0.0;

        // TO DO: Vec4 over the batch size
        for (int b = 0; b < ${e.batchSize}; b++) {
          for (int yR = 0; yR < ${e.outHeight}; yR++) {
            int xR = wR + yR * ${t} - ${o};

            if (xR < 0 || xR >= ${e.inHeight}) {
              continue;
            }

            for (int yC = 0; yC < ${e.outWidth}; yC++) {
              int xC = wC + yC * ${s} - ${r};

              if (xC < 0 || xC >= ${e.inWidth}) {
                continue;
              }

              float dyValue = getDy(b, yR, yC, d2);
              float xValue = getX(b, xR, xC, d1);
              dotProd += (xValue * dyValue);
            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
class Sb {
  constructor(e) {
    this.variableNames = ["dy", "W"], this.outputShape = e.inShape;
    const t = e.filterHeight, s = e.filterWidth, o = e.strideHeight, r = e.strideWidth, i = t - 1 - e.padInfo.top, a = s - 1 - e.padInfo.left, c = e.outChannels / e.inChannels;
    this.userCode = `
      const ivec2 pads = ivec2(${i}, ${a});

      void main() {
        ivec4 coords = getOutputCoords();
        int batch = coords[0];
        int d1 = coords[3];
        ivec2 dyCorner = coords.yz - pads;
        int dyRCorner = dyCorner.x;
        int dyCCorner = dyCorner.y;

        float dotProd = 0.0;

        for (int wR = 0; wR < ${t}; wR++) {
          float dyR = float(dyRCorner + wR) / ${o}.0;

          if (dyR < 0.0 || dyR >= ${e.outHeight}.0 || fract(dyR) > 0.0) {
            continue;
          }
          int idyR = int(dyR);

          int wRPerm = ${t} - 1 - wR;

          for (int wC = 0; wC < ${s}; wC++) {
            float dyC = float(dyCCorner + wC) / ${r}.0;

            if (dyC < 0.0 || dyC >= ${e.outWidth}.0 ||
                fract(dyC) > 0.0) {
              continue;
            }
            int idyC = int(dyC);

            int wCPerm = ${s} - 1 - wC;

            // TO DO: Vec4 over the channelMul
            for (int dm = 0; dm < ${c}; dm++) {
              int d2 = d1 * ${c} + dm;
              float xValue = getDy(batch, idyR, idyC, d2);
              float wValue = getW(wRPerm, wCPerm, d1, dm);
              dotProd += xValue * wValue;
            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ib(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, dy: r } = e, { strides: i, dilations: a, pad: c, dimRoundingMode: l, filterShape: u } = s, d = Be(
    o.shape,
    u,
    i,
    a,
    c,
    l,
    !0
    /* depthwise */
  ), h = new $b(d);
  return t.runWebGLProgram(h, [o, r], "float32");
}
const Rb = {
  kernelName: el,
  backendName: "webgl",
  kernelFunc: Ib
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Tb(n) {
  const { inputs: e, backend: t, attrs: s } = n, { dy: o, filter: r } = e, { strides: i, dilations: a, pad: c, dimRoundingMode: l, inputShape: u } = s, d = Be(
    u,
    r.shape,
    i,
    a,
    c,
    l,
    !0
    /* depthwise */
  ), h = new Sb(d);
  return t.runWebGLProgram(h, [o, r], "float32");
}
const Eb = {
  kernelName: tl,
  backendName: "webgl",
  kernelFunc: Tb
};
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Nb {
  constructor(e) {
    this.variableNames = ["X"], this.outputShape = [e, e], this.userCode = `
      void main() {
          ivec2 coords = getOutputCoords();
          float val = coords[0] == coords[1] ? getX(coords[0]) : 0.0;
          setOutput(val);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function kb(n) {
  const { inputs: e, backend: t } = n, { x: s } = e, o = [...s.shape, ...s.shape], r = T(s.shape), i = S({ inputs: { x: s }, backend: t, attrs: { shape: [r] } }), a = new Nb(r), c = t.runWebGLProgram(a, [i], i.dtype), l = S({ inputs: { x: c }, backend: t, attrs: { shape: o } });
  return t.disposeIntermediateTensorInfo(i), t.disposeIntermediateTensorInfo(c), l;
}
const Ab = {
  kernelName: nl,
  backendName: "webgl",
  kernelFunc: kb
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Fb {
  constructor(e) {
    this.variableNames = ["x", "W"], this.outputShape = e.outShape;
    const { inHeight: t, inWidth: s, padInfo: o, strideHeight: r, strideWidth: i, filterHeight: a, filterWidth: c, dilationHeight: l, dilationWidth: u } = e, { top: d, left: h } = o;
    this.userCode = `
      const ivec2 strides = ivec2(${r}, ${i});
      const ivec2 pads = ivec2(${d}, ${h});
      const float neg_infinity = -3.4e38;

      void main() {
        ivec4 coords = getOutputCoords();
        int batch = coords.x;
        int d1 = coords.w;
        ivec2 outTopLeftCorner =
            coords.yz * strides - pads;
        int hBeg = outTopLeftCorner.x;
        int wBeg = outTopLeftCorner.y;

        float curVal = neg_infinity;
        for (int h = 0; h < ${a}; h++) {
          int hIn = hBeg + h * ${l};

          if (hIn >= 0 && hIn < ${t}) {
            for (int w = 0; w < ${c}; w++) {
              int wIn = wBeg + w * ${u};

              if (wIn >= 0 && wIn < ${s}) {
                float xVal = getX(batch, hIn, wIn, d1);
                float wVal = getW(h, w, d1);

                float val = xVal + wVal;
                if (val > curVal) {
                  curVal = val;
                }
              }
            }
          }
        }

        float result = curVal;
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Db(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, filter: r } = e, { strides: i, pad: a, dilations: c } = s, l = mi(o.shape, r.shape, i, a, "NHWC", c);
  let u;
  const d = new Fb(l);
  u = t.runWebGLProgram(d, [o, r], "float32");
  const h = S({ inputs: { x: u }, backend: t, attrs: { shape: l.outShape } });
  return t.disposeIntermediateTensorInfo(u), h;
}
const Ob = {
  kernelName: sl,
  backendName: "webgl",
  kernelFunc: Db
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Pb(n) {
  const { inputs: e, backend: t, attrs: s } = n, { equation: o } = s, r = e, { allDims: i, summedDims: a, idDims: c } = Mi(o, r.length);
  Ui(i.length, c, r);
  const { path: l, steps: u } = Wi(a, c), d = u.length;
  let h = null, f = i.length;
  const p = [];
  for (let x = 0; x < d; ++x) {
    for (const g of u[x]) {
      const { permutationIndices: m, expandDims: C } = Vi(f, c[g]);
      let b;
      Gi(m) ? b = r[g] : (b = ae({ inputs: { x: r[g] }, backend: t, attrs: { perm: m } }), p.push(b));
      const w = b.shape.slice();
      for (let v = 0; v < C.length; ++v)
        w.splice(C[v], 0, 1);
      Z(b.shape, w) || (b = S({ inputs: { x: b }, backend: t, attrs: { shape: w } }), p.push(b)), h === null ? h = b : (h = mo({ inputs: { a: b, b: h }, backend: t }), p.push(h));
    }
    x < d - 1 && (l[x] >= 0 && (h = os({
      inputs: { x: h },
      backend: t,
      attrs: {
        axis: l[x] - (i.length - f),
        keepDims: !1
      }
    }), p.push(h)), f--);
  }
  for (const x of p)
    x !== h && t.disposeIntermediateTensorInfo(x);
  return h;
}
const _b = {
  kernelName: ol,
  backendName: "webgl",
  kernelFunc: Pb
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Lb = "return (x >= 0.0) ? x : (exp(x) - 1.0);", Bb = `
  vec4 result;

  result.r = (x.r >= 0.0) ? x.r : (exp(x.r) - 1.0);
  result.g = (x.g >= 0.0) ? x.g : (exp(x.g) - 1.0);
  result.b = (x.b >= 0.0) ? x.b : (exp(x.b) - 1.0);
  result.a = (x.a >= 0.0) ? x.a : (exp(x.a) - 1.0);

  return result;
`, Mb = _({ opSnippet: Lb, packedOpSnippet: Bb }), Vb = {
  kernelName: rl,
  backendName: "webgl",
  kernelFunc: Mb
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ub = "return (b >= 0.0) ? a : a * (b + 1.0);", Wb = `
  vec4 bGTEZero = vec4(greaterThanEqual(b, vec4(0.)));
  return (bGTEZero * a) + ((vec4(1.0) - bGTEZero) * (a * (b + vec4(1.0))));
`, Gb = (n) => {
  const { inputs: e, backend: t } = n, { dy: s, y: o } = e, r = y().getBool("WEBGL_PACK_BINARY_OPERATIONS") ? new tn(Wb, s.shape, o.shape) : new wt(Ub, s.shape, o.shape);
  return t.runWebGLProgram(r, [s, o], s.dtype);
}, zb = {
  kernelName: il,
  backendName: "webgl",
  kernelFunc: Gb
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Hb = `
  return vec4(equal(a, b));
`, Xb = "return float(a == b);", qb = ee({
  opSnippet: Xb,
  packedOpSnippet: Hb,
  dtype: "bool",
  cpuKernelImpl: Ig
}), jb = {
  kernelName: cl,
  backendName: "webgl",
  kernelFunc: qb
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Kb = `
  // Error function is calculated approximately with elementary function.
  // See "Handbook of Mathematical Functions with Formulas,
  // Graphs, and Mathematical Tables", Abramowitz and Stegun.
  float p = ${Di};
  float a1 = ${Oi};
  float a2 = ${Pi};
  float a3 = ${_i};
  float a4 = ${Li};
  float a5 = ${Bi};

  float sign = sign(x);
  x = abs(x);
  float t = 1.0 / (1.0 + p * x);
  return sign * (1.0 - (((((a5*t + a4)*t) + a3)*t + a2)*t + a1)*t*exp(-x*x));
`, Yb = _({ opSnippet: Kb }), Qb = {
  kernelName: al,
  backendName: "webgl",
  kernelFunc: Yb
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Zb = nn + `
  return exp(x);
`, Jb = `
  vec4 result = exp(x);
  bvec4 isNaN = isnan(x);
  result.r = isNaN.r ? x.r : result.r;
  result.g = isNaN.g ? x.g : result.g;
  result.b = isNaN.b ? x.b : result.b;
  result.a = isNaN.a ? x.a : result.a;

  return result;
`, Ma = _({
  opSnippet: Zb,
  packedOpSnippet: Jb,
  cpuKernelImpl: Rg,
  dtype: "float32"
}), ew = {
  kernelName: ll,
  backendName: "webgl",
  kernelFunc: Ma
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ws(n) {
  const { inputs: e, attrs: t, backend: s } = n, { dim: o } = t, { input: r } = e, i = r.shape.length, a = r.shape.slice();
  let c = o;
  return o < 0 && (N(-(i + 1) <= o, () => `Axis must be in the interval [${-(i + 1)}, ${i}]`), c = i + o + 1), a.splice(c, 0, 1), S({ inputs: { x: r }, backend: s, attrs: { shape: a } });
}
const tw = {
  kernelName: ul,
  backendName: "webgl",
  kernelFunc: Ws
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const mr = "return exp(x) - 1.0;", nw = _({ opSnippet: mr, packedOpSnippet: mr, cpuKernelImpl: Tg }), sw = {
  kernelName: dl,
  backendName: "webgl",
  kernelFunc: nw
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class gr {
  constructor(e, t, s) {
    this.variableNames = ["real", "imag"];
    const o = t[1];
    this.outputShape = t;
    const r = s ? `2.0 * ${Math.PI}` : `-2.0 * ${Math.PI}`, i = s ? `${o}.0` : "1.0";
    let a;
    if (e === "real")
      a = "return real * expR - imag * expI;";
    else if (e === "imag")
      a = "return real * expI + imag * expR;";
    else
      throw new Error(`FFT component must be either "real" or "imag", got ${e}.`);
    this.userCode = `
      const float exponentMultiplier = ${r};

      float unaryOpComplex(float real, float expR, float imag, float expI) {
        ${a}
      }

      float mulMatDFT(int batch, int index) {
        float indexRatio = float(index) / float(${o});
        float exponentMultiplierTimesIndexRatio =
            exponentMultiplier * indexRatio;

        float result = 0.0;

        for (int i = 0; i < ${o}; i++) {
          // x = (-2|2 * PI / N) * index * i;
          float x = exponentMultiplierTimesIndexRatio * float(i);
          float expR = cos(x);
          float expI = sin(x);
          float real = getReal(batch, i);
          float imag = getImag(batch, i);

          result +=
              unaryOpComplex(real, expR, imag, expI) / ${i};
        }

        return result;
      }

      void main() {
        ivec2 coords = getOutputCoords();
        setOutput(mulMatDFT(coords[0], coords[1]));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Va(n, e, t) {
  const s = t.texData.get(n.dataId), o = T(n.shape), r = n.shape[n.shape.length - 1], i = o / r, a = S({ inputs: { x: n }, backend: t, attrs: { shape: [i, r] } }), c = a.shape, l = new gr("real", c, e), u = new gr("imag", c, e), d = [
    {
      dataId: s.complexTensorInfos.real.dataId,
      dtype: s.complexTensorInfos.real.dtype,
      shape: c
    },
    {
      dataId: s.complexTensorInfos.imag.dataId,
      dtype: s.complexTensorInfos.imag.dtype,
      shape: c
    }
  ], h = t.runWebGLProgram(l, d, "float32"), f = t.runWebGLProgram(u, d, "float32"), p = ot({ inputs: { real: h, imag: f }, backend: t });
  t.disposeIntermediateTensorInfo(h), t.disposeIntermediateTensorInfo(f);
  const x = S({ inputs: { x: p }, backend: t, attrs: { shape: n.shape } });
  return t.disposeIntermediateTensorInfo(a), t.disposeIntermediateTensorInfo(p), x;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ow(n) {
  const { inputs: e, backend: t } = n, { input: s } = e;
  return Va(s, !1, t);
}
const rw = {
  kernelName: hl,
  backendName: "webgl",
  kernelFunc: ow
};
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class iw {
  constructor(e, t) {
    this.outputShape = [], this.customUniforms = [{ name: "value", type: "float" }], this.variableNames = ["x"], this.outputShape = e, this.userCode = `
      void main() {
        // Input can be obtained from uniform value.
        setOutput(value);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Sn(n) {
  const { backend: e, attrs: t } = n, { shape: s, value: o } = t;
  let { dtype: r } = t;
  if (r = r || gn(o), r === "string") {
    const i = q(r, T(s));
    return i.fill(o), e.makeTensorInfo(s, r, i);
  } else {
    const i = new iw(s, o), a = [[o]];
    return e.runWebGLProgram(i, [], r, a);
  }
}
const aw = {
  kernelName: Fr,
  backendName: "webgl",
  kernelFunc: Sn
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class cw {
  constructor(e) {
    this.variableNames = ["Image"], this.outputShape = [];
    const t = e[2];
    this.outputShape = e, this.userCode = `
        void main() {
          ivec4 coords = getOutputCoords();
          int x = coords[2];

          int coordX = ${t} - x - 1;
          float outputValue;
          if(coordX >= 0 && coordX < ${t}) {
            outputValue = getImage(coords[0], coords[1], coordX, coords[3]);
          } else {
            outputValue = getImage(coords[0], coords[1], coords[2], coords[3]);
          }
          setOutput(outputValue);
        }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const lw = {
  kernelName: fl,
  backendName: "webgl",
  kernelFunc: ({ inputs: n, backend: e }) => {
    const { image: t } = n, s = e, o = new cw(t.shape);
    return s.runWebGLProgram(o, [t], t.dtype);
  }
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const xr = "return floor(x);", uw = _({ opSnippet: xr, packedOpSnippet: xr, cpuKernelImpl: Eg }), dw = {
  kernelName: pl,
  backendName: "webgl",
  kernelFunc: uw
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const hw = `
  float s = sign(a) * sign(b);
  int ia = round(a);
  int ib = round(b);
  if (ib != 0) {
    // Windows (D3D) wants guaranteed non-zero int division at compile-time.
    return float(idiv(ia, ib, s));
  } else {
    return NAN;
  }
`, fw = `
  ivec4 ia = round(a);
  ivec4 ib = round(b);
  bvec4 cond = notEqual(ib, ivec4(0));
  ivec4 result = ivec4(0);
  vec4 s = sign(a) * sign(b);

  // Windows (D3D) wants guaranteed non-zero int division at compile-time.
  if (cond[0]) {
    result[0] = idiv(ia[0], ib[0], s[0]);
  }
  if (cond[1]) {
    result[1] = idiv(ia[1], ib[1], s[1]);
  }
  if (cond[2]) {
    result[2] = idiv(ia[2], ib[2], s[2]);
  }
  if (cond[3]) {
    result[3] = idiv(ia[3], ib[3], s[3]);
  }
  return vec4(result);
`, pw = ee({ opSnippet: hw, packedOpSnippet: fw, dtype: "int32" }), mw = {
  kernelName: Dr,
  backendName: "webgl",
  kernelFunc: pw
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class gw {
  constructor(e) {
    this.variableNames = ["A"];
    const t = le(), [s, o] = e;
    this.outputShape = e, this.userCode = `
      void main() {
        ivec3 coords = getOutputCoords();
        int texR = coords[0];
        int texC = coords[1];
        int depth = coords[2];
        vec2 uv = (vec2(texC, texR) + halfCR) / vec2(${o}.0, ${s}.0);

        vec4 values = ${t.texture2D}(A, uv);
        float value;
        if (depth == 0) {
          value = values.r;
        } else if (depth == 1) {
          value = values.g;
        } else if (depth == 2) {
          value = values.b;
        } else if (depth == 3) {
          value = values.a;
        }

        setOutput(floor(value * 255.0 + 0.5));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class xw {
  constructor(e) {
    this.variableNames = ["A"], this.packedInputs = !1, this.packedOutput = !0;
    const t = le(), [s, o] = e;
    this.outputShape = e, this.userCode = `
      void main() {
        ivec3 coords = getOutputCoords();
        int texR = coords[0];
        int texC = coords[1];
        int depth = coords[2];

        vec4 result = vec4(0.);

        for(int row=0; row<=1; row++) {
          for(int col=0; col<=1; col++) {
            texC = coords[1] + row;
            depth = coords[2] + col;

            vec2 uv = (vec2(texC, texR) + halfCR) /
                       vec2(${o}.0, ${s}.0);
            vec4 values = ${t.texture2D}(A, uv);
            float value;
            if (depth == 0) {
              value = values.r;
            } else if (depth == 1) {
              value = values.g;
            } else if (depth == 2) {
              value = values.b;
            } else if (depth == 3) {
              value = values.a;
            }

            result[row * 2 + col] = floor(value * 255.0 + 0.5);
          }
        }

        ${t.output} = result;
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Cw = {
  kernelName: nd,
  backendName: "webgl",
  kernelFunc: bw
};
let Ft, Cs = y().getBool("CANVAS2D_WILL_READ_FREQUENTLY_FOR_GPU");
function bw(n) {
  const { inputs: e, backend: t, attrs: s } = n;
  let { pixels: o } = e;
  const { numChannels: r } = s, i = typeof HTMLVideoElement < "u" && o instanceof HTMLVideoElement, a = typeof HTMLImageElement < "u" && o instanceof HTMLImageElement, [c, l] = i ? [
    o.videoWidth,
    o.videoHeight
  ] : [o.width, o.height], u = [l, c], d = [l, c, r];
  if (a || i) {
    const x = y().getBool("CANVAS2D_WILL_READ_FREQUENTLY_FOR_GPU");
    (Ft == null || x !== Cs) && (Cs = x, Ft = document.createElement("canvas").getContext("2d", { willReadFrequently: Cs })), Ft.canvas.width = c, Ft.canvas.height = l, Ft.drawImage(o, 0, 0, c, l), o = Ft.canvas;
  }
  const h = t.makeTensorInfo(u, "int32");
  t.texData.get(h.dataId).usage = xe.PIXELS, t.gpgpu.uploadPixelDataToTexture(t.getTexture(h.dataId), o);
  const f = y().getBool("WEBGL_PACK") ? new xw(d) : new gw(d), p = t.runWebGLProgram(f, [h], "int32");
  return t.disposeData(h.dataId), p;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function ww(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, filter: r, bias: i, preluActivationWeights: a } = e, { strides: c, pad: l, dataFormat: u, dilations: d, dimRoundingMode: h, activation: f, leakyreluAlpha: p } = s, x = Kt(u), g = Be(o.shape, r.shape, c, d, l, h, !1, x);
  let m;
  const C = [], b = i != null, w = a != null, v = f === "leakyrelu", E = () => {
    const $ = [o, r], F = (O, L) => {
      if (L === "NCHW" && O.shape.length === 1 && O.shape[0] !== 1) {
        const B = S({
          inputs: { x: O },
          backend: t,
          attrs: { shape: [O.shape[0], 1, 1] }
        });
        return C.push(B), B;
      }
      return O;
    };
    if (b && $.push(F(i, u)), w && $.push(F(a, u)), v) {
      const O = t.makeTensorInfo([], "float32", Xt(p, "float32"));
      $.push(O), C.push(O);
    }
    return $;
  };
  if (g.filterHeight === 1 && g.filterWidth === 1 && g.dilationHeight === 1 && g.dilationWidth === 1 && g.strideHeight === 1 && g.strideWidth === 1 && (g.padInfo.type === "SAME" || g.padInfo.type === "VALID"))
    m = Oa({
      x: o,
      filter: r,
      convInfo: g,
      backend: t,
      bias: i,
      activation: f,
      preluActivationWeights: a,
      leakyreluAlpha: p
    });
  else if (g.strideWidth <= 2 && x === "channelsLast" && y().getBool("WEBGL_EXP_CONV")) {
    const $ = f ? fn(f, !0) : null, F = new Da(g, b, $, w, v), O = [
      [g.padInfo.top, g.padInfo.left],
      [g.strideHeight, g.strideWidth],
      [g.dilationHeight, g.dilationWidth],
      [g.inHeight, g.inWidth]
    ], L = E();
    m = t.runWebGLProgram(F, L, "float32", O);
  } else if (y().getBool("WEBGL_CONV_IM2COL"))
    m = Pa({
      x: o,
      filter: r,
      convInfo: g,
      backend: t,
      bias: i,
      activation: f,
      preluActivationWeights: a,
      leakyreluAlpha: p
    });
  else {
    const $ = f ? fn(f, !1) : null, F = new Fa(g, b, $, w, v), O = E();
    m = t.runWebGLProgram(F, O, "float32");
  }
  const R = S({ inputs: { x: m }, backend: t, attrs: { shape: g.outShape } });
  return C.push(m), C.forEach(($) => t.disposeIntermediateTensorInfo($)), R;
}
const yw = {
  kernelName: rd,
  backendName: "webgl",
  kernelFunc: ww
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function vw(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, filter: r, bias: i, preluActivationWeights: a } = e, { strides: c, pad: l, dilations: u, dimRoundingMode: d, activation: h, leakyreluAlpha: f } = s, p = [];
  let x = u;
  x == null && (x = [1, 1]), N(jt(c, x), () => `Error in depthwiseConv2d: Either strides or dilations must be 1. Got strides ${c} and dilations '${x}'`);
  const g = Be(
    o.shape,
    r.shape,
    c,
    x,
    l,
    d,
    !0
    /* depthwise */
  ), m = y().getBool("WEBGL_PACK_DEPTHWISECONV") && g.strideWidth <= 2 && g.outChannels / g.inChannels === 1, C = h ? fn(h, m) : null, b = [o, r], w = i != null, v = a != null, E = h === "leakyrelu";
  if (w && b.push(i), v && b.push(a), E) {
    const O = t.makeTensorInfo([], "float32", Xt(f, "float32"));
    b.push(O), p.push(O);
  }
  let R;
  m ? R = new Ba(g, w, C, v, E) : R = new La(g, w, C, v, E);
  const $ = [
    [g.padInfo.top, g.padInfo.left],
    [g.strideHeight, g.strideWidth],
    [g.dilationHeight, g.dilationWidth],
    [g.inHeight, g.inWidth]
  ], F = t.runWebGLProgram(R, b, "float32", $);
  return p.forEach((O) => t.disposeIntermediateTensorInfo(O)), F;
}
const $w = {
  kernelName: id,
  backendName: "webgl",
  kernelFunc: vw
};
class Sw {
  constructor(e, t, s, o) {
    this.sliceDim = e, this.strides = t, this.paramsShape = o, this.variableNames = ["x", "indices"], this.outputShape = s;
    const r = V(s.length);
    let i = `
    int index;`;
    for (let a = 0; a < this.sliceDim; a++)
      i += `
          index = round(getIndices(coords[0], ${a}));
          out_of_bounds = out_of_bounds || index < 0;
          out_of_bounds = out_of_bounds || index >= ${this.paramsShape[a]};
          flattenIndex += index * ${this.strides[a]};`;
    this.userCode = `
         void main() {
          ${r} coords = getOutputCoords();
          int flattenIndex = 0;
          bool out_of_bounds = false;

          ${i}

          setOutput(out_of_bounds ? 0.0 : getX(flattenIndex, coords[1]));
        }
      `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Iw(n) {
  const { inputs: e, backend: t } = n, { params: s, indices: o } = e, r = o.shape, i = r[r.length - 1], a = T(s.shape), [c, l, u, d] = wi(s, o), h = S({ inputs: { x: o }, backend: t, attrs: { shape: [l, i] } }), f = S({
    inputs: { x: s },
    backend: t,
    attrs: { shape: [T(s.shape) / u, u] }
  });
  if (t.shouldExecuteOnCPU([s, o]) || s.dtype === "string") {
    const m = t.readSync(o.dataId), C = t.bufferSync(s), b = Ng(m, C, s.dtype, l, i, u, d, s.shape, a);
    return t.makeTensorInfo(c, s.dtype, b.values);
  }
  const p = new Sw(i, d, [l, u], s.shape), x = t.runWebGLProgram(p, [f, h], f.dtype), g = S({ inputs: { x }, backend: t, attrs: { shape: c } });
  return t.disposeIntermediateTensorInfo(h), t.disposeIntermediateTensorInfo(f), t.disposeIntermediateTensorInfo(x), g;
}
const Rw = {
  kernelName: xl,
  backendName: "webgl",
  kernelFunc: Iw
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Tw {
  constructor(e, t) {
    this.variableNames = ["A", "indices"], this.outputShape = t, this.rank = t.length;
    const s = V(this.rank), o = Ew(e);
    this.userCode = `
      void main() {
        ${s} resRC = getOutputCoords();
        int index = int(getIndices(resRC.x, resRC.z));
        float inBounds = (index >= 0) && (index < ${e[2]}) ? 1.0 : 0.0;
        setOutput(inBounds * getA(${o}));
      }
    `;
  }
}
function Ew(n, e) {
  const t = ["resRC.x", "resRC.y", "resRC.z", "resRC.w"], s = [];
  for (let o = 0; o < n.length; o++)
    o === 2 ? s.push("index") : s.push(`${t[o]}`);
  return s.join();
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ua(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, indices: r } = e, { axis: i, batchDims: a } = s, c = de(i, o.shape)[0];
  if (y().get("DEBUG")) {
    const C = t.readSync(r.dataId), b = o.shape[c];
    for (let w = 0; w < C.length; ++w) {
      const v = C[w];
      N(v <= b - 1 && v >= 0, () => `GatherV2: the index value ${v} is not in [0, ${b - 1}]`);
    }
  }
  const l = Sf(o, r, c, a), u = T(r.shape), d = [], h = S({
    inputs: { x: o },
    backend: t,
    attrs: {
      shape: [
        l.batchSize,
        l.outerSize,
        l.dimSize,
        l.sliceSize
      ]
    }
  }), f = S({
    inputs: { x: r },
    backend: t,
    attrs: { shape: [l.batchSize, u / l.batchSize] }
  });
  d.push(h), d.push(f);
  const p = [
    l.batchSize,
    l.outerSize,
    u / l.batchSize,
    l.sliceSize
  ];
  if (t.shouldExecuteOnCPU([o, r]) || o.dtype === "string") {
    const C = t.bufferSync(f), b = t.bufferSync(h), w = kg(b, C, p);
    return d.forEach((v) => t.disposeIntermediateTensorInfo(v)), t.makeTensorInfo(l.outputShape, w.dtype, w.values);
  }
  const x = new Tw(h.shape, p), g = t.runWebGLProgram(x, [h, f], h.dtype);
  d.push(g);
  const m = S({ inputs: { x: g }, backend: t, attrs: { shape: l.outputShape } });
  return d.forEach((C) => t.disposeIntermediateTensorInfo(C)), m;
}
const Nw = {
  kernelName: gl,
  backendName: "webgl",
  kernelFunc: Ua
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const kw = "return float(a > b);", Aw = `
  return vec4(greaterThan(a, b));
`, Fw = ee({
  opSnippet: kw,
  packedOpSnippet: Aw,
  cpuKernelImpl: Ag,
  dtype: "bool"
}), Dw = {
  kernelName: Cl,
  backendName: "webgl",
  kernelFunc: Fw
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ow = "return float(a >= b);", Pw = `
  return vec4(greaterThanEqual(a, b));
`, _w = ee({
  opSnippet: Ow,
  packedOpSnippet: Pw,
  dtype: "bool",
  cpuKernelImpl: Fg
}), Lw = {
  kernelName: bl,
  backendName: "webgl",
  kernelFunc: _w
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Bw(n) {
  const { inputs: e, backend: t } = n, { input: s } = e;
  return Va(s, !0, t);
}
const Mw = {
  kernelName: wl,
  backendName: "webgl",
  kernelFunc: Bw
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Vw = "return float(!isnan(x) && !isinf(x));", Uw = _({ opSnippet: Vw, dtype: "bool" }), Ww = {
  kernelName: vl,
  backendName: "webgl",
  kernelFunc: Uw
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Gw = "return float(isinf(x));", zw = _({ opSnippet: Gw, dtype: "bool" }), Hw = {
  kernelName: $l,
  backendName: "webgl",
  kernelFunc: zw
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Xw = "return float(isnan(x));", qw = _({ opSnippet: Xw, dtype: "bool" }), jw = {
  kernelName: Sl,
  backendName: "webgl",
  kernelFunc: qw
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Kw = "return float(a < b);", Yw = `
  return vec4(lessThan(a, b));
`, Qw = ee({
  opSnippet: Kw,
  packedOpSnippet: Yw,
  cpuKernelImpl: Dg,
  dtype: "bool"
}), Zw = {
  kernelName: Rl,
  backendName: "webgl",
  kernelFunc: Qw
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Jw = "return float(a <= b);", e1 = `
  return vec4(lessThanEqual(a, b));
`, t1 = ee({
  opSnippet: Jw,
  packedOpSnippet: e1,
  cpuKernelImpl: Og,
  dtype: "bool"
}), n1 = {
  kernelName: Tl,
  backendName: "webgl",
  kernelFunc: t1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function s1(n) {
  const { backend: e, attrs: t } = n, { start: s, stop: o, num: r } = t, i = Pg(s, o, r);
  return e.makeTensorInfo([i.length], "float32", i);
}
const o1 = {
  kernelName: El,
  backendName: "webgl",
  kernelFunc: s1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const r1 = nn + `
  return x < 0.0 ? 0./0. : log(x);
`, i1 = `
  vec4 result = log(x);
  bvec4 isNaN = isnan(x);
  result.r = isNaN.r ? x.r : (x.r < 0.0 ? 0./0. : result.r);
  result.g = isNaN.g ? x.g : (x.g < 0.0 ? 0./0. : result.g);
  result.b = isNaN.b ? x.b : (x.b < 0.0 ? 0./0. : result.b);
  result.a = isNaN.a ? x.a : (x.a < 0.0 ? 0./0. : result.a);
  return result;
`, a1 = _({ opSnippet: r1, packedOpSnippet: i1, cpuKernelImpl: _g }), c1 = {
  kernelName: Nl,
  backendName: "webgl",
  kernelFunc: a1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const l1 = nn + `
  return log(1.0 + x);
`, u1 = _({ opSnippet: l1 }), d1 = {
  kernelName: kl,
  backendName: "webgl",
  kernelFunc: u1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const h1 = "return float(a >= 1.0 && b >= 1.0);", f1 = `
  return vec4(
    vec4(greaterThanEqual(a, vec4(1.0))) *
    vec4(greaterThanEqual(b, vec4(1.0))));
`, p1 = ee({
  opSnippet: h1,
  packedOpSnippet: f1,
  dtype: "bool"
}), m1 = {
  kernelName: Al,
  backendName: "webgl",
  kernelFunc: p1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const g1 = "return float(!(x >= 1.0));", x1 = _({ opSnippet: g1 }), C1 = {
  kernelName: Fl,
  backendName: "webgl",
  kernelFunc: x1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const b1 = "return float(a >= 1.0 || b >= 1.0);", w1 = `
  return min(
    vec4(greaterThanEqual(a, vec4(1.0))) +
    vec4(greaterThanEqual(b, vec4(1.0))),
    vec4(1.0));
`, y1 = ee({ opSnippet: b1, packedOpSnippet: w1, dtype: "bool" }), v1 = {
  kernelName: Dl,
  backendName: "webgl",
  kernelFunc: y1
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class $1 {
  constructor(e, t, s, o, r) {
    this.variableNames = ["x"], this.outputShape = [];
    const i = t, a = e[3] - 1;
    this.outputShape = e;
    let c;
    const l = `float(${s}) + float(${o}) * sum`;
    r === 0.5 ? c = `inversesqrt(${l})` : r === 1 ? c = `1.0/(${l})` : c = `exp(log(${l}) * float(-${r}));`, this.userCode = `
      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int r = coords[1];
        int c = coords[2];
        int d = coords[3];
        float x = getX(b, r, c, d);
        float sum = 0.0;
        for (int j = -${i}; j <= ${i}; j++) {
          int idx = d + j;
          if (idx >= 0 && idx <=  ${a}) {
            float z = getX(b, r, c, idx);
            sum += z * z;
          }
        }
        float val = x * ${c};
        setOutput(val);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class S1 {
  constructor(e, t, s, o, r) {
    this.variableNames = ["x"], this.outputShape = [], this.packedInputs = !0, this.packedOutput = !0;
    const i = t, a = e[3] - 1;
    this.outputShape = e;
    let c;
    const l = `float(${s}) + float(${o}) * sum`;
    r === 0.5 ? c = `inversesqrt(${l})` : r === 1 ? c = `1.0/(${l})` : c = `exp(log(${l}) * float(-${r}));`, this.userCode = `
      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords.x;
        int r = coords.y;
        int c = coords.z;
        int d = coords.w;

        bool hasNextCol = d < ${this.outputShape[3]};
        bool hasNextRow = c < ${this.outputShape[2]};

        vec4 sum = vec4(0.);
        vec4 xFragAtOutputCoords = getX(b, r, c, d);

        vec4 xAtOutputCoords = vec4(
          getChannel(xFragAtOutputCoords, vec2(c, d)),
          hasNextCol ?
            getChannel(xFragAtOutputCoords, vec2(c, d + 1)) : 0.0,
          hasNextRow ?
            getChannel(xFragAtOutputCoords , vec2(c + 1, d)) : 0.0,
          (hasNextRow && hasNextCol) ?
            getChannel(xFragAtOutputCoords, vec2(c + 1, d + 1)) : 0.0
        );

        int firstChannel = d - ${i};
        vec2 cache = vec2(0.);
        if(firstChannel >= 0){
          vec4 firstChannelFrag = getX(b, r, c, firstChannel);
          cache.x = getChannel(firstChannelFrag, vec2(c, firstChannel));
            if(hasNextRow){
              cache.y = getChannel(firstChannelFrag, vec2(c + 1, firstChannel));
            }
        }

        ivec2 depth = ivec2(d, d + 1);
        for (int j = - ${i}; j <= ${i}; j++) {
          ivec2 idx = depth + j;
          bvec2 aboveLowerBound = greaterThanEqual(idx, ivec2(0));
          bvec2 belowUpperBound = lessThanEqual(idx, ivec2(${a}));

          bool depthInRange = aboveLowerBound.x && belowUpperBound.x;
          bool depthPlusOneInRange = aboveLowerBound.y && belowUpperBound.y;

          if(depthInRange || depthPlusOneInRange){
            vec4 z = vec4(0.);
            vec4 xFragAtCurrentDepth;
            z.xz = cache.xy;
            if(depthPlusOneInRange && hasNextCol){
              xFragAtCurrentDepth = idx.y != d ?
                getX(b, r, c, idx.y) : xFragAtOutputCoords;
              z.y = getChannel(xFragAtCurrentDepth, vec2(c, idx.y));
              if(hasNextRow){
                z.w = getChannel(xFragAtCurrentDepth, vec2(c + 1, idx.y));
              }
            }
            cache.xy = z.yw;
            sum += z * z;
          }
        }
        vec4 result = xAtOutputCoords * ${c};
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const I1 = (n) => {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { depthRadius: r, bias: i, alpha: a, beta: c } = s, l = y().getBool("WEBGL_PACK_NORMALIZATION") ? new S1(o.shape, r, i, a, c) : new $1(o.shape, r, i, a, c);
  return t.runWebGLProgram(l, [o], o.dtype);
}, R1 = {
  kernelName: Ol,
  backendName: "webgl",
  kernelFunc: I1
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class T1 {
  constructor(e, t, s, o, r) {
    this.variableNames = ["inputImage", "outputImage", "dy"], this.outputShape = [], this.outputShape = e, this.depth = e[3], this.depthRadius = t, this.bias = s, this.alpha = o, this.beta = r, this.userCode = `
      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int r = coords[1];
        int c = coords[2];

        float result = 0.0;
        for (int d = 0; d < ${this.depth}; ++d) {
          int depthBegin = int(max(0.0, float(d - ${t})));
          int depthEnd = int(min(float(${this.depth}),
              float(d + ${t} + 1)));

          const int MIN_DEPTH_BEGIN = 0;
          const int MAX_DEPTH_END = ${this.depth};

          float norm = 0.0;
          for (int k = MIN_DEPTH_BEGIN; k < MAX_DEPTH_END; ++k) {
            if (k < depthBegin){
              continue;
            }
            else if (k >= depthBegin && k < depthEnd) {
              norm += getInputImage(b, r, c, k) * getInputImage(b, r, c, k);
            }
            else {
              break;
            }
          }

          norm = float(${o}) * norm + float(${s});

          for(int k = MIN_DEPTH_BEGIN; k < MAX_DEPTH_END; ++k){
            if (k < depthBegin){
              continue;
            }
            else if (k >= depthBegin && k < depthEnd){
              float dyi = -2.0 * float(${o})
                * float(${r})
                * getInputImage(b, r, c, k) * getOutputImage(b, r, c, d)
                / norm;
              if (k == d) {
                dyi += pow(norm, -1.0 * ${r});
              }
              if (k == coords[3]) {
                dyi *= getDy(b, r, c, d);
                result += dyi;
              }
            }
            else {
              break;
            }
          }
      }
      setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const E1 = (n) => {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, y: r, dy: i } = e, { depthRadius: a, bias: c, alpha: l, beta: u } = s, d = new T1(o.shape, a, c, l, u);
  return t.runWebGLProgram(d, [o, r, i], o.dtype);
}, N1 = {
  kernelName: Pl,
  backendName: "webgl",
  kernelFunc: E1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function k1(n, e, t, s) {
  const o = T(e), i = T(n.shape) / o, a = S({ inputs: { x: n }, attrs: { shape: [i, o] }, backend: s }), c = Nt(a, n.dtype, "max", s), l = S({ inputs: { x: c }, attrs: { shape: t }, backend: s });
  return s.disposeIntermediateTensorInfo(a), s.disposeIntermediateTensorInfo(c), l;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Wa(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { reductionIndices: r, keepDims: i } = s, a = o.shape.length, c = de(r, o.shape);
  let l = c;
  const u = Ee(l, a), d = u != null, h = t.shouldExecuteOnCPU([o]);
  let f = o;
  if (d) {
    if (h) {
      const b = t.texData.get(f.dataId).values, w = new Array(a);
      for (let R = 0; R < w.length; R++)
        w[R] = o.shape[u[R]];
      const v = fo(b, o.shape, o.dtype, u, w);
      f = t.makeTensorInfo(w, o.dtype);
      const E = t.texData.get(f.dataId);
      E.values = v;
    } else
      f = ss(o, u, t);
    l = Ne(l.length, a);
  }
  Me("max", l, a);
  const [p, x] = He(f.shape, l);
  let g = p;
  i && (g = qe(p, c));
  let m;
  if (h) {
    const b = t.texData.get(f.dataId).values, w = Lg(b, T(x), g, o.dtype);
    m = t.makeTensorInfo(g, o.dtype);
    const v = t.texData.get(m.dataId);
    v.values = w;
  } else
    m = k1(f, x, g, t);
  return d && t.disposeIntermediateTensorInfo(f), m;
}
const A1 = {
  kernelName: _l,
  backendName: "webgl",
  kernelFunc: Wa
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const F1 = po + `
  return max(a, b);
`, D1 = `
  vec4 result = vec4(max(a, b));
  bvec4 isNaNA = isnan(a);
  bvec4 isNaNB = isnan(b);
  bvec4 isNaN = bvec4(isNaNA.x || isNaNB.x, isNaNA.y || isNaNB.y, isNaNA.z || isNaNB.z, isNaNA.w || isNaNB.w);
  ` + Et + `
  return result;
`, O1 = ee({
  opSnippet: F1,
  packedOpSnippet: D1,
  cpuKernelImpl: Bg
}), P1 = {
  kernelName: Or,
  backendName: "webgl",
  kernelFunc: O1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function _1(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e;
  yn(o, "maxPool");
  const { filterSize: r, strides: i, pad: a, dimRoundingMode: c } = s, l = 1;
  N(jt(i, l), () => `Error in maxPool: Either strides or dilations must be 1. Got strides ${i} and dilations '${l}'`);
  const u = qt(o.shape, r, i, l, a, c);
  if (u.filterWidth === 1 && u.filterHeight === 1 && Z(u.inShape, u.outShape))
    return me({ inputs: { x: o }, backend: t });
  const d = new pn(u, "max", !1);
  return t.runWebGLProgram(d, [o], o.dtype);
}
const L1 = {
  kernelName: Ll,
  backendName: "webgl",
  kernelFunc: _1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function B1(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { filterSize: r, strides: i, pad: a, dataFormat: c, dimRoundingMode: l } = s, u = [1, 1, 1], d = Cn(o.shape, r, i, u, a, l, c), h = new go(d, "max", !1);
  return t.runWebGLProgram(h, [o], o.dtype);
}
const M1 = {
  kernelName: Ml,
  backendName: "webgl",
  kernelFunc: B1
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class V1 {
  constructor(e) {
    this.variableNames = ["dy", "maxPos"], this.outputShape = e.inShape;
    const t = e.strideHeight, s = e.strideWidth, o = e.dilationHeight, r = e.effectiveFilterHeight, i = e.effectiveFilterWidth, a = r - 1 - e.padInfo.top, c = i - 1 - e.padInfo.left, l = r * i - 1;
    this.userCode = `
      const ivec2 pads = ivec2(${a}, ${c});

      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int d = coords[3];

        ivec2 dyRCCorner = coords.yz - pads;
        int dyRCorner = dyRCCorner.x;
        int dyCCorner = dyRCCorner.y;

        // Convolve dy(?, ?, d) with pos mask(:, :, d) to get dx(xR, xC, d).
        // ? = to be determined. : = across all values in that axis.
        float dotProd = 0.0;
        for (int wR = 0; wR < ${r};
          wR += ${o}) {
          float dyR = float(dyRCorner + wR) / ${t}.0;

          if (dyR < 0.0 || dyR >= ${e.outHeight}.0 || fract(dyR) > 0.0) {
            continue;
          }
          int idyR = int(dyR);

          for (int wC = 0; wC < ${i}; wC++) {
            float dyC = float(dyCCorner + wC) / ${s}.0;

            if (dyC < 0.0 || dyC >= ${e.outWidth}.0 ||
                fract(dyC) > 0.0) {
              continue;
            }
            int idyC = int(dyC);

            float dyValue = getDy(b, idyR, idyC, d);
            int maxPosValue = ${l} - int(getMaxPos(b, idyR, idyC, d));

            // Get the current value, check it against the value from the
            // position matrix.
            int curPosValue = wR * ${i} + wC;
            float mask = float(maxPosValue == curPosValue ? 1.0 : 0.0);

            dotProd += dyValue * mask;
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
class U1 {
  constructor(e) {
    this.variableNames = ["dy", "maxPos"], this.outputShape = e.inShape;
    const t = e.strideDepth, s = e.strideHeight, o = e.strideWidth, r = e.dilationDepth, i = e.dilationHeight, a = e.dilationWidth, c = e.effectiveFilterDepth, l = e.effectiveFilterHeight, u = e.effectiveFilterWidth, d = c - 1 - e.padInfo.front, h = l - 1 - e.padInfo.top, f = u - 1 - e.padInfo.left, p = c * l * u - 1;
    this.userCode = `
      const ivec3 pads = ivec3(${d}, ${h}, ${f});

      void main() {
        ivec5 coords = getOutputCoords();
        int batch = coords.x;
        int ch = coords.u;

        ivec3 dyCorner = ivec3(coords.y, coords.z, coords.w) - pads;
        int dyDCorner = dyCorner.x;
        int dyRCorner = dyCorner.y;
        int dyCCorner = dyCorner.z;

        // Convolve dy(?, ?, ?, ch) with pos mask(:, :, :, d) to get
        // dx(xD, xR, xC, ch).
        // ? = to be determined. : = across all values in that axis.
        float dotProd = 0.0;

        for (int wD = 0; wD < ${c};
           wD += ${r}) {
          float dyD = float(dyDCorner + wD) / ${t}.0;

          if (dyD < 0.0 || dyD >= ${e.outDepth}.0 || fract(dyD) > 0.0) {
            continue;
          }
          int idyD = int(dyD);

          for (int wR = 0; wR < ${l};
              wR += ${i}) {
            float dyR = float(dyRCorner + wR) / ${s}.0;

            if (dyR < 0.0 || dyR >= ${e.outHeight}.0 ||
                fract(dyR) > 0.0) {
              continue;
            }
            int idyR = int(dyR);

            for (int wC = 0; wC < ${u};
                wC += ${a}) {
              float dyC = float(dyCCorner + wC) / ${o}.0;

              if (dyC < 0.0 || dyC >= ${e.outWidth}.0 ||
                  fract(dyC) > 0.0) {
                continue;
              }
              int idyC = int(dyC);

              float dyValue = getDy(batch, idyD, idyR, idyC, ch);
              int maxPosValue = ${p} -
                  int(getMaxPos(batch, idyD, idyR, idyC, ch));

              // Get the current value, check it against the value from the
              // position matrix.
              int curPosValue =
                  wD * ${l} * ${u} +
                  wR * ${u} + wC;
              float mask = float(maxPosValue == curPosValue ? 1.0 : 0.0);

              dotProd += dyValue * mask;
            }
          }
        }
        setOutput(dotProd);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function W1(n) {
  const { inputs: e, backend: t, attrs: s } = n, { dy: o, input: r } = e, i = r, { filterSize: a, strides: c, pad: l, dimRoundingMode: u } = s, d = [1, 1, 1], h = Cn(i.shape, a, c, d, l, u), f = new go(
    h,
    "max",
    !0
    /* get positions */
  ), p = t.runWebGLProgram(f, [i], i.dtype), x = new U1(h), g = t.runWebGLProgram(x, [o, p], i.dtype);
  return t.disposeIntermediateTensorInfo(p), g;
}
const G1 = {
  kernelName: Vl,
  backendName: "webgl",
  kernelFunc: W1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function z1(n) {
  const { inputs: e, backend: t, attrs: s } = n, { dy: o, input: r, output: i } = e, a = r;
  yn([r, i], "maxPoolGrad");
  const { filterSize: c, strides: l, pad: u, dimRoundingMode: d } = s, h = qt(a.shape, c, l, 1, u, d), f = !0, p = new pn(h, "max", f), x = t.runWebGLProgram(p, [a], a.dtype), g = new V1(h), m = t.runWebGLProgram(g, [o, x], a.dtype);
  return t.disposeIntermediateTensorInfo(x), m;
}
const H1 = {
  kernelName: Bl,
  backendName: "webgl",
  kernelFunc: z1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function X1(n, e, t, s) {
  let o = new pn(t, "max", !1);
  const r = s.runWebGLProgram(o, [n], "float32");
  o = new pn(t, "max", !0, !0, e);
  const i = s.runWebGLProgram(o, [n], "float32");
  return [r, i];
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const q1 = {
  kernelName: Ul,
  backendName: "webgl",
  kernelFunc: ({ inputs: n, attrs: e, backend: t }) => {
    const { x: s } = n, { filterSize: o, strides: r, pad: i, includeBatchInIndex: a } = e, c = t;
    N(s.shape.length === 4, () => `Error in maxPool: input must be rank 4 but got rank ${s.shape.length}.`);
    const l = [1, 1];
    N(jt(r, l), () => `Error in maxPool: Either strides or dilations must be 1. Got strides ${r} and dilations '${l}'`);
    const u = qt(s.shape, o, r, l, i), [d, h] = X1(s, a, u, c);
    return [d, h];
  }
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function j1(n, e, t, s) {
  const o = T(e), i = T(n.shape) / o, a = S({ inputs: { x: n }, attrs: { shape: [i, o] }, backend: s }), c = Nt(a, "float32", "mean", s), l = S({ inputs: { x: c }, attrs: { shape: t }, backend: s });
  return s.disposeIntermediateTensorInfo(a), s.disposeIntermediateTensorInfo(c), l;
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const K1 = {
  kernelName: Wl,
  backendName: "webgl",
  kernelFunc: ({ inputs: n, attrs: e, backend: t }) => {
    const { x: s } = n, { keepDims: o, axis: r } = e, i = t, a = s.shape.length, c = de(r, s.shape);
    let l = c;
    const u = Ee(l, a), d = u != null, h = i.shouldExecuteOnCPU([s]), f = [];
    let p = s;
    if (d) {
      if (h) {
        const w = i.texData.get(p.dataId).values, v = new Array(a);
        for (let $ = 0; $ < v.length; $++)
          v[$] = s.shape[u[$]];
        const E = fo(w, s.shape, s.dtype, u, v);
        p = i.makeTensorInfo(v, s.dtype);
        const R = i.texData.get(p.dataId);
        R.values = E;
      } else
        p = ss(s, u, i);
      f.push(p), l = Ne(l.length, a);
    }
    Me("sum", l, a);
    const [x, g] = He(p.shape, l);
    let m = x;
    o && (m = qe(x, c));
    const C = j1(p, g, m, i);
    for (const b of f)
      i.disposeIntermediateTensorInfo(b);
    return C;
  }
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Y1(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r, keepDims: i } = s, a = o.shape.length, c = de(r, o.shape);
  let l = c;
  const u = Ee(l, a);
  let d = o;
  u != null && (d = ae({ inputs: { x: o }, backend: t, attrs: { perm: u } }), l = Ne(l.length, o.shape.length)), Me("min", l, a);
  const [h, f] = He(d.shape, l), p = T(f), x = S({ inputs: { x: d }, backend: t, attrs: { shape: [-1, p] } }), g = Nt(x, x.dtype, "min", t);
  let m;
  if (i) {
    const C = qe(h, c);
    m = S({ inputs: { x: g }, backend: t, attrs: { shape: C } });
  } else
    m = S({ inputs: { x: g }, backend: t, attrs: { shape: h } });
  return t.disposeIntermediateTensorInfo(x), t.disposeIntermediateTensorInfo(g), u != null && t.disposeIntermediateTensorInfo(d), m;
}
const Q1 = {
  kernelName: Gl,
  backendName: "webgl",
  kernelFunc: Y1
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Z1 = po + `
  return min(a, b);
`, J1 = `
  vec4 result = vec4(min(a, b));
  bvec4 isNaNA = isnan(a);
  bvec4 isNaNB = isnan(b);
  bvec4 isNaN = bvec4(isNaNA.x || isNaNB.x, isNaNA.y || isNaNB.y, isNaNA.z || isNaNB.z, isNaNA.w || isNaNB.w);
  ` + Et + `
  return result;
`, ey = ee({
  opSnippet: Z1,
  packedOpSnippet: J1,
  cpuKernelImpl: Mg
}), ty = {
  kernelName: zl,
  backendName: "webgl",
  kernelFunc: ey
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class ny {
  constructor(e, t, s) {
    this.variableNames = ["x"], this.outputShape = t.map(
      (u, d) => u[0] + e[d] + u[1]
      /* afterPad */
    );
    const o = e.length, r = V(o), i = t.map((u) => u[0]).join(","), a = t.map((u, d) => u[0] + e[d]).join(","), c = ["coords[0]", "coords[1]", "coords[2]", "coords[3]"].slice(0, o), l = s === "reflect" ? 0 : 1;
    if (o === 1) {
      this.userCode = `
        int start = ${i};
        int end = ${a};

        void main() {
          int outC = getOutputCoords();
          if (outC < start) {
            outC = start * 2 - outC - ${l};
          } else if(outC >= end) {
            outC = (end - 1) * 2 - outC + ${l};
          }
          setOutput(getX(outC - start));
        }
      `;
      return;
    }
    this.userCode = `
      ${r} start = ${r}(${i});
      ${r} end = ${r}(${a});

      void main() {
        ${r} outC = getOutputCoords();
        for (int i = 0; i < ${o}; i++) {
          if (outC[i] < start[i]) {
            outC[i] = start[i] * 2 - outC[i] - ${l};
          } else if(outC[i] >= end[i]) {
            outC[i] = (end[i] - 1) * 2 - outC[i] + ${l};
          }
        }
        ${r} coords = outC - start;
        setOutput(getX(${c}));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class sy {
  constructor(e, t, s) {
    this.variableNames = ["x"], this.packedInputs = !0, this.packedOutput = !0, this.outputShape = t.map(
      (p, x) => p[0] + e[x] + p[1]
      /* afterPad */
    );
    const o = e.length, r = V(o), i = t.map((p) => p[0]).join(","), a = t.map((p, x) => p[0] + e[x]).join(","), c = re("rc", o), l = re("source", o), u = `${c[o - 1]} < ${this.outputShape[o - 1]}`, d = o === 1 ? "source" : `vec2(${l.slice(-2).join()})`, h = s === "reflect" ? 0 : 1;
    let f = "";
    if (o === 1) {
      const p = `
        ${r} source = rc;
        if (source < start) {
          source = start * 2 - source - ${h};
        } else if (source >= end) {
          source = (end - 1) * 2 - source + ${h};
        }
        source -= start;
      `;
      f = `
        ${r} rc = outputLoc;
        ${p}
        result[0] = getChannel(getX(${l.join()}), ${d});
        ${c[o - 1]} += 1;
        if(${u}) {
          ${p}
          result[1] = getChannel(getX(${l.join()}), ${d});
        }
      `;
    } else {
      const p = `
        ${r} source = rc;
        ${r} lt = ${r}(lessThan(source, start));
        ${r} gte = ${r}(greaterThanEqual(source, end));
        ${r} orig = 1 - (lt + gte);
        source = orig * source +
                lt * (start * 2 - source - ${h}) +
                gte * ((end - 1) * 2 - source + ${h});
        source -= start;
      `;
      f = `
        ${r} rc = outputLoc;
        ${p}
        result[0] = getChannel(getX(${l.join()}), ${d});
        ${c[o - 1]} += 1;
        if(${u}) {
          ${p}
          result[1] = getChannel(getX(${l.join()}), ${d});
        }
        rc = outputLoc;
        ${c[o - 2]} += 1;
        if(${c[o - 2]} < ${this.outputShape[o - 2]}) {
          ${p}
          result[2] = getChannel(getX(${l.join()}), ${d});
          ${c[o - 1]} += 1;
          if(${u}) {
            ${p}
            result[3] = getChannel(getX(${l.join()}), ${d});
          }
        }
      `;
    }
    this.userCode = `
      const ${r} start = ${r}(${i});
      const ${r} end = ${r}(${a});

      void main() {
        ${r} outputLoc = getOutputCoords();
        vec4 result = vec4(0.);
        ${f}
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const oy = ({ inputs: n, backend: e, attrs: t }) => {
  const { x: s } = n, { paddings: o, mode: r } = t, i = y().getBool("WEBGL_PACK_ARRAY_OPERATIONS") ? new sy(s.shape, o, r) : new ny(s.shape, o, r);
  return e.runWebGLProgram(i, [s], s.dtype);
}, ry = {
  kernelName: Hl,
  backendName: "webgl",
  kernelFunc: oy
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const iy = `if (b == 0.0) return NAN;
  return mod(a, b);`, ay = `
  vec4 result = mod(a, b);
  bvec4 isNaN = equal(b, vec4(0.0));
  ` + Et + `
  return result;
`, cy = ee({
  opSnippet: iy,
  packedOpSnippet: ay
}), ly = {
  kernelName: Xl,
  backendName: "webgl",
  kernelFunc: cy
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class uy {
  constructor(e, t, s) {
    this.variableNames = ["probs"], this.customUniforms = [{ name: "seed", type: "float" }], this.outputShape = [e, s], this.userCode = `
      void main() {
        ivec2 coords = getOutputCoords();
        int batch = coords[0];

        float r = random(seed);
        float cdf = 0.0;

        for (int i = 0; i < ${t - 1}; i++) {
          cdf += getProbs(batch, i);

          if (r < cdf) {
            setOutput(float(i));
            return;
          }
        }

        // If no other event happened, last event happened.
        setOutput(float(${t - 1}));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const dy = `
if (a == b) {
  return 1.0;
};
return a / b;`, hy = `
  // vec4 one = vec4(equal(a, b));
  // return one + (vec4(1.0) - one) * a / b;
  vec4 result = a / b;
  if(a.x == b.x) {
    result.x = 1.;
  }
  if(a.y == b.y) {
    result.y = 1.;
  }
  if(a.z == b.z) {
    result.z = 1.;
  }
  if(a.w == b.w) {
    result.w = 1.;
  }

  return result;
`, Ga = ee({ opSnippet: dy, packedOpSnippet: hy, checkOutOfBounds: !0 }), fy = {
  kernelName: Ar,
  backendName: "webgl",
  kernelFunc: Ga
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Cr = "return a - b;", za = ee({
  opSnippet: Cr,
  packedOpSnippet: Cr,
  supportsComplex: !0,
  cpuKernelImpl: ix
}), py = {
  kernelName: Mr,
  backendName: "webgl",
  kernelFunc: za
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ha(n) {
  const { inputs: e, backend: t, attrs: s } = n, { logits: o } = e, { dim: r } = s, i = de([r], o.shape), a = Wa({
    inputs: { x: o },
    backend: t,
    attrs: { reductionIndices: i, keepDims: !1 }
  }), c = qe(a.shape, i), l = S({ inputs: { x: a }, backend: t, attrs: { shape: c } }), u = za({ inputs: { a: o, b: l }, backend: t }), d = Ma({ inputs: { x: u }, backend: t }), h = os({ inputs: { x: d }, backend: t, attrs: { axis: i, keepDims: !1 } }), f = S({ inputs: { x: h }, backend: t, attrs: { shape: c } }), p = Ga({ inputs: { a: d, b: f }, backend: t });
  return t.disposeIntermediateTensorInfo(a), t.disposeIntermediateTensorInfo(l), t.disposeIntermediateTensorInfo(u), t.disposeIntermediateTensorInfo(d), t.disposeIntermediateTensorInfo(h), t.disposeIntermediateTensorInfo(f), p;
}
const my = {
  kernelName: Ou,
  backendName: "webgl",
  kernelFunc: Ha
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function gy(n) {
  const { inputs: e, backend: t, attrs: s } = n, { logits: o } = e, { numSamples: r, seed: i, normalized: a } = s, c = a ? o : Ha({ inputs: { logits: o }, backend: t, attrs: { dim: o.shape.length - 1 } }), l = c.shape[0], u = c.shape[1], d = new uy(l, u, r), h = [[i]], f = t.runWebGLProgram(d, [c], "int32", h);
  return a || t.disposeIntermediateTensorInfo(c), f;
}
const xy = {
  kernelName: ql,
  backendName: "webgl",
  kernelFunc: gy
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Cy = ke + `
  return -x;
`, by = `
  vec4 result = -x;
  bvec4 isNaN = isnan(x);

  result.r = isNaN.r ? x.r : result.r;
  result.g = isNaN.g ? x.g : result.g;
  result.b = isNaN.b ? x.b : result.b;
  result.a = isNaN.a ? x.a : result.a;

  return result;
`;
function wy(n) {
  const { inputs: e, backend: t } = n, { x: s } = e;
  if (t.shouldExecuteOnCPU([s])) {
    const r = t.texData.get(s.dataId), [i, a] = Ug(r.values, s.shape, s.dtype);
    return t.makeTensorInfo(a, s.dtype, i);
  }
  let o;
  return y().getBool("WEBGL_PACK_UNARY_OPERATIONS") ? o = new et(s.shape, by) : o = new Ue(s.shape, Cy), t.runWebGLProgram(o, [s], s.dtype);
}
const yy = {
  kernelName: jl,
  backendName: "webgl",
  kernelFunc: wy
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const vy = Bh;
function $y(n) {
  Pe("tf.nonMaxSuppression() in webgl locks the UI thread. Call tf.nonMaxSuppressionAsync() instead");
  const { inputs: e, backend: t, attrs: s } = n, { boxes: o, scores: r } = e, { maxOutputSize: i, iouThreshold: a, scoreThreshold: c } = s, l = t.readSync(o.dataId), u = t.readSync(r.dataId), { selectedIndices: d } = vy(l, u, i, a, c);
  return t.makeTensorInfo([d.length], "int32", new Int32Array(d));
}
const Sy = {
  kernelName: Yl,
  backendName: "webgl",
  kernelFunc: $y
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Iy = Mh;
function Ry(n) {
  Pe("tf.nonMaxSuppression() in webgl locks the UI thread. Call tf.nonMaxSuppressionAsync() instead");
  const { inputs: e, backend: t, attrs: s } = n, { boxes: o, scores: r } = e, { maxOutputSize: i, iouThreshold: a, scoreThreshold: c, padToMaxOutputSize: l } = s, u = t.readSync(o.dataId), d = t.readSync(r.dataId), { selectedIndices: h, validOutputs: f } = Iy(u, d, i, a, c, l);
  return [
    t.makeTensorInfo([h.length], "int32", new Int32Array(h)),
    t.makeTensorInfo([], "int32", new Int32Array([f]))
  ];
}
const Ty = {
  kernelName: Ql,
  backendName: "webgl",
  kernelFunc: Ry
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ey = Vh;
function Ny(n) {
  Pe("tf.nonMaxSuppression() in webgl locks the UI thread. Call tf.nonMaxSuppressionAsync() instead");
  const { inputs: e, backend: t, attrs: s } = n, { boxes: o, scores: r } = e, { maxOutputSize: i, iouThreshold: a, scoreThreshold: c, softNmsSigma: l } = s, u = t.readSync(o.dataId), d = t.readSync(r.dataId), h = i, f = a, p = c, x = l, { selectedIndices: g, selectedScores: m } = Ey(u, d, h, f, p, x);
  return [
    t.makeTensorInfo([g.length], "int32", new Int32Array(g)),
    t.makeTensorInfo([m.length], "float32", new Float32Array(m))
  ];
}
const ky = {
  kernelName: Zl,
  backendName: "webgl",
  kernelFunc: Ny
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Ay {
  constructor(e, t, s, o) {
    this.variableNames = ["indices"], this.outputShape = [e, t], this.userCode = `
      void main() {
        ivec2 coords = getOutputCoords();
        int index = round(getIndices(coords.x));
        setOutput(mix(float(${o}), float(${s}),
                      float(index == coords.y)));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Fy = (n) => {
  const { inputs: e, backend: t, attrs: s } = n, { indices: o } = e, { dtype: r, depth: i, onValue: a, offValue: c } = s, l = T(o.shape), u = new Ay(l, i, a, c), d = S({ inputs: { x: o }, backend: t, attrs: { shape: [l] } }), h = t.runWebGLProgram(u, [d], r);
  t.disposeIntermediateTensorInfo(d);
  const f = [...o.shape, i], p = S({ inputs: { x: h }, backend: t, attrs: { shape: f } });
  return t.disposeIntermediateTensorInfo(h), p;
}, Dy = {
  kernelName: eu,
  backendName: "webgl",
  kernelFunc: Fy
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function jn(n) {
  const { inputs: e, backend: t } = n, { x: s } = e;
  if (s.dtype === "complex64") {
    const o = $n({ inputs: { input: s }, backend: t }), r = jn({ inputs: { x: o }, backend: t }), i = rs({ inputs: { input: s }, backend: t }), a = jn({ inputs: { x: i }, backend: t }), c = ot({ inputs: { real: r, imag: a }, backend: t });
    return t.disposeIntermediateTensorInfo(o), t.disposeIntermediateTensorInfo(r), t.disposeIntermediateTensorInfo(i), t.disposeIntermediateTensorInfo(a), c;
  } else
    return Sn({
      attrs: {
        shape: s.shape,
        dtype: s.dtype,
        value: s.dtype === "string" ? "" : 0
      },
      backend: t
    });
}
const Oy = {
  kernelName: Ur,
  backendName: "webgl",
  kernelFunc: jn
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Xa(n) {
  const { inputs: e, backend: t } = n, { x: s } = e;
  if (s.dtype === "string")
    throw new Error("onesLike is not supported under string dtype");
  if (s.dtype === "complex64") {
    const o = $n({ inputs: { input: s }, backend: t }), r = Xa({ inputs: { x: o }, backend: t }), i = rs({ inputs: { input: s }, backend: t }), a = jn({ inputs: { x: i }, backend: t }), c = ot({ inputs: { real: r, imag: a }, backend: t });
    return t.disposeIntermediateTensorInfo(o), t.disposeIntermediateTensorInfo(r), t.disposeIntermediateTensorInfo(i), t.disposeIntermediateTensorInfo(a), c;
  } else
    return Sn({ attrs: { shape: s.shape, dtype: s.dtype, value: 1 }, backend: t });
}
const Py = {
  kernelName: Jl,
  backendName: "webgl",
  kernelFunc: Xa
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function _y(n) {
  const { inputs: e, backend: t, attrs: s } = n, { axis: o } = s;
  if (e.length === 1)
    return Ws({ inputs: { input: e[0] }, backend: t, attrs: { dim: o } });
  const r = e[0].shape, i = e[0].dtype;
  e.forEach((u) => {
    $r(r, u.shape, "All tensors passed to stack must have matching shapes"), N(i === u.dtype, () => "All tensors passed to stack must have matching dtypes");
  });
  const a = [], c = e.map((u) => {
    const d = Ws({ inputs: { input: u }, backend: t, attrs: { dim: o } });
    return a.push(d), d;
  }), l = Aa({ inputs: c, backend: t, attrs: { axis: o } });
  return a.forEach((u) => t.disposeIntermediateTensorInfo(u)), l;
}
const Ly = {
  kernelName: tu,
  backendName: "webgl",
  kernelFunc: _y
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class By {
  constructor(e, t, s) {
    this.variableNames = ["x"], this.customUniforms = [{ name: "value", type: "float" }], this.outputShape = t.map(
      (l, u) => l[0] + e[u] + l[1]
      /* afterPad */
    );
    const o = e.length, r = V(o), i = t.map((l) => l[0]).join(","), a = t.map((l, u) => l[0] + e[u]).join(","), c = ["coords[0]", "coords[1]", "coords[2]", "coords[3]"].slice(0, o);
    if (o === 1) {
      this.userCode = `
        int start = ${i};
        int end = ${a};

        void main() {
          int outC = getOutputCoords();
          if (outC < start || outC >= end) {
            setOutput(value);
          } else {
            setOutput(getX(outC - start));
          }
        }
      `;
      return;
    }
    this.userCode = `
      ${r} start = ${r}(${i});
      ${r} end = ${r}(${a});

      void main() {
        ${r} outC = getOutputCoords();
        if (any(lessThan(outC, start)) || any(greaterThanEqual(outC, end))) {
          setOutput(value);
        } else {
          ${r} coords = outC - start;
          setOutput(getX(${c}));
        }
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class My {
  constructor(e, t, s) {
    this.variableNames = ["x"], this.packedInputs = !0, this.packedOutput = !0, this.customUniforms = [{ name: "value", type: "float" }], this.outputShape = t.map(
      (x, g) => x[0] + e[g] + x[1]
      /* afterPad */
    );
    const o = e.length, r = V(o), i = t.map((x) => x[0]).join(","), a = t.map((x, g) => x[0] + e[g]).join(","), c = re("rc", o), l = re("source", o), u = `${c[o - 1]} < ${this.outputShape[o - 1]}`, d = o === 1 ? "source" : `vec2(${l.slice(-2).join()})`, h = [
      `${r} rc = outputLoc;`,
      `${c[o - 1]} += 1;
       if(${u}) {
      `,
      o === 1 ? "" : `}
       rc = outputLoc;
       ${c[o - 2]} += 1;
       if(${c[o - 2]} < ${this.outputShape[o - 2]}) {`,
      o === 1 ? "" : `  ${c[o - 1]} += 1;
         if(${u}) {`
    ], f = o === 1 ? "rc < start || rc >= end" : "any(lessThan(rc, start)) || any(greaterThanEqual(rc, end))";
    let p = "";
    for (let x = 0, g = o === 1 ? 2 : 4; x < g; x++)
      p += `
        ${h[x]}
        if (${f}) {
          result[${x}] = float(value);
        } else {
          ${r} source = rc - start;
          result[${x}] = getChannel(getX(${l.join()}), ${d});
        }
      `;
    p += o === 1 ? "} " : "}}", this.userCode = `
      const ${r} start = ${r}(${i});
      const ${r} end = ${r}(${a});

      void main() {
        ${r} outputLoc = getOutputCoords();
        vec4 result = vec4(0.);
        ${p}
        setOutput(result);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const qa = (n) => {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { paddings: r, constantValue: i } = s;
  if (T(o.shape) === 0) {
    const l = r.map(
      (u, d) => u[0] + o.shape[d] + u[1]
      /* afterPad */
    );
    return Sn({
      backend: t,
      attrs: { shape: l, value: i, dtype: o.dtype }
    });
  }
  const a = y().getBool("WEBGL_PACK_ARRAY_OPERATIONS") ? new My(o.shape, r, i) : new By(o.shape, r, i), c = [[i]];
  return t.runWebGLProgram(a, [o], o.dtype, c);
}, Vy = {
  kernelName: nu,
  backendName: "webgl",
  kernelFunc: qa
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Uy = `
  if(a < 0.0 && floor(b) < b){
    return NAN;
  }
  if (b == 0.0) {
    return 1.0;
  }
  return (round(mod(b, 2.0)) != 1) ?
      pow(abs(a), b) : sign(a) * pow(abs(a), b);
`, Wy = `
  // isModRound1 has 1 for components with round(mod(b, 2.0)) == 1, 0 otherwise.
  vec4 isModRound1 = vec4(equal(round(mod(b, 2.0)), ivec4(1)));
  vec4 multiplier = sign(a) * isModRound1 + (vec4(1.0) - isModRound1);
  vec4 result = multiplier * pow(abs(a), b);

  // Ensure that a^0 = 1, including 0^0 = 1 as this correspond to TF and JS
  bvec4 isExpZero = equal(b, vec4(0.0));
  result.r = isExpZero.r ? 1.0 : result.r;
  result.g = isExpZero.g ? 1.0 : result.g;
  result.b = isExpZero.b ? 1.0 : result.b;
  result.a = isExpZero.a ? 1.0 : result.a;

  bvec4 isNaN1 = lessThan(a, vec4(0.0));
  bvec4 isNaN2 = lessThan(floor(b), b);
  bvec4 isNaN = bvec4(isNaN1.x && isNaN2.x, isNaN1.y && isNaN2.y, isNaN1.z && isNaN2.z, isNaN1.w && isNaN2.w);
  ` + Et + `
  return result;
`, Gy = ee({ opSnippet: Uy, packedOpSnippet: Wy }), zy = {
  kernelName: _r,
  backendName: "webgl",
  kernelFunc: Gy
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Hy(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { axis: r, keepDims: i } = s, a = o.shape.length, c = [], l = de(r, o.shape);
  let u = l;
  const d = Ee(u, a);
  let h = o;
  d != null && (h = ae({ inputs: { x: o }, backend: t, attrs: { perm: d } }), u = Ne(u.length, a), c.push(h)), Me("prod", u, a);
  let f;
  if (t.shouldExecuteOnCPU([h])) {
    const p = t.texData.get(h.dataId).values, { outVals: x, outShape: g, outDtype: m } = Gg(h.shape, h.dtype, p, u);
    f = t.makeTensorInfo(g, m, x);
  } else {
    const [p, x] = He(h.shape, u), g = T(x), m = S({ inputs: { x: h }, backend: t, attrs: { shape: [-1, g] } }), C = Qs(o.dtype), b = Nt(m, C, "prod", t);
    f = S({ inputs: { x: b }, backend: t, attrs: { shape: p } }), c.push(m), c.push(b);
  }
  if (i) {
    c.push(f);
    const p = qe(f.shape, l);
    f = S({ inputs: { x: f }, backend: t, attrs: { shape: p } });
  }
  return c.forEach((p) => t.disposeIntermediateTensorInfo(p)), f;
}
const Xy = {
  kernelName: ou,
  backendName: "webgl",
  kernelFunc: Hy
};
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function qy(n) {
  const { inputs: e, backend: t, attrs: s } = n, { paramsNestedSplits: o, paramsDenseValues: r, indices: i } = e, { outputRaggedRank: a } = s, c = o.map((m) => t.readSync(m.dataId)), l = o.map((m) => m.shape), u = t.readSync(r.dataId), d = t.readSync(i.dataId), [h, f, p] = zg(c, l, u, r.shape, r.dtype, d, i.shape, a), x = h.map((m) => t.makeTensorInfo([m.length], "int32", m)), g = t.makeTensorInfo(p, r.dtype, f);
  return x.concat([g]);
}
const jy = {
  kernelName: ru,
  backendName: "webgl",
  kernelFunc: qy
};
/**
 * @license
 * Copyright 2022 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ky(n) {
  const { inputs: e, backend: t } = n, { starts: s, limits: o, deltas: r } = e, i = t.readSync(s.dataId), a = t.readSync(o.dataId), c = t.readSync(r.dataId), [l, u] = Hg(i, s.shape, s.dtype, a, o.shape, c, r.shape), d = t.makeTensorInfo([l.length], "int32", l), h = t.makeTensorInfo([u.length], s.dtype, u);
  return [d, h];
}
const Yy = {
  kernelName: iu,
  backendName: "webgl",
  kernelFunc: Ky
};
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Qy(n) {
  const { inputs: e, backend: t, attrs: s } = n, { shape: o, values: r, defaultValue: i, rowPartitionTensors: a } = e, { rowPartitionTypes: c } = s, l = t.readSync(o.dataId), u = t.readSync(r.dataId), d = t.readSync(i.dataId), h = a.map((g) => t.readSync(g.dataId)), f = a.map((g) => g.shape), [p, x] = Xg(l, o.shape, u, r.shape, r.dtype, d, i.shape, h, f, c);
  return t.makeTensorInfo(p, r.dtype, x);
}
const Zy = {
  kernelName: au,
  backendName: "webgl",
  kernelFunc: Qy
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ja = (n) => {
  const { backend: e, attrs: t } = n, { start: s, stop: o, step: r, dtype: i } = t, a = qg(s, o, r, i);
  return e.makeTensorInfo([a.length], i, a);
}, Jy = {
  kernelName: cu,
  backendName: "webgl",
  kernelFunc: ja
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const ev = "return 1.0 / x;", tv = _({ opSnippet: ev }), nv = {
  kernelName: uu,
  backendName: "webgl",
  kernelFunc: tv
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const sv = ke + `
  return (x < 0.0) ? 0.0 : x;
`, ov = `
  vec4 result = x * vec4(greaterThanEqual(x, vec4(0.0)));
  bvec4 isNaN = isnan(x);

  result.r = isNaN.r ? x.r : result.r;
  result.g = isNaN.g ? x.g : result.g;
  result.b = isNaN.b ? x.b : result.b;
  result.a = isNaN.a ? x.a : result.a;

  return result;
`, rv = _({ opSnippet: sv, packedOpSnippet: ov }), iv = {
  kernelName: du,
  backendName: "webgl",
  kernelFunc: rv
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const av = ke + `
  return (x < 0.0) ? 0.0 : min(6.0, x);
`, cv = `
  vec4 result = min(x, vec4(6.)) * vec4(greaterThanEqual(x, vec4(0.0)));
  bvec4 isNaN = isnan(x);

  result.r = isNaN.r ? x.r : result.r;
  result.g = isNaN.g ? x.g : result.g;
  result.b = isNaN.b ? x.b : result.b;
  result.a = isNaN.a ? x.a : result.a;

  return result;
`, lv = _({ opSnippet: av, packedOpSnippet: cv }), uv = {
  kernelName: gu,
  backendName: "webgl",
  kernelFunc: lv
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class dv {
  constructor(e, t, s, o, r) {
    this.variableNames = ["A"], this.outputShape = [];
    const [i, a, c, l] = e;
    this.outputShape = [i, t, s, l];
    const u = [
      o && t > 1 ? a - 1 : a,
      o && s > 1 ? c - 1 : c
    ], d = [
      o && t > 1 ? t - 1 : t,
      o && s > 1 ? s - 1 : s
    ];
    let h;
    r ? h = "(vec2(yRC) + vec2(0.5)) * effectiveInputOverOutputRatioRC - vec2(0.5)" : h = "vec2(yRC) * effectiveInputOverOutputRatioRC", this.userCode = `
      const vec2 effectiveInputOverOutputRatioRC = vec2(
          ${u[0] / d[0]},
          ${u[1] / d[1]});
      const vec2 inputShapeRC = vec2(${a}.0, ${c}.0);

      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int d = coords[3];
        ivec2 yRC = coords.yz;

        // Fractional source index.
        vec2 sourceFracIndexRC = ${h};

        // Compute the four integer indices.
        ivec2 sourceFloorRC = ivec2(max(sourceFracIndexRC, vec2(0.0)));
        ivec2 sourceCeilRC = ivec2(
          min(inputShapeRC - 1.0, ceil(sourceFracIndexRC)));

        float topLeft = getA(b, sourceFloorRC.x, sourceFloorRC.y, d);
        float bottomLeft = getA(b, sourceCeilRC.x, sourceFloorRC.y, d);
        float topRight = getA(b, sourceFloorRC.x, sourceCeilRC.y, d);
        float bottomRight = getA(b, sourceCeilRC.x, sourceCeilRC.y, d);

        vec2 fracRC = sourceFracIndexRC - vec2(sourceFloorRC);

        float top = topLeft + (topRight - topLeft) * fracRC.y;
        float bottom = bottomLeft + (bottomRight - bottomLeft) * fracRC.y;
        float newValue = top + (bottom - top) * fracRC.x;

        setOutput(newValue);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class hv {
  constructor(e, t, s, o, r) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0, this.outputShape = [];
    const [i, a, c, l] = e;
    this.outputShape = [i, t, s, l];
    const u = [
      o && t > 1 ? a - 1 : a,
      o && s > 1 ? c - 1 : c
    ], d = [
      o && t > 1 ? t - 1 : t,
      o && s > 1 ? s - 1 : s
    ];
    let h;
    r ? h = "(vec3(yRC) + vec3(0.5)) * effectiveInputOverOutputRatioRC - vec3(0.5)" : h = "vec3(yRC) * effectiveInputOverOutputRatioRC", this.userCode = `
      const vec3 effectiveInputOverOutputRatioRC = vec3(
          ${u[0] / d[0]},
          ${u[1] / d[1]},
          ${u[1] / d[1]});
      const vec3 inputShapeRC = vec3(${a}.0, ${c}.0,
                                     ${c}.0);

      float getAValue(int b, int r, int c, int d) {
        return getChannel(getA(b, r, c, d), vec2(c, d));
      }

      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int d = coords[3];
        // Calculate values for next column in yRC.z.
        ivec3 yRC = coords.yzz + ivec3(0, 0, 1);

        // Fractional source index.
        vec3 sourceFracIndexRC = ${h};

        // Compute the four integer indices.
        ivec3 sourceFloorRC = ivec3(max(sourceFracIndexRC, vec3(0.0)));
        ivec3 sourceCeilRC = ivec3(
          min(inputShapeRC - 1.0, ceil(sourceFracIndexRC)));

        // Should we calculate next column and row elements in 2x2 packed cell.
        bool hasNextCol = d < ${l - 1};
        bool hasNextRow = coords.z < ${s - 1};

        // In parallel, construct four corners for all four components in
        // packed 2x2 cell.
        vec4 topLeft = vec4(
          getAValue(b, sourceFloorRC.x, sourceFloorRC.y, d),
          hasNextCol ? getAValue(b, sourceFloorRC.x, sourceFloorRC.y, d + 1)
                     : 0.0,
          hasNextRow ? getAValue(b, sourceFloorRC.x, sourceFloorRC.z, d)
                     : 0.0,
          (hasNextRow && hasNextCol) ?
            getAValue(b, sourceFloorRC.x, sourceFloorRC.z, d + 1) : 0.0);

        vec4 bottomLeft = vec4(
          getAValue(b, sourceCeilRC.x, sourceFloorRC.y, d),
          hasNextCol ? getAValue(b, sourceCeilRC.x, sourceFloorRC.y, d + 1)
                     : 0.0,
          hasNextRow ? getAValue(b, sourceCeilRC.x, sourceFloorRC.z, d)
                     : 0.0,
          (hasNextRow && hasNextCol) ?
            getAValue(b, sourceCeilRC.x, sourceFloorRC.z, d + 1) : 0.0);

        vec4 topRight = vec4(
          getAValue(b, sourceFloorRC.x, sourceCeilRC.y, d),
          hasNextCol ? getAValue(b, sourceFloorRC.x, sourceCeilRC.y, d + 1)
                     : 0.0,
          hasNextRow ? getAValue(b, sourceFloorRC.x, sourceCeilRC.z, d)
                     : 0.0,
          (hasNextRow && hasNextCol) ?
            getAValue(b, sourceFloorRC.x, sourceCeilRC.z, d + 1) : 0.0);

        vec4 bottomRight = vec4(
          getAValue(b, sourceCeilRC.x, sourceCeilRC.y, d),
          hasNextCol ? getAValue(b, sourceCeilRC.x, sourceCeilRC.y, d + 1)
                     : 0.0,
          hasNextRow ? getAValue(b, sourceCeilRC.x, sourceCeilRC.z, d)
                     : 0.0,
          (hasNextRow && hasNextCol) ?
            getAValue(b, sourceCeilRC.x, sourceCeilRC.z, d + 1) : 0.0);

        vec3 fracRC = sourceFracIndexRC - vec3(sourceFloorRC);

        vec4 top = mix(topLeft, topRight, fracRC.yyzz);
        vec4 bottom = mix(bottomLeft, bottomRight, fracRC.yyzz);
        vec4 newValue = mix(top, bottom, fracRC.x);

        setOutput(newValue);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function fv(n) {
  const { inputs: e, backend: t, attrs: s } = n, { images: o } = e, { alignCorners: r, halfPixelCenters: i, size: a } = s, [c, l] = a, u = y().getBool("WEBGL_PACK_IMAGE_OPERATIONS") ? new hv(o.shape, c, l, r, i) : new dv(o.shape, c, l, r, i);
  return t.runWebGLProgram(u, [o], "float32");
}
const pv = {
  kernelName: pu,
  backendName: "webgl",
  kernelFunc: fv
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class mv {
  constructor(e, t, s) {
    this.variableNames = ["dy"], this.outputShape = [], this.outputShape = t;
    const [, o, r] = t, [, i, a] = e, c = [
      s && i > 1 ? o - 1 : o,
      s && a > 1 ? r - 1 : r
    ], l = [
      s && i > 1 ? i - 1 : i,
      s && a > 1 ? a - 1 : a
    ], u = c[0] / l[0], d = c[1] / l[1], h = 1 / u, f = 1 / d, p = Math.ceil(h) * 2 + 2, x = Math.ceil(f) * 2 + 2;
    this.userCode = `
      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int d = coords[3];
        int r = coords[1];
        int c = coords[2];

        float accumulator = 0.0;

        const float heightScale = float(${u});
        const float widthScale = float(${d});

        const float invHeightScale = float(${h});
        const float invWidthScale = float(${f});

        const int winHeight = int(${p});
        const int winWidth = int(${x});

        // Compute bounds for where in dy we will look
        float startRLerp = floor(float(r) * invHeightScale);
        int startDyR = int(startRLerp - float(winHeight / 2));

        float startCLerp = floor(float(c) * invWidthScale);
        int startDyC = int(startCLerp - float(winWidth / 2));

        // Loop over dy
        for (int dyROffset = 0; dyROffset < winHeight; dyROffset++) {
          int dyR = dyROffset + startDyR;

          // Guard against the window exceeding the bounds of dy
          if (dyR < 0 || dyR >= ${i}) {
            continue;
          }

          for (int dyCOffset = 0; dyCOffset < winWidth; dyCOffset++) {
            int dyC = dyCOffset + startDyC;

            // Guard against the window exceeding the bounds of dy
            if (dyC < 0 || dyC >= ${a}) {
              continue;
            }

            float dxR = float(dyR) * heightScale;
            int topDxRIndex = int(floor(dxR));
            int bottomDxRIndex = int(min(ceil(dxR), ${o - 1}.0));
            float dxRLerp = dxR - float(topDxRIndex);
            float inverseDxRLerp = 1.0 - dxRLerp;

            float dxC = float(dyC) * widthScale;
            int leftDxCIndex = int(floor(dxC));
            int rightDxCIndex = int(min(ceil(dxC), ${r - 1}.0));
            float dxCLerp = dxC - float(leftDxCIndex);
            float inverseDxCLerp = 1.0 - dxCLerp;

            if (r == topDxRIndex && c == leftDxCIndex) {
              // topLeft
              accumulator +=
                getDy(b, dyR, dyC, d) * inverseDxRLerp * inverseDxCLerp;
            }

            if (r == topDxRIndex && c == rightDxCIndex) {
              // topRight
              accumulator += getDy(b, dyR, dyC, d) * inverseDxRLerp * dxCLerp;
            }

            if (r == bottomDxRIndex && c == leftDxCIndex) {
              // bottomLeft
              accumulator += getDy(b, dyR, dyC, d) * dxRLerp * inverseDxCLerp;
            }

            if (r == bottomDxRIndex && c == rightDxCIndex) {
              // bottomRight
              accumulator += getDy(b, dyR, dyC, d) * dxRLerp * dxCLerp;
            }
          }
        }
        // End loop over dy

        setOutput(accumulator);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function gv(n) {
  const { inputs: e, backend: t, attrs: s } = n, { images: o, dy: r } = e, { alignCorners: i } = s, a = new mv(r.shape, o.shape, i);
  return t.runWebGLProgram(a, [r], r.dtype);
}
const xv = {
  kernelName: mu,
  backendName: "webgl",
  kernelFunc: gv
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Cv {
  constructor(e, t, s, o, r) {
    this.variableNames = ["A"], this.outputShape = [];
    const [i, a, c, l] = e;
    this.outputShape = [i, t, s, l];
    const u = [
      o && t > 1 ? a - 1 : a,
      o && s > 1 ? c - 1 : c
    ], d = [
      o && t > 1 ? t - 1 : t,
      o && s > 1 ? s - 1 : s
    ], h = o ? "0.5" : "0.0";
    let f;
    r ? f = "max((vec2(yRC) + vec2(0.5)) * effectiveInputOverOutputRatioRC, vec2(0.0))" : f = "vec2(yRC) * effectiveInputOverOutputRatioRC", this.userCode = `
      const vec2 effectiveInputOverOutputRatioRC = vec2(
          ${u[0] / d[0]},
          ${u[1] / d[1]});
      const vec2 inputShapeRC = vec2(${a}.0, ${c}.0);

      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int d = coords[3];
        ivec2 yRC = coords.yz;

        // Fractional source index.
        vec2 sourceFracIndexRC = ${f};

        // Compute the coordinators of nearest neighbor point.
        ivec2 sourceNearestRC = ivec2(
          min(inputShapeRC - 1.0, floor(sourceFracIndexRC + ${h})));
        float newValue = getA(b, sourceNearestRC.x, sourceNearestRC.y, d);

        setOutput(newValue);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class bv {
  constructor(e, t, s, o, r) {
    this.variableNames = ["A"], this.packedInputs = !0, this.packedOutput = !0, this.outputShape = [];
    const [i, a, c, l] = e;
    this.outputShape = [i, t, s, l];
    const u = [
      o && t > 1 ? a - 1 : a,
      o && s > 1 ? c - 1 : c
    ], d = [
      o && t > 1 ? t - 1 : t,
      o && s > 1 ? s - 1 : s
    ], h = o ? "0.5" : "0.0";
    let f;
    r ? f = "max((vec3(yRC) + vec3(0.5)) * effectiveInputOverOutputRatioRC, vec3(0.0))" : f = "vec3(yRC) * effectiveInputOverOutputRatioRC", this.userCode = `
      const vec3 effectiveInputOverOutputRatioRC = vec3(
          ${u[0] / d[0]},
          ${u[1] / d[1]},
          ${u[1] / d[1]});
      const vec3 inputShapeRC = vec3(${a}.0, ${c}.0,
                                     ${c}.0);

      float getAValue(int b, int r, int c, int d) {
        return getChannel(getA(b, r, c, d), vec2(c, d));
      }

      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int d = coords[3];
        // Calculate values for next column in yRC.z.
        ivec3 yRC = coords.yzz + ivec3(0, 0, 1);

        // Fractional source index.
        vec3 sourceFracIndexRC = ${f};

        // Compute the coordinators of nearest neighbor point.
        ivec3 sourceNearestRC = ivec3(
          min(inputShapeRC - 1.0, floor(sourceFracIndexRC + ${h})));

        // Should we calculate next column and row elements in 2x2 packed cell.
        bool hasNextCol = d < ${l - 1};
        bool hasNextRow = coords.z < ${s - 1};

        vec4 newValue = vec4(
          getAValue(b, sourceNearestRC.x, sourceNearestRC.y, d),
          hasNextCol ? getAValue(b, sourceNearestRC.x, sourceNearestRC.y, d + 1)
                     : 0.0,
          hasNextRow ? getAValue(b, sourceNearestRC.x, sourceNearestRC.z, d)
                     : 0.0,
          (hasNextRow && hasNextCol) ?
            getAValue(b, sourceNearestRC.x, sourceNearestRC.z, d + 1) : 0.0);

        setOutput(newValue);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function wv(n) {
  const { inputs: e, backend: t, attrs: s } = n, { images: o } = e, { alignCorners: r, halfPixelCenters: i, size: a } = s, [c, l] = a, u = y().getBool("WEBGL_PACK_IMAGE_OPERATIONS") ? new bv(o.shape, c, l, r, i) : new Cv(o.shape, c, l, r, i);
  return t.runWebGLProgram(u, [o], o.dtype);
}
const yv = {
  kernelName: hu,
  backendName: "webgl",
  kernelFunc: wv
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class vv {
  constructor(e, t, s) {
    this.variableNames = ["dy"], this.outputShape = [], this.outputShape = t;
    const [, o, r] = t, [, i, a] = e, c = [
      s && i > 1 ? o - 1 : o,
      s && a > 1 ? r - 1 : r
    ], l = [
      s && i > 1 ? i - 1 : i,
      s && a > 1 ? a - 1 : a
    ], u = c[0] / l[0], d = c[1] / l[1], h = 1 / u, f = 1 / d, p = Math.ceil(h) * 2 + 2, x = Math.ceil(f) * 2 + 2;
    this.userCode = `
      void main() {
        ivec4 coords = getOutputCoords();
        int b = coords[0];
        int d = coords[3];
        int r = coords[1];
        int c = coords[2];

        float accumulator = 0.0;

        const float heightScale = float(${u});
        const float widthScale = float(${d});

        const float invHeightScale = float(${h});
        const float invWidthScale = float(${f});

        const int winHeight = int(${p});
        const int winWidth = int(${x});

        // Compute bounds for where in dy we will look
        float startRLerp = floor(float(r) * invHeightScale);
        int startDyR = int(floor(startRLerp - float(winHeight / 2)));

        float startCLerp = floor(float(c) * invWidthScale);
        int startDyC = int(floor(startCLerp - float(winWidth / 2)));

        // Loop over dy
        for (int dyROffset = 0; dyROffset < winHeight; dyROffset++) {
          int dyR = dyROffset + startDyR;

          // Guard against the window exceeding the bounds of dy
          if (dyR < 0 || dyR >= ${i}) {
            continue;
          }

          for (int dyCOffset = 0; dyCOffset < winWidth; dyCOffset++) {
            int dyC = dyCOffset + startDyC;

            // Guard against the window exceeding the bounds of dy
            if (dyC < 0 || dyC >= ${a}) {
              continue;
            }

            float sourceFracRow =
              float(${c[0]}) *
                (float(dyR) / float(${l[0]}));

            float sourceFracCol =
                float(${c[1]}) *
                  (float(dyC) / float(${l[1]}));

            int sourceNearestRow = int(min(
                float(int(${o}) - 1),
                ${s} ? float(round(sourceFracRow)) :
                                  float(floor(sourceFracRow))));

            int sourceNearestCol = int(min(
                float(int(${r}) - 1),
                ${s} ? float(round(sourceFracCol)) :
                                  float(floor(sourceFracCol))));

            if (r == sourceNearestRow && c == sourceNearestCol) {
              accumulator += getDy(b, dyR, dyC, d);
            }
          }
        }
        // End loop over dy

        setOutput(accumulator);
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function $v(n) {
  const { inputs: e, backend: t, attrs: s } = n, { images: o, dy: r } = e, { alignCorners: i } = s, a = new vv(r.shape, o.shape, i);
  return t.runWebGLProgram(a, [r], r.dtype);
}
const Sv = {
  kernelName: fu,
  backendName: "webgl",
  kernelFunc: $v
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Iv {
  constructor(e, t) {
    this.variableNames = ["x"];
    const s = e.length;
    if (s > 4)
      throw new Error(`WebGL backend: Reverse of rank-${s} tensor is not yet supported`);
    if (this.outputShape = e, s === 1) {
      this.userCode = `
        void main() {
          int coord = getOutputCoords();
          setOutput(getX(${e[0]} - coord - 1));
        }
      `;
      return;
    }
    const o = (a) => t.indexOf(a) !== -1 && e[a] !== 1 ? `${e[a]} - coords[${a}] - 1` : `coords[${a}]`, r = e.map((a, c) => o(c)).join(","), i = V(s);
    this.userCode = `
      void main() {
        ${i} coords = getOutputCoords();
        setOutput(getX(${r}));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Rv {
  constructor(e, t) {
    this.variableNames = ["x"], this.packedInputs = !0, this.packedOutput = !0;
    const s = e.length;
    if (s > 4)
      throw new Error(`WebGL backend: Reverse of rank-${s} tensor is not yet supported`);
    this.outputShape = e;
    const o = re("rc", s), r = `${o[s - 1]} + 1 < ${this.outputShape[s - 1]}`, i = `${o[s - 2]} + 1 < ${this.outputShape[s - 2]}`, a = V(s);
    s === 1 ? this.userCode = `
        void main(){
          int rc = getOutputCoords();
          vec4 result = vec4(0.);
          result.r = getChannel(getX(${e[0]} - rc - 1),
            ${e[0]} - rc - 1);
          if(${r}){
              result.g = getChannel(getX(${e[0]} - (rc  + 1) - 1),
                ${e[0]} - (rc  + 1) - 1);
          }
          setOutput(result);
        }
      ` : this.userCode = `
        void main() {
          ${a} rc = getOutputCoords();
          vec4 result = vec4(0.);
          result.r = ${c(o.slice())};
          if(${r}){
            result.g = ${l(o.slice())};
          }
          if(${i}) {
            result.b = ${u(o.slice())};
            if(${r}) {
              result.a = ${d(o.slice())};
            }
          }
          setOutput(result);
        }
    `;
    function c(p) {
      return h(p);
    }
    function l(p) {
      return p[s - 1] = "(" + p[s - 1] + " + 1)", h(p);
    }
    function u(p) {
      return p[s - 2] = "(" + p[s - 2] + " + 1)", h(p);
    }
    function d(p) {
      return p[s - 1] = "(" + p[s - 1] + " + 1)", p[s - 2] = "(" + p[s - 2] + " + 1)", h(p);
    }
    function h(p) {
      const x = e.map((C, b) => f(b, p)), g = x.join(","), m = x.slice(-2).join(",");
      return `getChannel(getX(${g}), vec2(${m}))`;
    }
    function f(p, x) {
      return t.indexOf(p) !== -1 && e[p] !== 1 ? `${e[p]} - ${x[p]} - 1` : `${x[p]}`;
    }
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Tv(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { dims: r } = s, i = o.shape.length, a = de(r, o.shape);
  if (i === 0)
    return me({ inputs: { x: o }, backend: t });
  const c = y().getBool("WEBGL_PACK_ARRAY_OPERATIONS") ? new Rv(o.shape, a) : new Iv(o.shape, a);
  return t.runWebGLProgram(c, [o], o.dtype);
}
const Ev = {
  kernelName: xu,
  backendName: "webgl",
  kernelFunc: Tv
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Nv {
  constructor(e, t) {
    this.variableNames = ["Image"], this.outputShape = [], this.customUniforms = [{ name: "params", type: "vec4" }];
    const s = e[1], o = e[2];
    this.outputShape = e;
    let r = "";
    typeof t == "number" ? r = `float outputValue = ${t.toFixed(2)};` : r = `
        vec3 fill = vec3(${t.join(",")});
        float outputValue = fill[coords[3]];`, this.userCode = `
        void main() {
          ivec4 coords = getOutputCoords();
          int x = coords[2];
          int y = coords[1];
          float coordXFloat = (float(x) - params[0]) * params[3] -
            (float(y) - params[1]) * params[2];
          float coordYFloat = (float(x) - params[0]) * params[2] +
            (float(y) - params[1]) * params[3];
          int coordX = int(round(coordXFloat + params[0]));
          int coordY = int(round(coordYFloat + params[1]));
          ${r}
          if(coordX >= 0 && coordX < ${o} && coordY >= 0 && coordY < ${s}) {
            outputValue = getImage(coords[0], coordY, coordX, coords[3]);
          }
          setOutput(outputValue);
        }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const kv = {
  kernelName: sd,
  backendName: "webgl",
  kernelFunc: ({ inputs: n, attrs: e, backend: t }) => {
    const { image: s } = n, { radians: o, fillValue: r, center: i } = e, a = t, c = new Nv(s.shape, r), [l, u] = Ei(i, s.shape[1], s.shape[2]), d = [[l, u, Math.sin(o), Math.cos(o)]];
    return a.runWebGLProgram(c, [s], s.dtype, d);
  }
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Av = `
  // OpenGL ES does not support round function.
  // The algorithm is based on banker's rounding.
  float base = floor(x);
  if ((x - base) < 0.5) {
    return floor(x);
  } else if ((x - base) > 0.5) {
    return ceil(x);
  } else {
    if (mod(base, 2.0) == 0.0) {
      return base;
    } else {
      return base + 1.0;
    }
  }
`, Fv = _({ opSnippet: Av }), Dv = {
  kernelName: Cu,
  backendName: "webgl",
  kernelFunc: Fv
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Ov = "return inversesqrt(x);", Pv = _({ opSnippet: Ov, cpuKernelImpl: jg }), _v = {
  kernelName: bu,
  backendName: "webgl",
  kernelFunc: Pv
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class xo {
  constructor(e, t, s, o, r, i, a = !0, c = !1) {
    this.variableNames = ["updates", "indices", "defaultValue"], this.outputShape = i;
    const l = V(r.length), u = V(i.length);
    let d = "";
    s === 1 ? d = "i" : s === 2 && (d = "i, j");
    const h = `getIndices(${d})`;
    let f = "";
    o === 1 ? f = "i" : o === 2 && (f = "i, coords[1]");
    const p = `getUpdates(${f})`;
    let x = "";
    c && (x = "coords[0], coords[1]");
    const g = `getDefaultValue(${x})`, m = t > 1 ? "strides[j]" : "strides";
    this.userCode = `
        ${l} strides = ${l}(${r});

        void main() {
          ${u} coords = getOutputCoords();
          float sum = 0.0;
          bool found = false;
          for (int i = 0; i < ${e}; i++) {
            int flattenedIndex = 0;
            for (int j = 0; j < ${t}; j++) {
              int index = round(${h});
              flattenedIndex += index * ${m};
            }
            if (flattenedIndex == coords[0]) {
              sum += ${p};
              found = true;
            }
          }
          setOutput(mix(${g}, sum, float(found)));
        }
      `;
  }
}
/**
 * @license
 * Copyright 2023 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Lv {
  constructor(e, t, s, o, r, i, a = !0, c = !1) {
    this.variableNames = ["updates", "indices", "defaultValue"], this.packedInputs = !0, this.packedOutput = !0, this.outputShape = i;
    const l = V(r.length), u = V(i.length);
    let d = "";
    s === 1 ? d = "i" : s === 2 && (d = "i, j");
    const h = `getIndices(${d})`;
    let f = "";
    o === 1 ? f = "i" : o === 2 && (f = "i, coords[1]");
    const p = `getUpdates(${f})`;
    let x = "";
    c && (x = "coords[0], coords[1]");
    const g = `getDefaultValue(${x})`, m = t > 1 ? "strides[j]" : "strides", C = t > 1 ? "strides[j + 1]" : "strides";
    this.userCode = `
        ${l} strides = ${l}(${r});

        void main() {
          ${u} coords = getOutputCoords();
          vec4 sum = vec4(0.);
          vec4 found = vec4(0.);
          for (int i = 0; i < ${e}; i+=2) {
            ivec2 flattenedIndex = ivec2(0);
            for (int j = 0; j < ${t}; j+=2) {
              ivec4 index = round(${h});
              flattenedIndex += index.xz * ${m};
              if (j + 1 < ${t}) {
                flattenedIndex += index.yw * ${C};
              }
            }
            if (flattenedIndex[0] == coords[0] || flattenedIndex[1] == coords[0] ||
                flattenedIndex[0] == coords[0] + 1 || flattenedIndex[1] == coords[0] + 1) {
              vec4 updVals = ${p};
              if (flattenedIndex[0] == coords[0]) {
                sum.xy += updVals.xy;
                found.xy = vec2(1.);
              } else if (flattenedIndex[0] == coords[0] + 1) {
                sum.zw += updVals.xy;
                found.zw = vec2(1.);
              }
              if (flattenedIndex[1] == coords[0]) {
                sum.xy += updVals.zw;
                found.xy = vec2(1.);
              } else if (flattenedIndex[1] == coords[0] + 1) {
                sum.zw += updVals.zw;
                found.zw = vec2(1.);
              }
            }
          }
          setOutput(mix(${g}, sum, found));
        }
      `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Bv(n) {
  const { inputs: e, backend: t, attrs: s } = n, { indices: o, updates: r } = e, { shape: i } = s, { sliceRank: a, numUpdates: c, sliceSize: l, strides: u, outputSize: d } = Jn(r, o, i), h = [d / l, l];
  if (d === 0)
    return t.makeTensorInfo(i, o.dtype);
  const f = S({ inputs: { x: o }, backend: t, attrs: { shape: [c, a] } }), p = S({ inputs: { x: r }, backend: t, attrs: { shape: [c, l] } }), x = t.makeTensorInfo([], "float32", new Float32Array([0]));
  let g;
  y().getBool("WEBGL_PACK") ? g = new Lv(c, a, f.shape.length, p.shape.length, u, h) : g = new xo(c, a, f.shape.length, p.shape.length, u, h);
  const m = t.runWebGLProgram(g, [p, f, x], p.dtype), C = S({ inputs: { x: m }, backend: t, attrs: { shape: i } });
  return t.disposeIntermediateTensorInfo(f), t.disposeIntermediateTensorInfo(p), t.disposeIntermediateTensorInfo(m), t.disposeIntermediateTensorInfo(x), C;
}
const Mv = {
  kernelName: wu,
  backendName: "webgl",
  kernelFunc: Bv
};
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Vv {
  constructor(e, t, s, o) {
    this.variableNames = ["sortedSequence", "values"], this.customUniforms = [{ name: "numInputs", type: "int" }], this.outputShape = [e, s];
    const r = "while (left < right) {", i = `for (int i = 0; i < ${Math.ceil(Math.log2(t + 1))}; ++i) { if (left >= right) break;`, a = y().getNumber("WEBGL_VERSION") === 2 ? r : i, c = o === "left" ? "<" : "<=";
    this.userCode = `
       int findBound(int batch, float value) {
         int left = 0;
         int right = numInputs;
         int mid;
         ${a}
           mid = (left + right) / 2;
           if (getSortedSequence(batch, mid) ${c} value) {
             left = mid + 1;
           } else {
             right = mid;
           }
         }
         return right;
       }

       void main() {
         ivec2 coords = getOutputCoords();
         int batch = coords[0];
         int valueIndex = coords[1];

         float value = getValues(batch, valueIndex);

         setOutput(float(findBound(batch, value)));
       }
     `;
  }
}
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Uv(n) {
  const { inputs: e, backend: t, attrs: s } = n, { sortedSequence: o, values: r } = e, { side: i } = s, a = new Vv(o.shape[0], o.shape[1], r.shape[1], i), c = [[o.shape[1]]];
  return t.runWebGLProgram(a, [o, r], "int32", c);
}
const Wv = {
  kernelName: vu,
  backendName: "webgl",
  kernelFunc: Uv
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class Gv {
  constructor(e, t, s) {
    this.variableNames = ["c", "a", "b"], this.outputShape = t;
    let o, r;
    if (s > 4)
      throw Error(`Where for rank ${s} is not yet supported`);
    if (s === 1)
      r = "resRC", o = "resRC";
    else {
      const a = ["resRC.x", "resRC.y", "resRC.z", "resRC.w"], c = [], l = [];
      for (let u = 0; u < t.length; u++)
        l.push(`${a[u]}`), u < e && c.push(`${a[u]}`);
      o = c.join(), r = l.join();
    }
    const i = V(s);
    this.userCode = `
      void main() {
        ${i} resRC = getOutputCoords();
        float cVal = getC(${o});
        if (cVal >= 1.0) {
          setOutput(getA(${r}));
        } else {
          setOutput(getB(${r}));
        }
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function zv(n) {
  const { inputs: e, backend: t } = n, { condition: s, t: o, e: r } = e, i = new Gv(s.shape.length, o.shape, o.shape.length);
  return t.runWebGLProgram(i, [s, o, r], ze(o.dtype, r.dtype));
}
const Hv = {
  kernelName: $u,
  backendName: "webgl",
  kernelFunc: zv
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Xv = `
  // Stable and Attracting Fixed Point (0, 1) for Normalized Weights.
  // see: https://arxiv.org/abs/1706.02515
  float scaleAlpha = ${Ai};
  float scale = ${Fi};
  return (x >= 0.0) ? scale * x : scaleAlpha * (exp(x) - 1.0);
`, qv = _({ opSnippet: Xv }), jv = {
  kernelName: Su,
  backendName: "webgl",
  kernelFunc: qv
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Kv = nn + `
  return 1.0 / (1.0 + exp(-1.0 * x));
`, Yv = `
  vec4 result = 1.0 / (1.0 + exp(-1.0 * x));
  bvec4 isNaN = isnan(x);

  result.r = isNaN.r ? x.r : result.r;
  result.g = isNaN.g ? x.g : result.g;
  result.b = isNaN.b ? x.b : result.b;
  result.a = isNaN.a ? x.a : result.a;

  return result;
`, Qv = _({
  opSnippet: Kv,
  packedOpSnippet: Yv,
  cpuKernelImpl: Yg
}), Zv = {
  kernelName: Nu,
  backendName: "webgl",
  kernelFunc: Qv
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const Jv = `
  if (isnan(x)) { return 0.0; }
  return sign(x);
`, e$ = _({ opSnippet: Jv }), t$ = {
  kernelName: Eu,
  backendName: "webgl",
  kernelFunc: e$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const n$ = nn + `
  return sin(x);
`, s$ = `
  vec4 result = sin(x);
  bvec4 isNaN = isnan(x);
  ${Et}
  return result;
`, o$ = _({ opSnippet: n$, packedOpSnippet: s$ }), r$ = {
  kernelName: Ru,
  backendName: "webgl",
  kernelFunc: o$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const i$ = `
  float e2x = exp(x);
  return (e2x - 1.0 / e2x) / 2.0;
`, a$ = _({ opSnippet: i$ }), c$ = {
  kernelName: Tu,
  backendName: "webgl",
  kernelFunc: a$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const l$ = `
  float epsilon = 1.1920928955078125e-7;
  float threshold = log(epsilon) + 2.0;

  bool too_large = x > -threshold;
  bool too_small = x < threshold;

  float result;
  float exp_x = exp(x);

  if (too_large){
    result = x;
  }
  else if (too_small){
    result = exp_x;
  }
  else{
    result = log(exp_x + 1.0);
  }
  return result;
`, u$ = _({ opSnippet: l$ }), d$ = {
  kernelName: ku,
  backendName: "webgl",
  kernelFunc: u$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const h$ = (n) => {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { blockShape: r, paddings: i } = s;
  N(o.shape.length <= 4, () => "spaceToBatchND for rank > 4 with a WebGL backend not implemented yet");
  const a = r.reduce((m, C) => m * C), c = [[0, 0]];
  c.push(...i);
  for (let m = 1 + r.length; m < o.shape.length; ++m)
    c.push([0, 0]);
  const l = [], u = qa({
    inputs: { x: o },
    backend: t,
    attrs: { paddings: c, constantValue: 0 }
  }), d = ro(u.shape, r, a, !1), h = io(d.length, r.length, !1), f = ao(u.shape, r, a, !1), p = S({ inputs: { x: u }, backend: t, attrs: { shape: d } }), x = ae({
    inputs: { x: p },
    backend: t,
    attrs: { perm: h }
  }), g = S({ inputs: { x }, backend: t, attrs: { shape: f } });
  return l.push(u), l.push(p), l.push(x), l.forEach((m) => t.disposeIntermediateTensorInfo(m)), g;
}, f$ = {
  kernelName: Fu,
  backendName: "webgl",
  kernelFunc: h$
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function p$(n) {
  const { inputs: e, backend: t } = n, { indices: s, values: o, denseShape: r, defaultValue: i } = e;
  if (r.shape.length !== 1)
    throw new Error(`Dense shape must be a vector, saw:
         ${r.shape}`);
  if (s.shape.length !== 2)
    throw new Error(`Indices must be a matrix, saw:
         ${s.shape}`);
  if (o.shape.length !== 1)
    throw new Error(`Values must be a vector, saw:
         ${o.shape}`);
  if (i.shape.length !== 0)
    throw new Error(`Default value must be a scalar, saw:
        ${i.shape}`);
  const a = t.readSync(s.dataId), c = t.readSync(o.dataId), l = t.readSync(r.dataId), u = t.readSync(i.dataId)[0], [d, h, f, p, x] = Zg(a, s.shape, s.dtype, c, o.dtype, l, u);
  return [
    t.makeTensorInfo(h, s.dtype, d),
    t.makeTensorInfo([h[0]], o.dtype, f),
    t.makeTensorInfo([p.length], "bool", new Uint8Array(p.map((g) => Number(g)))),
    t.makeTensorInfo([x.length], s.dtype, new Int32Array(x))
  ];
}
const m$ = {
  kernelName: Pu,
  backendName: "webgl",
  kernelFunc: p$
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function g$(n) {
  const { inputs: e, backend: t } = n, { inputIndices: s, inputShape: o, newShape: r } = e;
  if (s.shape.length !== 2)
    throw new Error(`Input indices should be a matrix but received shape ${s.shape}`);
  if (o.shape.length !== 1)
    throw new Error(`Input shape should be a vector but received shape ${o.shape}`);
  if (r.shape.length !== 1)
    throw new Error(`Target shape should be a vector but received shape ${r.shape}`);
  const i = Array.from(t.readSync(o.dataId)), a = t.readSync(s.dataId), c = Array.from(t.readSync(r.dataId)), [l, u, d] = Jg(a, s.shape, s.dtype, i, c);
  return [
    t.makeTensorInfo(u, s.dtype, l),
    t.makeTensorInfo([d.length], r.dtype, new Int32Array(d))
  ];
}
const x$ = {
  kernelName: _u,
  backendName: "webgl",
  kernelFunc: g$
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function C$(n) {
  const { inputs: e, backend: t } = n, { data: s, indices: o, segmentIds: r } = e;
  if (s.shape.length < 1)
    throw new Error("Data should be at least 1 dimensional but received scalar");
  if (o.shape.length !== 1)
    throw new Error(`Indices should be a vector but received shape
              ${o.shape}`);
  if (r.shape.length !== 1)
    throw new Error(`Segment ids should be a vector but received shape
              ${r.shape}`);
  const i = t.readSync(s.dataId), a = t.readSync(o.dataId), c = t.readSync(r.dataId), [l, u] = Ca(i, s.shape, s.dtype, a, c, !0);
  return t.makeTensorInfo(u, s.dtype, l);
}
const b$ = {
  kernelName: Lu,
  backendName: "webgl",
  kernelFunc: C$
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function w$(n) {
  const { inputs: e, backend: t } = n, { data: s, indices: o, segmentIds: r } = e;
  if (s.shape.length < 1)
    throw new Error("Data should be at least 1 dimensional but received scalar");
  if (o.shape.length !== 1)
    throw new Error(`Indices should be a vector but received shape
             ${o.shape}`);
  if (r.shape.length !== 1)
    throw new Error(`Segment ids should be a vector but received shape
             ${r.shape}`);
  const i = t.readSync(s.dataId), a = t.readSync(o.dataId), c = t.readSync(r.dataId), [l, u] = Ca(i, s.shape, s.dtype, a, c);
  return t.makeTensorInfo(u, s.dtype, l);
}
const y$ = {
  kernelName: Bu,
  backendName: "webgl",
  kernelFunc: w$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function v$(n) {
  const { inputs: e, backend: t, attrs: s } = n, { sparseIndices: o, sparseValues: r, defaultValue: i } = e, { outputShape: a } = s, { sliceRank: c, numUpdates: l, sliceSize: u, strides: d, outputSize: h } = Jn(r, o, a), f = !1;
  if (r.dtype === "string") {
    const m = t.bufferSync(o), C = t.bufferSync(r), b = Vt(t.readSync(i.dataId)[0]), w = Kg(m, C, a, h, u, l, c, d, b, f);
    return t.makeTensorInfo(a, w.dtype, w.values);
  }
  const p = new xo(l, c, o.shape.length, r.shape.length, d, [h, 1], f), x = t.runWebGLProgram(p, [r, o, i], r.dtype), g = S({ inputs: { x }, backend: t, attrs: { shape: a } });
  return t.disposeIntermediateTensorInfo(x), g;
}
const $$ = {
  kernelName: Mu,
  backendName: "webgl",
  kernelFunc: v$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function S$(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { numOrSizeSplits: r, axis: i } = s, a = de(i, o.shape)[0], c = zi(o, r, a), l = o.shape.length, u = new Array(l).fill(0), d = o.shape.slice();
  return c.map((h) => {
    const f = [...d];
    f[a] = h;
    const p = sn({ inputs: { x: o }, backend: t, attrs: { begin: u, size: f } });
    return u[a] += h, p;
  });
}
const I$ = {
  kernelName: Du,
  backendName: "webgl",
  kernelFunc: S$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const br = "return sqrt(x);", R$ = _({ opSnippet: br, packedOpSnippet: br, cpuKernelImpl: ex }), T$ = {
  kernelName: Br,
  backendName: "webgl",
  kernelFunc: R$
};
/**
 * @license
 * Copyright 2019 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const E$ = "return x * x;", N$ = _({ opSnippet: E$ }), k$ = {
  kernelName: Uu,
  backendName: "webgl",
  kernelFunc: N$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const wr = "return (a - b) * (a - b);", A$ = ee({ opSnippet: wr, packedOpSnippet: wr }), F$ = {
  kernelName: Vu,
  backendName: "webgl",
  kernelFunc: A$
};
/**
 * @license
 * Copyright 2023 Google LLC.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function D$(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e;
  if (o.dtype !== "string")
    throw new Error("Input must be of datatype string");
  const r = t.readSync(o.dataId), i = Gt(r), a = tx(i, "string", s);
  return t.makeTensorInfo(o.shape, "string", a);
}
const O$ = {
  kernelName: Wu,
  backendName: "webgl",
  kernelFunc: D$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function P$({ inputs: n, attrs: e, backend: t }) {
  const { x: s } = n, o = ke + `
    return x > 0.0 ? 1.0 : float(${e.alpha});
  `, r = new Ue(s.shape, o);
  return t.runWebGLProgram(r, [s], s.dtype);
}
const _$ = {
  kernelName: td,
  backendName: "webgl",
  kernelFunc: P$
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class L$ {
  constructor(e, t, s) {
    this.variableNames = ["x"], this.outputShape = s;
    const o = s.length, r = V(s.length), i = V(s.length);
    let a = "";
    if (o === 1)
      a = "coords * strides + begin";
    else {
      let c = 0;
      a = s.map((l, u) => (c++, s.length === 1 ? `coords * strides[${u}] + begin[${u}]` : `coords[${c - 1}] * strides[${u}] + begin[${u}]`)).join(",");
    }
    this.userCode = `
      ${r} begin = ${r}(${e});
      ${r} strides = ${r}(${t});

      void main() {
        ${i} coords = getOutputCoords();
        setOutput(getX(${a}));
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function B$(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { begin: r, end: i, strides: a, beginMask: c, endMask: l, ellipsisMask: u, newAxisMask: d, shrinkAxisMask: h } = s, { finalShapeSparse: f, finalShape: p, isIdentity: x, sliceDim0: g, isSimpleSlice: m, begin: C, end: b, strides: w } = gf(o.shape, r, i, a, c, l, u, d, h);
  let v;
  if (x)
    v = S({ inputs: { x: o }, backend: t, attrs: { shape: p } });
  else if (g || m) {
    N(o.shape.length >= 1, () => `Input must have rank at least 1, got: ${o.shape.length}`);
    const R = pf(C, b, w), $ = sn({ inputs: { x: o }, backend: t, attrs: { begin: C, size: R } });
    v = S({ inputs: { x: $ }, backend: t, attrs: { shape: p } }), t.disposeIntermediateTensorInfo($);
  } else if (t.shouldExecuteOnCPU([o])) {
    const $ = t.readSync(o.dataId), F = J(o.shape, o.dtype, $), O = nx(f, F, w, C);
    v = t.makeTensorInfo(p, o.dtype, O.values);
  } else {
    const $ = new L$(C, w, f);
    v = t.runWebGLProgram($, [o], o.dtype);
  }
  const E = S({ inputs: { x: v }, backend: t, attrs: { shape: p } });
  return t.disposeIntermediateTensorInfo(v), E;
}
const M$ = {
  kernelName: Gu,
  backendName: "webgl",
  kernelFunc: B$
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function V$(n) {
  const { inputs: e, backend: t, attrs: s } = n, { separator: o, nGramWidths: r, leftPad: i, rightPad: a, padWidth: c, preserveShortSequences: l } = s, { data: u, dataSplits: d } = e, h = t.readSync(u.dataId), f = t.readSync(d.dataId), [p, x] = sx(h, f, o, r, i, a, c, l);
  return [
    t.makeTensorInfo([p.length], "string", p),
    t.makeTensorInfo(d.shape, "int32", x)
  ];
}
const U$ = {
  kernelName: zu,
  backendName: "webgl",
  kernelFunc: V$
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function W$(n) {
  const { inputs: e, backend: t, attrs: s } = n, { skipEmpty: o } = s, { input: r, delimiter: i } = e;
  if (r.dtype !== "string")
    throw new Error("Input must be of datatype string");
  if (r.shape.length !== 1)
    throw new Error(`Input must be a vector, got shape: ${r.shape}`);
  if (i.shape.length !== 0)
    throw new Error(`Delimiter must be a scalar, got shape: ${i.shape}`);
  const a = t.readSync(r.dataId), c = t.readSync(i.dataId)[0], [l, u, d] = ox(a, c, o), h = u.length;
  return [
    t.makeTensorInfo([h, 2], "int32", l),
    t.makeTensorInfo([h], "string", u),
    t.makeTensorInfo([2], "int32", new Int32Array(d))
  ];
}
const G$ = {
  kernelName: Hu,
  backendName: "webgl",
  kernelFunc: W$
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function z$(n) {
  const { inputs: e, backend: t, attrs: s } = n, { numBuckets: o } = s, { input: r } = e;
  if (r.dtype !== "string")
    throw new Error("Input must be of datatype string");
  if (o <= 0)
    throw new Error("Number of buckets must be at least 1");
  const i = t.readSync(r.dataId), a = rx(i, o);
  return t.makeTensorInfo(r.shape, "int32", a);
}
const H$ = {
  kernelName: Xu,
  backendName: "webgl",
  kernelFunc: z$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const X$ = "return tan(x);", q$ = _({ opSnippet: X$ }), j$ = {
  kernelName: qu,
  backendName: "webgl",
  kernelFunc: q$
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const K$ = `
  float e2x = exp(-2.0 * abs(x));
  return sign(x) * (1.0 - e2x) / (1.0 + e2x);
`, Y$ = _({ opSnippet: K$ }), Q$ = {
  kernelName: ju,
  backendName: "webgl",
  kernelFunc: Y$
};
/**
 * @license
 * Copyright 2022 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Z$(n) {
  const { inputs: e, backend: t, attrs: s } = n, { tensor: o, indices: r, updates: i } = e, { sliceRank: a, numUpdates: c, sliceSize: l, strides: u, outputSize: d } = Jn(i, r, o.shape), h = [d / l, l];
  if (d === 0)
    return t.makeTensorInfo(o.shape, r.dtype);
  const f = S({ inputs: { x: r }, backend: t, attrs: { shape: [c, a] } }), p = S({ inputs: { x: i }, backend: t, attrs: { shape: [c, l] } }), x = S({ inputs: { x: o }, backend: t, attrs: { shape: h } }), g = new xo(c, a, f.shape.length, p.shape.length, u, h, !1, !0), m = t.runWebGLProgram(g, [p, f, x], x.dtype), C = S({ inputs: { x: m }, backend: t, attrs: { shape: o.shape } });
  return t.disposeIntermediateTensorInfo(f), t.disposeIntermediateTensorInfo(p), t.disposeIntermediateTensorInfo(x), t.disposeIntermediateTensorInfo(m), C;
}
const J$ = {
  kernelName: yu,
  backendName: "webgl",
  kernelFunc: Z$
};
/**
 * @license
 * Copyright 2017 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class eS {
  constructor(e, t) {
    this.variableNames = ["A"];
    const s = new Array(e.length);
    for (let i = 0; i < s.length; i++)
      s[i] = e[i] * t[i];
    this.outputShape = s, this.rank = s.length;
    const o = V(this.rank), r = tS(e);
    this.userCode = `
      void main() {
        ${o} resRC = getOutputCoords();
        setOutput(getA(${r}));
      }
    `;
  }
}
function tS(n) {
  const e = n.length;
  if (e > 5)
    throw Error(`Tile for rank ${e} is not yet supported`);
  if (e === 1)
    return `imod(resRC, ${n[0]})`;
  const t = ["resRC.x", "resRC.y", "resRC.z", "resRC.w", "resRC.u"], s = [];
  for (let o = 0; o < n.length; o++)
    s.push(`imod(${t[o]}, ${n[o]})`);
  return s.join();
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function Ka(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { reps: r } = s;
  if (o.dtype === "string" || o.shape.length > 5) {
    const c = t.readSync(o.dataId), l = o.dtype === "string" ? c.map((h) => Vt(h)) : c, u = J(o.shape, o.dtype, l), d = ax(u, r);
    return t.makeTensorInfo(d.shape, d.dtype, d.values);
  }
  const i = new eS(o.shape, r);
  return t.runWebGLProgram(i, [o], o.dtype);
}
const nS = {
  kernelName: Vr,
  backendName: "webgl",
  kernelFunc: Ka
};
class sS {
  /**
   * @param shape desired output shape (can be larger than input shape, output
   *                                    will be padded with -Infinity)
   */
  constructor(e) {
    this.variableNames = ["x", "indices"], this.customUniforms = [
      { name: "n", type: "int" },
      { name: "firstPass", type: "int" },
      { name: "negativeInf", type: "float" },
      { name: "dir", type: "int" },
      { name: "inc", type: "int" }
    ], this.outputShape = e, this.userCode = `
       void main() {
         ivec2 coords = getOutputCoords();
         int batch = coords[0];
         int elemIdx = coords[1];

         // We compare elements pair-wise within a group of size 2 * inc.
         // The comparing rule for each group alternates between ascending
         // and descending. Within each group, we compare each pair at
         // positions i and i+inc. To decide whether an element at position i
         // is x0 or x1, we mod it by 2 * inc, if the result is smaller than
         // inc, it is in the first half of the group, we denote it as x0,
         // otherwise we denote it as x1.
         // For example, as shown in the Bitonic top K paper referenced above,
         // Figure5(a) shows that element[1] is in the
         // second half of the group when group size is 2, but it is in the
         // first half of the group when group size is 4.

         bool isFirstInPair = imod(elemIdx, 2 * inc) < inc;
         int i = isFirstInPair ? elemIdx : elemIdx - inc;

         int i0 = firstPass == 1 ? i : int(getIndices(batch, i));
         int i1 = firstPass == 1 ? i + inc : int(getIndices(batch, i + inc));
         float x0 = i0 < n ? getX(batch, i0) : negativeInf;
         float x1 = i1 < n ? getX(batch, i1) : negativeInf;

         // Denotes which direction indices are in (ascending or descending).
         bool reverse = imod(elemIdx, 2 * dir) >= dir;
         bool isGreater = x0 > x1 || (x0 == x1 && i1 > i0);
         if (reverse == isGreater) { // Elements in opposite order of direction
           int iTemp = i0;
           i0 = i1;
           i1 = iTemp;
         }
         if (isFirstInPair) {
            setOutput(float(i0));
         } else {
            setOutput(float(i1));
         }
       }
     `;
  }
}
class oS {
  /**
   * @param shape desired output shape (must be half of the input size)
   */
  constructor(e) {
    this.variableNames = ["x", "indices"], this.customUniforms = [
      { name: "n", type: "int" },
      { name: "firstPass", type: "int" },
      { name: "k", type: "int" }
    ], this.outputShape = e, this.userCode = `
    void main() {
         // Takes max of indices (0, k), (1, k + 1), (2, k + 2) ...
         ivec2 coords = getOutputCoords();
         int batch = coords[0];
         int elemIdx = coords[1];

         // The output size is half of the previous size.
         // If the previous sequence is | | | | _ _ _ _  | | | |  _ _ _ _ (k=4),
         // we only need to output the indices at positions |, the indices at
         // positions _ can be thrown away, see Figure5(b) After Phase 2
         // (Merge phase) in the Bitonic Top K paper referenced above.
         // For example, the paper shows we only need to output the orange bars.
         // The output sequence should look like this | | | | | | | |.
         // Because the sequence is halved, to map the output index back
         // to the previous sequence to find the corresponding value,
         // we need to double the index. When we double the index,
         // we basically interpolate a position, so 2i looks like
         // | _ | _ | _ | _ | _ | _ | _. We move the | to the first k position
         // of each 2k positions by - elemIdx % k. E.g. for output at
         // index 4,5,6,7, we want to get the corresponding element at
         // original index 8,9,10,11, for output at index 8,9,10,11,
         // we want to get the corresponding element at original index
         // 16,17,18,19, so on and so forth.

         int i = elemIdx < k ? elemIdx : (elemIdx * 2 - imod(elemIdx, k));
         int i0 = firstPass == 1 ? i : int(getIndices(batch, i));
         int i1 = firstPass == 1 ? i + k : int(getIndices(batch, i + k));

         float x0 = getX(batch, i0);
         float x1 = i1 < n ? getX(batch, i1) : x0;

         setOutput(x0 >= x1 ? float(i0) : float(i1));
       }
     `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function rt(n, e) {
  e !== null && n.disposeIntermediateTensorInfo(e);
}
function yr(n) {
  let e = 1;
  for (; e < n; )
    e *= 2;
  return e;
}
function rS(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o } = e, { k: r, sorted: i } = s, a = y().getNumber("TOPK_LAST_DIM_CPU_HANDOFF_SIZE_THRESHOLD"), c = y().getNumber("TOPK_K_CPU_HANDOFF_THRESHOLD"), l = o.shape, u = l[l.length - 1];
  if (t.shouldExecuteOnCPU([o]) || u < a || r > c) {
    const O = t.readSync(o.dataId), [L, B] = cx(O, l, o.dtype, r, i);
    return [
      t.makeTensorInfo(L.shape, L.dtype, L.values),
      t.makeTensorInfo(B.shape, B.dtype, B.values)
    ];
  }
  if (r === 0)
    return l[l.length - 1] = 0, [
      t.makeTensorInfo(l, o.dtype, []),
      t.makeTensorInfo(l, "int32", [])
    ];
  if (u === 1)
    return [
      o,
      Sn({ attrs: { shape: l, dtype: "int32", value: 0 }, backend: t })
    ];
  const d = t.texData.get(o.dataId), h = d !== null && d.isPacked, f = h ? t.unpackTensor(o) : o, x = T(l) / u, g = S({ inputs: { x: f }, attrs: { shape: [x, u] }, backend: t });
  h && rt(t, f);
  const m = yr(r), C = yr(u);
  let b = null;
  const w = () => b === null ? [g, g] : [g, b], v = (O, L, B) => {
    const he = w(), j = new sS(B), we = [[u], [b === null ? 1 : 0], [Number.NEGATIVE_INFINITY], [O], [L]], Ae = b;
    b = t.runWebGLProgram(j, he, "int32", we), rt(t, Ae);
  };
  for (let O = 1; O < m; O *= 2) {
    const L = O * 2;
    for (let B = O; B >= 1; B /= 2)
      v(L, B, [x, C]);
  }
  for (let O = C; O > m; O /= 2) {
    const L = w(), B = new oS([x, O / 2]), j = [[u], [b === null ? 1 : 0], [m]], te = b;
    b = t.runWebGLProgram(B, L, "int32", j), rt(t, te);
    const we = m / 2, Ae = we * 2;
    for (let se = we; se >= 1; se /= 2)
      v(Ae, se, b.shape);
  }
  let E = b;
  b = sn({ inputs: { x: b }, backend: t, attrs: { begin: 0, size: [x, r] } }), rt(t, E);
  let R = Ua({ inputs: { x: g, indices: b }, backend: t, attrs: { axis: 1, batchDims: 1 } });
  rt(t, g);
  const $ = l.slice(0, -1);
  $.push(r), E = b, b = S({ inputs: { x: b }, attrs: { shape: $ }, backend: t }), rt(t, E);
  const F = R;
  return R = S({ inputs: { x: R }, attrs: { shape: $ }, backend: t }), rt(t, F), [R, b];
}
const iS = {
  kernelName: Ku,
  backendName: "webgl",
  kernelFunc: rS
};
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class aS {
  constructor(e, t, s, o, r, i) {
    this.variableNames = ["Image", "Transforms"], this.outputShape = i;
    const a = s === "nearest" ? 1 : 2;
    let c;
    switch (o) {
      case "constant":
        c = 1;
        break;
      case "reflect":
        c = 2;
        break;
      case "wrap":
        c = 3;
        break;
      case "nearest":
        c = 4;
        break;
      default:
        c = 1;
        break;
    }
    this.userCode = `
            float mapCoord(float outCoord, float len) {
              float inCoord = outCoord;
              if(${c} == 2) {
                if (inCoord < 0.0) {
                  if (len <= 1.0) {
                    inCoord = 0.0;
                  } else {
                    float sz2 = 2.0 * len;
                    if (inCoord < sz2) {
                      inCoord = sz2 * float(int(float(-inCoord / sz2))) +
                      inCoord;
                    }
                    inCoord = inCoord < -len ? inCoord + sz2 : -inCoord - 1.0;
                  }
                } else if (inCoord > len - 1.0) {
                  if (len <= 1.0) {
                    inCoord = 0.0;
                  } else {
                    float sz2 = 2.0 * len;
                    inCoord -= sz2 * float(int(float(inCoord / sz2)));
                    if (inCoord >= len) {
                      inCoord = sz2 - inCoord - 1.0;
                    }
                  }
                }
                return clamp(inCoord, 0.0, len - 1.0);
              } else if (${c} == 3) {
                if (inCoord < 0.0) {
                  if (len <= 1.0) {
                    inCoord = 0.0;
                  } else {
                    float sz = len - 1.0;
                    inCoord += len * (float(int(float(-inCoord / sz))) + 1.0);
                  }
                } else if (inCoord > len - 1.0) {
                  if (len <= 1.0) {
                    inCoord = 0.0;
                  } else {
                    float sz = len - 1.0;
                    inCoord -= len * float(int(float(inCoord / sz)));
                  }
                }
                return clamp(inCoord, 0.0, len - 1.0);
              } else if (${c} == 4) {
                return clamp(outCoord, 0.0, len - 1.0);
              } else {
                return outCoord;
              }
            }

            float readWithFillValue(int batch, int coordY, int coordX,
              int channel) {
              float outputValue;
              if (0 <= coordY && coordY < ${e} && 0 <= coordX && coordX < ${t}) {
                  outputValue = getImage(batch, coordY, coordX, channel);
              } else {
                outputValue = float(${r});
              }
              return outputValue;
            }

            void main() {
              ivec4 coords = getOutputCoords();
              float outputValue;
              int batch = coords[0];
              int x = coords[2];
              int y = coords[1];
              int channel = coords[3];
              float xf = float(x);
              float yf = float(y);
              float a1 = getTransforms(batch, 0);
              float a2 = getTransforms(batch, 1);
              float a3 = getTransforms(batch, 2);
              float b1 = getTransforms(batch, 3);
              float b2 = getTransforms(batch, 4);
              float b3 = getTransforms(batch, 5);
              float c1 = getTransforms(batch, 6);
              float c2 = getTransforms(batch, 7);
              float projection = c1 * xf + c2 * yf + 1.0;
              if (projection == 0.0) {
                outputValue = float(${r});
              } else {
                float inX = (a1 * xf + a2 * yf + a3) / projection;
                float inY = (b1 * xf + b2 * yf + b3) / projection;
                float mapX = mapCoord(inX, float(${t}));
                float mapY = mapCoord(inY, float(${e}));

                if (${a} == 1) {
                  int coordY = int(round(mapY));
                  int coordX = int(round(mapX));
                  outputValue = readWithFillValue(batch, coordY, coordX,
                    channel);
                } else {
                  float yFloor = floor(mapY);
                  float xFloor = floor(mapX);
                  float yCeil = yFloor + 1.0;
                  float xCeil = xFloor + 1.0;
                  float valueYFloor = (xCeil - mapX) *
                  readWithFillValue(batch, int(yFloor), int(xFloor), channel) +
                  (mapX - xFloor) *
                  readWithFillValue(batch, int(yFloor), int(xCeil), channel);
                  float valueYCeil = (xCeil - mapX) *
                  readWithFillValue(batch, int(yCeil), int(xFloor), channel) +
                  (mapX - xFloor) *
                  readWithFillValue(batch, int(yCeil), int(xCeil), channel);
                  outputValue = (yCeil - mapY) * valueYFloor +
                  (mapY - yFloor) * valueYCeil;
                }
              }
              setOutput(outputValue);
            }
        `;
  }
}
/**
 * @license
 * Copyright 2021 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function cS(n) {
  const { inputs: e, backend: t, attrs: s } = n, { image: o, transforms: r } = e, { interpolation: i, fillMode: a, fillValue: c, outputShape: l } = s, [u, d, h, f] = o.shape, [p, x] = l ?? [d, h], g = [
    u,
    p,
    x,
    f
  ], m = new aS(d, h, i, a, c, g);
  return t.runWebGLProgram(m, [o, r], "float32");
}
const lS = {
  kernelName: Yu,
  backendName: "webgl",
  kernelFunc: cS
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the License);
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an AS IS BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function uS(n) {
  const { inputs: e, attrs: t, backend: s } = n, { axis: o } = t, { x: r } = e;
  yn(r, "unique"), console.warn("WARNING: ", "UI might be locked temporarily as data is being downloaded");
  const i = s.readSync(r.dataId), { outputValues: a, outputShape: c, indices: l } = lx(i, o, r.shape, r.dtype);
  return [
    s.makeTensorInfo(c, r.dtype, a),
    s.makeTensorInfo([l.length], "int32", l)
  ];
}
const dS = {
  kernelName: Zu,
  backendName: "webgl",
  kernelFunc: uS
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function hS(n) {
  const { inputs: e, backend: t, attrs: s } = n, { value: o } = e;
  let { axis: r } = s;
  r < 0 && (r += o.shape.length);
  const i = o, a = i.shape.length, c = o.shape[r], l = new Array(a - 1);
  let u = 0;
  for (let x = 0; x < a; x++)
    x !== r && (l[u++] = i.shape[x]);
  const d = [], h = new Array(a).fill(0), f = i.shape.slice();
  f[r] = 1;
  const p = new Array(c);
  for (let x = 0; x < p.length; x++) {
    h[r] = x;
    const g = sn({ inputs: { x: i }, backend: t, attrs: { begin: h, size: f } }), m = S({ inputs: { x: g }, backend: t, attrs: { shape: l } });
    p[x] = m, d.push(g);
  }
  return d.forEach((x) => t.disposeIntermediateTensorInfo(x)), p;
}
const fS = {
  kernelName: Ju,
  backendName: "webgl",
  kernelFunc: hS
};
/**
 * @license
 * Copyright 2018 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
class pS {
  constructor(e, t) {
    this.variableNames = ["x", "segmentIds"];
    const s = e.windowSize, o = e.batchSize, r = e.inSize, i = e.numSegments, a = i * Math.ceil(r / s);
    this.outputShape = [o, a];
    const c = "0.0", l = "sumValue", u = Math.floor(s / 4) * 4, d = s % 4, h = `
        sumValue += dot(values, segFilter);
    `;
    let f = "";
    r % s > 0 && (f = `
        if (inIdx < 0 || inIdx >= ${r}) {
          return initializationValue;
        }
      `);
    let p = "";
    r % s > 0 && (p = `
        if (inIdx < 0 || inIdx >= ${r}) {
          return -1.0;
        }
      `), this.userCode = `
      const float initializationValue = ${c};

      float getValue(int batch, int inIdx) {
        ${f}
        return getX(batch, inIdx);
      }

      float getSegmentIdAtIndex(int inIdx) {
        ${p}
        return getSegmentIds(inIdx);
      }

      void main() {
        ivec2 coords = getOutputCoords();
        int batch = coords[0];
        int outIdx = coords[1];
        int inOffset = int(floor(float(outIdx) / float(
          ${i})) * float(${s}));
        int currentSeg = int(mod(float(outIdx), float(${i})));

        float sumValue = 0.0;

        for (int i = 0; i < ${u}; i += 4) {
          int inIdx = inOffset + i;
          vec4 values = vec4(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1),
            getValue(batch, inIdx + 2),
            getValue(batch, inIdx + 3)
          );

          vec4 segFilter = vec4(
            int(getSegmentIdAtIndex(inIdx)) == currentSeg ? 1 : 0,
            int(getSegmentIdAtIndex(inIdx + 1)) == currentSeg ? 1 : 0,
            int(getSegmentIdAtIndex(inIdx + 2)) == currentSeg ? 1 : 0,
            int(getSegmentIdAtIndex(inIdx + 3)) == currentSeg ? 1 : 0
          );

          ${h}
        }

        int inIdx = inOffset + ${u};
        if (${d === 1}) {
          vec4 values = vec4(
            getValue(batch, inIdx),
            initializationValue,
            initializationValue,
            initializationValue
          );

          int inIdxSeg = int(getSegmentIdAtIndex(inIdx));

          vec4 segFilter = vec4(
            int(getSegmentIdAtIndex(inIdx)) == currentSeg ? 1 : 0,
            0,
            0,
            0
          );

          ${h}
        } else if (${d === 2}) {
          vec4 values = vec4(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1),
            initializationValue,
            initializationValue
          );

          vec4 segFilter = vec4(
            int(getSegmentIdAtIndex(inIdx)) == currentSeg ? 1 : 0,
            int(getSegmentIdAtIndex(inIdx + 1)) == currentSeg ? 1 : 0,
              0,
              0
          );

          ${h}
        } else if (${d === 3}) {
          vec4 values = vec4(
            getValue(batch, inIdx),
            getValue(batch, inIdx + 1),
            getValue(batch, inIdx + 2),
            initializationValue
          );

          vec4 segFilter = vec4(
            int(getSegmentIdAtIndex(inIdx)) == currentSeg ? 1 : 0,
            int(getSegmentIdAtIndex(inIdx + 1)) == currentSeg ? 1 : 0,
            int(getSegmentIdAtIndex(inIdx + 2)) == currentSeg ? 1 : 0,
            0
          );

          ${h}
        }
        setOutput(${l});
      }
    `;
  }
}
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
function mS(n) {
  const { inputs: e, backend: t, attrs: s } = n, { x: o, segmentIds: r } = e, { numSegments: i } = s, a = o.shape.length, c = [];
  let l = 0;
  const u = Ee([l], a);
  let d = o;
  u != null && (d = ae({ inputs: { x: o }, backend: t, attrs: { perm: u } }), c.push(d), l = Ne(1, a)[0]);
  const h = $f(d.shape, l, i), f = T([d.shape[l]]), p = S({ inputs: { x: d }, backend: t, attrs: { shape: [-1, f] } });
  c.push(p);
  const x = Qs(o.dtype), g = (w, v, E, R, $) => {
    const F = w.shape[0], O = w.shape[1], L = vf(O, $), B = { windowSize: L, inSize: O, batchSize: F, numSegments: $ }, he = new pS(B, v), j = t.compileAndRun(he, [w, E], R);
    if (c.push(j), j.shape[1] === $)
      return j;
    const te = ja({
      backend: t,
      attrs: { start: 0, stop: $, step: 1, dtype: "float32" }
    }), we = Ka({
      inputs: { x: te },
      backend: t,
      attrs: { reps: [O / L] }
    });
    return c.push(te), c.push(we), g(j, v, we, R, $);
  }, m = g(p, "unsortedSegmentSum", r, x, i), C = S({ inputs: { x: m }, backend: t, attrs: { shape: h } });
  let b = C;
  if (u != null) {
    c.push(C);
    const w = to(u);
    b = ae({ inputs: { x: b }, backend: t, attrs: { perm: w } });
  }
  return c.forEach((w) => t.disposeIntermediateTensorInfo(w)), b;
}
const gS = {
  kernelName: ed,
  backendName: "webgl",
  kernelFunc: mS
};
/**
 * @license
 * Copyright 2020 Google LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 * =============================================================================
 */
const xS = [
  e0,
  n0,
  r0,
  c0,
  u0,
  f0,
  m0,
  x0,
  y0,
  $0,
  R0,
  N0,
  F0,
  _0,
  M0,
  U0,
  G0,
  q0,
  K0,
  Q0,
  tC,
  cC,
  uC,
  pC,
  gC,
  vC,
  SC,
  EC,
  Lx,
  AC,
  _C,
  VC,
  XC,
  KC,
  QC,
  JC,
  tb,
  rb,
  cb,
  db,
  fb,
  mb,
  xb,
  wb,
  vb,
  Rb,
  Eb,
  Ab,
  Ob,
  _b,
  Vb,
  zb,
  jb,
  Qb,
  ew,
  tw,
  sw,
  rw,
  aw,
  lw,
  dw,
  mw,
  Cw,
  yw,
  $w,
  Rw,
  Nw,
  Dw,
  Lw,
  _x,
  Mw,
  OC,
  Ww,
  Hw,
  jw,
  Mx,
  Zw,
  n1,
  o1,
  c1,
  d1,
  m1,
  C1,
  v1,
  R1,
  N1,
  A1,
  P1,
  L1,
  M1,
  G1,
  H1,
  q1,
  K1,
  Q1,
  ty,
  ry,
  ly,
  xy,
  Wx,
  yy,
  Sy,
  Ty,
  ky,
  CC,
  Dy,
  Py,
  Ly,
  Vy,
  zy,
  Ux,
  Xy,
  jy,
  Yy,
  Zy,
  Jy,
  bC,
  fy,
  nv,
  iv,
  uv,
  zx,
  pv,
  xv,
  yv,
  Sv,
  Ev,
  kv,
  Dv,
  _v,
  Mv,
  Wv,
  Hv,
  jv,
  Zv,
  t$,
  r$,
  c$,
  iC,
  my,
  d$,
  f$,
  m$,
  x$,
  b$,
  y$,
  $$,
  I$,
  T$,
  k$,
  F$,
  O$,
  _$,
  M$,
  U$,
  G$,
  H$,
  py,
  Qx,
  j$,
  Q$,
  J$,
  nS,
  iS,
  lS,
  Zx,
  dS,
  fS,
  gS,
  Oy
];
for (const n of xS)
  cd(n);
export {
  vS as _,
  CS as d,
  bS as m,
  yS as r,
  wS as s
};
