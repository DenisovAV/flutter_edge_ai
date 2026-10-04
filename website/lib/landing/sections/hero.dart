import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

/// Two-column hero section.
class Hero extends StatelessComponent {
  const Hero({super.key});

  @override
  Component build(BuildContext context) {
    return section(
      classes: 'hero',
      [
        // Decorative oversized logo watermark behind the hero content.
        img(
          src: '/images/logo-edge-ai@2x.png',
          alt: '',
          classes: 'hero-watermark',
          attributes: const {'aria-hidden': 'true'},
        ),
        div(classes: 'hero-inner', [
          // Left column
          div(classes: 'hero-copy', [
            h1(classes: 'hero-h1', [Component.text('On-device LLMs in your Flutter app.')]),
            p(classes: 'hero-subhead', [Component.text('No servers. No cloud. Just Dart.')]),
            div(classes: 'hero-buttons', [
              a(
                href: '/docs/getting-started',
                classes: 'btn btn-primary',
                [Component.text('Get Started')],
              ),
              a(
                href: 'https://github.com/DenisovAV/flutter_edge_ai',
                classes: 'btn btn-outline',
                attributes: {'target': '_blank', 'rel': 'noopener'},
                [Component.text('GitHub')],
              ),
            ]),
            div(classes: 'hero-install', [
              span(classes: 'install-prompt', [Component.text('\$')]),
              span(classes: 'install-cmd', [Component.text(' flutter pub add flutter_edge_ai flutter_edge_ai_litertlm')]),
            ]),
          ]),
          // Right column
          div(classes: 'hero-demo', [
            div(classes: 'hero-phone-frame', [
              img(
                src: '/images/gemma.gif',
                alt: 'flutter_edge_ai demo running on a device',
                classes: 'hero-gif',
              ),
              div(classes: 'hero-demo-overlay', [
                // Links to the live Flutter web example app at /try.
                a(
                  href: '/try',
                  classes: 'btn-try-live',
                  [Component.text('▶ Try it live')],
                ),
              ]),
            ]),
            p(classes: 'hero-caption', [Component.text('runs in your browser')]),
          ]),
        ]),
        // Badges row
        div(classes: 'hero-badges', [
          span(classes: 'badge', [Component.text('6 platforms')]),
          span(classes: 'badge-sep', [Component.text('·')]),
          span(classes: 'badge', [Component.text('multimodal')]),
          span(classes: 'badge-sep', [Component.text('·')]),
          span(classes: 'badge', [Component.text('private')]),
          span(classes: 'badge-sep', [Component.text('·')]),
          span(classes: 'badge', [Component.text('MIT')]),
        ]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.hero').styles(
      position: Position.relative(),
      overflow: Overflow.hidden,
      backgroundColor: Brand.navy,
      padding: Padding.only(top: 5.rem, bottom: 3.rem),
    ),
    // Oversized, faint logo watermark anchored to the lower-left empty area,
    // clear of the phone mock on the right.
    //
    // Selector is scoped under `.landing-root` ON PURPOSE: the landing reset
    // `.landing-root img { max-width: 100% }` (landing_page.dart) has
    // specificity (0,1,1), which OUTRANKS a bare `.hero-watermark` (0,1,0) and
    // silently overrode `max-width: 55%` — so the watermark rendered at its full
    // `width: 760px`, a giant logo crashing into the hero copy. `.landing-root
    // .hero-watermark` is (0,2,0), which wins, restoring the 55%/opacity cap.
    css('.landing-root .hero-watermark').styles(
      position: Position.absolute(top: 8.percent, left: 12.percent),
      width: 760.px,
      maxWidth: 55.percent,
      height: Unit.auto,
      opacity: 0.14,
      pointerEvents: PointerEvents.none,
      zIndex: ZIndex(0),
    ),
    css('.hero-inner').styles(
      position: Position.relative(),
      zIndex: ZIndex(1),
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      gap: Gap.all(4.rem),
      maxWidth: 1200.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
    ),
    css('.hero-copy').styles(
      flex: Flex(grow: 1),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.5.rem),
    ),
    css('.hero-h1').styles(
      fontFamily: Brand.fontSans,
      fontSize: 3.rem,
      fontWeight: FontWeight.w800,
      color: Brand.white,
      lineHeight: 1.15.em,
      letterSpacing: (-0.02).em,
      margin: Margin.zero,
    ),
    css('.hero-subhead').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.25.rem,
      color: Brand.white70,
      margin: Margin.zero,
      fontWeight: FontWeight.w400,
    ),
    css('.hero-buttons').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      gap: Gap.all(1.rem),
      flexWrap: FlexWrap.wrap,
    ),
    css('.btn').styles(
      display: Display.inlineBlock,
      padding: Padding.symmetric(vertical: 0.75.rem, horizontal: 1.5.rem),
      radius: BorderRadius.circular(0.5.rem),
      fontFamily: Brand.fontSans,
      fontWeight: FontWeight.w600,
      fontSize: 1.rem,
      textDecoration: TextDecoration.none,
      cursor: Cursor.pointer,
    ),
    css('.btn-primary').styles(
      backgroundColor: Brand.blue,
      color: Brand.white,
    ),
    css('.btn-outline').styles(
      backgroundColor: Color('transparent'),
      color: Brand.white,
      border: Border.all(color: Color('rgba(255,255,255,0.35)'), width: 1.px),
    ),
    css('.btn-primary:hover').styles(
      backgroundColor: Color('#2563eb'),
    ),
    css('.btn-outline:hover').styles(
      border: Border.all(color: Brand.white, width: 1.px),
    ),
    css('.hero-install').styles(
      display: Display.inlineFlex,
      alignItems: AlignItems.center,
      backgroundColor: Brand.navyDeep,
      padding: Padding.symmetric(vertical: 0.6.rem, horizontal: 1.rem),
      radius: BorderRadius.circular(0.4.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.1)'), width: 1.px),
    ),
    css('.install-prompt').styles(
      fontFamily: Brand.fontMono,
      color: Brand.green,
      fontSize: 0.9.rem,
      userSelect: UserSelect.none,
    ),
    css('.install-cmd').styles(
      fontFamily: Brand.fontMono,
      color: Brand.white70,
      fontSize: 0.9.rem,
    ),
    // Right column
    css('.hero-demo').styles(
      flex: Flex(grow: 1),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.center,
      gap: Gap.all(1.rem),
    ),
    css('.hero-phone-frame').styles(
      position: Position.relative(),
      radius: BorderRadius.circular(1.25.rem),
      overflow: Overflow.hidden,
      border: Border.all(color: Color('rgba(255,255,255,0.15)'), width: 2.px),
      maxWidth: 360.px,
      width: 100.percent,
      shadow: BoxShadow(
        offsetX: 0.px,
        offsetY: 24.px,
        blur: 60.px,
        color: Color('rgba(0,0,0,0.5)'),
      ),
    ),
    css('.hero-gif').styles(
      display: Display.block,
      width: 100.percent,
      height: Unit.auto,
    ),
    css('.hero-demo-overlay').styles(
      position: Position.absolute(bottom: 1.5.rem, left: 0.px, right: 0.px),
      display: Display.flex,
      justifyContent: JustifyContent.center,
    ),
    css('.btn-try-live').styles(
      backgroundColor: Color('rgba(11,35,81,0.85)'),
      color: Brand.white,
      border: Border.all(color: Color('rgba(255,255,255,0.3)'), width: 1.px),
      radius: BorderRadius.circular(2.rem),
      padding: Padding.symmetric(vertical: 0.6.rem, horizontal: 1.4.rem),
      fontFamily: Brand.fontSans,
      fontWeight: FontWeight.w600,
      fontSize: 0.9.rem,
      cursor: Cursor.pointer,
    ),
    css('.hero-caption').styles(
      color: Brand.white50,
      fontSize: 0.85.rem,
      fontFamily: Brand.fontSans,
      margin: Margin.zero,
      textAlign: TextAlign.center,
    ),
    // Badges
    css('.hero-badges').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      justifyContent: JustifyContent.center,
      alignItems: AlignItems.center,
      gap: Gap.all(0.75.rem),
      padding: Padding.only(top: 2.5.rem),
    ),
    css('.badge').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.9.rem,
      color: Brand.white70,
      fontWeight: FontWeight.w500,
    ),
    css('.badge-sep').styles(
      color: Brand.white50,
    ),
    // Responsive
    StyleRule.media(
      query: MediaQuery.screen(maxWidth: 768.px),
      styles: [
        css('.hero-inner').styles(
          flexDirection: FlexDirection.column,
          gap: Gap.all(2.5.rem),
        ),
        css('.hero-h1').styles(fontSize: 2.2.rem),
        css('.hero-demo').styles(width: 100.percent),
      ],
    ),
  ];
}
