import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

/// Platform capability matrix table.
class PlatformMatrix extends StatelessComponent {
  const PlatformMatrix({super.key});

  static const _headers = ['Platform', 'Vision', 'Audio', 'Embeddings', 'NPU'];

  static const _rows = [
    ['Android', '✅', '✅', '✅', '✅'],
    ['iOS', '✅', '✅', '✅', '❌'],
    ['Web', '✅', '❌', '✅', '❌'],
    ['macOS', '✅', '✅', '✅', '❌'],
    ['Windows', '✅', '✅', '✅', '✅'],
    ['Linux', '✅', '✅', '✅', '❌'],
  ];

  @override
  Component build(BuildContext context) {
    return section(
      classes: 'matrix-section',
      [
        div(classes: 'matrix-inner', [
          h2(classes: 'section-title', [Component.text('Platform support matrix')]),
          div(classes: 'matrix-scroll', [
            table(classes: 'matrix-table', [
              thead([
                tr([
                  for (final h in _headers)
                    th(
                      classes: h == 'Platform' ? 'matrix-th matrix-th--platform' : 'matrix-th',
                      [Component.text(h)],
                    ),
                ]),
              ]),
              tbody([
                for (final row in _rows)
                  tr(classes: 'matrix-row', [
                    for (var i = 0; i < row.length; i++)
                      if (i == 0)
                        td(classes: 'matrix-td matrix-td--platform', [Component.text(row[i])])
                      else
                        td(
                          classes: row[i] == '✅' ? 'matrix-td matrix-td--yes' : 'matrix-td matrix-td--no',
                          [Component.text(row[i])],
                        ),
                  ]),
              ]),
            ]),
          ]),
          p(classes: 'matrix-note', [
            Component.text(
              'NPU support covers supported Qualcomm Snapdragon devices on Android '
              'and Intel LunarLake/PantherLake on Windows. '
              'iOS GPU runs on Metal on device; the Simulator is CPU-only '
              '(256 MB Metal allocation cap).',
            ),
          ]),
        ]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.matrix-section').styles(
      backgroundColor: Brand.navy,
      padding: Padding.symmetric(vertical: 5.rem),
    ),
    css('.matrix-inner').styles(
      maxWidth: 900.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
    ),
    css('.matrix-scroll').styles(
      overflow: Overflow.only(x: OverflowValue.auto),
    ),
    css('.matrix-table').styles(
      width: 100.percent,
      radius: BorderRadius.circular(0.75.rem),
      overflow: Overflow.hidden,
      raw: {'border-collapse': 'collapse'},
    ),
    css('.matrix-th').styles(
      backgroundColor: Brand.navyDeep,
      color: Brand.white70,
      fontFamily: Brand.fontSans,
      fontWeight: FontWeight.w600,
      fontSize: 0.875.rem,
      textAlign: TextAlign.center,
      padding: Padding.symmetric(vertical: 0.875.rem, horizontal: 1.25.rem),
      border: Border.only(
        bottom: BorderSide(color: Color('rgba(255,255,255,0.1)'), width: 1.px),
      ),
    ),
    css('.matrix-th--platform').styles(
      textAlign: TextAlign.left,
    ),
    css('.matrix-row:nth-child(even)').styles(
      backgroundColor: Color('rgba(26,58,92,0.4)'),
    ),
    css('.matrix-td').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.rem,
      textAlign: TextAlign.center,
      padding: Padding.symmetric(vertical: 0.75.rem, horizontal: 1.25.rem),
      border: Border.only(
        bottom: BorderSide(color: Color('rgba(255,255,255,0.05)'), width: 1.px),
      ),
    ),
    css('.matrix-td--platform').styles(
      textAlign: TextAlign.left,
      fontWeight: FontWeight.w600,
      color: Brand.white,
      fontSize: 0.95.rem,
    ),
    css('.matrix-td--yes').styles(
      color: Brand.green,
      fontSize: 1.1.rem,
    ),
    css('.matrix-td--no').styles(
      color: Brand.white50,
      fontSize: 1.1.rem,
    ),
    css('.matrix-note').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.8.rem,
      color: Brand.white50,
      textAlign: TextAlign.center,
      margin: Margin.only(top: 1.25.rem, bottom: 0.px),
      lineHeight: 1.6.em,
    ),
  ];
}
