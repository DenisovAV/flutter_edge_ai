// Softmax regression on frozen embeddings — the `linear` decider method — and
// the optimiser that fits it.
//
// The reference is the decision measurements' `dq1.py` (`fit_linear`): weights
// and bias start at zero, the loss is the mean cross-entropy plus
// `decay · ‖W‖²` (bias not decayed), minimised by PyTorch's L-BFGS with
// lr 1, max_iter 500, history 20 and the strong-Wolfe line search. The
// optimiser below is a line-by-line port of `torch/optim/lbfgs.py` (torch
// 2.x: `_cubic_interpolate`, `_strong_wolfe`, `LBFGS.step`) in float64, so a
// fit here follows the reference's path up to summation order.
//
// Memory: the L-BFGS history holds 20 pairs of parameter-sized vectors, so
// about 2 · 20 · (d·C + C) · 8 bytes — 37 MB at d = 768 and 150 options,
// ~0.5 GB at 2000 — allocated once as it fills and then reused as a ring.
// Each objective evaluation allocates one gradient (kept by the line search).
//
// Every loop over rows, and the two-loop recursion over the history, asks a
// [FitPacer] whether to pause, so the fit can share a thread (web); without
// one it never awaits.

import 'dart:math' as math;
import 'dart:typed_data';

import 'dense_kernel.dart';
import 'fit_pacer.dart';

/// The fitted layer: `logits = x · W + b`.
final class SoftmaxFit {
  const SoftmaxFit({
    required this.weights,
    required this.bias,
    required this.loss,
    required this.iterations,
    required this.evaluations,
  });

  /// d × C row-major: `weights[j * C + c]`.
  final Float64List weights;

  /// C entries.
  final Float64List bias;

  /// The objective at the returned parameters.
  final double loss;

  /// L-BFGS iterations and objective evaluations spent.
  final int iterations;
  final int evaluations;
}

/// Fits softmax regression on [x] (n × d row-major) and [labels] (each in
/// [0, classes)), weight decay [decay].
Future<SoftmaxFit> fitSoftmaxRegression({
  required Float64List x,
  required Int32List labels,
  required int dimension,
  required int classes,
  double decay = 1e-5,
  int maxIter = 500,
  int historySize = 20,
  bool? simd,
  FitPacer? pacer,
}) async {
  final objective = SoftmaxObjective(
    x: x,
    labels: labels,
    dimension: dimension,
    classes: classes,
    decay: decay,
    simd: simd,
  );
  final theta = Float64List(objective.parameterCount);
  final result = await minimizeLbfgs(
    (at, grad) => objective.evaluate(at, grad, pacer: pacer),
    theta,
    maxIter: maxIter,
    historySize: historySize,
    pacer: pacer,
  );
  final wCount = dimension * classes;
  return SoftmaxFit(
    weights: Float64List.sublistView(theta, 0, wCount),
    bias: Float64List.sublistView(theta, wCount),
    loss: result.loss,
    iterations: result.iterations,
    evaluations: result.evaluations,
  );
}

/// Mean cross-entropy of `softmax(x · W + b)` plus `decay · ‖W‖²`, and its
/// gradient. Parameters are flat: W (d × C row-major), then b (C).
final class SoftmaxObjective {
  SoftmaxObjective({
    required this.x,
    required this.labels,
    required this.dimension,
    required this.classes,
    required this.decay,
    bool? simd,
  }) : _kernel = DenseKernel(d: dimension, columns: classes, simd: simd) {
    if (labels.isEmpty || x.length != labels.length * dimension) {
      throw ArgumentError('x must hold one row of $dimension per label');
    }
    _w = _kernel.matrix();
    _g = _kernel.matrix();
    _z = _kernel.row();
    _r = _kernel.row();
  }

  final Float64List x;
  final Int32List labels;
  final int dimension;
  final int classes;
  final double decay;
  final DenseKernel _kernel;

  late final Float64List _w;
  late final Float64List _g;
  late final Float64List _z;
  late final Float64List _r;

  int get parameterCount => dimension * classes + classes;

