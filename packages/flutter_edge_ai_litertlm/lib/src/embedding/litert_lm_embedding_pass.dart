// The EmbeddingGemma 2 `.litertlm` embedding pass over LiteRT-LM's
// EmbeddingEngine C API — what `LiteRtEmbeddingBackend.describe` hands core for
// a self-contained `.litertlm` embedder spec. Core builds it inside its
// embedding worker isolate, hosts it and closes it (R5 §4).
//
// The bundle carries its own tokenizer, so nothing here touches core's
// tokenizer registry: the pass hands the engine `taskType.prefix + text` and
// the engine tokenizes it, adding BOS and EOS (special tokens pinned on, D26).
//
// What it decides, and why (R5 D21-D26, §4.8, §4.10, measured in
// eg2_design_backup/measurements/REPORT.md):
// - Capabilities come from ModelInfo, read and freed BEFORE any settings or
//   engine exist: model type, dimension, text signatures, and image support
//   from `vision_signature_selection` — never `supports_input_modality`, which
//   claims vision and audio on the text-only 270m (D23). A declared medium is
//   refused here, so no engine (and no tower cache) is made for a request that
//   cannot be served. 1.13.0 embeds text only.
// - The input cap is set explicitly to 1024 tokens (D21): the bundles' metadata
//   says 1024 but no C getter exposes it, and one 8192-token input peaked at
//   +10.25 GB. `maxInputTokens` is the smallest text signature at or above the
//   setting — the limit the engine enforces.
// - The engine always gets an existing, writable cache directory that this
//   pass owns (D22), under the platform cache directory (never backed up):
//   without one it runs with no weight cache (+290 MB) or writes
//   `.xnnpack_cache` files next to the model. Our part of the path is kept
//   short — `flutter_edge_ai/emb/<8-hex hash>-<base36 size>-<base36 mtime>`
//   (see `liteRtLmCacheDirName`: Windows MAX_PATH), and a load that leaves it empty is reported. Caches of earlier
//   copies of the same file name are deleted only after the engine exists,
//   and not while they were touched in the last 10 minutes.
// - Overflow (§4.8): options use kError; a NULL response with status 3
//   (InvalidArgument) on the single, well-formed text part this pass built is
//   an overflow — the only InvalidArgument reachable for such a request at
//   v0.18.0. The count is not parsed out of the message (owner decision), so
//   `actualTokens` is null until the response getters land (P3).
// - Ownership (§4.10): every create has its delete on every path, and the
//   native error (thread-local) is copied in the same synchronous segment as
//   the failing call, before any other native call.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' show sha256;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';

import '../ffi/litert_lm_embedding_bindings.dart';
import '../ffi/litert_lm_library.dart';

/// The engine's name in messages and errors.
const liteRtLmEngineTag = 'LiteRT-LM';

/// 1.13.0's answer to any declared medium, from `describe()` and from the pass.
const liteRtLmTextOnlyRefusal =
    'flutter_edge_ai_litertlm 1.13.0 embeds text only; images arrive in '
    '1.14.0, audio in 1.16.0';

/// The explicit text input cap (D21). Never raised on mobile.
const liteRtLmMaxInputLength = 1024;

/// `kLiteRtLmStatusOk` / `kLiteRtLmStatusInvalidArgument` (`c/error_reporter.h`).
const _statusOk = 0;
const _statusInvalidArgument = 3;

/// What `LiteRtEmbeddingBackend.describe` hands core for a `.litertlm`
/// embedder. Crosses to core's worker isolate: strings, a set of enums and an
/// int, all sendable.
final class LiteRtLmEmbeddingConfig {
  const LiteRtLmEmbeddingConfig({
    required this.modelPath,
    required this.cacheBase,
    this.declaredMedia = const {},
    this.numThreads,
  });

  /// The `.litertlm` bundle core resolved for the active spec.
  final String modelPath;

  /// `<applicationCache>/flutter_edge_ai/emb` (path_provider's
  /// `getApplicationCacheDirectory()`), resolved in `describe()` — the worker
  /// isolate has no platform channels. The pass keeps one directory per bundle
  /// copy under it. A cache directory, so it is never backed up (iOS iCloud,
  /// Android Auto Backup's 25 MB quota); when the OS purges it, the next engine
  /// create rebuilds the weight cache.
  final String cacheBase;

