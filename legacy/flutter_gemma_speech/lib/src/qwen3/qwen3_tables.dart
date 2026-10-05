// Host embedding tables + text-projection MLP for the Qwen3-TTS pipeline.
//
// `Qwen3Tables` owns four on-disk NumPy tables shipped alongside the
// Qwen3-TTS talker model:
//  - `codec_embedding_fp32.npy`   (3072, 1024) <f4  — codec-token embeddings
//  - `mtp_embeddings_fp16.npy`    (15, 2048, 1024) <f2 — MTP residual
//                                 embeddings, one (2048,1024) table per of
//                                 the 15 residual groups
//  - `text_embedding_fp16.npy`    (151936, 2048) <f2 — the LLM's token
//                                 embedding table, reused as the text
//                                 frontend for TTS
//  - `text_projection_fp32.npz`   {w1 (2048,2048), b1 (2048), w2 (1024,2048),
//                                 b2 (1024)} <f4 — the SiLU MLP that
//                                 projects text-embedding rows (2048-d, LLM
//                                 hidden size) into talker space (1024-d)
//
// `codec_embedding` (12.5 MB) and `mtp_embeddings` (63 MB fp16 -> 126 MB
// fp32) are small enough to load whole into memory. `text_embedding` is not
// (622 MB fp16 on disk, ~1.2 GB up-cast to fp32) — it is kept as an open
// `RandomAccessFile` + parsed `NpyHeader` and rows are read on demand via
// [npyRowF16AsF32], which seeks directly to the row's byte offset instead of
// loading the whole table. Callers MUST call [dispose] to close that file
// handle.
//
// This file is pure Dart (`dart:io` + `dart:typed_data`) — no Flutter
// import — so it can be unit-tested without a device.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'npy_reader.dart';

/// Hidden size of the LLM token-embedding table (`text_embedding`'s row
/// width) — the input dimension of the text-projection MLP.
const int _textEmbedDim = 2048;

/// Talker hidden size — the output dimension of the text-projection MLP,
/// and the row width of `codec_embedding` / `mtp_embeddings`.
const int _talkerDim = 1024;

/// Number of MTP (multi-token-prediction) residual groups.
const int _mtpGroups = 15;

/// Host-side embedding tables + text-projection MLP for Qwen3-TTS.
///
/// Turns text-token ids into 1024-d talker-space embeddings
/// ([embedText]/[projectText]), and looks up codec-token / MTP-residual
/// embeddings used while decoding audio frames ([codecEmbRow]/[mtpEmbRow]).
class Qwen3Tables {
  Qwen3Tables._({
    required this._codecEmb,
    required this._mtpEmb,
    required this._textEmbFile,
    required this._textEmbHeader,
    required this._w1,
    required this._b1,
    required this._w2,
    required this._b2,
  });

