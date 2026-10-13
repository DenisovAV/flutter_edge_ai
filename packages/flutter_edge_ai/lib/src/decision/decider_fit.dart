// Fitting an embedding decider from embedded option inputs: centroids, the
// optional linear layer and the calibration. Pure data in, pure data out, so
// it runs on a background isolate (fit_runner_io.dart) or inline on web.
//
// The reference for every number is the decision measurements' `dq1.py`
// (2026-10-13): `centroids`, the C3ii cross-fit with `keep95`, `fit_linear`,
// `fit_temperature` and `threshold_rows`. Test: decider_dq1_test.dart holds
// this code to dq1's own output on real EmbeddingGemma 2 vectors.

import 'dart:math' as math;
import 'dart:typed_data';

import 'dense_kernel.dart';
import 'softmax_regression.dart';

/// Weight decay of the `linear` method. dq1: held-out rows and cross-fitting
/// both picked 1e-5 in 61–100 % of subsets and at 150 options at every k; a
/// fixed 1e-5 is within 0.0001 of either pick's accuracy.
const linearWeightDecay = 1e-5;

/// What [fitDecider] needs. Every vector is unit length.
final class DeciderFitRequest {
  const DeciderFitRequest({
    required this.dimension,
    required this.optionCount,
    required this.optionIds,
    required this.inputs,
    required this.labels,
    required this.ranks,
    required this.linear,
    required this.calibration,
    this.keep,
    this.fixedThreshold,
    this.maxError,
    this.labelledInputs,
    this.labelledLabels,
    this.simd,
  });

  final int dimension;
  final int optionCount;

  /// The options' ids, by index: what a refusal names.
  final List<String> optionIds;

  /// The options' inputs, row-major (rows × dimension).
  final Float64List inputs;

  /// The option index of each input row.
  final Int32List labels;

  /// The position of each input within its option (description first).
  final Int32List ranks;

  /// Whether to fit the `linear` layer.
  final bool linear;

  /// `none`, `crossFit`, `minSimilarity` or `labelled`.
  final String calibration;
  final double? keep;
  final double? fixedThreshold;
  final double? maxError;

  /// The `labelled` calibration's rows and their option indices.
  final Float64List? labelledInputs;
  final Int32List? labelledLabels;

  /// Tests only: force the SIMD or the scalar kernel.
  final bool? simd;
}

/// What [fitDecider] produced.
final class DeciderFit {
  const DeciderFit({
    required this.centroids,
    required this.threshold,
    required this.temperature,
    required this.weights,
    required this.bias,
    required this.linearLoss,
    required this.linearIterations,
    required this.fitTime,
  });

  /// optionCount × dimension, unit rows, row-major.
  final Float32List centroids;

  /// The abstain threshold on the highest centroid cosine; null = never.
  final double? threshold;

  /// The softmax temperature of calibrated probabilities; null = none.
  final double? temperature;

  /// The linear layer, transposed to optionCount × dimension, and its bias.
  final Float32List? weights;
  final Float32List? bias;

  /// The linear objective at the fit and the L-BFGS iterations it took.
  final double? linearLoss;
  final int? linearIterations;

  /// Wall time of the fit.
  final Duration fitTime;
}