  /// The media the caller declared. The pass refuses any of them in 1.13.0,
  /// from ModelInfo, before creating an engine.
  final Set<EmbeddingModality> declaredMedia;

  /// Engine threads; null leaves the engine's default (about 4).
  final int? numThreads;
}

/// The descriptor factory: a top-level tear-off, so it survives the trip into
/// core's worker isolate.
EmbeddingPass buildLiteRtLmEmbeddingPass(LiteRtLmEmbeddingConfig config) =>
    LiteRtLmEmbeddingPass(config);

/// Every C function the pass calls. A `libLiteRtLm` that exports fewer is
/// refused at load by [checkLiteRtLmEmbeddingSymbols], by name, instead of
/// failing on the first lookup somewhere inside the worker.
const liteRtLmEmbeddingSymbols = <String>[
  'litert_lm_clear_last_error',
  'litert_lm_get_last_error_code',
  'litert_lm_get_last_error_message',
  'litert_lm_loaded_file_create',
  'litert_lm_loaded_file_delete',
  'litert_lm_loaded_file_model_type',
  'litert_lm_loaded_file_embedding_dimension',
  'litert_lm_loaded_file_embedding_signature_selection',
  'litert_lm_loaded_file_vision_signature_selection',
  'litert_lm_embedding_engine_settings_create',
  'litert_lm_embedding_engine_settings_delete',
  'litert_lm_embedding_engine_settings_set_cache_dir',
  'litert_lm_embedding_engine_settings_set_max_input_length',
  'litert_lm_embedding_engine_settings_set_num_threads',
  'litert_lm_embedding_engine_create',
  'litert_lm_embedding_engine_delete',
  'litert_lm_embedding_engine_compute_embedding',
  'litert_lm_embedding_options_create',
  'litert_lm_embedding_options_delete',
  'litert_lm_embedding_options_set_normalize',
  'litert_lm_embedding_options_set_insert_special_tokens',
  'litert_lm_embedding_options_set_input_overflow_strategy',
  'litert_lm_input_data_create',
  'litert_lm_input_data_delete',
  'litert_lm_embedding_response_get_size',
  'litert_lm_embedding_response_get_values',
  'litert_lm_embedding_response_delete',
];

/// Throws [EmbeddingLoadException] naming every symbol of
/// [liteRtLmEmbeddingSymbols] that [provides] reports missing from [library].
void checkLiteRtLmEmbeddingSymbols(
  bool Function(String symbol) provides, {
  required String library,
}) {
  final missing = [
    for (final symbol in liteRtLmEmbeddingSymbols)
      if (!provides(symbol)) symbol,
  ];
  if (missing.isEmpty) return;
  throw EmbeddingLoadException(
    '$library does not export the LiteRT-LM EmbeddingEngine C API '
    '(missing: ${missing.join(', ')}). EmbeddingGemma 2 needs the native '
    'libraries of native-v0.18.0-d or newer; a stale local prebuilt under '
    'native/litert_lm/prebuilt/ is the usual cause.',
    engine: liteRtLmEngineTag,
  );
}

/// Binds [library] after checking it exports everything the pass calls.
LiteRtLmEmbeddingBindings bindLiteRtLmEmbeddings(
  DynamicLibrary library, {
  String label = 'libLiteRtLm',
}) {
  checkLiteRtLmEmbeddingSymbols(library.providesSymbol, library: label);
  return LiteRtLmEmbeddingBindings(library);
}

LiteRtLmEmbeddingBindings _openBindings() =>
    bindLiteRtLmEmbeddings(openLiteRtLmLibrary());

/// The `.litertlm` embedding pass. Text only in 1.13.0; CPU.
///
/// Built and run inside one isolate: the native handles it holds cannot cross
/// an isolate boundary — only its [LiteRtLmEmbeddingConfig] does.
final class LiteRtLmEmbeddingPass extends EmbeddingPass {
  LiteRtLmEmbeddingPass(
    this._config, {
    @visibleForTesting LiteRtLmEmbeddingBindings Function()? openBindings,
    @visibleForTesting Allocator allocator = calloc,
    @visibleForTesting DateTime Function()? clock,
  }) : _open = openBindings ?? _openBindings,
       _alloc = allocator,
       _now = clock ?? DateTime.now;

