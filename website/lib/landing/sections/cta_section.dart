import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

/// Closing call-to-action section.
class CtaSection extends StatelessComponent {
  const CtaSection({super.key});

  @override
  Component build(BuildContext context) {
    return section(
      classes: 'cta-section',
      [
        div(classes: 'cta-inner', [
          h2(classes: 'cta-headline', [
            Component.text('Ship AI that never leaves the device.'),
          ]),
          p(classes: 'cta-sub', [
            Component.text(
              'Open source, MIT licensed, maintained by the community. '
              'Star the repo and help spread on-device AI for Flutter.',
            ),
          ]),
          div(classes: 'cta-buttons', [
            a(
              href: '/docs/getting-started',
              classes: 'btn btn-primary',
              [Component.text('Read the docs')],
            ),
            a(
              href: 'https://github.com/DenisovAV/flutter_edge_ai',
              classes: 'btn btn-outline',
              attributes: {'target': '_blank', 'rel': 'noopener'},
              [Component.text('Star on GitHub')],
            ),
          ]),
        ]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.cta-section').styles(
      backgroundColor: Brand.navyDeep,
      padding: Padding.symmetric(vertical: 6.rem),
    ),
    css('.cta-inner').styles(
      maxWidth: 760.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      textAlign: TextAlign.center,
      gap: Gap.all(1.5.rem),
    ),
    css('.cta-headline').styles(
      fontFamily: Brand.fontSans,
      fontSize: 2.5.rem,
      fontWeight: FontWeight.w800,
      color: Brand.white,
      lineHeight: 1.2.em,
      margin: Margin.zero,
      letterSpacing: (-0.02).em,
    ),
    css('.cta-sub').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.05.rem,
      color: Brand.white70,
      lineHeight: 1.7.em,
      margin: Margin.zero,
    ),
    css('.cta-buttons').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      gap: Gap.all(1.rem),
      flexWrap: FlexWrap.wrap,
      justifyContent: JustifyContent.center,
    ),
    StyleRule.media(
      query: MediaQuery.screen(maxWidth: 480.px),
      styles: [
        css('.cta-headline').styles(fontSize: 1.8.rem),
        css('.cta-buttons').styles(flexDirection: FlexDirection.column, alignItems: AlignItems.stretch),
      ],
    ),
  ];
}
