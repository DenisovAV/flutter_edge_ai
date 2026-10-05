/// Reader for `litertlm_manifest.json` — the deployment manifest shipped at
/// the root of `.litertlm` model repos on Hugging Face.
///
/// Vendored from the reference reader at
/// https://github.com/john-rocky/hf-to-litertlm/tree/main/readers/dart (same
/// author); the resolution algorithm here and there must stay identical, so a
/// repo resolves to the same file no matter which integration reads it.
/// Spec: https://github.com/john-rocky/hf-to-litertlm/blob/main/manifest/SCHEMA.md
///
/// IO-free by design: pass a parsed manifest map (or JSON string). The HTTP
/// lives in [LitertlmManifestResolver] so this stays a pure, unit-testable
/// mirror of the reference implementation. No imports beyond dart:convert.
library;

import 'dart:convert';

/// The model's thinking-channel markers, exact strings, whitespace included
/// (e.g. Qwen3 ships `'<think>\n'` / `'\n</think>'`, LFM2.5 bare tags).
class ThinkingChannel {
  final String start;
  final String end;
  const ThinkingChannel(this.start, this.end);
}

/// One entry of the bundle's declared channel set (manifest 0.1.1+) —
/// thinking, tool-call, or anything else a model declares.
class DeclaredChannel {
  final String name;
  final String start;
  final String end;
  final bool isReasoning;
  const DeclaredChannel(
    this.name,
    this.start,
    this.end, {
    this.isReasoning = false,
  });
}

/// `model.capabilities` — declared (bundle-derived) capability flags.
class Capabilities {
  final bool vision;
  final bool audio;
  final bool thinkingDeclared;
  final ThinkingChannel? thinkingChannel;

  /// Full bundle-declared channel set (0.1.1+). Empty for 0.1.0 manifests;
  /// fall back to [thinkingChannel] plus your runtime's default channels.
  final List<DeclaredChannel> channels;

  const Capabilities({
    this.vision = false,
    this.audio = false,
    this.thinkingDeclared = false,
    this.thinkingChannel,
    this.channels = const [],
  });

  factory Capabilities.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const Capabilities();
    final t = j['thinking'] as Map<String, dynamic>?;
    final ch = t?['channel'] as Map<String, dynamic>?;
    return Capabilities(
      vision: j['vision'] == true,
      audio: j['audio'] == true,
      thinkingDeclared: t?['declared'] == true,
      thinkingChannel: ch == null
          ? null
          : ThinkingChannel(
              ch['start'] as String? ?? '',
              ch['end'] as String? ?? '',
            ),
      channels: ((j['channels'] as List?) ?? const [])
          .map((e) => e as Map<String, dynamic>)
          .map(
            (e) => DeclaredChannel(
              e['name'] as String? ?? '',
              e['start'] as String? ?? '',
              e['end'] as String? ?? '',
              isReasoning: e['is_reasoning'] == true,
            ),
          )
          .toList(),
    );
  }
}

/// One `recommended[]` row: the verified-fastest choice for a platform (and
/// optionally a free-string device class — no vocabulary is defined in v0.1).
class Recommendation {
  final String platform;
  final String? deviceClass;
  final String backend;
  final String? reason;
  const Recommendation(
    this.platform,
    this.deviceClass,
    this.backend,
    this.reason,
  );

  factory Recommendation.fromJson(Map<String, dynamic> j) => Recommendation(
    j['platform'] as String,
    j['device_class'] as String?,
    j['backend'] as String,
    j['reason'] as String?,
  );
}

/// One `variants[]` entry — a single `.litertlm` file in the repo.
class Variant {
  final String file;
  final String? sha256;
  final int? sizeBytes;
  final String quantization;

  /// Backends this file is *verified to generate* on — not merely load.
  final List<String> backends;
  final String? defaultBackend;
  final String? minRuntimeVersion;
  final List<Recommendation> recommended;
  final List<String> platformNotes;
  final List<String> knownIssues;

  /// The raw variant JSON, for fields the typed surface doesn't consume
  /// (`measured[]`, `sections`, `requirements.peak_ram_mb`).
  final Map<String, dynamic> raw;

