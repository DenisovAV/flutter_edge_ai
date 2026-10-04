import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../landing/sections/nav_bar.dart';
import '../landing/sections/site_footer.dart';
import '../theme/brand.dart';

/// One entry in the codelab catalogue.
///
/// [href] is null for a codelab that is not written yet: the card renders as
/// "Coming soon" and is deliberately NOT a link, so nothing on this page can
/// lead to an empty page.
class _Codelab {
  const _Codelab({
    required this.title,
    required this.blurb,
    required this.duration,
    required this.level,
    required this.tags,
    required this.accent,
    this.href,
  });

  final String title;
  final String blurb;

  /// Rough time to complete, e.g. `30 min`.
  final String duration;

  /// `Beginner` / `Intermediate` / `Advanced`.
  final String level;

  final List<String> tags;
  final Color accent;
  final String? href;

  bool get isPublished => href != null;
}

/// `/codelabs` — the catalogue that the nav's "Codelabs" link opens.
///
/// The codelabs themselves are static claat exports written to the directory
/// `codelabs/<id>/`; this page is a plain Jaspr route rendered into
/// `codelabs/index.html`, so the two never collide. Their [href]s are
/// slash-less all the same — `cleanUrls` serves the directory index at
/// `/codelabs/<id>` and `trailingSlash: false` 301s the slashed form.
class CodelabsPage extends StatelessComponent {
  const CodelabsPage({super.key});

  /// Ordered as a learning path, not a feature list: first run, then teaching
  /// your coding assistant the API so it writes the rest with you, then the
  /// engines that run a model, then the model capabilities built on top
  /// (multimodal, function calling), then the pipelines that combine several
  /// of them (RAG, voice, hybrid routing).
  static const _items = <_Codelab>[
    _Codelab(
      title: 'Getting Started with On-Device LLMs in Flutter',
      blurb:
          'Install flutter_edge_ai, pick and download a model, and stream your '
          'first reply — then have the app open on the chat, not the download '
          'screen.',
      duration: '35 min',
      level: 'Beginner',
      tags: ['flutter_edge_ai', 'Gemma 3', 'streaming'],
      accent: Brand.blue,
      href: '/codelabs/getting-started-flutter-gemma',
    ),
    _Codelab(
      title: 'Package Skills in Flutter: Teach Your Coding Assistant flutter_edge_ai',
      blurb:
          'flutter_edge_ai ships agent skills inside the package. Install them '
          'for your assistant with one command, ask it for an offline chat '
          'and a tool call, and check its code against the traps the skills '
          'exist to prevent.',
      duration: '45 min',
      level: 'Beginner',
      tags: ['agent skills', 'Antigravity', 'Claude Code'],
      accent: Brand.orange,
      href: '/codelabs/package-skills-flutter-gemma',
    ),
    _Codelab(
      title: 'Inference Engines in Flutter: From a Downloaded Model to Built-in AI',
      blurb:
          'LiteRT-LM runs a .litertlm file you ship or download. Built-in AI '
          'runs Gemini Nano and Apple Foundation Models with nothing to '
          'download at all — the OS owns the weights. Register either engine '
          'at startup; the inference code never changes.',
      duration: '41 min',
      level: 'Intermediate',
      tags: ['LiteRT-LM', 'built-in AI', 'Gemini Nano'],
      accent: Brand.green,
      href: '/codelabs/inference-engines-flutter-gemma',
    ),
    _Codelab(
      title: 'Multimodal Inference in Flutter: Vision and Audio on Device',
      blurb:
          'Start seeing on a 0.36 GB vision model, then pay once for a 2.59 GB '
          'one that also hears. A modality is a session flag on weights that '
          'have the encoder — so the real question is what this platform lets '
          'you switch on, and how the app says so.',
      duration: '46 min',
      level: 'Intermediate',
      tags: ['vision', 'audio', 'Gemma 4'],
      accent: Brand.orange,
      href: '/codelabs/multimodal-flutter-gemma',
    ),
    _Codelab(
      title: 'Function Calling with On-Device Models in Flutter',
      blurb:
          'Declare Dart functions the model can call, drive the call/response '
          'loop by hand and then hand it to the SDK, fine-tune a 270M model on '
          'your own tools, and watch a bigger one reason first with thinking '
          'mode.',
      duration: '56 min',
      level: 'Intermediate',
      tags: ['function calling', 'tools', 'fine-tuning', 'thinking mode'],
      accent: Brand.green,
      href: '/codelabs/function-calling-flutter-gemma',
    ),
    _Codelab(
      title: 'On-Device RAG in Flutter: Embeddings and Vector Search',
      blurb:
          'Embed your own documents with EmbeddingGemma, store the vectors in '
          'sqlite-vec, and ground the answers — no network at any step.',
      duration: '60 min',
      level: 'Advanced',
      tags: ['embeddings', 'sqlite-vec', 'RAG'],
      accent: Brand.green,
      href: '/codelabs/on-device-rag-flutter-gemma',
    ),
    _Codelab(
      title: 'Building an Offline Voice Assistant in Flutter: STT, LLM, and TTS',
      blurb:
          'Wire speech-to-text, the model, and text-to-speech into one loop '
          'that runs in airplane mode — with barge-in, and tools it calls by '
          'voice.',
      duration: '67 min',
      level: 'Advanced',
      tags: ['STT', 'TTS', 'voice loop', 'tools'],
      accent: Brand.orange,
      href: '/codelabs/voice-assistant-flutter-gemma',
    ),
    _Codelab(
      title: 'Hybrid AI in Flutter: From Cloud to On-Device with Genkit Dart',
      blurb:
          'Build an offline travel guide that routes each message between '
          'Gemini and on-device Gemma — five policies, images, and RAG.',
      duration: '2 hr 12 min',
      level: 'Advanced',
      tags: ['Genkit', 'hybrid routing', 'RAG'],
      accent: Brand.blue,
      href: '/codelabs/hybrid-ai-flutter-genkit',
    ),
  ];

