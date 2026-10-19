/// The people who look after a part of the project, in the order the
/// `/contributors` page shows them.
///
/// Plain Dart, no Jaspr: `tool/update_contributors.dart` imports this list to
/// leave these people out of the generated contributor grid, and it runs on
/// the VM without the site's build.
library;

class Maintainer {
  const Maintainer({
    required this.name,
    required this.login,
    required this.githubId,
    required this.about,
    required this.blurb,
    this.role,
    this.roleHref,
    this.packages = const [],
    this.website,
    this.photo,
  });

  final String name;

  /// GitHub login, without the `@`.
  final String login;

  /// The numeric GitHub user id. The avatar URL is built from it, so it keeps
  /// working when someone renames their account.
  final int githubId;

  /// Who they are, in one line: country first, then what they say about
  /// themselves in public.
  final String about;

  /// What they do in this project.
  final String blurb;

  /// A role shown instead of package chips, for someone who looks after an
  /// area that is not a package of its own.
  final String? role;

  /// Where [role] links to, when the area has a page of its own.
  final String? roleHref;

  /// The packages they look after, each linked to pub.dev.
  final List<String> packages;

  final String? website;

  /// A photo served from `web/`, e.g. `/images/contributors/<login>-1.jpg`.
  /// Null shows the GitHub avatar. Images are cached for a year
  /// (firebase.json), so a new photo needs a new file name, not the same one
  /// overwritten.
  final String? photo;

  String get avatarUrl => photo ?? 'https://avatars.githubusercontent.com/u/$githubId?s=192&v=4';
}

const maintainers = <Maintainer>[
  Maintainer(
    name: 'Sasha Denisov',
    login: 'DenisovAV',
    githubId: 9622910,
    role: 'Lead maintainer',
    about:
        'Germany · Google Developer Expert for Flutter, Dart, Firebase and AI · '
        'co-organizer of Flutter Berlin',
    blurb:
        'Created Flutter Edge AI and looks after the core API, the engines, '
        'the native builds and every release. Also created LiteTune, which '
        'fine-tunes a small model, converts it for LiteRT-LM and compares it '
        'with the model it came from.',
    website: 'https://sashadenisov.dev',
    photo: '/images/contributors/denisovav-1.jpg',
  ),
  Maintainer(
    name: 'Jhin Lee',
    login: 'leehack',
    githubId: 1233094,
    packages: ['flutter_edge_ai_llama'],
    about:
        'Canada · full-stack developer at Unity · Google Developer Expert for '
        'Flutter · organizer of Flutter and GDG Montreal',
    blurb:
        'Created llamadart, which runs GGUF models through llama.cpp, and '
        'LiteRT-LM models, in Dart and Flutter on Android, iOS, macOS, '
        'Windows, Linux and the web. flutter_edge_ai_llama brings it to '
        "Flutter Edge AI. One of the project's earliest contributors.",
    website: 'https://leehack.com',
  ),
  Maintainer(
    name: 'Francesco Vezzani',
    login: 'kekko7072',
    githubId: 32552589,
    packages: ['flutter_edge_ai_builtin_ai'],
    about:
        'Italy · Tomorrow Tech · mechatronic engineering at the University of '
        'Padua',
    blurb:
        'Runs the models the operating system ships: Gemini Nano on Android '
        'and in Chrome, Apple Foundation Models on iOS and macOS, Phi Silica '
        'on Windows. The package sits on flutter_local_ai, his own plugin, '
        'which owns every native layer.',
    website: 'https://vezz.io',
  ),
  Maintainer(
    name: 'Samarthsinh Vala',
    login: 'samarthsinh2660',
    githubId: 143015496,
    packages: ['flutter_edge_ai_diagnostics'],
    about: 'India · software engineer',
    blurb:
        'Measures how much memory a model really takes, read from the OS on '
        'Android, iOS and macOS, and records it next to the timings in the '
        'benchmark. Also fixed LiteRT-LM on the GPU and on Windows ARM64.',
    website: 'https://samarth-vala-portfolio.vercel.app',
  ),
  Maintainer(
    name: 'Daisuke Majima (MLBoy)',
    login: 'john-rocky',
    githubId: 23278992,
    role: 'Hugging Face integration',
    roleHref: '/docs/models#hugging-face',
    about:
        'Japan · ex-Ultralytics · has converted 400+ open models to LiteRT, '
        'Core AI and ExecuTorch and measured them on phones; 163 of them are '
        'in litert-community',
    blurb:
        'Built installing a model straight from its Hugging Face repository, '
        'and the check that keeps it working against the live catalog as '
        'repositories change.',
    website: 'https://john-rocky.github.io',
  ),
];