  final LiteRtLmEmbeddingConfig _config;
  final LiteRtLmEmbeddingBindings Function() _open;

  /// Every pointer the pass allocates, and frees.
  final Allocator _alloc;

  /// What "now" is when judging whether a sibling cache is still in use.
  final DateTime Function() _now;

  LiteRtLmEmbeddingBindings? _bindings;
  Pointer<LiteRtLmEmbeddingEngine> _engine = nullptr;
  Pointer<LiteRtLmEmbeddingOptions> _options = nullptr;
  int _dimension = 0;
  int _maxInputTokens = 0;
  String? _cacheDir;
  bool _loaded = false;
  bool _closed = false;

  String get _file => _fileName(_config.modelPath);

  /// The engine-owned cache directory [load] created; null before.
  @visibleForTesting
  String? get cacheDir => _cacheDir;

  @override
  Future<EmbeddingPassInfo> load() async {
    if (_loaded || _closed) {
      throw StateError('LiteRtLmEmbeddingPass.load() runs once, before close');
    }
    final LiteRtLmEmbeddingBindings b;
    try {
      b = _open();
    } on EmbeddingLoadException {
      rethrow;
    } catch (e) {
      throw EmbeddingLoadException(
        'could not open the LiteRT-LM native library: $e',
        engine: liteRtLmEngineTag,
        cause: e,
      );
    }
    _bindings = b;

    final info = _readModelInfo(b);
    final textSignatures = _checkModelInfo(info);
    final (:setting, :maxInputTokens) = liteRtLmInputLimit(textSignatures);
    final cacheDir = _createCacheDir();

    try {
      _engine = _createEngine(b, maxInputLength: setting, cacheDir: cacheDir);
      _options = _createOptions(b);
    } catch (_) {
      _free();
      rethrow;
    }
    _warnIfNoWeightCache(cacheDir);
    // Only now: a load that failed must not have cost another copy its cache.
    _deleteStaleSiblings(cacheDir);

    _dimension = info.dimension;
    _maxInputTokens = maxInputTokens;
    _cacheDir = cacheDir;
    _loaded = true;
    edgeAiLog(
      '[LiteRtLmEmbeddingPass] loaded $_file: dim=${info.dimension}, '
      'maxInputTokens=$maxInputTokens, backend=cpu, cache=$cacheDir',
    );
    return EmbeddingPassInfo(
      dimension: info.dimension,
      maxInputTokens: maxInputTokens,
    );
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final b = _bindings;
    if (!_loaded || _closed || b == null) {
      throw const EmbeddingEngineException(
        'LiteRtLmEmbeddingPass.embed() needs a loaded, open pass',
        engine: liteRtLmEngineTag,
      );
    }
    final text = input.text;
    if (text == null || input.modalities.length != 1) {
      // Core refuses this before sending; reaching it is a host bug.
      throw EmbeddingEngineException(
        'flutter_edge_ai_litertlm 1.13.0 embeds text only, got $input',
        engine: liteRtLmEngineTag,
      );
    }

    // Everything below is synchronous: the native error state is
    // thread-local, and an `await` could resume this isolate on another
    // thread before it is read.
    final bytes = utf8.encode('${taskType.prefix}$text');
    final buffer = _alloc<Uint8>(math.max(bytes.length, 1));
    final Pointer<LiteRtLmInputData> part;
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      // Copies the bytes (std::string). Returns NULL only for an unknown
      // type, and then sets no error — so none is read.
      part = b.litert_lm_input_data_create(
        LiteRtLmInputDataType.kLiteRtLmInputDataTypeText,
        buffer.cast(),
        bytes.length,
      );
    } finally {
      _alloc.free(buffer);
    }
    if (part == nullptr) {
      throw const EmbeddingEngineException(
        'litert_lm_input_data_create returned NULL for a text part',
        engine: liteRtLmEngineTag,
      );
    }