/// Fits [request]. Throws [ArgumentError] when the calibration cannot be
/// fitted from these inputs.
DeciderFit fitDecider(DeciderFitRequest request) {
  final watch = Stopwatch()..start();
  final d = request.dimension;
  final c = request.optionCount;
  final x = request.inputs;
  final labels = request.labels;

  final centroids64 = optionCentroids(x, labels, d, c, ids: request.optionIds);

  SoftmaxFit? linear;
  if (request.linear) {
    linear = fitSoftmaxRegression(
      x: x,
      labels: labels,
      dimension: d,
      classes: c,
      decay: linearWeightDecay,
      simd: request.simd,
    );
  }

  double? threshold;
  double? temperature;
  switch (request.calibration) {
    case 'none':
      break;
    case 'minSimilarity':
      threshold = request.fixedThreshold;
    case 'crossFit':
      final signal = crossFitSignal(
        x,
        labels,
        request.ranks,
        d,
        c,
        request.simd,
        ids: request.optionIds,
      );
      threshold = keepThreshold(signal, request.keep!);
    case 'labelled':
      final lx = request.labelledInputs!;
      final ly = request.labelledLabels!;
      final rows = ly.length;
      final scores = Float64List(rows * c);
      final signal = Float64List(rows);
      for (var i = 0; i < rows; i++) {
        var best = double.negativeInfinity;
        for (var o = 0; o < c; o++) {
          final cos = _dot(lx, i * d, centroids64, o * d, d);
          if (cos > best) best = cos;
          scores[i * c + o] = linear == null
              ? cos
              : _linearLogit(lx, i * d, linear, o, d, c);
        }
        signal[i] = best;
      }
      temperature = fitTemperature(scores, ly, c);
      final ok = <bool>[
        for (var i = 0; i < rows; i++) _argmax(scores, i * c, c) == ly[i],
      ];
      threshold = errorBudgetThreshold(signal, ok, request.maxError!);
      if (threshold > 1) {
        throw ArgumentError(
          'DeciderCalibration.fromLabelled: no threshold keeps the error on '
          'the labelled rows within maxError ${request.maxError} — the '
          'decider answers them too poorly. Add examples per option, use the '
          'linear method, or raise maxError.',
        );
      }
    default:
      throw ArgumentError.value(request.calibration, 'calibration');
  }

  Float32List? weights;
  Float32List? bias;
  if (linear != null) {
    weights = Float32List(c * d);
    bias = Float32List(c);
    for (var o = 0; o < c; o++) {
      for (var j = 0; j < d; j++) {
        weights[o * d + j] = linear.weights[j * c + o];
      }
      bias[o] = linear.bias[o];
    }
  }

  final centroids = Float32List.fromList(centroids64);
  checkFittedParameters(
    centroids: centroids,
    dimension: d,
    weights: weights,
    bias: bias,
    loss: linear?.loss,
    threshold: threshold,
    temperature: temperature,
  );
  return DeciderFit(
    centroids: centroids,
    threshold: threshold,
    temperature: temperature,
    weights: weights,
    bias: bias,
    linearLoss: linear?.loss,
    linearIterations: linear?.iterations,
    fitTime: watch.elapsed,
  );
}

/// Throws [StateError] unless every fitted value is finite and every
/// centroid has a direction: a decision is never computed from a NaN, and a
/// NaN centroid would otherwise win every request (it sorts first).
void checkFittedParameters({
  required List<double> centroids,
  required int dimension,
  List<double>? weights,
  List<double>? bias,
  double? loss,
  double? threshold,
  double? temperature,
}) {
  void finite(List<double>? values, String what) {
    if (values == null) return;
    for (final v in values) {
      if (!v.isFinite) {
        throw StateError(
          'The decider fit produced a non-finite $what; a decision is never '
          'computed from it.',
        );
      }
    }
  }

  finite(centroids, 'centroid');
  for (var o = 0; o * dimension < centroids.length; o++) {
    var norm = 0.0;
    for (var j = 0; j < dimension; j++) {
      final v = centroids[o * dimension + j];
      norm += v * v;
    }
    if (norm == 0) {
      throw StateError('The decider fit produced a zero centroid (option $o).');
    }
  }
  finite(weights, 'linear weight');
  finite(bias, 'linear bias');
  for (final (value, what) in [
    (loss, 'linear loss'),
    (threshold, 'threshold'),
    (temperature, 'temperature'),
  ]) {
    if (value != null && !value.isFinite) {
      throw StateError(
        'The decider fit produced a non-finite $what ($value); a decision is '
        'never computed from it.',
      );
    }
  }
}

/// dq1's `centroids`: each option's mean input, renormalised (float64).
///
/// Throws [StateError] for an option whose inputs cancel out: their mean is
/// the zero vector, which has no direction to compare with (dq1 divides by
/// its zero norm and gets NaN). [ids] name the options in that message.
Float64List optionCentroids(
  Float64List x,
  Int32List labels,
  int d,
  int c, {
  bool Function(int row)? include,
  List<String>? ids,
}) {
  final sums = Float64List(c * d);
  final counts = Int32List(c);
  for (var i = 0; i < labels.length; i++) {
    if (include != null && !include(i)) continue;
    final o = labels[i];
    counts[o]++;
    final so = o * d, xo = i * d;
    for (var j = 0; j < d; j++) {
      sums[so + j] += x[xo + j];
    }
  }
  for (var o = 0; o < c; o++) {
    if (counts[o] == 0) {
      throw StateError('option $o has no input to take a centroid of');
    }
    final so = o * d;
    var norm = 0.0;
    for (var j = 0; j < d; j++) {
      final mean = sums[so + j] / counts[o];
      sums[so + j] = mean;
      norm += mean * mean;
    }
    if (norm == 0) {
      final name = ids == null ? 'option $o' : 'option "${ids[o]}"';
      throw StateError(
        'The inputs of $name cancel out: their mean is the zero vector, so '
        'the option has no direction to compare a request with. Give it '
        'inputs that mean the same thing.',
      );
    }
    norm = math.sqrt(norm);
    for (var j = 0; j < d; j++) {
      sums[so + j] /= norm;
    }
  }
  return sums;
}

