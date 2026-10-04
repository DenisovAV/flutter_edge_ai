import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

/// Thin trust strip shown between Hero and Features.
class TrustBar extends StatelessComponent {
  const TrustBar({super.key});

  @override
  Component build(BuildContext context) {
    return div(
      classes: 'trust-bar',
      [
        div(classes: 'trust-inner', [
          span(classes: 'trust-item', [
            span(classes: 'trust-score', [Component.text('150')]),
            Component.text('/160 pub.dev points'),
          ]),
          span(classes: 'trust-sep', [Component.text('|')]),
          span(classes: 'trust-item', [
            Component.text('Built with '),
            a(
              href: 'https://deepwiki.com/DenisovAV/flutter_edge_ai',
              classes: 'trust-link',
              attributes: {'target': '_blank', 'rel': 'noopener'},
              [Component.text('DeepWiki docs')],
            ),
          ]),
          span(classes: 'trust-sep', [Component.text('|')]),
          span(classes: 'trust-item', [
            a(
              href: 'https://deepwiki.com/DenisovAV/flutter_edge_ai',
              classes: 'trust-link',
              attributes: {'target': '_blank', 'rel': 'noopener'},
              [Component.text('DeepWiki')],
            ),
            Component.text(' — AI-indexed codebase'),
          ]),
        ]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.trust-bar').styles(
      backgroundColor: Brand.navyDeep,
      radius: BorderRadius.circular(0.px),
      border: Border.only(
        bottom: BorderSide(color: Color('rgba(255,255,255,0.06)'), width: 1.px),
      ),
      padding: Padding.symmetric(vertical: 0.75.rem),
    ),
    css('.trust-inner').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.center,
      flexWrap: FlexWrap.wrap,
      gap: Gap.all(1.2.rem),
      maxWidth: 1200.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
    ),
    css('.trust-item').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.875.rem,
      color: Brand.white70,
    ),
    css('.trust-score').styles(
      color: Brand.green,
      fontWeight: FontWeight.w700,
    ),
    css('.trust-sep').styles(
      color: Brand.white50,
      userSelect: UserSelect.none,
    ),
    css('.trust-link').styles(
      color: Brand.blueLight,
      textDecoration: TextDecoration.none,
    ),
    css('.trust-link:hover').styles(
      textDecoration: TextDecoration(line: TextDecorationLine.underline),
    ),
  ];
}
