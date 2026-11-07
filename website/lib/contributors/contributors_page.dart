import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../landing/sections/nav_bar.dart';
import '../landing/sections/site_footer.dart';
import '../theme/brand.dart';
import 'contributor.dart';
import 'contributors_data.g.dart';
import 'maintainers.dart';

const _contributingUrl =
    'https://github.com/DenisovAV/flutter_edge_ai/blob/main/packages/flutter_edge_ai/CONTRIBUTING.md';

/// `/contributors` — the maintainers, each with the part of the project they
/// look after, then everyone else whose work landed in the repository.
///
/// The maintainers are a hand-kept list (`maintainers.dart`); the grid is
/// generated from GitHub by `tool/update_contributors.dart`, so the build
/// itself never calls GitHub. Avatars load from GitHub at view time.
class ContributorsPage extends StatelessComponent {
  const ContributorsPage({super.key});

  static const _accents = [Brand.blue, Brand.orange, Brand.green];

  static const _external = {'target': '_blank', 'rel': 'noopener'};

  @override
  Component build(BuildContext context) {
    // `.landing-root` supplies the navy canvas, `min-height: 100vh` and the
    // element resets the NavBar/SiteFooter styles are scoped to.
    return main_(classes: 'landing-root', [
      const NavBar(),
      section(classes: 'cb-head', [
        div(classes: 'cb-head-inner', [
          p(classes: 'cb-eyebrow', [Component.text('Contributors')]),
          h1(classes: 'cb-title', [
            Component.text('The people behind Flutter Edge AI'),
          ]),
          p(classes: 'cb-standfirst', [
            Component.text(
              'Flutter Edge AI is built in the open. The maintainers below '
              'look after its parts; everyone after them has work in it too.',
            ),
          ]),
        ]),
      ]),
      section(classes: 'cb-section', [
        div(classes: 'cb-section-inner', [
          h2(classes: 'cb-section-title', [Component.text('Maintainers')]),
          div(classes: 'cb-maintainers', [
            for (var i = 0; i < maintainers.length; i++) _maintainerCard(maintainers[i], _accents[i % _accents.length]),
          ]),
        ]),
      ]),
      section(classes: 'cb-section', [
        div(classes: 'cb-section-inner', [
          h2(classes: 'cb-section-title', [Component.text('Contributors')]),
          p(classes: 'cb-section-lead', [
            Component.text(
              'Everyone else whose work landed in the repository. Thank you.',
            ),
          ]),
          div(classes: 'cb-people', [
            for (final c in contributors) _contributorTile(c),
          ]),
          a(
            href: _contributingUrl,
            classes: 'cb-contribute',
            attributes: _external,
            [Component.text('How to contribute →')],
          ),
        ]),
      ]),
      const SiteFooter(),
    ]);
  }

  static Component _maintainerCard(Maintainer m, Color accent) {
    final githubUrl = 'https://github.com/${m.login}';
    return article(classes: 'cb-card', [
      div(
        classes: 'cb-accent',
        styles: Styles(raw: {'background': accent.value}),
        [],
      ),
      div(classes: 'cb-card-body', [
        div(classes: 'cb-person', [
          img(
            src: m.avatarUrl,
            alt: m.name,
            classes: 'cb-avatar',
            attributes: const {'width': '72', 'height': '72', 'loading': 'lazy'},
          ),
          div(classes: 'cb-person-text', [
            h3(classes: 'cb-name', [Component.text(m.name)]),
            a(
              href: githubUrl,
              classes: 'cb-handle',
              attributes: _external,
              [Component.text('@${m.login}')],
            ),
          ]),
        ]),
        p(classes: 'cb-about', [Component.text(m.about)]),
        div(classes: 'cb-tags', [
          if (m.role case final role?)
            m.roleHref == null
                ? span(classes: 'cb-role', [Component.text(role)])
                : a(href: m.roleHref!, classes: 'cb-role cb-role--link', [Component.text(role)]),
          for (final package in m.packages)
            a(
              href: 'https://pub.dev/packages/$package',
              classes: 'cb-package',
              attributes: _external,
              [Component.text(package)],
            ),
        ]),
        p(classes: 'cb-blurb', [Component.text(m.blurb)]),
        div(classes: 'cb-links', [
          a(
            href: githubUrl,
            classes: 'cb-link',
            attributes: _external,
            [Component.text('GitHub')],
          ),
          if (m.website case final website?)
            a(
              href: website,
              classes: 'cb-link',
              attributes: _external,
              [Component.text('Website')],
            ),
        ]),
      ]),
    ]);
  }

