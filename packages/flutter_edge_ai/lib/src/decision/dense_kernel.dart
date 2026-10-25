// The one dense product the decider's fitting spends its time in: a row of an
// n × d matrix times a d × cp matrix, and the matching outer-product
// accumulation for the gradient. Float64x2 SIMD on native; plain scalar loops
// on web, where dart2js and dart2wasm box SIMD values. Both give bit-identical
// results: the lanes multiply and add exactly as the scalar loop does (Dart
// never fuses a multiply-add), in the same order.

import 'dart:typed_data';

/// Whether this is a web build (dart2js or dart2wasm).
const bool _isWeb = bool.fromEnvironment('dart.library.js_interop');

/// Products against a d × cp row-major matrix whose width [cp] is even (the
/// caller pads an odd column count with a zero column).
final class DenseKernel {
  /// [simd] overrides the platform choice; tests use it to compare the paths.
  DenseKernel({required this.d, required int columns, bool? simd})
    : cp = columns + (columns & 1),
      simd = simd ?? !_isWeb;

  /// Rows of the matrix (the embedding dimension).
  final int d;

  /// Padded width of the matrix; even.
  final int cp;

  /// Whether the Float64x2 loops are used.
  final bool simd;

  /// A zeroed d × cp matrix.
  Float64List matrix() => Float64List(d * cp);

  /// A zeroed row of width cp.
  Float64List row() => Float64List(cp);

  /// `out = x[xo, xo + d) · m`, overwriting [out].
  void multiply(Float64List x, int xo, Float64List m, Float64List out) {
    out.fillRange(0, cp, 0);
    if (simd) {
      final half = cp >> 1;
      final m2 = Float64x2List.view(m.buffer, m.offsetInBytes, m.length >> 1);
      final o2 = Float64x2List.view(out.buffer, out.offsetInBytes, half);
      for (var j = 0; j < d; j++) {
        final s = Float64x2.splat(x[xo + j]);
        final base = j * half;
        for (var k = 0; k < half; k++) {
          o2[k] += s * m2[base + k];
        }
      }
      return;
    }
    for (var j = 0; j < d; j++) {
      final s = x[xo + j];
      final base = j * cp;
      for (var k = 0; k < cp; k++) {
        out[k] += s * m[base + k];
      }
    }
  }

  /// `g += x[xo, xo + d)ᵀ · r`: row `j` of [g] gains `x[xo + j] · r`.
  void addOuter(Float64List x, int xo, Float64List r, Float64List g) {
    if (simd) {
      final half = cp >> 1;
      final r2 = Float64x2List.view(r.buffer, r.offsetInBytes, half);
      final g2 = Float64x2List.view(g.buffer, g.offsetInBytes, g.length >> 1);
      for (var j = 0; j < d; j++) {
        final s = Float64x2.splat(x[xo + j]);
        final base = j * half;
        for (var k = 0; k < half; k++) {
          g2[base + k] += s * r2[k];
        }
      }
      return;
    }
    for (var j = 0; j < d; j++) {
      final s = x[xo + j];
      final base = j * cp;
      for (var k = 0; k < cp; k++) {
        g[base + k] += s * r[k];
      }
    }
  }
}
