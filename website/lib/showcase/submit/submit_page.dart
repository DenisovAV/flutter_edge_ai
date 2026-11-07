import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../landing/sections/nav_bar.dart';
import '../../landing/sections/site_footer.dart';
import '../../theme/brand.dart';
import 'submit_form.dart';

/// `/showcase/submit` — the form for adding an app to the showcase.
class ShowcaseSubmitPage extends StatelessComponent {
  const ShowcaseSubmitPage({super.key});

  @override
  Component build(BuildContext context) {
    return main_(classes: 'landing-root', [
      const NavBar(),
      section(classes: 'ss-section', [
        div(classes: 'ss-inner', [
          a(href: '/showcase', classes: 'ss-eyebrow', [Component.text('Showcase')]),
          h1(classes: 'ss-title', [Component.text('Add your app')]),
          p(classes: 'ss-standfirst', [
            Component.text('An app on Google Play or the App Store that runs AI on-device with '),
            code([Component.text('flutter_edge_ai')]),
            Component.text(' or '),
            code([Component.text('flutter_gemma')]),
            Component.text(' can be on the showcase. I check every submission before it is listed.'),
          ]),
          const ShowcaseSubmitForm(),
        ]),
      ]),
      const SiteFooter(),
    ]);
  }

  @css
  static List<StyleRule> get styles => [
    css('.ss-section').styles(
      padding: Padding.only(left: 2.rem, right: 2.rem, top: 4.rem, bottom: 4.rem),
    ),
    css('.ss-inner').styles(
      display: Display.flex,
      maxWidth: 1100.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.rem),
    ),
    css('.ss-eyebrow').styles(
      color: Brand.blueLight,
      textDecoration: TextDecoration.none,
      fontFamily: Brand.fontSans,
      fontSize: 0.8.rem,
      fontWeight: FontWeight.w600,
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.14.em,
    ),
    css('.ss-title').styles(
      margin: Margin.zero,
      color: Brand.white,
      fontFamily: Brand.fontSans,
      fontSize: 2.6.rem,
      fontWeight: FontWeight.w700,
      letterSpacing: (-0.02).em,
      lineHeight: 1.1.em,
    ),
    css('.ss-standfirst').styles(
      maxWidth: 640.px,
      margin: Margin.only(bottom: 1.rem),
      color: Brand.white70,
      fontFamily: Brand.fontSans,
      fontSize: 1.05.rem,
      lineHeight: 1.6.em,
    ),
    css('.ss-standfirst code').styles(color: Brand.white, fontFamily: Brand.fontMono, fontSize: 0.92.em),
    StyleRule.media(
      query: MediaQuery.screen(maxWidth: 640.px),
      styles: [
        css('.ss-section').styles(
          padding: Padding.only(left: 1.25.rem, right: 1.25.rem, top: 2.5.rem, bottom: 3.rem),
        ),
        css('.ss-title').styles(fontSize: 1.9.rem),
      ],
    ),
  ];
}