    final parts = _alloc<Pointer<LiteRtLmInputData>>();
    try {
      parts[0] = part;
      // The error state is per thread and survives successful calls: clear
      // it, so a NULL with nothing reported is never read as an old status.
      b.litert_lm_clear_last_error();
      final response = b.litert_lm_embedding_engine_compute_embedding(
        _engine,
        parts,
        1,
        _options,
      );
      if (response == nullptr) {
        final (:code, :message) = _lastError(b);
        if (code == _statusInvalidArgument) {
          // §4.8: the only InvalidArgument a single, well-formed text part
          // built here can reach at v0.18.0 is the signature-length check.
          throw EmbeddingInputTooLongException(
            'The input is longer than the $_maxInputTokens tokens '
            '$_file accepts (task prefix, BOS and EOS included). Nothing was '
            'truncated; split the text and embed the pieces.',
            maxInputTokens: _maxInputTokens,
          );
        }
        throw EmbeddingEngineException(
          'compute_embedding failed for $_file: $message',
          engine: liteRtLmEngineTag,
          nativeCode: code == _statusOk ? null : code,
        );
      }
      try {
        final size = b.litert_lm_embedding_response_get_size(response);
        final values = b.litert_lm_embedding_response_get_values(response);
        if (size != _dimension || values == nullptr) {
          throw EmbeddingEngineException(
            '$_file returned a vector of $size values for dimension '
            '$_dimension',
            engine: liteRtLmEngineTag,
          );
        }
        // The values belong to the response: copy before deleting it.
        return List<double>.generate(size, (i) => values[i]);
      } finally {
        b.litert_lm_embedding_response_delete(response);
      }
    } finally {
      b.litert_lm_input_data_delete(part);
      _alloc.free(parts);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _free();
  }

  /// Deletes the options and the engine, whichever exist. Idempotent.
  void _free() {
    final b = _bindings;
    if (b == null) return;
    final options = _options;
    final engine = _engine;
    _options = nullptr;
    _engine = nullptr;
    if (options != nullptr) b.litert_lm_embedding_options_delete(options);
    if (engine != nullptr) b.litert_lm_embedding_engine_delete(engine);
  }

  // ── ModelInfo ──────────────────────────────────────────────────────────

  _ModelInfo _readModelInfo(LiteRtLmEmbeddingBindings b) {
    final path = _config.modelPath.toNativeUtf8(allocator: _alloc);
    final Pointer<LiteRtLmLoadedFile> file;
    try {
      b.litert_lm_clear_last_error();
      file = b.litert_lm_loaded_file_create(path.cast());
    } finally {
      _alloc.free(path);
    }
    if (file == nullptr) {
      final (:code, :message) = _lastError(b);
      throw EmbeddingLoadException(
        'LiteRT-LM could not read $_file: $message',
        engine: liteRtLmEngineTag,
        nativeCode: code == _statusOk ? null : code,
      );
    }
    try {
      final LiteRtLmModelType? type;
      try {
        type = b.litert_lm_loaded_file_model_type(file);
      } on ArgumentError {
        // A model type newer than these bindings: not one this pass runs.
        return _unknownModelInfo;
      }
      return (
        type: type,
        dimension: b.litert_lm_loaded_file_embedding_dimension(file),
        textSignatures: _signatures(
          (lengths, max) =>
              b.litert_lm_loaded_file_embedding_signature_selection(
                file,
                lengths,
                max,
              ),
        ),
        visionSignatures: _signatures(
          (lengths, max) => b.litert_lm_loaded_file_vision_signature_selection(
            file,
            lengths,
            max,
          ),
        ),
      );
    } finally {
      b.litert_lm_loaded_file_delete(file);
    }
  }

  /// A ModelInfo length list: the count first (a NULL array), then the
  /// values. Null when the file defines none (-1).
  List<int>? _signatures(int Function(Pointer<Int32>, int) read) {
    final count = read(nullptr, 0);
    if (count < 0) return null;
    if (count == 0) return const [];
    final lengths = _alloc<Int32>(count);
    try {
      final written = math.min(read(lengths, count), count);
      return [for (var i = 0; i < written; i++) lengths[i]];
    } finally {
      _alloc.free(lengths);
    }
  }