  /// The objective at [theta]; writes its gradient into [grad]. Asks [pacer]
  /// after every row.
  Future<double> evaluate(
    Float64List theta,
    Float64List grad, {
    FitPacer? pacer,
  }) async {
    _load(theta);
    if (pauseFor(pacer) case final turn?) await turn;
    final gb = Float64List(classes);
    final n = labels.length;
    var loss = 0.0;
    for (var i = 0; i < n; i++) {
      loss += _row(i, theta, gb);
      if (pauseFor(pacer) case final turn?) await turn;
    }
    final penalty = _gradient(theta, grad, gb);
    return loss / n + decay * penalty;
  }

  /// W into the padded kernel matrix; the gradient accumulator cleared.
  void _load(Float64List theta) {
    final d = dimension, c = classes, cp = _kernel.cp;
    final w = _w;
    for (var j = 0; j < d; j++) {
      for (var k = 0; k < c; k++) {
        w[j * cp + k] = theta[j * c + k];
      }
    }
    _g.fillRange(0, _g.length, 0);
  }

  /// Row [i]'s cross-entropy; adds its gradient to the accumulator and [gb].
  double _row(int i, Float64List theta, Float64List gb) {
    final d = dimension, c = classes;
    final n = labels.length;
    final z = _z, r = _r;
    final biasAt = d * c;
    final xo = i * d;
    _kernel.multiply(x, xo, _w, z);
    var m = double.negativeInfinity;
    for (var k = 0; k < c; k++) {
      final v = z[k] + theta[biasAt + k];
      z[k] = v;
      if (v > m) m = v;
    }
    var sum = 0.0;
    for (var k = 0; k < c; k++) {
      final e = math.exp(z[k] - m);
      r[k] = e;
      sum += e;
    }
    final y = labels[i];
    final loss = m + math.log(sum) - z[y];
    for (var k = 0; k < c; k++) {
      final v = (r[k] / sum - (k == y ? 1.0 : 0.0)) / n;
      r[k] = v;
      gb[k] += v;
    }
    _kernel.addOuter(x, xo, r, _g);
    return loss;
  }

  /// The full gradient into [grad]; returns ‖W‖².
  double _gradient(Float64List theta, Float64List grad, Float64List gb) {
    final d = dimension, c = classes, cp = _kernel.cp;
    final g = _g;
    final biasAt = d * c;
    var penalty = 0.0;
    for (var j = 0; j < d; j++) {
      for (var k = 0; k < c; k++) {
        final wv = theta[j * c + k];
        penalty += wv * wv;
        grad[j * c + k] = g[j * cp + k] + 2 * decay * wv;
      }
    }
    for (var k = 0; k < c; k++) {
      grad[biasAt + k] = gb[k];
    }
    return penalty;
  }
}

/// What [minimizeLbfgs] ended with.
final class LbfgsResult {
  const LbfgsResult(this.loss, this.iterations, this.evaluations);
  final double loss;
  final int iterations;
  final int evaluations;
}

/// An objective: its value at `x`, its gradient written into `grad`.
typedef LbfgsObjective =
    Future<double> Function(Float64List x, Float64List grad);

