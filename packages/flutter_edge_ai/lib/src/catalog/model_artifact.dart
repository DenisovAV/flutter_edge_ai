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
  /// Advisory: an install checks [sizeBytes], not this.
  final String sha256;

  /// The file's size in bytes.
  final int sizeBytes;

  /// The name the file is installed under: its identity on the device.
  /// Fixed once a release ships it, so an installed file is found again.
  final String installFilename;

  /// Whether the repository is gated: downloading it needs a Hugging Face
  /// token whose account accepted the model's terms.
  final bool gated;

  /// The download URL: `https://huggingface.co/<repo>/resolve/<revision>/<path>`,
  /// each path segment percent-encoded.
  String get url =>
      'https://huggingface.co/$repo/resolve/$revision/'
      '${path.split('/').map(Uri.encodeComponent).join('/')}';

  @override
  bool operator ==(Object other) =>
      other is ModelArtifact &&
      other.repo == repo &&
      other.revision == revision &&
      other.path == path &&
      other.sha256 == sha256;

  @override
  int get hashCode => Object.hash(repo, revision, path, sha256);

  @override
  String toString() => 'ModelArtifact($repo@$revision/$path)';
}
