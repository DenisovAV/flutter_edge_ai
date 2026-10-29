/// One file a catalog model installs: a Hugging Face file pinned to a commit.
///
/// Catalogs are generated from the project's model registry
/// (`model_registry/` in the repository), where every file is checked against
/// its bytes; apps get artifacts from a catalog, never build them.
final class ModelArtifact {
  /// An artifact. Generated catalogs call this; an app has no reason to.
  const ModelArtifact({
    required this.repo,
    required this.revision,
    required this.path,
    required this.sha256,
    required this.sizeBytes,
    required this.installFilename,
    this.gated = false,
  });

  /// The Hugging Face repository, `owner/name`.
  final String repo;

  /// The 40-hex commit the file is pinned to; never a branch.
  final String revision;

  /// The file's path inside the repository.
  final String path;

  /// The SHA-256 of the file at [revision], as Hugging Face reports it.
  /// An install checks [sizeBytes] (not on the web), not this; hashing a
  /// model of several GB takes minutes on a phone.
  final String sha256;

  /// The file's size in bytes.
  final int sizeBytes;

  /// The name the file is installed under: its identity on the device.
  /// Fixed once a release ships it, so an installed file is found again.
  /// Core keeps a speech model's companions under their model's namespace:
  /// an STT tokenizer `tokenizer.json` is stored as
  /// `<model file's name>__tokenizer.json`, a TTS file `config.json` as
  /// `<type>__config.json`; this is the name before that prefix.
  final String installFilename;

  /// Whether the repository is gated: downloading it needs a Hugging Face
  /// token whose account accepted the model's terms.
  final bool gated;

  /// The download URL: `https://huggingface.co/<repo>/resolve/<revision>/<path>`,
  /// each path segment percent-encoded.
  String get url =>
      'https://huggingface.co/$repo/resolve/$revision/'
      '${path.split('/').map(Uri.encodeComponent).join('/')}';

  /// Every field: two artifacts that install the same bytes under another
  /// name, or that record another size, are not the same artifact.
  @override
  bool operator ==(Object other) =>
      other is ModelArtifact &&
      other.repo == repo &&
      other.revision == revision &&
      other.path == path &&
      other.sha256 == sha256 &&
      other.sizeBytes == sizeBytes &&
      other.installFilename == installFilename &&
      other.gated == gated;

  @override
  int get hashCode => Object.hash(
    repo,
    revision,
    path,
    sha256,
    sizeBytes,
    installFilename,
    gated,
  );

  @override
  String toString() => 'ModelArtifact($repo@$revision/$path)';
}
