import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

class _ModelData {
  const _ModelData({
    required this.name,
    required this.bestFor,
    required this.size,
    this.fc = false,
    this.thinking = false,
    this.vision = false,
  });
  final String name;
  final String bestFor;
  final String size;
  final bool fc;
  final bool thinking;
  final bool vision;
}

const _models = [
  _ModelData(
    name: 'Gemma 4 E2B',
    bestFor: 'Next-gen multimodal — text, image & audio',
    size: '2.4 GB',
    fc: true,
    thinking: true,
    vision: true,
  ),
  _ModelData(
    name: 'Gemma 4 E4B',
    bestFor: 'Next-gen multimodal — higher capacity',
    size: '4.3 GB',
    fc: true,
    thinking: true,
    vision: true,
  ),
  _ModelData(
    name: 'Gemma3n E2B/E4B',
    bestFor: 'Multimodal chat — image & audio; function calling on E4B .litertlm',
    size: '3–6 GB',
    fc: true,
    vision: true,
  ),
  _ModelData(
    name: 'FastVLM 0.5B',
    bestFor: 'Fast vision-language on desktop',
    size: '0.5 GB',
    vision: true,
  ),
  _ModelData(
    name: 'Phi-4 Mini',
    bestFor: 'Reasoning & instruction following',
    size: '3.9 GB',
    fc: true,
  ),
  _ModelData(
    name: 'DeepSeek R1',
    bestFor: 'Reasoning & code generation',
    size: '1.7 GB',
    fc: true,
    thinking: true,
  ),
  _ModelData(
    name: 'Qwen3 0.6B',
    bestFor: 'Compact multilingual with thinking',
    size: '586 MB',
    fc: true,
    thinking: true,
  ),
  _ModelData(
    name: 'Qwen 2.5',
    bestFor: 'Multilingual chat',
    size: '0.5–1.6 GB',
    fc: true,
  ),
  _ModelData(
    name: 'Gemma 3 1B',
    bestFor: 'Balanced text — all platforms',
    size: '0.5 GB',
  ),
  _ModelData(
    name: 'Gemma 3 270M',
    bestFor: 'LoRA fine-tuning base',
    size: '0.3 GB',
  ),
  _ModelData(
    name: 'FunctionGemma 270M',
    bestFor: 'On-device function calling',
    size: '284 MB',
    fc: true,
  ),
  _ModelData(
    name: 'SmolLM 135M',
    bestFor: 'Ultra-compact for edge devices',
    size: '135 MB',
  ),
];

/// Responsive gallery of supported models with capability badges.
class ModelsGallery extends StatelessComponent {
  const ModelsGallery({super.key});

  @override
  Component build(BuildContext context) {
    return section(
      id: 'models',
      classes: 'models-section',
      [
        div(classes: 'models-inner', [
          h2(classes: 'section-title', [Component.text('Supported models')]),
          p(classes: 'models-lead', [
            Component.text('All models run entirely on-device. Pick by capability, size, or platform support.'),
          ]),
          div(
            classes: 'models-grid',
            [
              for (final m in _models) _ModelCard(model: m),
            ],
          ),
        ]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.models-section').styles(
      backgroundColor: Brand.navyDeep,
      padding: Padding.symmetric(vertical: 5.rem),
    ),
    css('.models-inner').styles(
      maxWidth: 1200.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
    ),
    css('.models-lead').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.05.rem,
      color: Brand.white70,
      textAlign: TextAlign.center,
      margin: Margin.only(bottom: 3.rem, top: 0.px),
    ),
    css('.models-grid').styles(
      display: Display.grid,
      gridTemplate: GridTemplate(
        columns: GridTracks([
          GridTrack.repeat(
            TrackRepeat.autoFit,
            [GridTrack(TrackSize.minmax(TrackSize(260.px), TrackSize.fr(1)))],
          ),
        ]),
      ),
      gap: Gap.all(1.25.rem),
    ),
    css('.model-card').styles(
      backgroundColor: Brand.navyLight,
      radius: BorderRadius.circular(0.875.rem),
      padding: Padding.all(1.5.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.07)'), width: 1.px),
      display: Display.flex,
      flexDirection: FlexDirection.column,
      gap: Gap.all(0.6.rem),
    ),
    css('.model-name').styles(
      fontFamily: Brand.fontSans,
      fontWeight: FontWeight.w700,
      fontSize: 1.rem,
      color: Brand.white,
      margin: Margin.zero,
    ),
    css('.model-best-for').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.875.rem,
      color: Brand.white70,
      margin: Margin.zero,
      lineHeight: 1.5.em,
      flex: Flex(grow: 1),
    ),
    css('.model-footer').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      alignItems: AlignItems.center,
      justifyContent: JustifyContent.spaceBetween,
      gap: Gap.all(0.5.rem),
      flexWrap: FlexWrap.wrap,
      margin: Margin.only(top: 0.25.rem),
    ),
    css('.model-size').styles(
      fontFamily: Brand.fontMono,
      fontSize: 0.8.rem,
      color: Brand.white50,
    ),
    css('.model-badges').styles(
      display: Display.flex,
      flexDirection: FlexDirection.row,
      gap: Gap.all(0.35.rem),
      flexWrap: FlexWrap.wrap,
    ),
    css('.mbadge').styles(
      fontFamily: Brand.fontSans,
      fontSize: 0.7.rem,
      fontWeight: FontWeight.w600,
      padding: Padding.symmetric(vertical: 0.2.rem, horizontal: 0.45.rem),
      radius: BorderRadius.circular(0.25.rem),
    ),
    css('.mbadge-fc').styles(
      backgroundColor: Color('rgba(59,130,246,0.2)'),
      color: Brand.blueLight,
    ),
    css('.mbadge-think').styles(
      backgroundColor: Color('rgba(59,130,246,0.15)'),
      color: Color('#93C5FD'),
    ),
    css('.mbadge-vision').styles(
      backgroundColor: Color('rgba(245,158,11,0.15)'),
      color: Brand.orange,
    ),
  ];
}

class _ModelCard extends StatelessComponent {
  const _ModelCard({required this.model});
  final _ModelData model;

  @override
  Component build(BuildContext context) {
    return div(
      classes: 'model-card',
      [
        h3(classes: 'model-name', [Component.text(model.name)]),
        p(classes: 'model-best-for', [Component.text(model.bestFor)]),
        div(classes: 'model-footer', [
          span(classes: 'model-size', [Component.text(model.size)]),
          div(classes: 'model-badges', [
            if (model.fc) span(classes: 'mbadge mbadge-fc', [Component.text('FC')]),
            if (model.thinking) span(classes: 'mbadge mbadge-think', [Component.text('Think')]),
            if (model.vision) span(classes: 'mbadge mbadge-vision', [Component.text('Vision')]),
          ]),
        ]),
      ],
    );
  }
}
