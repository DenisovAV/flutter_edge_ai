/// The apps on the `/showcase` page and the two orders it shows them in.
///
/// Plain Dart, no Jaspr, like `maintainers.dart`. The page sorts the apps
/// while it is pre-rendered, so sorting on the deployed page needs no script.
library;

class ShowcaseApp {
  const ShowcaseApp({
    required this.name,
    required this.icon,
    this.googlePlay,
    this.appStore,
  }) : assert(googlePlay != null || appStore != null, 'an app needs a store');

  final String name;

  /// An icon served from `web/`: `/images/showcase/<id>-<n>.png`, where
  /// `<id>` is the Google Play application id, or `id<trackId>` from the App
  /// Store link for an app only there. Images are cached for a year
  /// (firebase.json), so a new icon takes the next `<n>` instead of
  /// overwriting the file.
  final String icon;

  final GooglePlayListing? googlePlay;

  final AppStoreListing? appStore;
}

class GooglePlayListing {
  const GooglePlayListing(this.applicationId, {required this.installs});

  final String applicationId;

  /// The lower bound Google Play shows for the install count: `10K+` is
  /// 10000.
  final int installs;

  String get url => 'https://play.google.com/store/apps/details?id=$applicationId';

  /// The install count as Google Play shows it, e.g. `10K+`.
  String get installsLabel => switch (installs) {
    >= 1000000000 => '${installs ~/ 1000000000}B+',
    >= 1000000 => '${installs ~/ 1000000}M+',
    >= 1000 => '${installs ~/ 1000}K+',
    _ => '$installs+',
  };
}

class AppStoreListing {
  const AppStoreListing(this.url, {this.ratings});

  final String url;

  /// `userRatingCount` from the iTunes Lookup API. Apple publishes no download
  /// count, so this orders the apps that are not on Google Play, and such an
  /// app needs it: [byDownloads] throws without it, which fails the build.
  final int? ratings;
}

/// Store figures as of 2026-11-04; GiGi's, Aura's and Clean Expense's as of
/// 2026-11-05.
const showcaseApps = <ShowcaseApp>[
  ShowcaseApp(
    name: 'LocalMind: Ollama & LM Studio',
    icon: '/images/showcase/pro.momin.localmind-1.png',
    googlePlay: GooglePlayListing('pro.momin.localmind', installs: 10000),
    appStore: AppStoreListing(
      'https://apps.apple.com/us/app/localmind-ollama-lm-studio/id6777025480',
    ),
  ),
  ShowcaseApp(
    name: 'Homiletics',
    icon: '/images/showcase/com.thirteenone.homiletics-1.png',
    googlePlay: GooglePlayListing('com.thirteenone.homiletics', installs: 5000),
    appStore: AppStoreListing(
      'https://apps.apple.com/us/app/homiletics/id1591978405',
    ),
  ),
  ShowcaseApp(
    name: 'flipper',
    icon: '/images/showcase/rw.flipper-1.png',
    googlePlay: GooglePlayListing('rw.flipper', installs: 500),
  ),
  ShowcaseApp(
    name: 'Live Captions XR',
    icon: '/images/showcase/com.livecaptionsxr.app-1.png',
    googlePlay: GooglePlayListing('com.livecaptionsxr.app', installs: 100),
  ),
  ShowcaseApp(
    name: 'GiGi by IntelliGeeks',
    icon: '/images/showcase/com.intelligeeks.gigi-1.png',
    googlePlay: GooglePlayListing('com.intelligeeks.gigi', installs: 10),
  ),
  ShowcaseApp(
    name: 'Aura - AI 관상·손금',
    icon: '/images/showcase/kr.co.taoist.gwansang-1.png',
    googlePlay: GooglePlayListing('kr.co.taoist.gwansang', installs: 100),
  ),
  ShowcaseApp(
    name: 'Clean Expense: Budget Tracker',
    icon: '/images/showcase/com.sutechs.expense-1.png',
    googlePlay: GooglePlayListing('com.sutechs.expense', installs: 100),
    appStore: AppStoreListing('https://apps.apple.com/us/app/clean-expense-budget-tracker/id6757723320'),
  ),
];

/// By name, ignoring case.
int compareByName(ShowcaseApp a, ShowcaseApp b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());

/// Most Google Play installs first. Apps only on the App Store come after
/// every app on Google Play, most App Store ratings first. Ties go by name.
int compareByDownloads(ShowcaseApp a, ShowcaseApp b) {
  final byStore = switch ((a.googlePlay, b.googlePlay)) {
    (final x?, final y?) => y.installs.compareTo(x.installs),
    (_?, null) => -1,
    (null, _?) => 1,
    (null, null) => _ratings(b).compareTo(_ratings(a)),
  };
  return byStore != 0 ? byStore : compareByName(a, b);
}

int _ratings(ShowcaseApp app) =>
    app.appStore?.ratings ?? (throw StateError('${app.name} is only on the App Store and needs its ratings'));

/// [apps] in the order of [compareByDownloads].
///
/// Every app that is only on the App Store is checked for its ratings first:
/// the comparison reads them only when two such apps meet, so a single one
/// without ratings would otherwise pass.
List<ShowcaseApp> byDownloads(List<ShowcaseApp> apps) {
  for (final app in apps) {
    if (app.googlePlay == null) _ratings(app);
  }
  return [...apps]..sort(compareByDownloads);
}

/// [apps] in the order of [compareByName].
List<ShowcaseApp> byName(List<ShowcaseApp> apps) => [...apps]..sort(compareByName);
