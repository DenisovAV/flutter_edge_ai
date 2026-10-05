import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/model.dart' show ModelFileType, ModelType;

/// Runtime defaults resolved from a Hugging Face repo's deployment metadata
/// (e.g. a `litertlm_manifest.json`), in flutter_gemma's own runtime vocabulary.
///
/// Every field is nullable: `null` means "the manifest is silent — use the SDK
/// default". These are the *how-to-run* knobs the app passes to
/// [FlutterGemma.getActiveModel] / `createSession`, NOT install-time identity.
/// They are **overridable defaults**, never authoritative config baked into the
/// model — an explicit argument at the call site always wins over the field
/// here, which in turn wins over the SDK default.
///
/// Kept as its own value object (separate from [ResolvedHfModel]'s identity
/// fields) so the identity record — [InferenceModelSpec] — never grows runtime
/// fields, preserving flutter_gemma's install-vs-runtime separation. It also
/// makes the merge a pure function: `explicit ?? defaults?.x ?? sdkDefault`.
class ModelRuntimeDefaults {
  /// Context-window size (`maxTokens`), if the manifest declares one
  /// (`model.context_length`). Still clamped by the engine downstream — a
  /// manifest cannot set a value the engine rejects.
  final int? maxTokens;

  /// Recommended text/decoder backend for this device.
  final PreferredBackend? preferredBackend;

  /// Declared vision capability (`capabilities.vision`).
  final bool? supportImage;

  /// Declared audio capability (`capabilities.audio`).
  final bool? supportAudio;

  /// Whether the model emits a thinking channel
  /// (`capabilities.thinking.declared`). Apply as `createSession`'s
  /// `enableThinking`.
  final bool? isThinking;

  /// The **minimum** output-token budget the model needs
  /// (`session_defaults.max_output_tokens_min`) — e.g. a reasoning model is cut
  /// off mid-`<think>` below this. This is a FLOOR, not a cap: when you set
  /// `createSession(maxOutputTokens:)`, keep it at or above this value (or leave
  /// the cap unset). Do NOT assume it is itself the cap to apply blindly —
  /// passing a floor into a smaller cap would truncate output.
  final int? minOutputTokens;

  const ModelRuntimeDefaults({
    this.maxTokens,
    this.preferredBackend,
    this.supportImage,
    this.supportAudio,
    this.isThinking,
    this.minOutputTokens,
  });
}

/// One file of a multi-file (directory) model resolved from a Hugging Face
/// repo — e.g. an ORT-GenAI model is a DIRECTORY (`genai_config.json` +
/// `model.onnx`[+`model.onnx_data`] + tokenizer files), not a single file.
///
/// [name] is the BARE leaf filename as it must appear inside the installed
/// model directory (ORT-GenAI's `genai_config.json` references its siblings by
/// bare name, and the native loader is handed the directory). It MUST be a
/// single path segment — no path separators and no `.`/`..` — or the installer
/// rejects it (a `../…` name would otherwise escape the model directory). [url]
/// is the pinned download URL. [sha256]/[sizeBytes] are advisory (carried, not
/// yet verified — see [ResolvedHfModel.sha256]).
class ResolvedHfFile {
  final String name;
  final String url;
  final String? sha256;
  final int? sizeBytes;

  const ResolvedHfFile({
    required this.name,
    required this.url,
    this.sha256,
    this.sizeBytes,
  });

  /// Whether [name] is a safe BARE leaf — a single path segment with no
  /// separators and no `.`/`..`. The installer refuses a directory member whose
  /// name is not (a `../…` name would escape the model directory). The rule
  /// lives here so resolvers and the installer share one definition.
  bool get isBareLeafName =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains(r'\');
}

/// A model resolved from a Hugging Face repo's deployment metadata into
/// flutter_gemma's install + runtime vocabulary.
///
/// Install identity — [modelType] / [fileType] for
/// [FlutterGemma.installModel], and [url] for the download (install from [url]
/// via `fromNetwork` so the resolver's revision is honoured; see [url]) — is
/// kept apart from [runtime], the overridable defaults the app applies at
/// `getActiveModel` / `createSession`. That split mirrors how Hugging Face
/// ships model identity (`config.json`) and generation defaults
/// (`generation_config.json`) as separate files.
class ResolvedHfModel {
  /// The variant filename chosen in the repo (e.g. `model.litertlm`). May
  /// contain `/` for a repo that nests variants in subfolders. Prefer [url] for
  /// the actual download — [file] is the variant's name / display value.
  final String file;

  /// The authoritative download URL (`…/resolve/<revision>/<file>`) — the
  /// resolver builds it and MAY pin a non-`main` revision/commit for
  /// reproducibility. Install from this via `installModel(...).fromNetwork(url)`
  /// (the plugin still auto-applies the HF token to `huggingface.co` hosts);
  /// `fromHuggingFace(repo, file:)` rebuilds a `main` URL and so would drop a
  /// pinned revision.
  final String url;

  /// How to install/route the model.
  final ModelFileType fileType;