  /// Refuses what this pass cannot run, from ModelInfo alone; returns the
  /// text signatures.
  List<int> _checkModelInfo(_ModelInfo info) {
    switch (info.type) {
      case LiteRtLmModelType.kLiteRtLmModelTypeEmbedding:
        break;
      case LiteRtLmModelType.kLiteRtLmModelTypeLlm:
        _refuse(
          '$_file is an LLM bundle, not an embedder. Install it with '
          '`installModel(fileType: ModelFileType.litertlm)` for inference, '
          'and an EmbeddingGemma 2 bundle with `installEmbedder()`.',
        );
      case LiteRtLmModelType.kLiteRtLmModelTypeUnknown || null:
        _refuse('$_file is not a LiteRT-LM embedding bundle.');
    }
    if (info.dimension <= 0) {
      _refuse('$_file declares no embedding dimension.');
    }
    final text = info.textSignatures;
    if (text == null || !text.any((length) => length > 0)) {
      _refuse('$_file declares no text signature to embed with.');
    }
    // D23: from the vision signatures, never supports_input_modality.
    final media = _config.declaredMedia;
    if (media.contains(EmbeddingModality.image) &&
        (info.visionSignatures?.isEmpty ?? true)) {
      _refuse(
        '$_file has no vision encoder; install '
        'embeddinggemma-2-text-vision-440m',
      );
    }
    if (media.any((m) => m != EmbeddingModality.text)) {
      _refuse(liteRtLmTextOnlyRefusal);
    }
    return text;
  }

  Never _refuse(String message) =>
      throw EmbeddingLoadException(message, engine: liteRtLmEngineTag);

  // ── Cache directory (D22) ──────────────────────────────────────────────

  /// Creates `<cacheBase>/<liteRtLmCacheDirName>/` for this copy of the
  /// bundle and returns its path. Nothing else is touched until the engine
  /// exists ([_deleteStaleSiblings]).
  String _createCacheDir() {
    try {
      final stat = File(_config.modelPath).statSync();
      if (stat.type == FileSystemEntityType.notFound) {
        throw FileSystemException('model file not found', _config.modelPath);
      }
      final name = liteRtLmCacheDirName(
        _file,
        size: stat.size,
        modified: stat.modified,
      );
      final dir = Directory(
        '${_config.cacheBase}${Platform.pathSeparator}$name',
      )..createSync(recursive: true);
      return dir.path;
    } on FileSystemException catch (e) {
      throw EmbeddingLoadException(
        'could not create the embedding cache directory for $_file under '
        '${_config.cacheBase}: ${e.osError?.message ?? e.message}',
        engine: liteRtLmEngineTag,
        cause: e,
      );
    }
  }

