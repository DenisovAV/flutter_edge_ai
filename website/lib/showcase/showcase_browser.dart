import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../theme/brand.dart';
import 'showcase_apps.dart';

/// A choice in one of the page's controls.
abstract interface class ShowcaseOption {
  String get label;
}

/// Which store's apps the grid shows.
enum ShowcaseStore implements ShowcaseOption {
  all('All'),
  googlePlay('Google Play'),
  appStore('App Store');

  const ShowcaseStore(this.label);

  @override
  final String label;

  bool shows(ShowcaseApp app) => switch (this) {
    all => true,
    googlePlay => app.googlePlay != null,
    appStore => app.appStore != null,
  };
}

/// The order of the grid.
enum ShowcaseSort implements ShowcaseOption {
  downloads('Downloads'),
  name('Name');

  const ShowcaseSort(this.label);

  @override
  final String label;

  List<ShowcaseApp> apply(List<ShowcaseApp> apps) => switch (this) {
    downloads => byDownloads(apps),
    name => byName(apps),
  };
}

/// The store filter, the sort order and the grid of [showcaseApps].
///
/// A `@client` component: the page is prerendered with every app by
/// downloads, and the controls re-render the grid in the browser. There is
/// one grid, so the order on screen is also the order of Tab and of a screen
/// reader.
///
/// The store badges are the stores' own artwork, unmodified, under their
/// guidelines: 40px high (Apple's onscreen minimum; Google's badge is the
/// same height, as its guidelines ask), a quarter of that as clear space and
/// Apple's black badge first. The trademark lines are on the page, below.
@client
class ShowcaseBrowser extends StatefulComponent {
  const ShowcaseBrowser({super.key});

  @override
  State<ShowcaseBrowser> createState() => ShowcaseBrowserState();
}

class ShowcaseBrowserState extends State<ShowcaseBrowser> {
  ShowcaseStore _store = ShowcaseStore.all;
  ShowcaseSort _sort = ShowcaseSort.downloads;

  static const _external = {'target': '_blank', 'rel': 'noopener'};

  @override
  Component build(BuildContext context) {
    final apps = _sort.apply(showcaseApps).where(_store.shows).toList();
    return div(classes: 'sc-browser', [
      div(classes: 'sc-controls', [
        _control('sc-store-caption', 'Store', ShowcaseStore.values, _store, (value) => _store = value),
        _control('sc-sort-caption', 'Sort by', ShowcaseSort.values, _sort, (value) => _sort = value),
      ]),
      div(classes: 'sc-grid', [
        for (var i = 0; i < apps.length; i++) _appCard(apps[i], 'sc-app-$i'),
        _yourAppCard(),
      ]),
    ]);
  }

  /// A labelled group of toggle buttons; the pressed one is the current value.
  Component _control<T extends ShowcaseOption>(
    String captionId,
    String caption,
    List<T> options,
    T current,
    void Function(T) select,
  ) {
    return div(
      classes: 'sc-control',
      attributes: {'role': 'group', 'aria-labelledby': captionId},
      [
        span(id: captionId, classes: 'sc-control-caption', [Component.text(caption)]),
        for (final o in options)
          button(
            type: ButtonType.button,
            classes: 'sc-option',
            attributes: {'aria-pressed': '${o == current}'},
            onClick: () => setState(() => select(o)),
            [Component.text(o.label)],
          ),
      ],
    );
  }

  /// The icon's alt is empty because the name beside it already names it. The
  /// glow behind it is the same icon, blurred, so it takes the icon's colours.
  /// Every badge link describes itself with the app's name: their own names
  /// repeat from card to card.
  static Component _appCard(ShowcaseApp app, String nameId) {
    final describedByName = {..._external, 'aria-describedby': nameId};
    return article(classes: 'sc-card', [
      div(
        classes: 'sc-icon-wrap',
        styles: Styles(raw: {'--sc-icon': 'url("${app.icon}")'}),
        [
          img(
            src: app.icon,
            alt: '',
            classes: 'sc-icon',
            attributes: const {'width': '64', 'height': '64', 'loading': 'lazy'},
          ),
        ],
      ),
      h2(id: nameId, classes: 'sc-name', [Component.text(app.name)]),
      div(classes: 'sc-badges', [
        // Apple's guidelines put the App Store badge first in a lineup.
        if (app.appStore case final store?)
          a(href: store.url, classes: 'sc-badge', attributes: describedByName, [
            img(
              src: '/images/showcase/badges/app-store-black.svg',
              alt: 'Download on the App Store',
              classes: 'sc-badge-apple',
              attributes: const {'width': '120', 'height': '40'},
            ),
          ]),
        if (app.googlePlay case final play?)
          div(classes: 'sc-badge-play-group', [
            a(href: play.url, classes: 'sc-badge', attributes: describedByName, [
              img(
                src: '/images/showcase/badges/google-play.png',
                alt: 'Get it on Google Play',
                classes: 'sc-badge-play',
                attributes: const {'width': '134', 'height': '40'},
              ),
            ]),
            span(classes: 'sc-downloads', [Component.text('${play.installsLabel} downloads')]),
          ]),
      ]),
    ]);
  }