/// `torch.optim.LBFGS(..., line_search_fn="strong_wolfe").step(closure)`,
/// minimising [evaluate] from [x] in place. [pacer] is asked between the
/// history entries of the two-loop recursion (and by [evaluate], if it
/// takes one).
Future<LbfgsResult> minimizeLbfgs(
  LbfgsObjective evaluate,
  Float64List x, {
  double lr = 1,
  int maxIter = 500,
  int? maxEval,
  double toleranceGrad = 1e-7,
  double toleranceChange = 1e-9,
  int historySize = 20,
  FitPacer? pacer,
}) async {
  final maxEvals = maxEval ?? maxIter * 5 ~/ 4;
  final size = x.length;
  var flatGrad = Float64List(size);
  var loss = await evaluate(x, flatGrad);
  var currentEvals = 1;
  if (_maxAbs(flatGrad) <= toleranceGrad) {
    return LbfgsResult(loss, 0, currentEvals);
  }

  // The search direction. torch's `q` becomes `d`; one buffer serves both,
  // since `s` (from the previous `d`) is computed before `q` is.
  final d = Float64List(size);
  var t = 0.0;
  final history = _History(historySize, size);
  var hDiag = 1.0;
  final prevFlatGrad = Float64List(size);
  var prevLoss = loss;
  final al = Float64List(historySize);
  final at = Float64List(size);

  // Between two pauses runs at most a couple of parameter-sized vector
  // operations (a few ms in a release web build at 2000 options).
  var nIter = 0;
  while (nIter < maxIter) {
    if (pauseFor(pacer) case final turn?) await turn;
    nIter++;
    if (nIter == 1) {
      for (var i = 0; i < size; i++) {
        d[i] = flatGrad[i] * -1;
      }
      hDiag = 1;
    } else {
      final y = history.nextDir;
      final s = history.nextStep;
      for (var i = 0; i < size; i++) {
        y[i] = flatGrad[i] - prevFlatGrad[i];
        s[i] = d[i] * t;
      }
      final ys = _dot(y, s);
      if (ys > 1e-10) {
        history.push(1.0 / ys);
        hDiag = ys / _dot(y, y);
      }
      if (pauseFor(pacer) case final turn?) await turn;
      final numOld = history.length;
      for (var i = 0; i < size; i++) {
        d[i] = flatGrad[i] * -1;
      }
      for (var i = numOld - 1; i >= 0; i--) {
        al[i] = _dot(history.step(i), d) * history.ro(i);
        _axpy(d, -al[i], history.dir(i));
        if (pauseFor(pacer) case final turn?) await turn;
      }
      for (var i = 0; i < size; i++) {
        d[i] = d[i] * hDiag;
      }
      for (var i = 0; i < numOld; i++) {
        final beI = _dot(history.dir(i), d) * history.ro(i);
        _axpy(d, al[i] - beI, history.step(i));
        if (pauseFor(pacer) case final turn?) await turn;
      }
    }
    prevFlatGrad.setAll(0, flatGrad);
    prevLoss = loss;

    if (nIter == 1) {
      var sumAbs = 0.0;
      for (final v in flatGrad) {
        sumAbs += v.abs();
      }
      t = math.min(1.0, 1.0 / sumAbs) * lr;
    } else {
      t = lr;
    }

    final gtd = _dot(flatGrad, d);
    if (gtd > -toleranceChange) break;
    if (pauseFor(pacer) case final turn?) await turn;

    final ls = await _strongWolfe(
      evaluate,
      x,
      t,
      d,
      loss,
      flatGrad,
      gtd,
      at,
      pacer,
      toleranceChange: toleranceChange,
      maxLs: maxEvals - currentEvals,
    );
    loss = ls.f;
    flatGrad = ls.g;
    t = ls.t;
    _axpy(x, t, d);
    if (pauseFor(pacer) case final turn?) await turn;
    final optCond = _maxAbs(flatGrad) <= toleranceGrad;
    currentEvals += ls.evals;

    if (nIter == maxIter) break;
    if (currentEvals >= maxEvals) break;
    if (optCond) break;
    if (_maxAbs(d) * t.abs() <= toleranceChange) break;
    if ((loss - prevLoss).abs() < toleranceChange) break;
  }
  return LbfgsResult(loss, nIter, currentEvals);
}

/// torch's `old_dirs`, `old_stps` and `ro`, oldest first, as a ring of at
/// most [capacity] pairs: the vectors are allocated while the history fills
/// and reused after, never one pair per iteration.
final class _History {
  _History(this.capacity, this.size)
    : _ro = Float64List(capacity),
      nextDir = Float64List(size),
      nextStep = Float64List(size);

  final int capacity;
  final int size;
  final _dirs = <Float64List>[];
  final _steps = <Float64List>[];
  final Float64List _ro;
  int _start = 0;

  /// How many pairs are held.
  int length = 0;

  /// Where the next `y` and `s` are computed; [push] keeps them.
  Float64List nextDir;
  Float64List nextStep;

  /// Keeps [nextDir] and [nextStep] with `ro` [ro] as the newest pair,
  /// dropping the oldest when full; the buffers it drops (or new ones while
  /// filling) become the next [nextDir] and [nextStep].
  void push(double ro) {
    if (length < capacity) {
      _dirs.add(nextDir);
      _steps.add(nextStep);
      _ro[length] = ro;
      length++;
      nextDir = Float64List(size);
      nextStep = Float64List(size);
      return;
    }
    final oldest = _start;
    final freedDir = _dirs[oldest];
    final freedStep = _steps[oldest];
    _dirs[oldest] = nextDir;
    _steps[oldest] = nextStep;
    _ro[oldest] = ro;
    nextDir = freedDir;
    nextStep = freedStep;
    _start = (_start + 1) % capacity;
  }

