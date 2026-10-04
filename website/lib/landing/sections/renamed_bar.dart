import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

/// Announcement strip above the nav: the project was Flutter Gemma until
/// 1.11.3, so a visitor who knows the old name learns here why it changed.
class RenamedBar extends StatelessComponent {
  const RenamedBar({super.key});

  @override
  Component build(BuildContext context) {
    return div(classes: 'renamed-bar', [
      div(classes: 'renamed-inner', [
        span(classes: 'renamed-text', [
          strong([Component.text('Flutter Gemma is now Flutter Edge AI.')]),
          Component.text(
            ' Same models, new name — 2.0 moves RAG into flutter_edge_ai_rag. ',
          ),
        ]),
        a(
          href: '/docs/migration',
          classes: 'renamed-link',
          [Component.text('Moving from flutter_gemma →')],
        ),
      ]),
    ]);
  }

  @css
  static List<StyleRule> get styles => [
    css('.renamed-bar').styles(
      backgroundColor: Brand.navyDeep,
      border: Border.only(
        bottom: BorderSide(color: Color('rgba(255,255,255,0.06)'), width: 1.px),
      ),
      padding: Padding.symmetric(vertical: 0.6.rem),
    ),
    css('.renamed-inner').styles(
      display: Display.flex,
      flexWrap: FlexWrap.wrap,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.center,
      gap: Gap.all(0.5.rem),
      maxWidth: 1200.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
      textAlign: TextAlign.center,
    ),
    css('.renamed-text').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.875.rem,
      color: Brand.white70,
    ),
    css('.renamed-text strong').styles(color: Brand.white),
    css('.renamed-link').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.875.rem,
      fontWeight: FontWeight.w600,
      color: Brand.blueLight,
      textDecoration: TextDecoration.none,
    ),
    css('.renamed-link:hover').styles(
      textDecoration: TextDecoration(line: TextDecorationLine.underline),
    ),
  ];
}
