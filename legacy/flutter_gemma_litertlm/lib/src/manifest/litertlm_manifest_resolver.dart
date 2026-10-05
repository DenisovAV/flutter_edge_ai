import 'dart:convert';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/model.dart' show ModelFileType, ModelType;
import 'package:flutter_gemma/core/registry/hugging_face_resolver.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'litertlm_manifest.dart';
import 'manifest_fetch_types.dart';
import 'manifest_fetch_web.dart' if (dart.library.io) 'manifest_fetch_io.dart';

export 'manifest_fetch_types.dart' show ManifestFetch, ManifestFetchException;

/// [HuggingFaceResolver] for repos that ship a `litertlm_manifest.json` —
/// the deployment manifest at the root of `.litertlm` model repos
/// (spec: https://github.com/john-rocky/hf-to-litertlm/blob/main/manifest/SCHEMA.md).
///
/// The manifest carries what the `.litertlm` bundle cannot: which of the
/// repo's files fits which platform (with verified-fastest recommendations),
/// sha256/size identity, and curated session guidance. Everything it returns
/// is an *overridable default* — the bundle header stays authoritative for the
/// conversation contract, and an explicit argument at the call site always
/// wins (core's `explicit arg > manifest > SDK default` merge).
///
/// ```dart
/// // LiteRtLmEngine carries this resolver (HuggingFaceResolverSource), so
/// // registering the engine auto-registers it — no huggingFaceResolvers: list.
/// // Pass one explicitly only to override, e.g. LitertlmManifestResolver(revision: …).
/// await FlutterGemma.initialize(inferenceEngines: [LiteRtLmEngine()]);
///
/// final r = await FlutterGemma.resolveHuggingFace(
///     'litert-community/Qwen3-4B-Thinking-2507',
///     fileType: ModelFileType.litertlm);
/// await FlutterGemma.installModel(
///       modelType: r.modelType ?? ModelType.general,
///       fileType: r.fileType,
///     )
///     .fromNetwork(r.url) // r.url honours this resolver's [revision] pin
///     .install();
/// final model = await FlutterGemma.getActiveModel(defaults: r.runtime);
/// final session = await model.createSession(
///   enableThinking: r.runtime.isThinking ?? false,
///   // minOutputTokens is a FLOOR, not a cap: keep the app's own budget
///   // unless the manifest asks for more (`max` from dart:math).
///   maxOutputTokens: max(1024, r.runtime.minOutputTokens ?? 0),
/// );
/// ```
///
/// Throws [ManifestFetchException] when the repo does not ship a manifest
/// (HTTP 404 — install with `fromHuggingFace(repo, file:)` instead), when
/// auth is missing or rejected (401/403 carry gated-repo guidance), or the
/// GET fails otherwise; and [FormatException] when the file exists but is
/// not a supported `0.1.x` manifest — including any wrong-typed field, which
/// never escapes as a raw `TypeError`.
class LitertlmManifestResolver implements HuggingFaceResolver {
  /// Git revision (branch, tag, or commit) the manifest AND the resolved file
  /// URL are pinned to. Defaults to `main`; pin a commit for reproducible
  /// installs — the returned `url` carries it, which is why installs go
  /// through `fromNetwork(r.url)`.
  final String revision;

  /// Test/app seam for the HTTP GET; null uses the platform default
  /// (`dart:io` [HttpClient] natively, the browser's `fetch` on web).
  final ManifestFetch? fetch;

  const LitertlmManifestResolver({this.revision = 'main', this.fetch});

  @override
  String get name => 'litertlm-manifest';

  @override
  int get priority => 0;

  /// Claims exactly [ModelFileType.litertlm] — never a null hint. With more
  /// than one resolver registered, a bare `resolveHuggingFace(repo)` must not
  /// route by registration order (it could send an `.onnx` repo here); the
  /// caller knows which file type it is installing, so it declares it.
  @override
  bool canResolve(String repo, {ModelFileType? fileType}) =>
      fileType == ModelFileType.litertlm;