  Variant.fromJson(Map<String, dynamic> j)
    : file = j['file'] as String,
      sha256 = j['sha256'] as String?,
      sizeBytes = j['size_bytes'] as int?,
      quantization = j['quantization'] as String? ?? '',
      backends = _requireBackends(j),
      defaultBackend = j['default_backend'] as String?,
      minRuntimeVersion = j['min_runtime_version'] as String?,
      recommended = ((j['recommended'] as List?) ?? const [])
          .map((e) => Recommendation.fromJson(e as Map<String, dynamic>))
          .toList(),
      // `.toList()` after `.cast<String>()` on purpose: the cast alone is
      // lazy, so a non-string element would surface as a TypeError at first
      // use (inside resolve()) instead of failing here, at parse.
      platformNotes =
          (((j['requirements'] as Map<String, dynamic>?)?['platform_notes'])
                  as List?)
              ?.cast<String>()
              .toList() ??
          const [],
      knownIssues =
          (j['known_issues'] as List?)?.cast<String>().toList() ?? const [],
      raw = j;

  static List<String> _requireBackends(Map<String, dynamic> j) {
    final b = (j['backends'] as List?)?.cast<String>().toList();
    if (b == null || b.isEmpty) {
      throw FormatException(
        'variant ${j['file']} lists no backends (schema requires minItems: 1)',
      );
    }
    return b;
  }
}

/// A parsed `litertlm_manifest.json`.
class LitertlmManifest {
  final String schemaVersion;
  final String repo;
  final String displayName;

  /// `model.context_length` — on the model, not the variant (bundle
  /// `max_num_tokens`, identical across a repo's variants).
  final int? contextLength;
  final Capabilities capabilities;

  /// `model.session_defaults` — an OPEN object: the JSON Schema declares no
  /// properties for it, so treat the object and every key as optional. Keys in
  /// shipped manifests today: `max_output_tokens_min` (int), `notes` (string),
  /// and sampler hints (`temperature`, `top_k`, `top_p`).
  final Map<String, dynamic>? sessionDefaults;
  final List<Variant> variants;

  /// Not part of the file: the revision the manifest was fetched at (the
  /// caller does its own HTTP), so [resolve] URLs follow a pinned fetch.
  /// Defaults to `main`.
  final String? revision;

  LitertlmManifest._(
    this.schemaVersion,
    this.repo,
    this.displayName,
    this.contextLength,
    this.capabilities,
    this.sessionDefaults,
    this.variants,
    this.revision,
  );

  factory LitertlmManifest.fromJson(dynamic input, {String? revision}) {
    final m =
        (input is String ? jsonDecode(input) : input) as Map<String, dynamic>;
    final schema = m['manifest_schema'] as String?;
    final vs = m['variants'] as List?;
    if (schema == null || vs == null || vs.isEmpty) {
      throw const FormatException(
        'not a litertlm_manifest.json (missing manifest_schema or variants)',
      );
    }
    // While the schema is 0.x the minor version is the compatibility line:
    // refuse anything outside 0.1.x rather than half-parse it.
    if (!schema.startsWith('0.1.')) {
      throw FormatException(
        'unsupported manifest_schema $schema (reader supports 0.1.x)',
      );
    }
    final model = m['model'] as Map<String, dynamic>? ?? const {};
    return LitertlmManifest._(
      schema,
      m['repo'] as String,
      model['display_name'] as String? ?? m['repo'] as String,
      model['context_length'] as int?,
      Capabilities.fromJson(model['capabilities'] as Map<String, dynamic>?),
      model['session_defaults'] as Map<String, dynamic>?,
      vs.map((e) => Variant.fromJson(e as Map<String, dynamic>)).toList(),
      revision,
    );
  }

  /// The model's declared thinking markers (exact strings, whitespace
  /// included); null when no thinking channel is declared.
  ThinkingChannel? get thinkingMarkers =>
      capabilities.thinkingDeclared ? capabilities.thinkingChannel : null;

  /// The bundle's full declared channel set (manifest 0.1.1+). Empty for
  /// 0.1.0 manifests — fall back to [thinkingMarkers] plus the runtime's
  /// default channels.
  List<DeclaredChannel> get declaredChannels => capabilities.channels;