  /// The login is visible text, not a tooltip: a phone has no hover. The
  /// avatar's alt is empty because the login next to it already names it.
  static Component _contributorTile(Contributor c) {
    return a(
      href: c.commitsUrl,
      classes: 'cb-tile',
      attributes: _external,
      [
        img(
          src: c.avatarUrl,
          alt: '',
          classes: 'cb-tile-avatar',
          attributes: const {'width': '56', 'height': '56', 'loading': 'lazy'},
        ),
        span(classes: 'cb-tile-name', [Component.text(c.login)]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    // ---- header (same scale as /codelabs) ----
    css('.cb-head').styles(
      padding: Padding.symmetric(horizontal: 2.rem, vertical: 4.rem),
    ),
    css('.cb-head-inner').styles(
      maxWidth: 760.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.rem),
    ),
    css('.cb-eyebrow').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 0.8.rem,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.14.em,
      textTransform: TextTransform.upperCase,
      color: Brand.blueLight,
    ),
    css('.cb-title').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 2.6.rem,
      fontWeight: FontWeight.w700,
      lineHeight: 1.1.em,
      letterSpacing: (-0.02).em,
      color: Brand.white,
    ),
    css('.cb-standfirst').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 1.05.rem,
      lineHeight: 1.6.em,
      color: Brand.white70,
    ),