  @override
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  }) async {
    // Fail loud at the seam (same stance as fromHuggingFace): an empty repo
    // would otherwise become a URL that 404s far downstream.
    if (repo.trim().isEmpty) {
      throw ArgumentError.value(repo, 'repo', 'must be a non-empty "org/name"');
    }

    // The revision is one path segment (a slash-bearing ref like `refs/pr/1`
    // must be percent-encoded on Hugging Face `/resolve/` paths) — same rule
    // as the vendored reader's Resolution.url.
    final rev = Uri.encodeComponent(revision);
    final manifestUrl = Uri.parse(
      'https://huggingface.co/$repo/resolve/$rev/litertlm_manifest.json',
    );
    // The URL is always huggingface.co (built two lines up), so the token —
    // core passes its configured HF token by default — is safe to attach.
    final headers = <String, String>{
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };

    String body;
    try {
      body = await (fetch ?? defaultManifestFetch)(manifestUrl, headers);
    } on ManifestFetchException catch (e) {
      // Measured Hugging Face behaviour: a PUBLIC repo missing the file is a
      // real 404, but an unauthenticated request to a gated, private, or
      // NONEXISTENT repo is answered 401 (repo existence is not revealed) —
      // so each gets its own guidance.
      switch (e.statusCode) {
        case 404:
          throw ManifestFetchException(
            manifestUrl,
            '"$repo" does not ship a litertlm_manifest.json at revision '
            '"$revision". Install a specific file instead: '
            'installModel(...).fromHuggingFace(repo, file: ...).',
            statusCode: 404,
          );
        case 401:
          throw ManifestFetchException(
            manifestUrl,
            'Hugging Face answered 401 for "$repo" — it does that for gated '
            'and private repos without a valid token, and for repo ids that '
            'do not exist. Pass a token '
            '(FlutterGemma.initialize(huggingFaceToken:) or '
            'resolveHuggingFace(token:)), or check the repo id.',
            statusCode: 401,
          );
        case 403:
          throw ManifestFetchException(
            manifestUrl,
            'Hugging Face rejected the token for "$repo" (403). A gated repo '
            'also needs its license accepted on huggingface.co first.',
            statusCode: 403,
          );
        default:
          rethrow;
      }
    }

    final LitertlmManifest manifest;
    final String baseModel;
    final String architecture;
    final bool capabilitiesDeclared;
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      manifest = LitertlmManifest.fromJson(decoded, revision: revision);
      // Every raw field the mapping reads is read HERE, so a wrong-typed one
      // (`"base_model": 3`) is a parse error like any other rather than a
      // TypeError thrown later from the mapping.
      final rawModel = decoded['model'] as Map<String, dynamic>? ?? const {};
      baseModel = rawModel['base_model'] as String? ?? '';
      architecture = rawModel['architecture'] as String? ?? '';
      // The converter derives `capabilities` from the bundle header, so a
      // manifest without the block never looked: that is "silent", which the
      // seam spells `null` — not "declared unsupported", which is `false`.
      capabilitiesDeclared = rawModel['capabilities'] != null;
    } on FormatException {
      rethrow;
    } catch (e) {
      // TypeError from a malformed field — surface as the same parse-error
      // family instead of an opaque cast failure.
      throw FormatException('malformed litertlm_manifest.json in "$repo": $e');
    }

    // Core sends 'unknown' for hosts outside its documented set; the
    // manifest vocabulary has no such platform, so treat it as "no hint"
    // rather than a key that can never match a recommendation.
    final platformKey = platform == 'unknown' ? null : platform;
    final requestedBackend = _wireName(preferredBackend);
    String? droppedHint;
    var resolution = manifest.resolve(
      platform: platformKey,
      backend: requestedBackend,
      // v1 resolves on platform only: `device_class` values in published
      // manifests are free strings with no defined vocabulary, and
      // flutter_gemma has no device-class detection to feed one from.
    );
    if (resolution == null) {
      // Only an explicit backend request can filter to nothing: the spec's
      // resolution rule makes it a filter, and the reader returns null rather
      // than substituting a backend the caller didn't ask for. At this seam
      // [preferredBackend] is a hint (core's contract: prefer it "when the
      // metadata lists it"), so drop it and resolve without — the returned
      // runtime.preferredBackend then carries the manifest's own choice,
      // never a silent claim of the requested backend.
      droppedHint = requestedBackend;
      gemmaLog(
        '[LitertlmManifestResolver] no variant of $repo is verified on '
        '"$requestedBackend" — dropping the backend hint.',
      );
      // Never null without a backend filter: a parsed manifest has >= 1
      // variant and every variant >= 1 backend.
      resolution = manifest.resolve(platform: platformKey)!;
    }

    gemmaLog(
      '[LitertlmManifestResolver] $repo → ${resolution.file} '
      '(${resolution.backend}; ${resolution.reason})',
    );

    return ResolvedHfModel(
      file: resolution.file,
      url: _fileUrl(repo, resolution.file),
      fileType: ModelFileType.litertlm,
      modelType: mapModelType(
        baseModel: baseModel,
        displayName: manifest.displayName,
        architecture: architecture,
      ),
      sha256: resolution.variant.sha256,
      sizeBytes: resolution.variant.sizeBytes,
      runtime: ModelRuntimeDefaults(
        maxTokens: resolution.contextLength,
        preferredBackend: _fromWireName(resolution.backend, repo),
        supportImage: capabilitiesDeclared
            ? resolution.capabilities.vision
            : null,
        supportAudio: capabilitiesDeclared
            ? resolution.capabilities.audio
            : null,
        isThinking: capabilitiesDeclared
            ? resolution.capabilities.thinkingDeclared
            : null,
        minOutputTokens: _minOutputTokens(resolution.sessionDefaults, repo),
      ),
      notes: List.unmodifiable([
        ...resolution.notes,
        // `session_defaults` is an open object; its optional `notes` string is
        // curated guidance (e.g. why a reasoning model needs the output
        // floor) — surface it with the platform notes.
        if (resolution.sessionDefaults?['notes'] is String)
          resolution.sessionDefaults!['notes'] as String,
        // A dropped backend hint is a downgrade the app should see in a
        // release build too (gemmaLog is debug-only), so it also lands in the
        // notes the app already surfaces.
        if (droppedHint != null)
          'No variant of "$repo" is verified on the requested $droppedHint '
              'backend; resolved without that hint (${resolution.backend}).',
      ]),
    );
  }

  /// `…/resolve/<revision>/<file>`, every segment encoded independently so a
  /// repo that nests variants in subfolders keeps its path structure — same
  /// rule as core's `fromHuggingFace`. The revision is a single segment.
  String _fileUrl(String repo, String file) {
    final encoded = file.split('/').map(Uri.encodeComponent).join('/');
    return 'https://huggingface.co/$repo/resolve/'
        '${Uri.encodeComponent(revision)}/$encoded';
  }

  String? _wireName(PreferredBackend? backend) => switch (backend) {
    null => null,
    PreferredBackend.cpu => 'cpu',
    PreferredBackend.gpu => 'gpu',
    PreferredBackend.npu => 'npu',
  };

  PreferredBackend? _fromWireName(String backend, String repo) {
    switch (backend) {
      case 'cpu':
        return PreferredBackend.cpu;
      case 'gpu':
        return PreferredBackend.gpu;
      case 'npu':
        return PreferredBackend.npu;
      default:
        // A backend name this plugin has no enum for (schema `backends` is
        // open). Null = "manifest is silent" — the SDK default applies.
        gemmaLog(
          '[LitertlmManifestResolver] $repo recommends backend "$backend", '
          'which flutter_gemma has no PreferredBackend for — leaving the '
          'backend to the SDK default.',
        );
        return null;
    }
  }

  /// `session_defaults.max_output_tokens_min`, tolerantly: the schema
  /// declares `session_defaults` as an open object, so the key is read by
  /// name. A value outside the schema's `integer, minimum: 1` is logged and
  /// treated as "not declared" — an advisory knob must not fail the whole
  /// manifest.
  int? _minOutputTokens(Map<String, dynamic>? sessionDefaults, String repo) {
    final v = sessionDefaults?['max_output_tokens_min'];
    if (v == null) return null;
    if (v is int && v >= 1) return v;
    gemmaLog(
      '[LitertlmManifestResolver] $repo declares '
      'session_defaults.max_output_tokens_min = $v, which is not a positive '
      'integer (schema: integer, minimum 1) — ignoring it.',
    );
    return null;
  }

  /// Maps the manifest's model identity onto a [ModelType], or null when no
  /// mapping is certain — the app then supplies one (`r.modelType ??
  /// ModelType.general`).
  ///
  /// Deliberately conservative: on iOS `.litertlm` chats are formatted
  /// manually by [ModelType] (Android/desktop read the template from the
  /// bundle), so a wrong guess breaks conversations there. The manifest's
  /// `architecture` is free prose that names *compute* lineage — e.g.
  /// granite-docling says "Llama-architecture granite decoder", which must NOT
  /// become [ModelType.llama] — so family words match only the curated
  /// `base_model` + `display_name` ids, and `architecture` is consulted for
  /// exactly two machine-precise `*ForCausalLM` class tokens (they catch
  /// finetunes whose ids drop the family name, e.g. an ASR normalizer built
  /// on Qwen3).
  ///
  /// Qwen3.5 maps to [ModelType.qwen], not `qwen3`: same ChatML handling,
  /// but `qwen3` also appends ` /no_think` to user turns when thinking is
  /// off, which Qwen3.5 does not understand and would read as literal text.
  @visibleForTesting
  static ModelType? mapModelType({
    required String baseModel,
    required String displayName,
    required String architecture,
  }) {
    final id = '$baseModel $displayName'.toLowerCase();
    final arch = architecture.toLowerCase();
    if (id.contains('deepseek')) return ModelType.deepSeek;
    if (id.contains('functiongemma') ||
        id.contains('function-gemma') ||
        id.contains('function_gemma')) {
      return ModelType.functionGemma;
    }
    // The lookahead keeps size-suffixed ids ("gemma-4b") out of gemma4 —
    // that enum value is the Gemma 4 E2B/E4B generation, not a 4B Gemma 3.
    if (RegExp(r'gemma[ _-]?4(?![0-9b])').hasMatch(id)) {
      return ModelType.gemma4;
    }
    if (id.contains('gemma')) return ModelType.gemmaIt;
    if (id.contains('qwen3.5')) return ModelType.qwen;
    if (id.contains('qwen3') || arch.contains('qwen3forcausallm')) {
      return ModelType.qwen3;
    }
    if (id.contains('qwen') || arch.contains('qwen2forcausallm')) {
      return ModelType.qwen;
    }
    if (RegExp(r'(^|[^a-z])phi[ _-]?\d').hasMatch(id)) return ModelType.phi;
    if (RegExp(r'(^|[^a-z])llama').hasMatch(id)) return ModelType.llama;
    return null;
  }
}
