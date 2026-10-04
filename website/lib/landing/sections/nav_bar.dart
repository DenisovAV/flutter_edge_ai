import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

/// Sticky top navigation bar.
///
/// Pure CSS — NOT a `@client` component. The mobile menu toggles via a hidden
/// checkbox + `:checked` sibling selector, so it works with **no JavaScript and
/// no hydration**. This site is Jaspr static mode; the earlier `@client`
/// version's `onClick` never hydrated on the deployed static build (the burger
/// was dead, and the links only worked because they fell back to `href`
/// navigation). The checkbox hack removes that dependency entirely.
class NavBar extends StatelessComponent {
  const NavBar({super.key});

  static const _links = <({String text, String href, bool external, bool cta})>[
    (text: 'Docs', href: '/docs/getting-started', external: false, cta: false),
    // Slash-less: firebase.json sets `trailingSlash: false`, so `/codelabs/`
    // would 301 to `/codelabs` on every click.
    (text: 'Codelabs', href: '/codelabs', external: false, cta: false),
    // Root-anchored on purpose. The `id="models"` target lives in
    // models_gallery.dart, which only LandingPage renders — a bare `#models`
    // resolves against the current page and does nothing from /codelabs.
    (text: 'Models', href: '/#models', external: false, cta: false),
    (
      text: 'GitHub',
      href: 'https://github.com/DenisovAV/flutter_edge_ai',
      external: true,
      cta: false,
    ),
    (
      text: 'pub.dev',
      href: 'https://pub.dev/packages/flutter_edge_ai',
      external: true,
      cta: true,
    ),
  ];

  @override
  Component build(BuildContext context) {
    return nav(classes: 'navbar', [
      div(classes: 'navbar-inner', [
        a(href: '/', classes: 'navbar-brand', [
          img(
            src: '/images/logo-edge-ai.png',
            alt: 'Flutter Edge AI logo',
            classes: 'navbar-logo',
            attributes: const {'srcset': '/images/logo-edge-ai@2x.png 2x'},
          ),
          span(classes: 'navbar-wordmark', [Component.text('Flutter Edge AI')]),
        ]),
        // Hidden checkbox drives the mobile menu open/closed state — pure CSS,
        // no JS. The <label> below is the visible hamburger; clicking it toggles
        // the checkbox, and `.navbar-toggle:checked ~ .navbar-links` reveals the
        // dropdown. Hidden on wide screens via the desktop media query.
        input(
          type: InputType.checkbox,
          id: 'navbar-toggle',
          classes: 'navbar-toggle',
          attributes: const {'aria-hidden': 'true'},
        ),
        // Hamburger label (shown only on narrow screens via CSS).
        label(
          classes: 'navbar-burger',
          attributes: {
            'for': 'navbar-toggle',
            'aria-label': 'Toggle navigation menu',
          },
          [
            span(classes: 'navbar-burger-bar', []),
            span(classes: 'navbar-burger-bar', []),
            span(classes: 'navbar-burger-bar', []),
          ],
        ),
        div(classes: 'navbar-links', [
          for (final l in _links)
            // Full-page navigation via `href` (static multi-page site). The
            // menu closes on its own because navigation reloads the page.
            a(
              href: l.href,
              classes: l.cta ? 'navbar-link navbar-link--cta' : 'navbar-link',
              attributes: l.external ? {'target': '_blank', 'rel': 'noopener'} : const {},
              [Component.text(l.text)],
            ),
        ]),
      ]),
    ]);
  }

