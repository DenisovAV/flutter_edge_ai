import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

class _FeatureData {
  const _FeatureData({
    required this.icon,
    required this.title,
    required this.desc,
    required this.accent,
  });
  final String icon;
  final String title;
  final String desc;
  final Color accent;
}

const _features = [
  _FeatureData(
    icon: '🧠',
    title: 'Multimodal',
    desc: 'Vision + audio input with Gemma 4, Gemma3n, FastVLM',
    accent: Brand.orange,
  ),
  _FeatureData(
    icon: '📞',
    title: 'Function Calling',
    desc: 'Models call your Dart functions — structured tool use on-device',
    accent: Brand.blue,
  ),
  _FeatureData(
    icon: '💭',
    title: 'Thinking Mode',
    desc: 'See the reasoning chains of Gemma 4, DeepSeek R1 & Qwen3',
    accent: Brand.blue,
  ),
  _FeatureData(
    icon: '🤖',
    title: 'Agent Skills',
    desc: 'Give the model SKILL.md skills it runs itself — JS, native intents, MCP',
    accent: Brand.blueLight,
  ),
  _FeatureData(
    icon: '🎤',
    title: 'Speech (STT + TTS)',
    desc: 'Transcribe audio and synthesize speech on-device — selectable models, LiteRT C API, fully offline',
    accent: Brand.green,
  ),
  _FeatureData(
    icon: '🔍',
    title: 'On-device RAG',
    desc: 'qdrant-edge native vector store, sqlite-vec on all platforms incl. web',
    accent: Brand.green,
  ),
  _FeatureData(
    icon: '⚡',
    title: 'GPU Acceleration',
    desc: 'Metal / Vulkan / WebGPU / DX12 — all backends covered',
    accent: Brand.orange,
  ),
  _FeatureData(
    icon: '📱',
    title: 'Built-in AI',
    desc: 'Run Gemini Nano & Apple Intelligence — an OS-owned model, zero download',
    accent: Brand.blue,
  ),
  _FeatureData(
    icon: '🔌',
    title: 'Pluggable Engines',
    desc: 'LiteRT-LM, MediaPipe, ONNX Runtime & built-in OS AI — register the engine you need',
    accent: Brand.orange,
  ),
  _FeatureData(
    icon: '📦',
    title: 'Opt-in Packages',
    desc: 'Core + 11 opt-in packages — agent skills, speech, RAG & more; ship only what you use',
    accent: Brand.green,
  ),
  _FeatureData(
    icon: '🧑‍💻',
    title: 'Package Skills',
    desc: 'Claude Code, Codex, Cursor & Copilot learn the flutter_edge_ai API from skills shipped in the package',
    accent: Brand.blue,
  ),
];

/// Feature grid.
class Features extends StatelessComponent {
  const Features({super.key});

  @override
  Component build(BuildContext context) {
    return section(
      classes: 'features-section',
      [
        div(classes: 'features-inner', [
          h2(classes: 'section-title', [Component.text('Everything you need for on-device AI')]),
          div(
            classes: 'features-grid',
            [
              for (final f in _features) _FeatureCard(feature: f),
            ],
          ),
        ]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.features-section').styles(
      backgroundColor: Brand.navyDeep,
      padding: Padding.symmetric(vertical: 5.rem),
    ),
    css('.features-inner').styles(
      maxWidth: 1200.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
    ),
    css('.section-title').styles(
      fontFamily: Brand.fontSans,
      fontSize: 2.rem,
      fontWeight: FontWeight.w700,
      color: Brand.white,
      textAlign: TextAlign.center,
      margin: Margin.only(bottom: 3.rem, top: 0.px),
    ),
    css('.features-grid').styles(
      display: Display.grid,
      gridTemplate: GridTemplate(
        columns: GridTracks([
          GridTrack.repeat(
            TrackRepeat.autoFit,
            [GridTrack(TrackSize.minmax(TrackSize(280.px), TrackSize.fr(1)))],
          ),
        ]),
      ),
      gap: Gap.all(1.5.rem),
    ),
    css('.feature-card').styles(
      backgroundColor: Brand.navyLight,
      radius: BorderRadius.circular(1.rem),
      padding: Padding.all(1.75.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.07)'), width: 1.px),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(0.75.rem),
    ),
    css('.feature-icon').styles(
      fontSize: 2.rem,
      lineHeight: 1.em,
    ),
    css('.feature-title').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.1.rem,
      fontWeight: FontWeight.w600,
      color: Brand.white,
      margin: Margin.zero,
    ),
    css('.feature-desc').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.925.rem,
      color: Brand.white70,
      margin: Margin.zero,
      lineHeight: 1.6.em,
    ),
    css('.feature-accent-orange').styles(
      radius: BorderRadius.circular(1.rem),
      border: Border.only(
        left: BorderSide(color: Brand.orange, width: 3.px),
      ),
    ),
    css('.feature-accent-blue').styles(
      radius: BorderRadius.circular(1.rem),
      border: Border.only(
        left: BorderSide(color: Brand.blue, width: 3.px),
      ),
    ),
    css('.feature-accent-green').styles(
      radius: BorderRadius.circular(1.rem),
      border: Border.only(
        left: BorderSide(color: Brand.green, width: 3.px),
      ),
    ),
  ];
}

class _FeatureCard extends StatelessComponent {
  const _FeatureCard({required this.feature});
  final _FeatureData feature;

  String get _accentClass {
    if (feature.accent == Brand.orange) return 'feature-accent-orange';
    if (feature.accent == Brand.green) return 'feature-accent-green';
    return 'feature-accent-blue';
  }

  @override
  Component build(BuildContext context) {
    return div(
      classes: 'feature-card $_accentClass',
      [
        span(classes: 'feature-icon', [Component.text(feature.icon)]),
        h3(classes: 'feature-title', [Component.text(feature.title)]),
        p(classes: 'feature-desc', [Component.text(feature.desc)]),
      ],
    );
  }
}