  @override
  Component build(BuildContext context) {
    // `.landing-root` supplies the navy canvas, `min-height: 100vh` and the
    // element resets the NavBar/SiteFooter styles are scoped to.
    return main_(classes: 'landing-root', [
      const NavBar(),
      section(classes: 'cl-head', [
        div(classes: 'cl-head-inner', [
          p(classes: 'cl-eyebrow', [Component.text('Codelabs')]),
          h1(classes: 'cl-title', [
            Component.text('Build something that runs on the device'),
          ]),
          p(classes: 'cl-standfirst', [
            Component.text(
              'Hands-on, step-by-step guides for running language models '
              'inside a Flutter app, ordered from first run to full '
              'pipelines. Start with the quickstart; the ones marked '
              '"Coming soon" are still being written.',
            ),
          ]),
        ]),
      ]),
      section(classes: 'cl-grid-wrap', [
        div(classes: 'cl-grid', [
          for (final c in _items) _card(c),
        ]),
      ]),
      const SiteFooter(),
    ]);
  }

  /// A published codelab is an `<a>`; an unwritten one is a `<div>` so it is
  /// not focusable and cannot be followed.
  static Component _card(_Codelab c) {
    final children = <Component>[
      div(
        classes: 'cl-accent',
        styles: Styles(raw: {'background': c.accent.value}),
        [],
      ),
      div(classes: 'cl-card-body', [
        div(classes: 'cl-meta', [
          span(classes: 'cl-level', [Component.text(c.level)]),
          span(classes: 'cl-dot', [Component.text('·')]),
          span(classes: 'cl-duration', [Component.text(c.duration)]),
          if (!c.isPublished) span(classes: 'cl-soon', [Component.text('Coming soon')]),
        ]),
        h2(classes: 'cl-card-title', [Component.text(c.title)]),
        p(classes: 'cl-blurb', [Component.text(c.blurb)]),
        div(classes: 'cl-tags', [
          for (final t in c.tags) span(classes: 'cl-tag', [Component.text(t)]),
        ]),
        if (c.isPublished) span(classes: 'cl-start', [Component.text('Start codelab →')]),
      ]),
    ];

    return c.isPublished
        ? a(href: c.href!, classes: 'cl-card cl-card--live', children)
        : div(classes: 'cl-card cl-card--soon', children);
  }