  /// Pair [i], 0 the oldest.
  Float64List dir(int i) => _dirs[(_start + i) % capacity];
  Float64List step(int i) => _steps[(_start + i) % capacity];
  double ro(int i) => _ro[(_start + i) % capacity];
}

typedef _Eval = ({double f, Float64List g});

/// The objective at `x + t·d`, evaluated at [at] (overwritten). The gradient
/// is a new list: the line search keeps it.
Future<_Eval> _directional(
  LbfgsObjective evaluate,
  Float64List x,
  double t,
  Float64List d,
  Float64List at,
  FitPacer? pacer,
) async {
  for (var i = 0; i < x.length; i++) {
    at[i] = x[i] + t * d[i];
  }
  if (pauseFor(pacer) case final turn?) await turn;
  final g = Float64List(x.length);
  final f = await evaluate(at, g);
  return (f: f, g: g);
}

/// torch's `_strong_wolfe`. No gradient here is ever written after it is
/// made, so the brackets hold them without torch's defensive clones.
Future<({double f, Float64List g, double t, int evals})> _strongWolfe(
  LbfgsObjective evaluate,
  Float64List x,
  double t,
  Float64List d,
  double f,
  Float64List g,
  double gtd,
  Float64List at,
  FitPacer? pacer, {
  double c1 = 1e-4,
  double c2 = 0.9,
  double toleranceChange = 1e-9,
  int maxLs = 25,
}) async {
  final dNorm = _maxAbs(d);
  var (f: fNew, g: gNew) = await _directional(evaluate, x, t, d, at, pacer);
  var lsFuncEvals = 1;
  var gtdNew = _dot(gNew, d);

  var tPrev = 0.0, fPrev = f, gtdPrev = gtd;
  var gPrev = g;
  var done = false;
  var lsIter = 0;
  var bracket = <double>[];
  var bracketF = <double>[];
  var bracketG = <Float64List>[];
  var bracketGtd = <double>[];
  while (lsIter < maxLs) {
    if (fNew > (f + c1 * t * gtd) || (lsIter > 1 && fNew >= fPrev)) {
      bracket = [tPrev, t];
      bracketF = [fPrev, fNew];
      bracketG = [gPrev, gNew];
      bracketGtd = [gtdPrev, gtdNew];
      break;
    }
    if (gtdNew.abs() <= -c2 * gtd) {
      bracket = [t];
      bracketF = [fNew];
      bracketG = [gNew];
      done = true;
      break;
    }
    if (gtdNew >= 0) {
      bracket = [tPrev, t];
      bracketF = [fPrev, fNew];
      bracketG = [gPrev, gNew];
      bracketGtd = [gtdPrev, gtdNew];
      break;
    }
    final minStep = t + 0.01 * (t - tPrev);
    final maxStep = t * 10;
    final tmp = t;
    t = _cubicInterpolate(
      tPrev,
      fPrev,
      gtdPrev,
      t,
      fNew,
      gtdNew,
      boundMin: minStep,
      boundMax: maxStep,
    );
    tPrev = tmp;
    fPrev = fNew;
    gPrev = gNew;
    gtdPrev = gtdNew;
    (f: fNew, g: gNew) = await _directional(evaluate, x, t, d, at, pacer);
    lsFuncEvals++;
    gtdNew = _dot(gNew, d);
    lsIter++;
  }

  if (lsIter == maxLs) {
    bracket = [0, t];
    bracketF = [f, fNew];
    bracketG = [g, gNew];
  }

  var insufProgress = false;
  var (lowPos, highPos) = bracketF.first <= bracketF.last ? (0, 1) : (1, 0);
  while (!done && lsIter < maxLs) {
    if ((bracket[1] - bracket[0]).abs() * dNorm < toleranceChange) break;

    t = _cubicInterpolate(
      bracket[0],
      bracketF[0],
      bracketGtd[0],
      bracket[1],
      bracketF[1],
      bracketGtd[1],
    );

    final hi = _pyMax(bracket[0], bracket[1]);
    final lo = _pyMin(bracket[0], bracket[1]);
    final eps = 0.1 * (hi - lo);
    if (_pyMin(hi - t, t - lo) < eps) {
      if (insufProgress || t >= hi || t <= lo) {
        if ((t - hi).abs() < (t - lo).abs()) {
          t = hi - eps;
        } else {
          t = lo + eps;
        }
        insufProgress = false;
      } else {
        insufProgress = true;
      }
    } else {
      insufProgress = false;
    }

    (f: fNew, g: gNew) = await _directional(evaluate, x, t, d, at, pacer);
    lsFuncEvals++;
    gtdNew = _dot(gNew, d);
    lsIter++;

    if (fNew > (f + c1 * t * gtd) || fNew >= bracketF[lowPos]) {
      bracket[highPos] = t;
      bracketF[highPos] = fNew;
      bracketG[highPos] = gNew;
      bracketGtd[highPos] = gtdNew;
      (lowPos, highPos) = bracketF[0] <= bracketF[1] ? (0, 1) : (1, 0);
    } else {
      if (gtdNew.abs() <= -c2 * gtd) {
        done = true;
      } else if (gtdNew * (bracket[highPos] - bracket[lowPos]) >= 0) {
        bracket[highPos] = bracket[lowPos];
        bracketF[highPos] = bracketF[lowPos];
        bracketG[highPos] = bracketG[lowPos];
        bracketGtd[highPos] = bracketGtd[lowPos];
      }
      bracket[lowPos] = t;
      bracketF[lowPos] = fNew;
      bracketG[lowPos] = gNew;
      bracketGtd[lowPos] = gtdNew;
    }
  }

  return (
    f: bracketF[lowPos],
    g: bracketG[lowPos],
    t: bracket[lowPos],
    evals: lsFuncEvals,
  );
}