/// dq1's out-of-fold signal (b) for the C3 calibrations: input `i` of each
/// option sits in fold `ranks[i] % 5`; each held-out input's highest cosine to
/// the centroids of the other four folds.
Float64List crossFitSignal(
  Float64List x,
  Int32List labels,
  Int32List ranks,
  int d,
  int c,
  bool? simd, {
  List<String>? ids,
}) {
  final rows = labels.length;
  final out = Float64List(rows);
  final kernel = DenseKernel(d: d, columns: c, simd: simd);
  final transposed = kernel.matrix();
  final z = kernel.row();
  for (var f = 0; f < 5; f++) {
    final held = [
      for (var i = 0; i < rows; i++)
        if (ranks[i] % 5 == f) i,
    ];
    if (held.isEmpty) continue;
    final cf = optionCentroids(
      x,
      labels,
      d,
      c,
      include: (i) => ranks[i] % 5 != f,
      ids: ids,
    );
    for (var o = 0; o < c; o++) {
      for (var j = 0; j < d; j++) {
        transposed[j * kernel.cp + o] = cf[o * d + j];
      }
    }
    for (final i in held) {
      kernel.multiply(x, i * d, transposed, z);
      var best = double.negativeInfinity;
      for (var o = 0; o < c; o++) {
        if (z[o] > best) best = z[o];
      }
      out[i] = best;
    }
  }
  return out;
}

/// dq1's `keep95`, for any [keep]: the ascending-sorted signal at index
/// `floor((1 − keep) · n)`, so that share of the inputs is at or above it.
double keepThreshold(Float64List signal, double keep) {
  final sorted = Float64List.fromList(signal)..sort();
  final index = math.min(
    ((1 - keep) * sorted.length).floor(),
    sorted.length - 1,
  );
  return sorted[index];
}

/// dq1's `fit_temperature`: the temperature among 241 log-spaced values in
/// [1e-3, 10] with the lowest negative log-likelihood of [labels] under
/// `softmax(scores / T)` (probabilities floored at 1e-12; the smallest
/// temperature wins a tie).
double fitTemperature(Float64List scores, Int32List labels, int c) {
  final lo = math.log(1e-3), hi = math.log(10.0);
  const steps = 241;
  final step = (hi - lo) / (steps - 1);
  final rows = labels.length;
  final z = Float64List(c);
  var bestNll = double.infinity;
  var bestTemp = 1.0;
  for (var s = 0; s < steps; s++) {
    final temp = math.exp(s == steps - 1 ? hi : s * step + lo);
    var nll = 0.0;
    for (var i = 0; i < rows; i++) {
      var m = double.negativeInfinity;
      for (var o = 0; o < c; o++) {
        final v = scores[i * c + o] / temp;
        z[o] = v;
        if (v > m) m = v;
      }
      var sum = 0.0;
      for (var o = 0; o < c; o++) {
        final e = math.exp(z[o] - m);
        z[o] = e;
        sum += e;
      }
      final q = z[labels[i]] / sum;
      nll += -math.log(q > 1e-12 ? q : 1e-12);
    }
    nll /= rows;
    if (nll < bestNll) {
      bestNll = nll;
      bestTemp = temp;
    }
  }
  return bestTemp;
}

/// dq1's `threshold_conf`: rows sorted by [signal] descending (stable), the
/// signal of the last row at which the answered rows' error rate is within
/// [budget]; `1 + 1e-9` (abstain on everything) when no prefix is.
double errorBudgetThreshold(Float64List signal, List<bool> ok, double budget) {
  final order = List<int>.generate(signal.length, (i) => i)
    ..sort((a, b) {
      final bySignal = signal[b].compareTo(signal[a]);
      return bySignal != 0 ? bySignal : a.compareTo(b);
    });
  var errors = 0;
  int? last;
  for (var k = 0; k < order.length; k++) {
    if (!ok[order[k]]) errors++;
    if (errors / (k + 1) <= budget) last = k;
  }
  return last == null ? 1.0 + 1e-9 : signal[order[last]];
}

double _linearLogit(
  Float64List x,
  int xo,
  SoftmaxFit fit,
  int o,
  int d,
  int c,
) {
  var s = 0.0;
  for (var j = 0; j < d; j++) {
    s += x[xo + j] * fit.weights[j * c + o];
  }
  return s + fit.bias[o];
}

double _dot(Float64List a, int ao, Float64List b, int bo, int d) {
  var s = 0.0;
  for (var j = 0; j < d; j++) {
    s += a[ao + j] * b[bo + j];
  }
  return s;
}

int _argmax(Float64List v, int offset, int length) {
  var best = 0;
  for (var k = 1; k < length; k++) {
    if (v[offset + k] > v[offset + best]) best = k;
  }
  return best;
}
