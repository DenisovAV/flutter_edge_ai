import 'package:flutter_edge_ai/src/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/src/model.dart'
    show ModelFamily, ModelFileType, ModelType;
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show ModelManagementType, SttModelType, TtsModelType;

/// Runtime defaults resolved from a Hugging Face repo's deployment metadata
/// (e.g. a `litertlm_manifest.json`) or listed by a catalog variant, in
/// flutter_edge_ai's own runtime vocabulary.
///
/// Every field is nullable: `null` means "the source is silent — use the SDK
/// default". These are the *how-to-run* knobs the app passes as `defaults:`
/// to `FlutterEdgeAi.getActiveModel` / `openModel` (inference),
/// `getActiveEmbedder`, `getActiveStt` and `getActiveTts`, NOT install-time
/// identity. One class serves every role: each call reads the fields its
/// role uses (named on each field) and ignores the rest.
/// They are **overridable defaults**, never authoritative config baked into the
/// model — an explicit argument at the call site always wins over the field
/// here, which in turn wins over the SDK default.
///
/// Kept as its own value object (separate from [ResolvedHfModel]'s identity
/// fields) so the identity record — [InferenceModelSpec] — never grows runtime
/// fields, preserving flutter_edge_ai's install-vs-runtime separation. It also
/// makes the merge a pure function: `explicit ?? defaults?.x ?? sdkDefault`.
class ModelRuntimeDefaults {
  /// Context-window size (`maxTokens`), if the manifest declares one
  /// (`model.context_length`). Still clamped by the engine downstream — a
  /// manifest cannot set a value the engine rejects. Read by: inference.
  final int? maxTokens;

  /// Recommended backend for this device (for an LLM, its text decoder).
  /// Read by: inference, embedding, stt, tts.
  final PreferredBackend? preferredBackend;

  /// Declared vision capability (`capabilities.vision`). Read by: inference,
  /// embedding.
  final bool? supportImage;

  /// Declared audio capability (`capabilities.audio`). Read by: inference,
  /// embedding.
  final bool? supportAudio;

  /// The language to transcribe into (speech-to-text) or to speak
  /// (text-to-speech), in the form `getActiveStt(language:)` /
  /// `getActiveTts(language:)` take. Read by: stt, tts.
  final String? language;

  /// Whether the manifest declares a thinking channel
  /// (`capabilities.thinking.declared`): what the bundle carries, not a
  /// request. A hint for `createChat`'s / `createSession`'s `enableThinking`.
  /// Read by: inference (forwarded by the app; see `getActiveModel`).
  final bool? thinkingDeclared;

  /// The **minimum** output-token budget the model needs
  /// (`session_defaults.max_output_tokens_min`) — e.g. a reasoning model is cut
  /// off mid-`<think>` below this. This is a FLOOR, not a cap: when you set
  /// `createSession(maxOutputTokens:)`, keep it at or above this value (or leave
  /// the cap unset). Do NOT assume it is itself the cap to apply blindly —
  /// passing a floor into a smaller cap would truncate output. Read by:
  /// inference (forwarded by the app; see `getActiveModel`).
  final int? minOutputTokens;

  const ModelRuntimeDefaults({
    this.maxTokens,
    this.preferredBackend,
    this.supportImage,
    this.supportAudio,
    this.thinkingDeclared,
    this.minOutputTokens,
    this.language,
  });
}

/// One file of a model resolved from a Hugging Face repo that comes as more
/// than one file: a member of a DIRECTORY model (an ORT-GenAI model is
/// `genai_config.json` + `model.onnx`[+`model.onnx_data`] + tokenizer files),
/// or an embedder's model file or its tokenizer file (see
/// [ResolvedHfModel.files]).
///
/// [name] is the BARE leaf filename the file is installed under: inside the
/// model directory for a directory member (ORT-GenAI's `genai_config.json`
/// references its siblings by bare name, and the native loader is handed the
/// directory), beside the other models for an embedder's file. It MUST be a
/// single path segment — no path separators and no `.`/`..` — or the installer
/// rejects it (a `../…` name would otherwise escape the model directory). [url]
/// is the pinned download URL.
///
/// [sizeBytes], when set, is checked once the file is installed, before the
/// model becomes active, for a directory member and for an embedder's files
/// (a file of another size is deleted with its record and the install fails;
/// not on the web). Null means nothing to check. [sha256] is advisory
/// (carried, not verified).
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
/// flutter_edge_ai's install + runtime vocabulary.
///
/// Install identity — [family] / [fileType] for the installer, and [url] for
/// the download (install from [url] via `fromNetwork` so the resolver's
/// revision is honoured; see [url]) — is kept apart from [runtime], the
/// overridable defaults the app applies at `getActiveModel` /
/// `getActiveEmbedder` / `createSession`. That split mirrors how Hugging Face
/// ships model identity (`config.json`) and generation defaults
/// (`generation_config.json`) as separate files.
///
/// The shapes a resolver returns, by role:
///
/// - **Language model, single file** (`.litertlm`, `.task`): [file] and
///   [url] name it; [files], [directoryName] and [tokenizerFile] are null.
///   Its [sizeBytes] is not checked.
/// - **Language model, directory** (ORT-GenAI): [files] lists every member
///   by bare leaf name, [directoryName] is required, and [file]/[url] name
///   the primary member the engine loads (`genai_config.json`), which is
///   also in [files]. Each member's [ResolvedHfFile.sizeBytes], when given,
///   is checked.
/// - **Embedder**: one model file, with a tokenizer file when the model
///   needs one (anything but a `.litertlm` or `.gguf` container). Either a
///   single file as above, whose [sizeBytes] is checked when given, or
///   [files] = the model file and its tokenizer file by bare leaf names,
///   [tokenizerFile] naming the tokenizer, [directoryName] null, and [file]
///   the model member's bare name (a repo path whose leaf is that name is
///   accepted too). Each [ResolvedHfFile.sizeBytes], when given, is checked.
///   [family] is null.
///
/// Of the resolvers shipped beside core, the ONNX language-model resolver
/// gives no sizes yet.
class ResolvedHfModel {
  /// The variant filename chosen in the repo (e.g. `model.litertlm`). May
  /// contain `/` for a repo that nests variants in subfolders. Prefer [url] for
  /// the actual download — [file] is the variant's name / display value.
  /// With [files] set it names the primary member (a directory model) or the
  /// model member (an embedder), by the bare name it has in [files]. A
  /// single-file embedder installs under the leaf of [file].
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

