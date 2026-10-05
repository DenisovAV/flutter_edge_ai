import 'dart:convert';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart'
    show HuggingFaceResolver, ResolvedHfFile, ResolvedHfModel;
import 'package:flutter_gemma/core/utils/file_name_utils.dart'
    show FileNameUtils;

import 'hf/hf_fetch_types.dart';
import 'hf/hf_fetch_web.dart' if (dart.library.io) 'hf/hf_fetch_io.dart';

/// [HuggingFaceResolver] for ONNX (ORT-GenAI) models.
///
/// An ORT-GenAI model is a DIRECTORY — `genai_config.json` + `model.onnx`
/// (+ `model.onnx_data` for external weights) + tokenizer files — and a repo
/// usually ships several execution-provider (EP) variants, one per subfolder
/// (`cpu_and_mobile/…`, `cuda/…`, …). On NATIVE this resolver lists the repo
/// via the Hugging Face tree API, picks one EP folder, and returns every file
/// in it as a directory [ResolvedHfModel] (`files` + `directoryName`) — core's
/// directory-install path then downloads them into a per-model subdirectory.
///
/// On WEB, ONNX generation is fileless (Transformers.js owns the repo id and
/// caches it itself), so this returns a single-file/`files == null` model whose
/// `NetworkSource` URL maps to the repo id — the existing web install path
/// handles it, no filesystem needed.
///
/// EP selection: pass [variant] (the exact folder, e.g.
/// `cpu_and_mobile/cpu-int4-…`) to pin one; otherwise the resolver auto-picks a
/// CPU/mobile folder, falling back to the sole/first variant when none looks
/// CPU. The bundled ORT-GenAI runtime is CPU-only, so GPU execution-provider
/// folders are NOT auto-selected and `preferredBackend` is ignored. Pinning a
/// GPU [variant] is allowed but flagged in the result notes — it will likely
/// fail to load until a GPU runtime is bundled.
///
/// Auto-registered from `OnnxEngine` (which implements
/// `HuggingFaceResolverSource`), so registering the engine is enough; pass an
/// explicit `OnnxHuggingFaceResolver(variant: …)` to
/// `FlutterGemma.initialize(huggingFaceResolvers: [...])` only to override.
class OnnxHuggingFaceResolver implements HuggingFaceResolver {
  /// [variant] pins an exact EP subfolder (skips the backend heuristic).
  /// [revision] is the repo revision to pin (default `main`). [fetch] is a
  /// test/app seam for the HTTP GET; null uses the platform default (`dart:io`
  /// [HttpClient] natively, the browser's `fetch` on web).
  const OnnxHuggingFaceResolver({
    String? variant,
    String revision = 'main',
    HfFetch? fetch,
  }) : _variant = variant,
       _revision = revision,
       _fetch = fetch;

  final String? _variant;
  final String _revision;
  final HfFetch? _fetch;

  /// Single-page tree-listing budget. A response at this size is treated as
  /// possibly-truncated and refused (see [resolve]) — full pagination is a
  /// follow-up.
  static const _treeLimit = 1000;

  @override
  String get name => 'onnx-huggingface';

  @override
  int get priority => 0;

  @override
  bool canResolve(String repo, {ModelFileType? fileType}) =>
      fileType == ModelFileType.onnx;

