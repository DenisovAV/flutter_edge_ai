import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

class _Prop {
  const _Prop({required this.icon, required this.title, required this.desc});
  final String icon;
  final String title;
  final String desc;
}

const _props = [
  _Prop(icon: '🔒', title: 'Privacy', desc: 'Data never leaves the device'),
  _Prop(icon: '✈️', title: 'Offline', desc: 'Works with no network connection'),
  _Prop(icon: '💸', title: 'Zero cost', desc: 'No API bills, no rate limits'),
  _Prop(icon: '⚡', title: 'Low latency', desc: 'No round-trip to a server'),
];

/// 4-column value proposition strip.
class WhyOnDevice extends StatelessComponent {
  const WhyOnDevice({super.key});

  @override
  Component build(BuildContext context) {
    return section(
      classes: 'why-section',
      [
        div(classes: 'why-inner', [
          h2(classes: 'section-title', [Component.text('Why on-device?')]),
          div(
            classes: 'why-grid',
            [
              for (final prop in _props)
                div(classes: 'why-card', [
                  span(classes: 'why-icon', [Component.text(prop.icon)]),
                  h3(classes: 'why-title', [Component.text(prop.title)]),
                  p(classes: 'why-desc', [Component.text(prop.desc)]),
                ]),
            ],
          ),
        ]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.why-section').styles(
      backgroundColor: Brand.navyLight,
      padding: Padding.symmetric(vertical: 5.rem),
    ),
    css('.why-inner').styles(
      maxWidth: 1200.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
    ),
    css('.why-grid').styles(
      display: Display.grid,
      gridTemplate: GridTemplate(
        columns: GridTracks([
          GridTrack.repeat(
            TrackRepeat.autoFit,
            [GridTrack(TrackSize.minmax(TrackSize(200.px), TrackSize.fr(1)))],
          ),
        ]),
      ),
      gap: Gap.all(1.5.rem),
    ),
    css('.why-card').styles(
      backgroundColor: Brand.navy,
      radius: BorderRadius.circular(1.rem),
      padding: Padding.all(2.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.07)'), width: 1.px),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      textAlign: TextAlign.center,
      gap: Gap.all(0.75.rem),
    ),
    css('.why-icon').styles(
      fontSize: 2.5.rem,
      lineHeight: 1.em,
    ),
    css('.why-title').styles(
      fontFamily: Brand.fontSans,
      fontWeight: FontWeight.w700,
      fontSize: 1.1.rem,
      color: Brand.white,
      margin: Margin.zero,
    ),
    css('.why-desc').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.9.rem,
      color: Brand.white70,
      margin: Margin.zero,
      lineHeight: 1.5.em,
    ),
  ];
}