    // ---- sections ----
    css('.cb-section').styles(
      padding: Padding.only(left: 2.rem, right: 2.rem, bottom: 4.rem),
    ),
    css('.cb-section-inner').styles(
      maxWidth: 1100.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.25.rem),
    ),
    css('.cb-section-title').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.5.rem,
      fontWeight: FontWeight.w700,
      letterSpacing: (-0.01).em,
      color: Brand.white,
    ),
    css('.cb-section-lead').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 0.98.rem,
      lineHeight: 1.6.em,
      color: Brand.white70,
    ),

    // ---- maintainer cards ----
    // 280px floor, as in `.cl-grid`: a larger one scrolls sideways on a
    // 360px phone.
    css('.cb-maintainers').styles(
      display: Display.grid,
      gridTemplate: GridTemplate(
        columns: GridTracks([
          GridTrack.repeat(
            TrackRepeat.autoFit,
            [GridTrack(TrackSize.minmax(TrackSize(280.px), TrackSize.fr(1)))],
          ),
        ]),
      ),
      gap: Gap.all(1.25.rem),
    ),
    css('.cb-card').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      overflow: Overflow.hidden,
      backgroundColor: Brand.navyLight,
      radius: BorderRadius.circular(10.px),
      border: Border.all(color: Color('rgba(255,255,255,0.08)'), width: 1.px),
    ),
    css('.cb-accent').styles(height: 3.px, width: 100.percent),
    css('.cb-card-body').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(0.8.rem),
      padding: Padding.all(1.4.rem),
      flex: Flex(grow: 1),
    ),
    css('.cb-person').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      gap: Gap.all(0.9.rem),
    ),
    // Scoped under `.landing-root`: its `img { height: auto }` reset is
    // (0,1,1) and would beat a bare `.cb-avatar` (0,1,0) — see
    // `.landing-root .navbar-logo` in nav_bar.dart.
    css('.landing-root .cb-avatar').styles(
      width: 72.px,
      height: 72.px,
      radius: BorderRadius.circular(50.percent),
      backgroundColor: Brand.navy,
      raw: {'object-fit': 'cover', 'flex-shrink': '0'},
    ),
    css('.cb-person-text').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(0.2.rem),
      raw: {'min-width': '0'},
    ),
    css('.cb-name').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.15.rem,
      fontWeight: FontWeight.w700,
      lineHeight: 1.3.em,
      color: Brand.white,
    ),
    css('.cb-handle').styles(
      fontFamily: Brand.fontMono,
      fontSize: 0.85.rem,
      color: Brand.blueLight,
      textDecoration: TextDecoration.none,
    ),
    css('.cb-handle:hover').styles(
      textDecoration: TextDecoration(line: TextDecorationLine.underline),
    ),
    css('.cb-about').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 0.85.rem,
      lineHeight: 1.5.em,
      color: Brand.white70,
    ),
    css('.cb-tags').styles(
      display: Display.flex,
      flexWrap: FlexWrap.wrap,
      gap: Gap.all(0.4.rem),
    ),
    css('.cb-package, .cb-role').styles(
      padding: Padding.symmetric(horizontal: 0.55.rem, vertical: 0.2.rem),
      backgroundColor: Color('rgba(255,255,255,0.07)'),
      radius: BorderRadius.circular(4.px),
      fontSize: 0.75.rem,
      color: Brand.white,
      textDecoration: TextDecoration.none,
    ),
    css('.cb-package').styles(fontFamily: Brand.fontMono),
    css('.cb-role').styles(
      fontFamily: Brand.fontSans,
      fontWeight: FontWeight.w600,
    ),
    css('.cb-package:hover, .cb-role--link:hover').styles(
      backgroundColor: Color('rgba(147,197,253,0.18)'),
    ),
    css('.cb-blurb').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 0.93.rem,
      lineHeight: 1.55.em,
      color: Brand.white70,
      flex: Flex(grow: 1),
    ),
    css('.cb-links').styles(
      display: Display.flex,
      flexWrap: FlexWrap.wrap,
      gap: Gap.all(1.1.rem),
    ),
    css('.cb-link').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.9.rem,
      fontWeight: FontWeight.w600,
      color: Brand.blueLight,
      textDecoration: TextDecoration.none,
    ),
    css('.cb-link:hover').styles(
      textDecoration: TextDecoration(line: TextDecorationLine.underline),
    ),

    // ---- contributor grid ----
    css('.cb-people').styles(
      display: Display.grid,
      gridTemplate: GridTemplate(
        columns: GridTracks([
          GridTrack.repeat(
            TrackRepeat.autoFill,
            [GridTrack(TrackSize.minmax(TrackSize(92.px), TrackSize.fr(1)))],
          ),
        ]),
      ),
      // 92px + 0.75rem: three tiles across a 360px phone, whose content box
      // is 320px after the section's 1.25rem gutters.
      gap: Gap.all(0.75.rem),
    ),
    css('.cb-tile').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap.all(0.5.rem),
      padding: Padding.symmetric(vertical: 0.75.rem, horizontal: 0.4.rem),
      radius: BorderRadius.circular(10.px),
      textDecoration: TextDecoration.none,
      raw: {'transition': 'background-color .15s ease'},
    ),
    css('.cb-tile:hover').styles(
      backgroundColor: Color('rgba(255,255,255,0.06)'),
    ),
    css('.landing-root .cb-tile-avatar').styles(
      width: 56.px,
      height: 56.px,
      radius: BorderRadius.circular(50.percent),
      backgroundColor: Brand.navyLight,
      raw: {'object-fit': 'cover'},
    ),
    css('.cb-tile-name').styles(
      maxWidth: 100.percent,
      fontFamily: Brand.fontSans,
      fontSize: 0.8.rem,
      lineHeight: 1.3.em,
      textAlign: TextAlign.center,
      color: Brand.white70,
      raw: {'overflow-wrap': 'anywhere'},
    ),
    css('.cb-tile:hover .cb-tile-name').styles(color: Brand.white),
    css('.cb-contribute').styles(
      alignSelf: AlignSelf.start,
      margin: Margin.only(top: 1.rem),
      fontFamily: Brand.fontSans,
      fontSize: 0.95.rem,
      fontWeight: FontWeight.w600,
      color: Brand.blueLight,
      textDecoration: TextDecoration.none,
    ),
    css('.cb-contribute:hover').styles(
      textDecoration: TextDecoration(line: TextDecorationLine.underline),
    ),

    // ---- wider screens ----
    // Wider tiles where there is room, so a 16-character login such as
    // `frdteknikelektro` fits on one line; the phone keeps three across.
    StyleRule.media(
      query: MediaQuery.screen(minWidth: 641.px),
      styles: [
        css('.cb-people').styles(
          gridTemplate: GridTemplate(
            columns: GridTracks([
              GridTrack.repeat(
                TrackRepeat.autoFill,
                [
                  GridTrack(
                    TrackSize.minmax(TrackSize(116.px), TrackSize.fr(1)),
                  ),
                ],
              ),
            ]),
          ),
        ),
      ],
    ),

    // ---- narrow screens ----
    StyleRule.media(
      query: MediaQuery.screen(maxWidth: 640.px),
      styles: [
        css('.cb-head').styles(
          padding: Padding.symmetric(horizontal: 1.25.rem, vertical: 2.5.rem),
        ),
        css('.cb-title').styles(fontSize: 1.9.rem),
        css('.cb-section').styles(
          padding: Padding.only(left: 1.25.rem, right: 1.25.rem, bottom: 3.rem),
        ),
      ],
    ),
  ];
}