  /// Deletes the caches earlier copies of this file name left (a re-download
  /// or a new revision under the same name changes size or mtime). Runs only
  /// after this pass's engine exists, and spares any sibling touched within
  /// [_siblingGrace] — directory or newest entry — because another process
  /// (an app extension sharing the container, the app mid-replacement) may be
  /// creating its engine from it right now; it is collected by a later load.
  /// Costs disk, never correctness: a sibling that will not go is logged and
  /// the rest are still tried.
  void _deleteStaleSiblings(String cacheDir) {
    final keep = _fileName(cacheDir);
    final ours = RegExp(
      '^${liteRtLmCacheDirPrefix(_file)}-[0-9a-z]+-[0-9a-z]+\$',
    );
    final List<FileSystemEntity> entries;
    try {
      // Sorted, so the order is the same everywhere (listing order is not).
      entries = Directory(_config.cacheBase).listSync()
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException catch (e) {
      edgeAiLog(
        '[LiteRtLmEmbeddingPass] could not list ${_config.cacheBase}: $e',
      );
      return;
    }
    final now = _now();
    for (final entry in entries) {
      final name = _fileName(entry.path);
      if (entry is! Directory || name == keep || !ours.hasMatch(name)) {
        continue;
      }
      try {
        if (now.difference(_lastTouched(entry)) < _siblingGrace) continue;
        entry.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        edgeAiLog(
          '[LiteRtLmEmbeddingPass] could not delete the stale cache '
          '${entry.path}: $e',
        );
      }
    }
  }

  /// The latest modification of [dir] itself or of anything directly in it.
  static DateTime _lastTouched(Directory dir) {
    var latest = dir.statSync().modified;
    for (final entry in dir.listSync()) {
      final modified = entry.statSync().modified;
      if (modified.isAfter(latest)) latest = modified;
    }
    return latest;
  }

  /// How recently a sibling cache may have been touched and still be spared.
  static const _siblingGrace = Duration(minutes: 10);

  /// The engine writes its weight cache at create. When it could not (a
  /// path too long for the platform, a full disk) it runs anyway — slower to
  /// load and about 290 MB larger — and says so only in the native log. Said
  /// here in release builds too, because that is a cost the app pays silently.
  void _warnIfNoWeightCache(String cacheDir) {
    final bool empty;
    try {
      empty = Directory(cacheDir).listSync().whereType<File>().isEmpty;
    } on FileSystemException {
      return; // the directory existed a moment ago; nothing useful to add
    }
    if (!empty) return;
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_litertlm] WARNING: LiteRT-LM wrote no weight cache to '
      '$cacheDir while loading $_file, so this embedder runs without one '
      '(slower to load, about 290 MB more memory). The native log says why.',
    );
  }

  // ── Settings, engine, options ──────────────────────────────────────────

  Pointer<LiteRtLmEmbeddingEngine> _createEngine(
    LiteRtLmEmbeddingBindings b, {
    required int maxInputLength,
    required String cacheDir,
  }) {
    final path = _config.modelPath.toNativeUtf8(allocator: _alloc);
    final cpu = 'cpu'.toNativeUtf8(allocator: _alloc);
    final Pointer<LiteRtLmEmbeddingEngineSettings> settings;
    try {
      // Tower backends NULL (D26): present towers run on the main backend,
      // and naming one the bundle lacks fails create with code 5.
      b.litert_lm_clear_last_error();
      settings = b.litert_lm_embedding_engine_settings_create(
        path.cast(),
        cpu.cast(),
        nullptr,
        nullptr,
      );
    } finally {
      _alloc.free(path);
      _alloc.free(cpu);
    }
    if (settings == nullptr) {
      final (:code, :message) = _lastError(b);
      throw EmbeddingLoadException(
        'LiteRT-LM could not build embedding settings for $_file: $message',
        engine: liteRtLmEngineTag,
        nativeCode: code == _statusOk ? null : code,
      );
    }
    try {
      final dir = cacheDir.toNativeUtf8(allocator: _alloc);
      try {
        b.litert_lm_embedding_engine_settings_set_cache_dir(
          settings,
          dir.cast(),
        );
      } finally {
        _alloc.free(dir);
      }
      b.litert_lm_embedding_engine_settings_set_max_input_length(
        settings,
        maxInputLength,
      );
      final threads = _config.numThreads;
      if (threads != null) {
        b.litert_lm_embedding_engine_settings_set_num_threads(
          settings,
          threads,
        );
      }
      b.litert_lm_clear_last_error();
      final engine = b.litert_lm_embedding_engine_create(settings);
      if (engine == nullptr) {
        final (:code, :message) = _lastError(b);
        // Measured: a missing or read-only cache dir is code 3 at create.
        throw EmbeddingLoadException(
          code == _statusInvalidArgument
              ? 'LiteRT-LM refused the embedding cache directory $cacheDir '
                    '(missing or not writable): $message'
              : 'LiteRT-LM could not create the embedding engine for $_file: '
                    '$message',
          engine: liteRtLmEngineTag,
          nativeCode: code == _statusOk ? null : code,
        );
      }
      return engine;
    } finally {
      // The engine copied what it needs.
      b.litert_lm_embedding_engine_settings_delete(settings);
    }
  }

  Pointer<LiteRtLmEmbeddingOptions> _createOptions(
    LiteRtLmEmbeddingBindings b,
  ) {
    final options = b.litert_lm_embedding_options_create();
    if (options == nullptr) {
      // `new` in C++; a NULL here sets no error.
      throw const EmbeddingLoadException(
        'litert_lm_embedding_options_create returned NULL',
        engine: liteRtLmEngineTag,
      );
    }
    b
      ..litert_lm_embedding_options_set_normalize(options, true)
      // Pinned (D26): BOS 2 / EOS 1, as Sentence Transformers; off changes
      // the vectors (cos ≈ 0.90).
      ..litert_lm_embedding_options_set_insert_special_tokens(options, true)
      ..litert_lm_embedding_options_set_input_overflow_strategy(
        options,
        LiteRtLmInputOverflowStrategy.kLiteRtLmInputOverflowStrategyError,
      );
    // output_size is never set: MRL is an app recipe (D18).
    return options;
  }
}