/// torch's `_cubic_interpolate` (from torch/optim's polyinterp.lua).
double _cubicInterpolate(
  double x1,
  double f1,
  double g1,
  double x2,
  double f2,
  double g2, {
  double? boundMin,
  double? boundMax,
}) {
  final double xminBound, xmaxBound;
  if (boundMin != null && boundMax != null) {
    xminBound = boundMin;
    xmaxBound = boundMax;
  } else if (x1 <= x2) {
    xminBound = x1;
    xmaxBound = x2;
  } else {
    xminBound = x2;
    xmaxBound = x1;
  }
  final d1 = g1 + g2 - 3 * (f1 - f2) / (x1 - x2);
  final d2Square = d1 * d1 - g1 * g2;
  if (d2Square >= 0) {
    final d2 = math.sqrt(d2Square);
    final double minPos;
    if (x1 <= x2) {
      minPos = x2 - (x2 - x1) * ((g2 + d2 - d1) / (g2 - g1 + 2 * d2));
    } else {
      minPos = x1 - (x1 - x2) * ((g1 + d2 - d1) / (g1 - g2 + 2 * d2));
    }
    return _pyMin(_pyMax(minPos, xminBound), xmaxBound);
  }
  return (xminBound + xmaxBound) / 2.0;
}

/// Python's `max(a, b)`: `a` unless `b > a` (so a NaN `a` stays).
double _pyMax(double a, double b) => b > a ? b : a;

/// Python's `min(a, b)`: `a` unless `b < a`.
double _pyMin(double a, double b) => b < a ? b : a;

double _dot(Float64List a, Float64List b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

/// `y += alpha · x`.
void _axpy(Float64List y, double alpha, Float64List x) {
  for (var i = 0; i < y.length; i++) {
    y[i] += alpha * x[i];
  }
}

/// torch's `v.abs().max()`, which is NaN when any entry is: a NaN gradient
/// never reads as "converged". (`if (!(a <= m)) m = a` alone is not enough:
/// the next finite entry replaces the NaN, since `a <= NaN` is false.)
double _maxAbs(Float64List v) {
  var m = 0.0;
  for (final x in v) {
    final a = x.abs();
    if (a > m) {
      m = a;
    } else if (a.isNaN) {
      return a;
    }
  }
  return m;
}
