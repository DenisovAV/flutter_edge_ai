import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';

import 'stores.dart';
import 'submission.dart';

/// Where a pubspec that depends on the showcase's packages was found.
typedef SourceFinding = ({String pubspecPath, List<String> packages});

/// Whether a pubspec [dependency] is one of the packages the showcase is for:
/// either core package, or any of their satellites.
bool isShowcaseDependency(String dependency) =>
    showcasePackages.contains(dependency) ||
    dependency.startsWith('flutter_edge_ai_') ||
    dependency.startsWith('flutter_gemma_');

/// The showcase packages that [pubspec] lists under `dependencies`.
List<String> showcaseDependencies(String pubspec) {
  final Object? yaml;
  try {
    yaml = loadYaml(pubspec);
  } on YamlException {
    return const [];
  }
  if (yaml case {'dependencies': final Map<Object?, Object?> dependencies}) {
    return [
      for (final name in dependencies.keys)
        if (name is String && isShowcaseDependency(name)) name,
    ]..sort();
  }
  return const [];
}

/// Reads a public repository's pubspecs over raw.githubusercontent.com, and
/// its file list over GitHub's API only when the root pubspec does not have
/// the packages, because the API allows 60 requests an hour per address.
class SourceCheck {
  SourceCheck(this._client);

  final http.Client _client;

  static const _timeout = Duration(seconds: 10);

  /// Pubspecs read when searching the tree, nearest the root first. A
  /// monorepo can keep the dependency deep in a package of its own: flipper's
  /// is in packages/flipper_ai_feature, the 23rd of its 43 pubspecs.
  static const _maxPubspecs = 100;

  /// Pubspecs read at once, so a large monorepo still answers in seconds.
  static const _batch = 10;

  Future<SourceFinding> find(GitHubSource source) async {
    final name = '${source.owner}/${source.repo}';
    final ref = source.ref ?? 'HEAD';
    if (source.path case final path?) {
      final pubspecPath = '$path/pubspec.yaml';
      final packages = showcaseDependencies(await _raw(source, ref, pubspecPath) ?? '');
      if (packages.isEmpty) {
        throw SubmissionException('$pubspecPath in $name does not depend on flutter_edge_ai or flutter_gemma.');
      }
      return (pubspecPath: pubspecPath, packages: packages);
    }
    final root = await _raw(source, ref, 'pubspec.yaml');
    final rootPackages = root == null ? const <String>[] : showcaseDependencies(root);
    if (rootPackages.isNotEmpty) return (pubspecPath: 'pubspec.yaml', packages: rootPackages);
    final paths = await _pubspecPaths(source, ref);
    for (var start = 0; start < paths.length; start += _batch) {
      final batch = paths.skip(start).take(_batch).toList();
      final pubspecs = await Future.wait([for (final path in batch) _raw(source, ref, path)]);
      for (var i = 0; i < batch.length; i++) {
        final packages = showcaseDependencies(pubspecs[i] ?? '');
        if (packages.isNotEmpty) return (pubspecPath: batch[i], packages: packages);
      }
    }
    throw SubmissionException('No pubspec.yaml in $name depends on flutter_edge_ai or flutter_gemma.');
  }

  /// The file at [path], or null when the repository does not have it.
  Future<String?> _raw(GitHubSource source, String ref, String path) async {
    final response = await _client
        .get(Uri.https('raw.githubusercontent.com', '/${source.owner}/${source.repo}/$ref/$path'))
        .timeout(_timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw StoreUnavailableException('GitHub', 'raw.githubusercontent.com answered ${response.statusCode}');
    }
    return response.body;
  }

  /// Every pubspec.yaml below the root, nearest first; generated and
  /// vendored folders are skipped.
  Future<List<String>> _pubspecPaths(GitHubSource source, String ref) async {
    final response = await _client
        .get(
          Uri.https('api.github.com', '/repos/${source.owner}/${source.repo}/git/trees/$ref', {'recursive': '1'}),
          headers: {'accept': 'application/vnd.github+json', 'user-agent': 'flutteredge.ai-showcase'},
        )
        .timeout(_timeout);
    if (response.statusCode == 404 || response.statusCode == 409) {
      throw SubmissionException('GitHub has no public repository ${source.owner}/${source.repo}.');
    }
    if (response.statusCode != 200) {
      throw StoreUnavailableException('GitHub', 'the trees API answered ${response.statusCode}');
    }
    final tree = jsonDecode(response.body);
    final paths = [
      if (tree case {'tree': final List<Object?> entries})
        for (final entry in entries)
          if (entry case {
            'type': 'blob',
            'path': final String path,
          } when path.endsWith('/pubspec.yaml') && !_skipped.hasMatch(path))
            path,
    ]..sort((a, b) => '/'.allMatches(a).length.compareTo('/'.allMatches(b).length));
    return paths.take(_maxPubspecs).toList();
  }

  static final _skipped = RegExp(r'(^|/)(\.[^/]+|build|ios/Pods|ios/\.symlinks)/');
}