  /// Loads all four tables from disk.
  ///
  /// [codecEmbPath] and [mtpEmbPath] are read whole into memory.
  /// [textEmbPath] is opened and kept as a [RandomAccessFile] — rows are
  /// read on demand by [embedText] (call [dispose] when done with this
  /// instance to close it). [projectionNpzPath] is a `.npz` archive with
  /// members `w1`, `b1`, `w2`, `b2`.
  static Future<Qwen3Tables> load({
    required String codecEmbPath,
    required String mtpEmbPath,
    required String textEmbPath,
    required String projectionNpzPath,
  }) async {
    final codecEmb = readNpyF32(codecEmbPath);
    final mtpEmb = readNpyF16AsF32(mtpEmbPath);

    final textEmbFile = File(textEmbPath).openSync();
    final textEmbHeader = parseNpyHeader(textEmbFile);
    if (textEmbHeader.dtype != '<f2') {
      textEmbFile.closeSync();
      throw StateError(
        'Qwen3Tables.load: expected text_embedding dtype <f2, got '
        '${textEmbHeader.dtype} ($textEmbPath)',
      );
    }
    if (textEmbHeader.shape.length != 2 ||
        textEmbHeader.shape[1] != _textEmbedDim) {
      textEmbFile.closeSync();
      throw StateError(
        'Qwen3Tables.load: expected text_embedding shape (*, $_textEmbedDim), '
        'got ${textEmbHeader.shape} ($textEmbPath)',
      );
    }

    final proj = readNpzF32(projectionNpzPath);
    final w1 = _requireProjMember(proj, 'w1', projectionNpzPath);
    final b1 = _requireProjMember(proj, 'b1', projectionNpzPath);
    final w2 = _requireProjMember(proj, 'w2', projectionNpzPath);
    final b2 = _requireProjMember(proj, 'b2', projectionNpzPath);
    if (w1.length != _textEmbedDim * _textEmbedDim) {
      textEmbFile.closeSync();
      throw StateError(
        "Qwen3Tables.load: 'w1' expected ($_textEmbedDim,$_textEmbedDim), "
        'got ${w1.length} elements ($projectionNpzPath)',
      );
    }
    if (b1.length != _textEmbedDim) {
      textEmbFile.closeSync();
      throw StateError(
        "Qwen3Tables.load: 'b1' expected ($_textEmbedDim,), got "
        '${b1.length} elements ($projectionNpzPath)',
      );
    }
    if (w2.length != _talkerDim * _textEmbedDim) {
      textEmbFile.closeSync();
      throw StateError(
        "Qwen3Tables.load: 'w2' expected ($_talkerDim,$_textEmbedDim), got "
        '${w2.length} elements ($projectionNpzPath)',
      );
    }
    if (b2.length != _talkerDim) {
      textEmbFile.closeSync();
      throw StateError(
        "Qwen3Tables.load: 'b2' expected ($_talkerDim,), got "
        '${b2.length} elements ($projectionNpzPath)',
      );
    }

    return Qwen3Tables._(
      codecEmb: codecEmb,
      mtpEmb: mtpEmb,
      textEmbFile: textEmbFile,
      textEmbHeader: textEmbHeader,
      w1: w1,
      b1: b1,
      w2: w2,
      b2: b2,
    );
  }

  static Float32List _requireProjMember(
    Map<String, Float32List> proj,
    String name,
    String path,
  ) {
    final m = proj[name];
    if (m == null) {
      throw StateError(
        "Qwen3Tables.load: projection .npz missing member '$name' ($path)",
      );
    }
    return m;
  }

  /// Codec-token embedding table, `(3072, 1024)` <f4, loaded whole.
  final Float32List _codecEmb;

  /// MTP residual-embedding table, `(15, 2048, 1024)`, up-cast from <f2 to
  /// <f4 and loaded whole.
  final Float32List _mtpEmb;

  /// Open handle to `text_embedding_fp16.npy` — kept open (not loaded
  /// whole) so individual rows can be read on demand via [npyRowF16AsF32].
  final RandomAccessFile _textEmbFile;
  final NpyHeader _textEmbHeader;

  /// Text-projection MLP weights, from the `.npz`: `w1` (2048,2048), `b1`
  /// (2048), `w2` (1024,2048), `b2` (1024), all <f4.
  final Float32List _w1;
  final Float32List _b1;
  final Float32List _w2;
  final Float32List _b2;

  bool _disposed = false;

  /// Looks up and projects text-embedding rows to talker space: for each id
  /// in [ids], reads its `text_embedding` row (2048-d, fp16 up-cast to
  /// fp32), stacks the rows `[ids.length, 2048]`, and runs [projectText].
  ///
  /// Returns a flat `[ids.length * 1024]` array (row-major).
  Float32List embedText(List<int> ids) {
    _checkNotDisposed();
    final n = ids.length;
    final rows = Float32List(n * _textEmbedDim);
    for (var i = 0; i < n; i++) {
      final row = npyRowF16AsF32(_textEmbFile, _textEmbHeader, ids[i]);
      rows.setRange(i * _textEmbedDim, (i + 1) * _textEmbedDim, row);
    }
    return projectText(rows);
  }

