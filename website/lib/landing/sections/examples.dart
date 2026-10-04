import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

/// A single capability demo: a looping screen-recording inside a phone frame,
/// a title + blurb, and a call-to-action button.
class _Example {
  const _Example({
    required this.id,
    required this.title,
    required this.blurb,
    required this.accent,
    required this.videoBase,
    required this.ctaLabel,
    required this.ctaHref,
  });

  final String id;
  final String title;
  final String blurb;
  final Color accent;

  /// Base path under /demos without extension, e.g. `/demos/multimodal`.
  /// Loads `<base>.webm` + `<base>.mp4` with `<base>-poster.jpg`.
  final String videoBase;

  final String ctaLabel;
  final String ctaHref;
}

/// "See it in action" — capability demos as looping videos in phone frames.
class Examples extends StatelessComponent {
  const Examples({super.key});

  static const _items = <_Example>[
    _Example(
      id: 'thinking',
      title: 'Thinking mode',
      blurb:
          'Watch the model reason step by step before it answers — '
          'fully on-device.',
      accent: Brand.blue,
      videoBase: '/demos/thinking',
      ctaLabel: '▶ Try it live',
      ctaHref: '/try',
    ),
    _Example(
      id: 'function-calling',
      title: 'Function calling',
      blurb:
          'The model calls your Dart functions with structured arguments — '
          'no server in the loop.',
      accent: Brand.green,
      videoBase: '/demos/function-calling',
      ctaLabel: '▶ Try it live',
      ctaHref: '/try',
    ),
    _Example(
      id: 'multimodal',
      title: 'Multimodal with Gemma 4',
      blurb:
          'Send an image and chat about it — vision and audio input, '
          'running locally with Gemma 4.',
      accent: Brand.orange,
      videoBase: '/demos/multimodal',
      // The web app has no audio input, so point at the docs instead of /try.
      ctaLabel: 'Learn more →',
      ctaHref: '/docs/multimodal',
    ),
    _Example(
      id: 'agent',
      title: 'On-device agent skills',
      blurb:
          'Give the model a set of SKILL.md skills and watch it pick and run '
          'them through the tool-calling loop — text, JS, native intents, MCP.',
      accent: Brand.blueLight,
      videoBase: '/demos/agent',
      ctaLabel: 'Learn more →',
      ctaHref: '/docs/agent',
    ),
  ];

  @override
  Component build(BuildContext context) {
    return section(id: 'examples', classes: 'examples', [
      div(classes: 'examples-inner', [
        h2(classes: 'section-title', [Component.text('See it in action')]),
        p(classes: 'examples-subtitle', [
          Component.text('Real on-device features — recorded on a phone, not a server.'),
        ]),
        div(
          classes: 'examples-grid',
          [for (final item in _items) _card(item)],
        ),
      ]),
    ]);
  }

  Component _card(_Example item) {
    return div(classes: 'example-card', [
      // Phone frame with the looping demo.
      div(classes: 'example-phone', [
        video(
          [
            source(src: '${item.videoBase}.webm', type: 'video/webm'),
            source(src: '${item.videoBase}.mp4', type: 'video/mp4'),
          ],
          classes: 'example-video',
          autoplay: true,
          loop: true,
          muted: true,
          poster: '${item.videoBase}-poster.jpg',
          attributes: const {
            'playsinline': '',
            'muted': '',
            'preload': 'metadata',
          },
        ),
      ]),
      div(classes: 'example-meta', [
        h3(classes: 'example-title', [Component.text(item.title)]),
        p(classes: 'example-blurb', [Component.text(item.blurb)]),
        a(
          href: item.ctaHref,
          classes: 'example-cta',
          [Component.text(item.ctaLabel)],
        ),
      ]),
    ]);
  }

  @css
  static List<StyleRule> get styles => [
    css('.examples').styles(
      backgroundColor: Brand.navyDeep,
      padding: Padding.symmetric(vertical: 5.rem, horizontal: 1.rem),
    ),
    css('.examples-inner').styles(
      maxWidth: 1200.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
    ),
    css('.examples-subtitle').styles(
      color: Brand.white70,
      fontSize: 1.1.rem,
      textAlign: TextAlign.center,
      margin: Margin.only(top: 0.px, bottom: 3.rem),
      maxWidth: 560.px,
    ),
    css('.examples-grid').styles(
      display: Display.grid,
      gridTemplate: GridTemplate(
        // Narrower min so all four demos fit on one row on a wide screen
        // (auto-fit still wraps them to fewer columns on smaller viewports).
        columns: GridTracks([
          GridTrack.repeat(
            TrackRepeat.autoFit,
            [GridTrack(TrackSize.minmax(TrackSize(220.px), TrackSize.fr(1)))],
          ),
        ]),
      ),
      gap: Gap.all(1.5.rem),
      width: 100.percent,
    ),
    css('.example-card').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      backgroundColor: Brand.navyLight,
      radius: BorderRadius.circular(1.25.rem),
      padding: Padding.all(1.5.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.08)'), width: 1.px),
    ),
    // Phone frame
    css('.example-phone').styles(
      position: Position.relative(),
      width: 190.px,
      radius: BorderRadius.circular(1.75.rem),
      overflow: Overflow.hidden,
      border: Border.all(color: Color('rgba(255,255,255,0.18)'), width: 3.px),
      backgroundColor: Brand.navy,
      shadow: BoxShadow(
        offsetX: 0.px,
        offsetY: 16.px,
        blur: 40.px,
        color: Color('rgba(0,0,0,0.45)'),
      ),
    ),
    css('.example-video').styles(
      display: Display.block,
      width: 100.percent,
      height: Unit.auto,
    ),
    css('.example-meta').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap.all(0.75.rem),
      margin: Margin.only(top: 1.5.rem),
      textAlign: TextAlign.center,
    ),
    css('.example-title').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.25.rem,
      fontWeight: FontWeight.w700,
      color: Brand.white,
    ),
    css('.example-blurb').styles(
      color: Brand.white70,
      fontSize: 0.95.rem,
      lineHeight: 1.5.em,
      margin: Margin.zero,
    ),
    css('.example-cta').styles(
      margin: Margin.only(top: 0.5.rem),
      display: Display.inlineBlock,
      padding: Padding.symmetric(vertical: 0.6.rem, horizontal: 1.4.rem),
      radius: BorderRadius.circular(2.rem),
      backgroundColor: Color('rgba(255,255,255,0.06)'),
      border: Border.all(color: Color('rgba(255,255,255,0.25)'), width: 1.px),
      color: Brand.white,
      fontFamily: Brand.fontSans,
      fontWeight: FontWeight.w600,
      fontSize: 0.9.rem,
      textDecoration: TextDecoration.none,
      cursor: Cursor.pointer,
    ),
    css('.example-cta:hover').styles(
      backgroundColor: Color('rgba(255,255,255,0.12)'),
      border: Border.all(color: Brand.white, width: 1.px),
    ),
  ];
}