  @override
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  }) async {
    if (repo.trim().isEmpty) {
      throw ArgumentError.value(repo, 'repo', 'must be a non-empty "org/name"');
    }

    // WEB: ONNX generation is fileless (Transformers.js resolves + caches the
    // repo from its id). Return a files==null model whose NetworkSource URL maps
    // to the repo id (see transformers_repo_id.dart); the web install path uses
    // it directly, and no directory download is attempted (there is no FS).
    if (platform == 'web') {
      return ResolvedHfModel(
        file: repo.split('/').last,
        url: 'https://huggingface.co/$repo',
        fileType: ModelFileType.onnx,
      );
    }

    final fetch = _fetch ?? defaultHfFetch;
    final headers = <String, String>{
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    // List the repo's file tree (recursive; one page is enough for the handful
    // of files an ORT-GenAI model ships — limit guards a many-variant repo).
    final treeUrl = Uri.parse(
      'https://huggingface.co/api/models/$repo/tree/$_revision'
      '?recursive=true&limit=$_treeLimit',
    );
    final String body;
    try {
      body = await fetch(treeUrl, headers);
    } on HfFetchException catch (e) {
      if (e.statusCode == 404) {
        throw StateError(
          'Hugging Face repo "$repo" (revision "$_revision") was not found, or '
          'its file tree is not accessible${token == null ? " — a gated repo "
                    "needs a token" : ""}.',
        );
      }
      rethrow;
    }

    final decoded = jsonDecode(body);
    if (decoded is! List) {
      throw StateError(
        'Unexpected Hugging Face tree response for "$repo" — expected a JSON '
        'array, got ${decoded.runtimeType}. The repo/revision may be wrong or '
        'the request was rate-limited/redirected to an error page.',
      );
    }
    // A full page means the listing may be TRUNCATED. `HfFetch` returns only the
    // body, so HF's pagination-continuation header is invisible here — refuse
    // rather than silently install an incomplete directory (a dropped
    // `model.onnx_data` past the cutoff would install "successfully" then fail
    // to load). Full pagination is a follow-up; pin the variant folder to avoid.
    if (decoded.length >= _treeLimit) {
      throw StateError(
        'Hugging Face repo "$repo" returned $_treeLimit or more tree entries; '
        'the resolver lists the whole repo in one page and does not paginate '
        'yet, so a complete model directory cannot be guaranteed for a repo this '
        'large (pinning a variant does not shrink the listing). Install it from '
        'a local directory with fromFile(genai_config.json) instead.',
      );
    }
    // Keep file entries, skip directories. A `type == 'file'` entry whose
    // `path` is missing/non-string is a MALFORMED listing, not a directory —
    // surface it loudly rather than silently dropping what might be a required
    // model file (a silent drop installs an incomplete directory that only
    // fails later inside OgaCreateModel).
    final filePaths = <String>[];
    for (final e in decoded) {
      if (e is! Map || e['type'] != 'file') continue;
      final path = e['path'];
      if (path is! String) {
        throw StateError(
          'Malformed Hugging Face tree entry for "$repo": a file entry has no '
          'string "path" ($e). The listing is corrupt; refusing to install a '
          'possibly incomplete model directory.',
        );
      }
      filePaths.add(path);
    }

    // Folders that contain a genai_config.json — the ORT-GenAI signal. '' means
    // the repo root. Sorted so the tie-break in [_pickFolder] is deterministic
    // (the HF tree order is not).
    const marker = 'genai_config.json';
    final configFolders = <String>[
      for (final p in filePaths)
        if (p == marker)
          ''
        else if (p.endsWith('/$marker'))
          p.substring(0, p.length - marker.length - 1),
    ].toSet().toList()..sort();
    if (configFolders.isEmpty) {
      throw StateError(
        'Hugging Face repo "$repo" has no genai_config.json — it is not an '
        'ORT-GenAI model directory. Install a repo that ships an ORT-GenAI '
        'export (genai_config.json + model.onnx + tokenizer).',
      );
    }

    final folder = _pickFolder(configFolders, repo: repo);
    final prefix = folder.isEmpty ? '' : '$folder/';

    // The chosen folder's DIRECT children (ORT-GenAI folders are flat), sorted
    // for a deterministic file order.
    final members = <String>[
      for (final p in filePaths)
        if (p.startsWith(prefix) && !p.substring(prefix.length).contains('/'))
          p,
    ]..sort();

    // A genai_config.json alone is not a loadable model — require a `.onnx`
    // graph. This checks the graph file is PRESENT; it does NOT parse
    // genai_config to verify every weight it references (external `.onnx_data`,
    // tokenizer aux) is in the folder, so a mis-export can still fail inside
    // OgaCreateModel. It catches the common incomplete case: config + tokenizer,
    // no `.onnx` at all. (`.onnx_data` ends in `.onnx_data`, not `.onnx`, so an
    // external-data blob without its graph does not satisfy this.)
    if (!members.any((p) => p.endsWith('.onnx'))) {
      throw StateError(
        'The ORT-GenAI directory '
        '"${folder.isEmpty ? "(repo root)" : folder}" in "$repo" has a '
        'genai_config.json but no .onnx model file — it cannot load. The repo '
        'is likely an incomplete export.',
      );
    }

    String urlFor(String path) {
      final encoded = path.split('/').map(Uri.encodeComponent).join('/');
      return 'https://huggingface.co/$repo/resolve/$_revision/$encoded';
    }

    final files = <ResolvedHfFile>[
      for (final p in members)
        ResolvedHfFile(name: p.substring(prefix.length), url: urlFor(p)),
    ];

    // Base the EP note on the folder actually PICKED, not merely on whether a
    // variant was pinned: `_pickFolder`'s fallback (a repo with no CPU/mobile
    // folder) and an explicit GPU `variant:` both land on a non-CPU folder while
    // `_variant == null`/`!= null` says nothing about it. Warn only when the
    // pick looks GPU (the bundled runtime is CPU-only → it will likely not
    // load); a CPU/mobile, root, or unlabeled export runs on CPU as expected.
    final notes = <String>[
      'Resolved ORT-GenAI directory '
          '"${folder.isEmpty ? "(repo root)" : folder}" (${files.length} files).',
      if (_looksGpu(folder))
        'Selected the GPU execution-provider variant "$folder", but the bundled '
            'ORT-GenAI runtime is CPU-only — it may fail to load. Pin a '
            'CPU/mobile variant with OnnxHuggingFaceResolver(variant: …).'
      else
        'Installed the CPU execution-provider variant; on-device GPU execution '
            'is not bundled yet.',
    ];

    return ResolvedHfModel(
      file: marker, // the primary the engine loads from
      // Reuse the primary's URL from [files] so it can never desync from the
      // matching ResolvedHfFile.url.
      url: files.firstWhere((f) => f.name == marker).url,
      fileType: ModelFileType.onnx,
      files: files,
      directoryName: FileNameUtils.sanitizeHfDirName(
        repo,
        variant: folder.isEmpty ? null : folder,
      ),
      notes: List.unmodifiable(notes),
    );
  }

  /// Picks the EP folder among [folders] (each a path that holds a
  /// genai_config.json). An explicit [variant] wins; otherwise a CPU/mobile
  /// folder is preferred (the bundled runtime is CPU-only), falling back to the
  /// sole/first variant when none looks CPU.
  String _pickFolder(List<String> folders, {required String repo}) {
    if (_variant != null) {
      if (!folders.contains(_variant)) {
        throw ArgumentError.value(
          _variant,
          'variant',
          'has no genai_config.json in "$repo" (available: '
              '${folders.map((f) => f.isEmpty ? "(root)" : f).join(", ")})',
        );
      }
      return _variant;
    }
    if (folders.length == 1) return folders.first;
    // v1: the bundled ORT-GenAI runtime is CPU-only (GPU EP libs are not
    // shipped), so the automatic pick always prefers a CPU/mobile variant —
    // auto-picking a CUDA export the CPU runtime can't load would be worse than
    // useless. Pin a GPU folder explicitly with `variant:` if you have a GPU
    // runtime. [folders] is already sorted, so both branches are deterministic.
    final cpu = folders.where(_looksCpu).toList();
    return cpu.isNotEmpty ? cpu.first : folders.first;
  }

  static final _cpuRe = RegExp(r'cpu|mobile', caseSensitive: false);
  static bool _looksCpu(String folder) => _cpuRe.hasMatch(folder);

  // GPU/NPU execution-provider folder labels the bundled CPU-only runtime
  // cannot load. Used only to phrase the result note honestly — NOT for
  // selection (auto-pick never chooses these; only an explicit `variant:` does).
  static final _gpuRe = RegExp(
    r'cuda|dml|directml|tensorrt|rocm|coreml|webgpu|gpu|npu|qnn',
    caseSensitive: false,
  );
  static bool _looksGpu(String folder) => _gpuRe.hasMatch(folder);
}
