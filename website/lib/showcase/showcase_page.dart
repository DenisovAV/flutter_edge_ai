import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../landing/sections/nav_bar.dart';
import '../landing/sections/site_footer.dart';
import '../theme/brand.dart';
import 'showcase_browser.dart';

/// `/showcase` — apps in the stores that use flutter_edge_ai or flutter_gemma,
/// with a store filter and two sort orders ([ShowcaseBrowser]).
class ShowcasePage extends StatelessComponent {
  const ShowcasePage({super.key});

  @override
  Component build(BuildContext context) {
    // `.landing-root` supplies the navy canvas, `min-height: 100vh` and the
    // element resets the NavBar/SiteFooter styles are scoped to.
    return main_(classes: 'landing-root', [
      const NavBar(),
      section(classes: 'sc-head', [
        div(classes: 'sc-head-inner', [
          p(classes: 'sc-eyebrow', [Component.text('Showcase')]),
          h1(classes: 'sc-title', [
            Component.text('Built with Flutter Edge AI'),
          ]),
          p(classes: 'sc-standfirst', [
            Component.text(
              'Apps on Google Play and the App Store that run AI on-device with ',
            ),
            code([Component.text('flutter_edge_ai')]),
            Component.text(' or '),
            code([Component.text('flutter_gemma')]),
            Component.text('.'),
          ]),
        ]),
      ]),
      section(classes: 'sc-section', [
        div(classes: 'sc-section-inner', [
          const ShowcaseBrowser(),
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

  @css
  static List<StyleRule> get styles => [
    // ---- header ----
    // As wide as the grid, so the title starts where the cards do.
    css('.sc-head').styles(
      padding: Padding.only(
        left: 2.rem,
        right: 2.rem,
        top: 4.rem,
        bottom: 2.5.rem,
      ),
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
    css(
      '.sc-standfirst code',
    ).styles(color: Brand.white, fontFamily: Brand.fontMono, fontSize: 0.92.em),

    // ---- section ----
    css('.sc-section').styles(
      padding: Padding.only(left: 2.rem, right: 2.rem, bottom: 4.rem),
    ),
    css('.sc-section-inner').styles(
      display: Display.flex,
      maxWidth: 1100.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.25.rem),
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
          padding: Padding.only(
            left: 1.25.rem,
            right: 1.25.rem,
            top: 2.5.rem,
            bottom: 1.75.rem,
          ),
        ),
        css('.sc-title').styles(fontSize: 1.9.rem),
        css('.sc-section').styles(
          padding: Padding.only(left: 1.25.rem, right: 1.25.rem, bottom: 3.rem),
        ),
      ],
    ),
  ];
}