  /// The model family, if the resolver can map the repo's declared
  /// architecture to one: a [ModelType] (`gemmaIt`/`gemma4`/`qwen3`/…) for a
  /// language model, an [SttModelType] or a [TtsModelType] for a speech
  /// model. Null when the resolver can't determine it — the app must then
  /// supply it — and for an embedder, which has no family type. Each
  /// installer accepts only its own family type and refuses another (the
  /// inference installer throws [StateError] for a family that is not a
  /// [ModelType]). Not cosmetic: [ModelType] drives runtime branching
  /// (tool-call format, thinking-tag handling).
  final ModelFamily? family;

  /// Manifest-declared integrity metadata (`sha256` / `size_bytes`) of the
  /// file [url] names, when [files] is null.
  ///
  /// [sizeBytes] is checked for a single-file embedder (as
  /// [ResolvedHfFile.sizeBytes] is for members of [files]); for a
  /// single-file language model it is carried, not checked. [sha256] is
  /// never verified by core: a caller that needs a hash check must verify
  /// it itself.
  final String? sha256;
  final int? sizeBytes;

  /// Every file the model installs, each by its BARE leaf
  /// [ResolvedHfFile.name]; null for a single-file model, which installs
  /// [url] alone. For a DIRECTORY model (ORT-GenAI) the members of the
  /// model's directory, with [file]/[url] naming the PRIMARY entry the
  /// engine loads from (`genai_config.json`), which must also appear in this
  /// list. For an embedder the model file and its tokenizer file, with
  /// [file] naming the model member and [tokenizerFile] the tokenizer.
  final List<ResolvedHfFile>? files;

  /// The BARE leaf name, among [files], of the model's tokenizer when it is a
  /// file of its own (e.g. `tokenizer.json` beside an embedder's `.onnx`);
  /// null when the model carries its tokenizer or none is needed. When set
  /// it MUST name a member of [files] other than [file]:
  /// `FlutterEdgeAi.resolveHuggingFace` refuses a result whose
  /// [tokenizerFile] is not there, or is [file].
  final String? tokenizerFile;

  /// For a DIRECTORY model: the single filesystem-safe subdirectory name the
  /// files install into. REQUIRED whenever [files] is non-null (the installer
  /// throws without it) and MUST include the resolved execution-provider variant
  /// (e.g. `microsoft__Phi-3.5-mini-instruct-onnx__cpu_and_mobile`) so two EP
  /// variants of the same repo never share a directory — build it with
  /// `FileNameUtils.sanitizeHfDirName(repo, variant: …)`. Null for a
  /// single-file model and for an embedder, whose files install flat.
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
    this.family,
    this.sha256,
    this.sizeBytes,
    this.files,
    this.tokenizerFile,
    this.directoryName,
    this.runtime = const ModelRuntimeDefaults(),
    this.notes = const [],
  });
}

/// A pluggable resolver that turns a Hugging Face repo id into a
/// [ResolvedHfModel] by reading that repo's deployment metadata.
///
/// Implemented in an engine or backend package — e.g.
/// `flutter_edge_ai_litertlm` reads `litertlm_manifest.json` — and either
/// carried by its provider (`HuggingFaceResolverSource`) or passed to
/// `FlutterEdgeAi.initialize` via `huggingFaceResolvers:`.
///
/// A resolver serves one role, its [type]: an inference resolver answers
/// `installModel(...).fromHuggingFace`, an embedding resolver
/// `installEmbedder().fromHuggingFace`, and
/// `FlutterEdgeAi.resolveHuggingFace(type:)` reaches only the resolvers of
/// the role it is asked for. So one file type (`onnx`, `litertlm`) can have
/// a language-model resolver and an embedder resolver side by side.
///
/// Within a role, core selects one via the same probe-chain shape as
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

  /// The role this resolver serves: [ModelManagementType.inference] for a
  /// language model, [ModelManagementType.embedding] for an embedder, and
  /// so on. Only the installer and the `resolveHuggingFace(type:)` call of
  /// that role reach it, and `FlutterEdgeAi.initialize` refuses a provider
  /// whose resolver's role is not the role of the list it was passed in.
  ModelManagementType get type;

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