  /// Applies the 2048->1024 text-projection MLP (SiLU activation) to [rows]
  /// (flat `[n * 2048]`, row-major). Returns a flat `[n * 1024]` array.
  ///
  /// Ports `Qwen3TtsPipeline._project_text`:
  /// `h = rows @ w1.T + b1; h = h * sigmoid(h); out = h @ w2.T + b2`.
  /// `w1` is `(2048,2048)` so `h[j] = sum_k rows[k] * w1[j,k] + b1[j]`;
  /// `w2` is `(1024,2048)` so `out[i] = sum_j h[j] * w2[i,j] + b2[i]`.
  Float32List projectText(Float32List rows) {
    _checkNotDisposed();
    if (rows.length % _textEmbedDim != 0) {
      throw ArgumentError(
        'projectText: rows length ${rows.length} is not a multiple of '
        '$_textEmbedDim',
      );
    }
    final n = rows.length ~/ _textEmbedDim;
    final out = Float32List(n * _talkerDim);
    final h = Float32List(_textEmbedDim);

    for (var row = 0; row < n; row++) {
      final rowOffset = row * _textEmbedDim;

      // h[j] = sum_k rows[k] * w1[j,k] + b1[j]; then SiLU: h = h * sigmoid(h).
      for (var j = 0; j < _textEmbedDim; j++) {
        var acc = 0.0;
        final w1Row = j * _textEmbedDim;
        for (var k = 0; k < _textEmbedDim; k++) {
          acc += rows[rowOffset + k] * _w1[w1Row + k];
        }
        acc += _b1[j];
        h[j] = acc / (1.0 + math.exp(-acc));
      }

      // out[i] = sum_j h[j] * w2[i,j] + b2[i].
      final outOffset = row * _talkerDim;
      for (var i = 0; i < _talkerDim; i++) {
        var acc = 0.0;
        final w2Row = i * _textEmbedDim;
        for (var j = 0; j < _textEmbedDim; j++) {
          acc += h[j] * _w2[w2Row + j];
        }
        out[outOffset + i] = acc + _b2[i];
      }
    }
    return out;
  }

  /// Returns codec-token embedding row [id] (`[1024]`), as a view into the
  /// `(3072, 1024)` `codec_embedding` table (backed by the same buffer — do
  /// not mutate, and do not use after [dispose]).
  Float32List codecEmbRow(int id) {
    _checkNotDisposed();
    final rows = _codecEmb.length ~/ _talkerDim;
    if (id < 0 || id >= rows) {
      throw RangeError.range(id, 0, rows - 1, 'id');
    }
    return Float32List.sublistView(
      _codecEmb,
      id * _talkerDim,
      (id + 1) * _talkerDim,
    );
  }

  /// Returns MTP residual-embedding row `[group][id]` (`[1024]`), as a view
  /// into the `(15, 2048, 1024)` `mtp_embeddings` table (backed by the same
  /// buffer — do not mutate, and do not use after [dispose]).
  Float32List mtpEmbRow(int group, int id) {
    _checkNotDisposed();
    if (group < 0 || group >= _mtpGroups) {
      throw RangeError.range(group, 0, _mtpGroups - 1, 'group');
    }
    final idsPerGroup = _mtpEmb.length ~/ (_mtpGroups * _talkerDim);
    if (id < 0 || id >= idsPerGroup) {
      throw RangeError.range(id, 0, idsPerGroup - 1, 'id');
    }
    final base = (group * idsPerGroup + id) * _talkerDim;
    return Float32List.sublistView(_mtpEmb, base, base + _talkerDim);
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('Qwen3Tables: used after dispose()');
    }
  }

  /// Closes the open `text_embedding` file handle. Safe to call more than
  /// once. The instance must not be used after this call.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _textEmbFile.closeSync();
  }

  /// Alias for [dispose] (symmetry with the closeable conventions used
  /// elsewhere in the SDK, e.g. `InferenceModelSession.close()`).
  void close() => dispose();
}
