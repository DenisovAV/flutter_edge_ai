import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../landing/sections/nav_bar.dart';
import '../landing/sections/site_footer.dart';
import '../theme/brand.dart';
import 'showcase_apps.dart';

/// `/showcase` — apps in the stores that use flutter_edge_ai or flutter_gemma,
/// with a store filter and two sort orders.
///
/// Filter and sort are pure CSS, like the NavBar's menu: this site is Jaspr
/// static mode and a `@client` component does not hydrate on the deployed
/// build. Hidden radio buttons precede the controls and the grid; each card
/// carries its rank in both orders as CSS variables, and `:checked ~` picks
/// the `order` and hides the cards without the chosen store.
///
/// The store badges are the stores' own artwork, unmodified, under their
/// guidelines: 40px high (Apple's onscreen minimum; Google's badge is the
/// same height, as its guidelines ask), a quarter of that as clear space,
/// Apple's black badge first, and the trademark lines below the grid.
class ShowcasePage extends StatelessComponent {
  const ShowcasePage({super.key});

  static const _stores = <({String id, String text})>[
    (id: 'sc-store-all', text: 'All'),
    (id: 'sc-store-play', text: 'Google Play'),
    (id: 'sc-store-apple', text: 'App Store'),
  ];

  static const _sorts = <({String id, String text})>[
    (id: 'sc-sort-downloads', text: 'Downloads'),
    (id: 'sc-sort-name', text: 'Name'),
  ];

  static const _external = {'target': '_blank', 'rel': 'noopener'};

  @override
  Component build(BuildContext context) {
    final byDownloads = rankBy(showcaseApps, compareByDownloads);
    final byName = rankBy(showcaseApps, compareByName);
    final last = showcaseApps.length + 1;

    // `.landing-root` supplies the navy canvas, `min-height: 100vh` and the
    // element resets the NavBar/SiteFooter styles are scoped to.
    return main_(classes: 'landing-root', [
      const NavBar(),
      section(classes: 'sc-head', [
        div(classes: 'sc-head-inner', [
          p(classes: 'sc-eyebrow', [Component.text('Showcase')]),
          h1(classes: 'sc-title', [Component.text('Built with Flutter Edge AI')]),
          p(classes: 'sc-standfirst', [
            Component.text('Apps on Google Play and the App Store that run AI on-device with '),
            code([Component.text('flutter_edge_ai')]),
            Component.text(' or '),
            code([Component.text('flutter_gemma')]),
            Component.text('.'),
          ]),
        ]),
      ]),
      section(classes: 'sc-section', [
        div(classes: 'sc-section-inner', [
          // The radios carry the state and must come before `.sc-controls`
          // and `.sc-grid` for `~` to reach them. Visually hidden but not
          // `display: none`, so Tab and the arrow keys still reach them.
          for (final o in _stores) _radio(o.id, 'sc-store', 'sc-store-caption', checked: o == _stores.first),
          for (final o in _sorts) _radio(o.id, 'sc-sort', 'sc-sort-caption', checked: o == _sorts.first),
          div(classes: 'sc-controls', [
            _control('sc-store-caption', 'Store', _stores),
            _control('sc-sort-caption', 'Sort by', _sorts),
          ]),
          div(classes: 'sc-grid', [
            for (var i = 0; i < showcaseApps.length; i++)
              _appCard(showcaseApps[i], 'sc-app-$i', byDownloads[i], byName[i]),
            _yourAppCard(last),
          ]),
          p(classes: 'sc-legal', [
            Component.text(
              'Apple and the Apple logo are trademarks of Apple Inc., registered in the U.S. and other '
              'countries. App Store is a service mark of Apple Inc. Google Play and the Google Play logo '
              'are trademarks of Google LLC.',
            ),
          ]),
        ]),
      ]),
      const SiteFooter(),
    ]);
  }

  static Component _radio(String id, String name, String captionId, {required bool checked}) {
    return input(
      type: InputType.radio,
      id: id,
      name: name,
      checked: checked,
      classes: 'sc-radio',
      attributes: {'aria-describedby': captionId},
    );
  }

  static Component _control(String captionId, String caption, List<({String id, String text})> options) {
    return div(classes: 'sc-control', [
      span(id: captionId, classes: 'sc-control-caption', [Component.text(caption)]),
      for (final o in options) label(htmlFor: o.id, classes: 'sc-option', [Component.text(o.text)]),
    ]);
  }

  static Styles _ranks(int byDownloads, int byName) => Styles(
    raw: {'--sc-rank-downloads': '$byDownloads', '--sc-rank-name': '$byName'},
  );

  /// The icon's alt is empty because the name below it already names it. The
  /// glow behind it is the same icon, blurred, so it takes the icon's colours.
  /// Every badge link describes itself with the app's name: their own names
  /// repeat from card to card.
  static Component _appCard(ShowcaseApp app, String nameId, int byDownloads, int byName) {
    final describedByName = {..._external, 'aria-describedby': nameId};
    return article(
      classes: [
        'sc-card',
        'sc-app',
        if (app.googlePlay != null) 'sc-on-play',
        if (app.appStore != null) 'sc-on-apple',
      ].join(' '),
      styles: _ranks(byDownloads, byName),
      [
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
      ],
    );
  }