  /// Last under every filter and order; it leads to the submission form.
  static Component _yourAppCard() {
    return a(href: '/showcase/submit', classes: 'sc-card sc-yours', [
      div(classes: 'sc-yours-plus', [
        svg(
          viewBox: '0 0 24 24',
          width: 24.px,
          height: 24.px,
          attributes: const {'aria-hidden': 'true'},
          [
            path(
              d: 'M12 5v14M5 12h14',
              stroke: Brand.blueLight,
              strokeWidth: '2.2',
              attributes: const {'stroke-linecap': 'round'},
              [],
            ),
          ],
        ),
      ]),
      p(classes: 'sc-yours-text', [Component.text('Your app here')]),
    ]);
  }

  @css
  static List<StyleRule> get styles => [
    css('.sc-browser').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.25.rem),
    ),

    // ---- filter and sort ----
    css('.sc-controls').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      flexWrap: FlexWrap.wrap,
      gap: Gap(row: 0.75.rem, column: 2.rem),
    ),
    css('.sc-control').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      flexWrap: FlexWrap.wrap,
      alignItems: AlignItems.center,
      gap: Gap.all(0.45.rem),
    ),
    css('.sc-control-caption').styles(
      margin: Margin.only(right: 0.25.rem),
      color: Brand.white50,
      fontFamily: Brand.fontSans,
      fontSize: 0.85.rem,
    ),
    css('.sc-option').styles(
      padding: Padding.symmetric(horizontal: 0.85.rem, vertical: 0.4.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.15)'), width: 1.px),
      radius: BorderRadius.circular(999.px),
      cursor: Cursor.pointer,
      color: Brand.white70,
      fontFamily: Brand.fontSans,
      fontSize: 0.9.rem,
      fontWeight: FontWeight.w500,
      backgroundColor: Color('transparent'),
    ),
    css('.sc-option:hover').styles(color: Brand.white),
    css('.sc-option[aria-pressed="true"]').styles(
      border: Border.all(color: Brand.blue, width: 1.px),
      color: Brand.white,
      fontWeight: FontWeight.w700,
      backgroundColor: Color('rgba(59,130,246,0.22)'),
    ),
    css('.sc-option:focus-visible').styles(
      raw: {
        'outline': '2px solid ${Brand.blueLight.value}',
        'outline-offset': '2px',
      },
    ),

    // ---- cards ----
    // A row per app, as in a store's list: the icon on the left, the name
    // and the badges beside it. Two columns from a 1080px viewport, where a
    // card has room for both badges and the download count on one line, one
    // below; `min(…, 100%)` keeps a 320px screen from scrolling sideways.
    css('.sc-grid').styles(
      display: Display.grid,
      gap: Gap.all(1.rem),
      raw: {'grid-template-columns': 'repeat(auto-fill, minmax(min(500px, 100%), 1fr))'},
    ),
    css('.sc-card').styles(
      display: Display.grid,
      padding: Padding.symmetric(horizontal: 1.25.rem, vertical: 1.1.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.08)'), width: 1.px),
      radius: BorderRadius.circular(14.px),
      alignItems: AlignItems.center,
      backgroundColor: Color('rgba(255,255,255,0.035)'),
      raw: {
        'grid-template-columns': '64px minmax(0, 1fr)',
        'column-gap': '1rem',
        'row-gap': '0.75rem',
        'align-content': 'center',
      },
    ),
    css('.sc-icon-wrap').styles(
      position: Position.relative(),
      width: 64.px,
      height: 64.px,
      raw: {'grid-row': 'span 2'},
    ),
    css('.sc-icon-wrap::before').styles(
      content: '',
      position: Position.absolute(top: 6.px, left: 6.px, right: 6.px, bottom: 6.px),
      radius: BorderRadius.circular(16.px),
      opacity: 0.5,
      raw: {
        'background': 'var(--sc-icon) center / cover',
        'filter': 'blur(18px)',
      },
    ),
    // Scoped under `.landing-root`: its `img { height: auto }` reset is
    // (0,1,1) and would beat a bare `.sc-icon` (0,1,0) — see
    // `.landing-root .navbar-logo` in nav_bar.dart.
    css('.landing-root .sc-icon').styles(
      display: Display.block,
      position: Position.relative(),
      width: 100.percent,
      height: 100.percent,
      radius: BorderRadius.circular(14.px),
      raw: {'object-fit': 'cover'},
    ),
    // Scoped for the same reason: `.landing-root h2 { margin: 0 }` is
    // (0,1,1).
    css('.landing-root .sc-name').styles(
      margin: Margin.zero,
      color: Brand.white,
      fontFamily: Brand.fontSans,
      fontSize: 1.rem,
      fontWeight: FontWeight.w600,
      lineHeight: 1.35.em,
      raw: {'align-self': 'end'},
    ),
    // The gaps are the badges' clear space: a quarter of their 40px height.
    css('.sc-badges').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      flexWrap: FlexWrap.wrap,
      alignItems: AlignItems.center,
      gap: Gap.all(10.px),
      raw: {'align-self': 'start'},
    ),
    css('.sc-badge').styles(display: Display.block, raw: {'line-height': '0'}),
    css('.landing-root .sc-badge-apple').styles(display: Display.block, width: 120.px, height: 40.px),
    css('.landing-root .sc-badge-play').styles(display: Display.block, width: 134.px, height: 40.px),
    css('.sc-badge-play-group').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      gap: Gap.all(10.px),
    ),
    css('.sc-downloads').styles(
      color: Brand.white50,
      fontFamily: Brand.fontSans,
      fontSize: 0.78.rem,
      lineHeight: 1.em,
      raw: {'white-space': 'nowrap'},
    ),

    // ---- "Your app here" ----
    css('.sc-yours').styles(
      border: Border.all(color: Color('rgba(147,197,253,0.4)'), width: 1.5.px, style: BorderStyle.dashed),
      textDecoration: TextDecoration.none,
      backgroundColor: Color('transparent'),
    ),
    css('.sc-yours:hover').styles(
      border: Border.all(color: Brand.blueLight, width: 1.5.px, style: BorderStyle.dashed),
      backgroundColor: Color('rgba(147,197,253,0.06)'),
    ),
    css('.sc-yours:focus-visible').styles(
      raw: {'outline': '2px solid ${Brand.blueLight.value}', 'outline-offset': '2px'},
    ),
    css('.sc-yours-plus').styles(
      display: Display.flex,
      width: 64.px,
      height: 64.px,
      border: Border.all(color: Color('rgba(147,197,253,0.4)'), width: 1.5.px, style: BorderStyle.dashed),
      radius: BorderRadius.circular(14.px),
      justifyContent: JustifyContent.center,
      alignItems: AlignItems.center,
    ),
    css('.landing-root .sc-yours-text').styles(
      margin: Margin.zero,
      color: Brand.white70,
      fontFamily: Brand.fontSans,
      fontSize: 1.rem,
      fontWeight: FontWeight.w600,
    ),

    // ---- narrow screens ----
    StyleRule.media(
      query: MediaQuery.screen(maxWidth: 640.px),
      styles: [
        // A narrow card: the icon beside the name only, the badges below
        // both, and the download count under the Google Play badge.
        css('.sc-card').styles(
          padding: Padding.all(1.rem),
          raw: {'grid-template-columns': '48px minmax(0, 1fr)', 'column-gap': '0.85rem'},
        ),
        css('.sc-icon-wrap').styles(width: 48.px, height: 48.px, raw: {'grid-row': 'auto'}),
        css('.landing-root .sc-icon').styles(radius: BorderRadius.circular(11.px)),
        css('.landing-root .sc-name').styles(raw: {'align-self': 'center'}),
        css('.sc-badges').styles(alignItems: AlignItems.start, raw: {'grid-column': '1 / -1'}),
        css('.sc-badge-play-group').styles(flexDirection: FlexDirection.column),
        css('.sc-yours-plus').styles(width: 48.px, height: 48.px),
      ],
    ),
  ];
}