  /// Pick the variant + backend for a device. v0.1 algorithm, deterministic —
  /// identical to the TypeScript and Dart reference readers:
  ///
  /// 1. An explicit [backend] request is a filter, not a score: only variants
  ///    listing it compete, the result keeps that backend, and resolve()
  ///    returns null when no variant lists it — it never substitutes another
  ///    backend.
  /// 2. A variant with a `recommended` entry matching [platform] wins;
  ///    matching [deviceClass] too ranks higher. When a backend was requested,
  ///    only recommendations naming that backend count.
  /// 3. Otherwise the smallest variant (by size_bytes), on the requested
  ///    backend (else its `default_backend`, else the first listed backend).
  ///
  /// Ties break toward the smaller file. Never returns a backend absent from
  /// the variant's verified `backends` list — recommendations naming an
  /// unlisted backend are ignored.
  Resolution? resolve({
    String? platform,
    String? backend,
    String? deviceClass,
    String? revision,
  }) {
    final candidates = backend != null
        ? variants.where((v) => v.backends.contains(backend)).toList()
        : variants;
    if (candidates.isEmpty) return null;

    final scored = <_Scored>[];
    for (final v in candidates) {
      var score = 0;
      String? chosen = backend;
      var reason = backend != null
          ? 'supports requested backend $backend'
          : 'fallback: smallest variant';
      if (platform != null && v.recommended.isNotEmpty) {
        final recs = v.recommended
            .where(
              (r) =>
                  r.platform == platform &&
                  v.backends.contains(r.backend) &&
                  (backend == null || r.backend == backend),
            )
            .toList();
        Recommendation? classRec;
        if (deviceClass != null) {
          for (final r in recs) {
            if (r.deviceClass == deviceClass) {
              classRec = r;
              break;
            }
          }
        }
        Recommendation? classFree;
        for (final r in recs) {
          if (r.deviceClass == null || deviceClass == null) {
            classFree = r;
            break;
          }
        }
        final rec =
            classRec ?? classFree ?? (recs.isNotEmpty ? recs.first : null);
        if (rec != null) {
          score = classRec != null ? 300 : 200;
          chosen = backend ?? rec.backend;
          final classNote =
              classRec == null && deviceClass != null && rec.deviceClass != null
              ? ' (no $deviceClass entry; using the ${rec.deviceClass} '
                    'recommendation)'
              : '';
          reason =
              'recommended for $platform'
              '${classRec != null ? "/$deviceClass" : ""}$classNote: '
              '${rec.reason ?? ""}';
        }
      }
      chosen ??=
          (v.defaultBackend != null && v.backends.contains(v.defaultBackend))
          ? v.defaultBackend!
          : (v.backends.isNotEmpty ? v.backends.first : 'cpu');
      scored.add(_Scored(v, chosen, score, reason.trim()));
    }
    scored.sort((a, b) {
      final s = b.score.compareTo(a.score);
      if (s != 0) return s;
      return (a.variant.sizeBytes ?? 1 << 62).compareTo(
        b.variant.sizeBytes ?? 1 << 62,
      );
    });
    final best = scored.first;
    final v = best.variant;
    final rev = Uri.encodeComponent(revision ?? this.revision ?? 'main');
    return Resolution(
      file: v.file,
      // Per-segment encoding so a nested variant path keeps its structure —
      // same rule as the reference readers and fromHuggingFace.
      url:
          'https://huggingface.co/$repo/resolve/$rev/${v.file.split('/').map(Uri.encodeComponent).join('/')}',
      backend: best.backend,
      variant: v,
      sessionDefaults: sessionDefaults,
      capabilities: capabilities,
      thinkingChannel: thinkingMarkers,
      contextLength: contextLength,
      notes: [...v.platformNotes, ...v.knownIssues],
      reason: best.reason,
    );
  }
}

class _Scored {
  final Variant variant;
  final String backend;
  final int score;
  final String reason;
  _Scored(this.variant, this.backend, this.score, this.reason);
}

/// The answer to "given this device, which file, on which backend, with which
/// settings" — in the manifest's own (string) vocabulary.
/// [LitertlmManifestResolver] maps this onto flutter_gemma's `ResolvedHfModel`.
class Resolution {
  final String file;

  /// Reader URL, following the revision the manifest was fetched at
  /// (`fromJson(revision:)`, else `main`) and anchored to the manifest's own
  /// `repo` field. The resolver builds its own authoritative URL instead,
  /// anchored to the repo id the caller actually asked for.
  final String url;
  final String backend;
  final Variant variant;
  final Map<String, dynamic>? sessionDefaults;
  final Capabilities capabilities;
  final ThinkingChannel? thinkingChannel;
  final int? contextLength;
  final List<String> notes;
  final String reason;
  const Resolution({
    required this.file,
    required this.url,
    required this.backend,
    required this.variant,
    this.sessionDefaults,
    required this.capabilities,
    this.thinkingChannel,
    this.contextLength,
    required this.notes,
    required this.reason,
  });
}