  /// The model family (`gemmaIt`/`gemma4`/`qwen3`/…), if the resolver can map
  /// the repo's declared architecture to one. Pass to [FlutterGemma.installModel]'s
  /// required `modelType`. Null when the resolver can't determine it — the app
  /// must then supply it. Not cosmetic: `ModelType` drives runtime branching
  /// (tool-call format, thinking-tag handling).
  final ModelType? modelType;

  /// Manifest-declared integrity metadata (`sha256` / `size_bytes`).
  ///
  /// ADVISORY — carried for a post-download integrity check that core does
  /// **not** perform yet (the install path only asserts a non-empty file
  /// landed). Wiring an actual expected-hash/size verification into the
  /// download is a follow-up; until then a caller that needs integrity must
  /// verify these itself.
  final String? sha256;
  final int? sizeBytes;

  /// For a DIRECTORY model (ORT-GenAI): every file that must be installed into
  /// the model's directory, each by its BARE leaf [ResolvedHfFile.name]. Null
  /// for a single-file model (`.litertlm`, `.task`) — that path installs [url]
  /// alone, unchanged. When non-null, [file]/[url] name the PRIMARY entry the
  /// engine loads from (for ORT-GenAI: `genai_config.json`) and that entry must
  /// also appear in this list.
  final List<ResolvedHfFile>? files;

  /// For a DIRECTORY model: the single filesystem-safe subdirectory name the
  /// files install into. REQUIRED whenever [files] is non-null (the installer
  /// throws without it) and MUST include the resolved execution-provider variant
  /// (e.g. `microsoft__Phi-3.5-mini-instruct-onnx__cpu_and_mobile`) so two EP
  /// variants of the same repo never share a directory — build it with
  /// `FileNameUtils.sanitizeHfDirName(repo, variant: …)`. Null for single-file.
  final String? directoryName;

  /// The overridable runtime defaults (see [ModelRuntimeDefaults]).
  final ModelRuntimeDefaults runtime;

  /// Advisory notes to surface (platform notes, known issues) — not acted on.
  /// Read-only; resolvers should pass an unmodifiable list.
  final List<String> notes;

  const ResolvedHfModel({
    required this.file,
    required this.url,
    required this.fileType,
    this.modelType,
    this.sha256,
    this.sizeBytes,
    this.files,
    this.directoryName,
    this.runtime = const ModelRuntimeDefaults(),
    this.notes = const [],
  });
}

/// A pluggable resolver that turns a Hugging Face repo id into a
/// [ResolvedHfModel] by reading that repo's deployment metadata.
///
/// Implemented in an engine package — e.g. `flutter_gemma_litertlm` reads
/// `litertlm_manifest.json` — and passed to `FlutterGemma.initialize` via
/// `huggingFaceResolvers:`. Core selects one via the same probe-chain shape as
/// [InferenceEngineProvider] (highest [priority], first-registered breaks
/// ties), but the discriminator differs: an engine's `canHandle` inspects an
/// already-resolved [InferenceModelSpec], whereas a resolver has only a bare
/// `org/repo` string and the caller's [ModelFileType] hint until it fetches the
/// manifest. So [canResolve] selects on that declared [fileType] hint — the
/// same "select by declared ModelFileType" rule the engine registry uses.
///
/// Core never fetches on the resolver's behalf: the resolver does its own IO
/// inside [resolve].
abstract class HuggingFaceResolver {
  /// Human-readable name for diagnostics (e.g. 'litertlm-manifest').
  String get name;

  /// Selection precedence on overlap. Core-adjacent resolvers use 0; a third
  /// party raises this to take precedence for a repo both could handle.
  int get priority => 0;

  /// Whether this resolver handles a repo whose model is declared as [fileType].
  ///
  /// A resolver should claim a **specific** [fileType] (the litertlm resolver
  /// returns true only for `fileType == ModelFileType.litertlm`) and NOT match a
  /// `null` hint — otherwise, with more than one resolver registered, a bare
  /// `resolveHuggingFace(repo)` with no hint would route by registration order
  /// and could send an `.onnx` repo to the litertlm resolver. Callers pass the
  /// `fileType` they are installing (they know it), so requiring it is cheap.
  /// [repo] is available for future host/owner-scoped rules but current
  /// selection is by [fileType].
  bool canResolve(String repo, {ModelFileType? fileType});

  /// Read the repo's deployment metadata and resolve the variant + defaults for
  /// the current device.
  ///
  /// [platform] is a lowercase platform key — `android`, `ios`, `macos`,
  /// `windows`, `linux`, `web`, or `unknown` for an unmapped host — so the
  /// resolver can honour per-platform recommendations. A resolver should treat
  /// `unknown` as "no per-platform recommendation" and fall back to its
  /// default. [preferredBackend] is an optional caller hint the resolver may
  /// prefer when the metadata lists it.
  Future<ResolvedHfModel> resolve(
    String repo, {
    String? token,
    String? platform,
    PreferredBackend? preferredBackend,
  });
}
