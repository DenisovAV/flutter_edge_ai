/// One entry of the generated contributor grid
/// (`contributors_data.g.dart`, written by `tool/update_contributors.dart`).
///
/// A login and an avatar only: the grid shows what GitHub already shows
/// publicly next to their commits, nothing more.
class Contributor {
  const Contributor({required this.login, required this.githubId});

  /// GitHub login, without the `@`.
  final String login;

  /// The numeric GitHub user id the avatar URL is built from.
  final int githubId;

  String get avatarUrl => 'https://avatars.githubusercontent.com/u/$githubId?s=112&v=4';

  /// Their commits in the repository: every contributor here has some, while
  /// someone whose work landed before pull requests has no merged PR to list.
  String get commitsUrl => 'https://github.com/DenisovAV/flutter_edge_ai/commits?author=$login';
}