  @css
  static List<StyleRule> get styles => [
    // ---- header ----
    css('.cl-head').styles(
      padding: Padding.symmetric(horizontal: 2.rem, vertical: 4.rem),
    ),
    css('.cl-head-inner').styles(
      maxWidth: 760.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(1.rem),
    ),
    css('.cl-eyebrow').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 0.8.rem,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.14.em,
      textTransform: TextTransform.upperCase,
      color: Brand.blueLight,
    ),
    css('.cl-title').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 2.6.rem,
      fontWeight: FontWeight.w700,
      lineHeight: 1.1.em,
      letterSpacing: (-0.02).em,
      color: Brand.white,
    ),
    css('.cl-standfirst').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 1.05.rem,
      lineHeight: 1.6.em,
      color: Brand.white70,
    ),

    // ---- grid ----
    css('.cl-grid-wrap').styles(
      padding: Padding.only(
        left: 2.rem,
        right: 2.rem,
        bottom: 5.rem,
      ),
    ),
    css('.cl-grid').styles(
      maxWidth: 1100.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      display: Display.grid,
      // 280px matches `.features-grid` — an auto-fit track cannot shrink below
      // its minimum, so a larger floor makes the page scroll sideways on a
      // ≤360px viewport (iPhone SE 1st gen, Galaxy Fold cover screen).
      gridTemplate: GridTemplate(
        columns: GridTracks([
          GridTrack.repeat(
            TrackRepeat.autoFit,
            [GridTrack(TrackSize.minmax(TrackSize(280.px), TrackSize.fr(1)))],
          ),
        ]),
      ),
      gap: Gap.all(1.25.rem),
    ),

    // ---- card ----
    css('.cl-card').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      overflow: Overflow.hidden,
      backgroundColor: Brand.navyLight,
      radius: BorderRadius.circular(10.px),
      border: Border.all(color: Color('rgba(255,255,255,0.08)'), width: 1.px),
      textDecoration: TextDecoration.none,
    ),
    css('.cl-card--live').styles(
      raw: {'transition': 'transform .15s ease, border-color .15s ease'},
    ),
    css('.cl-card--live:hover').styles(
      transform: Transform.translate(y: (-3).px),
      border: Border.all(color: Color('rgba(147,197,253,0.55)'), width: 1.px),
    ),
    // The unwritten state used to be carried by `opacity: 0.62` on the whole
    // card, which composited the white70 blurb down to ~3.6:1 against the navy
    // page — below the 4.5:1 WCAG AA floor for normal text, on six of seven
    // cards. Only the decorative accent bar is dimmed now; the "Coming soon"
    // pill and the absent "Start codelab →" carry the signal in text.
    css('.cl-card--soon .cl-accent').styles(opacity: 0.45),
    css('.cl-accent').styles(height: 3.px, width: 100.percent),
    css('.cl-card-body').styles(
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(0.7.rem),
      padding: Padding.all(1.4.rem),
    ),

    // ---- meta row ----
    // Wraps on purpose: `.cl-card` is `overflow: hidden`, so a non-wrapping row
    // clipped the "Coming soon" pill off a narrow card — and that pill is the
    // only signal that the codelab does not exist yet.
    // white70, not white50: at 0.75rem this is normal-size text, and white50 on
    // the card sits at ~4.2:1, under the 4.5:1 AA floor.
    css('.cl-meta').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      flexWrap: FlexWrap.wrap,
      alignItems: AlignItems.center,
      gap: Gap.all(0.45.rem),
      fontFamily: Brand.fontSans,
      fontSize: 0.75.rem,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.06.em,
      textTransform: TextTransform.upperCase,
      color: Brand.white70,
    ),
    css('.cl-dot').styles(color: Brand.white70),
    css('.cl-soon').styles(
      margin: Margin.only(left: Unit.auto),
      padding: Padding.symmetric(horizontal: 0.5.rem, vertical: 0.15.rem),
      backgroundColor: Color('rgba(255,255,255,0.10)'),
      radius: BorderRadius.circular(999.px),
      color: Brand.white70,
      letterSpacing: 0.04.em,
    ),

    css('.cl-card-title').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 1.15.rem,
      fontWeight: FontWeight.w700,
      lineHeight: 1.3.em,
      letterSpacing: (-0.01).em,
      color: Brand.white,
    ),
    css('.cl-blurb').styles(
      margin: Margin.zero,
      fontFamily: Brand.fontSans,
      fontSize: 0.93.rem,
      lineHeight: 1.55.em,
      color: Brand.white70,
    ),

    // ---- tags ----
    css('.cl-tags').styles(
      display: Display.flex,
      flexWrap: FlexWrap.wrap,
      gap: Gap.all(0.4.rem),
      margin: Margin.only(top: 0.15.rem),
    ),
    css('.cl-tag').styles(
      padding: Padding.symmetric(horizontal: 0.55.rem, vertical: 0.2.rem),
      backgroundColor: Color('rgba(255,255,255,0.07)'),
      radius: BorderRadius.circular(4.px),
      fontFamily: Brand.fontMono,
      fontSize: 0.72.rem,
      color: Brand.white70,
    ),

    css('.cl-start').styles(
      margin: Margin.only(top: 0.35.rem),
      fontFamily: Brand.fontSans,
      fontSize: 0.9.rem,
      fontWeight: FontWeight.w600,
      color: Brand.blueLight,
    ),

    // ---- narrow screens ----
    StyleRule.media(
      query: MediaQuery.screen(maxWidth: 640.px),
      styles: [
        css('.cl-head').styles(
          padding: Padding.symmetric(horizontal: 1.25.rem, vertical: 2.5.rem),
        ),
        css('.cl-title').styles(fontSize: 1.9.rem),
        css('.cl-grid-wrap').styles(
          padding: Padding.only(
            left: 1.25.rem,
            right: 1.25.rem,
            bottom: 3.rem,
          ),
        ),
      ],
    ),
  ];
}