  /// Last in both orders and under every filter. Not a link yet.
  static Component _yourAppCard(int rank) {
    return div(classes: 'sc-card sc-yours', styles: _ranks(rank, rank), [
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

  /// Per-option rules: the checked option is highlighted, and a focused radio
  /// shows its ring on the label that stands in for it.
  static List<StyleRule> _optionRules(String id) => [
    css('#$id:checked ~ .sc-controls .sc-option[for="$id"]').styles(
      border: Border.all(color: Brand.blue, width: 1.px),
      color: Brand.white,
      fontWeight: FontWeight.w700,
      backgroundColor: Color('rgba(59,130,246,0.22)'),
    ),
    css('#$id:focus-visible ~ .sc-controls .sc-option[for="$id"]').styles(
      raw: {
        'outline': '2px solid ${Brand.blueLight.value}',
        'outline-offset': '2px',
      },
    ),
  ];

  @css
  static List<StyleRule> get styles => [
    // ---- header ----
    // As wide as the grid, so the title starts where the cards do.
    css('.sc-head').styles(
      padding: Padding.only(left: 2.rem, right: 2.rem, top: 4.rem, bottom: 2.5.rem),
    ),
    css('.sc-head-inner').styles(
      display: Display.flex,
      maxWidth: 1100.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.rem),
    ),
    css('.sc-eyebrow').styles(
      margin: Margin.zero,
      color: Brand.blueLight,
      fontFamily: Brand.fontSans,
      fontSize: 0.8.rem,
      fontWeight: FontWeight.w600,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.14.em,
    ),
    css('.sc-title').styles(
      margin: Margin.zero,
      color: Brand.white,
      fontFamily: Brand.fontSans,
      fontSize: 2.6.rem,
      fontWeight: FontWeight.w700,
      letterSpacing: (-0.02).em,
      lineHeight: 1.1.em,
    ),
    css('.sc-standfirst').styles(
      maxWidth: 640.px,
      margin: Margin.zero,
      color: Brand.white70,
      fontFamily: Brand.fontSans,
      fontSize: 1.05.rem,
      lineHeight: 1.6.em,
    ),
    css('.sc-standfirst code').styles(
      color: Brand.white,
      fontFamily: Brand.fontMono,
      fontSize: 0.92.em,
    ),

    // ---- section ----
    // `position: relative` keeps the absolutely placed radios inside the
    // section, so focusing one does not scroll the page to its top.
    css('.sc-section').styles(
      padding: Padding.only(left: 2.rem, right: 2.rem, bottom: 4.rem),
    ),
    css('.sc-section-inner').styles(
      display: Display.flex,
      position: Position.relative(),
      maxWidth: 1100.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.25.rem),
    ),

    // ---- filter and sort ----
    css('.sc-radio').styles(
      position: Position.absolute(top: 0.px, left: 0.px),
      margin: Margin.zero,
      raw: {
        'opacity': '0',
        'width': '1px',
        'height': '1px',
        'pointer-events': 'none',
      },
    ),
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
      raw: {'user-select': 'none'},
    ),
    css('.sc-option:hover').styles(color: Brand.white),
    for (final o in [..._stores, ..._sorts]) ..._optionRules(o.id),

    // ---- cards ----
    // A row per app, as in a store's list: the icon on the left, the name
    // and the badges beside it. Two 540px columns in the 1100px section, one
    // below; `min(…, 100%)` keeps a 320px screen from scrolling sideways.
    css('.sc-grid').styles(
      display: Display.grid,
      gap: Gap.all(1.rem),
      raw: {'grid-template-columns': 'repeat(auto-fill, minmax(min(480px, 100%), 1fr))'},
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
        'order': 'var(--sc-rank-downloads)',
      },
    ),
    css('#sc-sort-name:checked ~ .sc-grid .sc-card').styles(
      raw: {'order': 'var(--sc-rank-name)'},
    ),
    css('#sc-store-play:checked ~ .sc-grid .sc-app:not(.sc-on-play)').styles(display: Display.none),
    css('#sc-store-apple:checked ~ .sc-grid .sc-app:not(.sc-on-apple)').styles(display: Display.none),
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
      backgroundColor: Color('transparent'),
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

    css('.sc-legal').styles(
      margin: Margin.only(top: 0.75.rem),
      color: Brand.white50,
      fontFamily: Brand.fontSans,
      fontSize: 0.75.rem,
      lineHeight: 1.5.em,
    ),

    // ---- narrow screens ----
    StyleRule.media(
      query: MediaQuery.screen(maxWidth: 640.px),
      styles: [
        css('.sc-head').styles(
          padding: Padding.only(left: 1.25.rem, right: 1.25.rem, top: 2.5.rem, bottom: 1.75.rem),
        ),
        css('.sc-title').styles(fontSize: 1.9.rem),
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
        css('.sc-section').styles(
          padding: Padding.only(left: 1.25.rem, right: 1.25.rem, bottom: 3.rem),
        ),
      ],
    ),
  ];
}