/// The text input setting and the resulting limit for a bundle whose text
/// signatures are [textSignatures] (at least one positive).
///
/// The setting is [liteRtLmMaxInputLength] (D21), or the largest signature
/// when none reaches it; the engine then accepts inputs up to the smallest
/// signature at or above the setting — that is `maxInputTokens`.
({int setting, int maxInputTokens}) liteRtLmInputLimit(
  List<int> textSignatures,
) {
  final lengths = [
    for (final length in textSignatures)
      if (length > 0) length,
  ]..sort();
  if (lengths.isEmpty) {
    throw ArgumentError.value(textSignatures, 'textSignatures', 'no length');
  }
  final setting = math.min(liteRtLmMaxInputLength, lengths.last);
  return (
    setting: setting,
    maxInputTokens: lengths.firstWhere((length) => length >= setting),
  );
}

/// The cache directory name for one copy of a bundle:
/// `<liteRtLmCacheDirPrefix(file)>-<size>-<mtime ms>`, both numbers in base 36,
/// so a re-downloaded or replaced file never reads the weight cache of another
/// (the engine's own cache file names carry the same pair).
///
/// Short on purpose (R5 D22 spells the file name out): the engine names its
/// cache file `<model file name>_<mtime>_<size>.<graph>.xnnpack_cache` inside
/// this directory, and on Windows the whole path must stay under MAX_PATH or
/// the engine runs without a weight cache. With `<cache>/flutter_edge_ai/emb/`
/// and this 24-character name the example app's path is 232 characters for a
/// 20-character user name; spelling the file name out made it about 284.
String liteRtLmCacheDirName(
  String modelFileName, {
  required int size,
  required DateTime modified,
}) =>
    '${liteRtLmCacheDirPrefix(modelFileName)}-${size.toRadixString(36)}-'
    '${modified.millisecondsSinceEpoch.toRadixString(36)}';

/// The part of [liteRtLmCacheDirName] that names the file: the first 8 hex
/// digits of the SHA-256 of its name. Directories with this prefix and another
/// size or time are stale copies of the same file.
String liteRtLmCacheDirPrefix(String modelFileName) =>
    sha256.convert(utf8.encode(modelFileName)).toString().substring(0, 8);

typedef _ModelInfo = ({
  LiteRtLmModelType? type,
  int dimension,
  List<int>? textSignatures,
  List<int>? visionSignatures,
});

const _ModelInfo _unknownModelInfo = (
  type: null,
  dimension: -1,
  textSignatures: null,
  visionSignatures: null,
);

/// The calling thread's last LiteRT-LM error, copied. Call it right after the
/// failing call, before any other native call or `await`, and clear the state
/// right before that call: success never resets it, so without the clear an
/// earlier failure on this (pooled) thread would read as this one's. Code 0
/// after a NULL means the call reported nothing.
({int code, String message}) _lastError(LiteRtLmEmbeddingBindings b) {
  final code = b.litert_lm_get_last_error_code();
  final message = b.litert_lm_get_last_error_message();
  return (
    code: code,
    message: code == _statusOk || message == nullptr
        ? 'no error reported (status $code)'
        : message.cast<Utf8>().toDartString(),
  );
}

String _fileName(String path) => path.split(RegExp(r'[/\\]')).last;
