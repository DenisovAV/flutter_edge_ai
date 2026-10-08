/// Centralized SharedPreferences keys for model management
///
/// SINGLE SOURCE OF TRUTH for all preference keys used by the plugin
class PreferencesKeys {
  // Private constructor to prevent instantiation
  PreferencesKeys._();

  // ============================================================================
  // Multi-model lists (NEW system - supports multiple models)
  // ============================================================================

  /// `List<String>` of installed inference model files
  static const String installedModels = 'installed_models';

  /// `List<String>` of installed LoRA files
  static const String installedLoras = 'installed_loras';

  /// `List<String>` of installed embedding model files
  static const String installedEmbeddingModels = 'installed_embedding_models';

  /// `List<String>` of installed tokenizer files
  static const String installedTokenizers = 'installed_tokenizers';

  // ============================================================================
  // Legacy single-value keys (OLD system - backward compatibility)
  // ============================================================================

  /// Legacy: Single inference model filename
  static const String installedModelFileName = 'installed_model_file_name';

  /// Legacy: Single LoRA filename
  static const String installedLoraFileName = 'installed_lora_file_name';

  /// Legacy: Single embedding model filename
  static const String embeddingModelFile = 'embedding_model_file';

  /// Legacy: Single tokenizer filename
  static const String embeddingTokenizerFile = 'embedding_tokenizer_file';

  /// Legacy: Single STT model filename
  static const String sttModelFile = 'stt_model_file';

  /// Legacy: Single STT tokenizer filename
  static const String sttTokenizerFile = 'stt_tokenizer_file';

  // ============================================================================
  // Active model identity (for auto-restore after app restart, #227)
  // ============================================================================

  /// `ModelType.name` of the currently active inference model.
  /// Read on `FlutterEdgeAi.initialize()` together with [activeInferenceFileType]
  /// and [installedModelFileName] to rehydrate `_activeInferenceModel`.
  static const String activeInferenceModelType = 'active_inference_model_type';

  /// `ModelFileType.name` of the currently active inference model.
  static const String activeInferenceFileType = 'active_inference_file_type';

  /// Filename of the currently active inference model. Required because the
  /// "installed" filename key ([installedModelFileName]) is legacy-only —
  /// the new multi-model system tracks installs through [installedModels],
  /// not a single filename, so we need a dedicated active-pointer.
  static const String activeInferenceFilename = 'active_inference_filename';

  /// Filename of the currently active embedding model.
  static const String activeEmbeddingFilename = 'active_embedding_filename';

  /// Filename of the currently active embedding tokenizer.
  static const String activeEmbeddingTokenizerFilename =
      'active_embedding_tokenizer_filename';

  /// Whether [activeEmbeddingFilename] came from an explicit install identity
  /// rather than the legacy source-derived filename behavior.
  static const String activeEmbeddingModelFilenameExplicit =
      'active_embedding_model_filename_explicit';

  /// Whether [activeEmbeddingTokenizerFilename] came from an explicit install
  /// identity. Restore must not apply legacy tokenizer namespacing when true.
  static const String activeEmbeddingTokenizerFilenameExplicit =
      'active_embedding_tokenizer_filename_explicit';

  /// Atomic, versioned JSON record for the complete active embedding identity.
  /// New code writes only this key; the separate keys above remain a read-only
  /// fallback for installs created by older releases.
  static const String activeEmbeddingIdentityRecord =
      'active_embedding_identity_record';

  // ============================================================================
  // Active model source descriptors (web restore needs more than a filename —
  // Cache API / IndexedDB lookups go through the original `ModelSource`)
  // ============================================================================

  /// Encoded source for the active inference model. Format: `<kind>|<value>`
  /// where kind ∈ {`network`,`asset`,`bundled`} and value is the URL / asset
  /// path / bundle resource name. `file` is not encoded — Mobile uses a
  /// resolved `FileSource(filePath)` reconstructed from
  /// [activeInferenceFilename] directly.
  static const String activeInferenceSource = 'active_inference_source';

  /// Same encoding as [activeInferenceSource], for the embedding model file.
  static const String activeEmbeddingSource = 'active_embedding_source';

  /// Same encoding as [activeInferenceSource], for the embedding tokenizer.
  static const String activeEmbeddingTokenizerSource =
      'active_embedding_tokenizer_source';

  // ============================================================================
  // Active STT model identity (mirrors the active embedding identity keys)
  // ============================================================================

  /// Filename of the currently active STT model.
  static const String activeSttFilename = 'active_stt_filename';

  /// Filename of the currently active STT tokenizer.
  static const String activeSttTokenizerFilename =
      'active_stt_tokenizer_filename';

  /// `SttModelType.name` of the currently active STT model — required to
  /// rehydrate [SttModelSpec.sttModelType] on restore (the model is
  /// SELECTABLE, so the type is not inferable from the filename alone).
  static const String activeSttModelType = 'active_stt_model_type';

  /// Same encoding as [activeInferenceSource], for the STT model.
  static const String activeSttSource = 'active_stt_source';

  /// Same encoding as [activeInferenceSource], for the STT tokenizer.
  static const String activeSttTokenizerSource = 'active_stt_tokenizer_source';

  // ============================================================================
  // Active TTS model identity (simplified vs. STT: the manifest re-derives the
  // bundle filenames on restore, so only name + type need persisting)
  // ============================================================================

  /// Filename-independent identity of the active TTS model: its display name.
  static const String activeTtsName = 'active_tts_name';

  /// `TtsModelType.name` of the active TTS model — the manifest re-derives the
  /// bundle filenames on restore, so only name + type need persisting.
  static const String activeTtsModelType = 'active_tts_model_type';

  // ============================================================================
  // One-key active identities. Each holds the per-field keys above as one JSON
  // object, written in one call, so a crash mid-write can no longer leave one
  // model's filename next to another model's type (see ActiveIdentityStore).
  // The per-field keys stay as the field names, and are read only from
  // installs made before these existed.
  // ============================================================================

  /// The active inference model's identity, as one JSON object.
  static const String activeInferenceIdentity = 'active_inference_identity';

  /// The active STT model's identity, as one JSON object.
  static const String activeSttIdentity = 'active_stt_identity';

  /// The active TTS model's identity, as one JSON object.
  static const String activeTtsIdentity = 'active_tts_identity';

  // ============================================================================
  // Path mappings (dynamic keys with filename)
  // ============================================================================

  /// Get key for bundled file path mapping
  /// Format: 'bundled_path_{filename}'
  static String bundledPath(String filename) => 'bundled_path_$filename';

  /// Get key for external file path mapping
  /// Format: 'external_path_{filename}'
  static String externalPath(String filename) => 'external_path_$filename';

  // ============================================================================
  // Web Cache Management (Cache API metadata)
  // ============================================================================

  /// Prefix for web cache metadata keys
  /// Format: 'web_cache_{url.hashCode}'
  static const String webCacheMetadataPrefix = 'web_cache_';

  /// Whether persistent storage was granted
  static const String webCachePersistentGranted =
      'web_cache_persistent_granted';

  /// Last cache cleanup timestamp
  static const String webCacheLastCleanup = 'web_cache_last_cleanup';
}