  @css
  static List<StyleRule> get styles => [
    css('.navbar').styles(
      position: Position.sticky(top: 0.px),
      zIndex: ZIndex(100),
      width: 100.percent,
      backgroundColor: Brand.navy,
      radius: BorderRadius.circular(0.px),
      border: Border.only(
        bottom: BorderSide(color: Color('rgba(255,255,255,0.08)'), width: 1.px),
      ),
    ),
    css('.navbar-inner').styles(
      position: Position.relative(),
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.spaceBetween,
      maxWidth: 1200.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem, vertical: 1.rem),
    ),
    css('.navbar-brand').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      gap: Gap.all(0.6.rem),
      textDecoration: TextDecoration.none,
    ),
    // Scoped under `.landing-root` ON PURPOSE: the landing reset
    // `.landing-root img { height: auto; max-width: 100% }` (landing_page.dart)
    // is specificity (0,1,1) and OUTRANKS a bare `.navbar-logo` (0,1,0),
    // silently overriding `height: 2.2rem` with `height: auto` — so the logo
    // rendered at its full intrinsic size, a giant logo filling the header.
    // `.landing-root .navbar-logo` is (0,2,0), which wins and restores 2.2rem.
    css('.landing-root .navbar-logo').styles(
      height: 2.2.rem,
      width: Unit.auto,
      display: Display.block,
    ),
    css('.navbar-wordmark').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.2.rem,
      fontWeight: FontWeight.w700,
      color: Brand.white,
      textDecoration: TextDecoration.none,
      letterSpacing: (-0.01).em,
    ),
    css('.navbar-link').styles(
      color: Brand.white70,
      textDecoration: TextDecoration.none,
      fontSize: 0.95.rem,
      fontWeight: FontWeight.w500,
      fontFamily: Brand.fontSans,
    ),
    css('.navbar-link--cta').styles(
      color: Brand.blueLight,
      fontWeight: FontWeight.w600,
    ),
    css('.navbar-link:hover').styles(color: Brand.white),
    css('.navbar-burger-bar').styles(
      display: Display.block,
      width: 100.percent,
      height: 2.px,
      backgroundColor: Brand.white,
      radius: BorderRadius.circular(2.px),
    ),
    // ---- MOBILE-FIRST BASE (narrow screens) ----
    // Burger visible, links collapse into an absolutely-positioned dropdown that
    // is hidden until the hidden checkbox is `:checked` (toggled by the burger
    // <label>). Desktop overrides below via a min-width media query, so source
    // order can't accidentally re-hide the burger (the earlier ordering bug).
    // The checkbox itself is always visually hidden — it only carries state.
    css('.navbar-toggle').styles(
      position: Position.absolute(),
      raw: {
        'opacity': '0',
        'width': '1px',
        'height': '1px',
        'pointer-events': 'none',
      },
    ),
    css('.navbar-burger').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      justifyContent: JustifyContent.center,
      gap: Gap.all(5.px),
      width: 2.5.rem,
      height: 2.5.rem,
      padding: Padding.all(0.5.rem),
      backgroundColor: Color('transparent'),
      border: Border.none,
      cursor: Cursor.pointer,
      raw: {'flex-shrink': '0'},
    ),
    css('.navbar-links').styles(
      position: Position.absolute(top: 100.percent, left: 0.px, right: 0.px),
      display: Display.none,
      flexDirection: FlexDirection.column,
      alignItems: AlignItems.stretch,
      gap: Gap.all(0.px),
      backgroundColor: Brand.navy,
      padding: Padding.symmetric(vertical: 0.5.rem),
      border: Border.only(
        bottom: BorderSide(color: Color('rgba(255,255,255,0.08)'), width: 1.px),
      ),
    ),
    // Checkbox checked → reveal the dropdown (pure-CSS toggle, no JS).
    css('.navbar-toggle:checked ~ .navbar-links').styles(display: Display.flex),
    css('.navbar-links .navbar-link').styles(
      padding: Padding.symmetric(vertical: 0.85.rem, horizontal: 2.rem),
      fontSize: 1.rem,
    ),
    // ---- DESKTOP OVERRIDE (>= 769px) ----
    StyleRule.media(
      query: MediaQuery.screen(minWidth: 769.px),
      styles: [
        css('.navbar-burger').styles(display: Display.none),
        // On desktop the links are always inline regardless of checkbox state.
        css('.navbar-toggle:checked ~ .navbar-links').styles(
          flexDirection: FlexDirection.row,
        ),
        css('.navbar-links').styles(
          position: Position.static,
          display: Display.flex,
          flexDirection: FlexDirection.row,
          alignItems: AlignItems.center,
          gap: Gap.all(1.8.rem),
          backgroundColor: Color('transparent'),
          padding: Padding.zero,
          border: Border.none,
        ),
        css('.navbar-links .navbar-link').styles(
          padding: Padding.zero,
          fontSize: 0.95.rem,
        ),
      ],
    ),
  ];
}
