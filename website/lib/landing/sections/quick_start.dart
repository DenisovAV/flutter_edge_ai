import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../theme/brand.dart';

const _code = '''await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine(), MediaPipeEngine()],
  embeddingBackends: [LiteRtEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],
  vectorStore: QdrantVectorStore(),
);

await FlutterEdgeAi.installModel(
  modelType: ModelType.gemma4,
  fileType: ModelFileType.litertlm, // the declared type picks the engine
).fromNetwork('https://.../gemma-4-E2B-it.litertlm').install();

final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);
final chat = await model.createChat();
await chat.addQueryChunk(Message.text(text: 'Hello!', isUser: true));
final response = await chat.generateChatResponse();''';

/// Static code block showing canonical flutter_edge_ai usage.
class QuickStart extends StatelessComponent {
  const QuickStart({super.key});

  @override
  Component build(BuildContext context) {
    return section(
      classes: 'quickstart-section',
      [
        div(classes: 'quickstart-inner', [
          h2(classes: 'section-title', [Component.text('5 minutes to on-device inference')]),
          p(classes: 'quickstart-lead', [
            Component.text(
              'Register your engines once, install a model, create a chat session — '
              'then generate. The same Dart API across all six platforms.',
            ),
          ]),
          div(classes: 'code-block-wrap', [
            div(classes: 'code-lang', [Component.text('dart')]),
            pre(classes: 'code-pre', [
              code(classes: 'code-inner', [Component.text(_code)]),
            ]),
          ]),
          p(classes: 'quickstart-cta', [
            Component.text('Need step-by-step setup? '),
            a(
              href: '/docs/getting-started',
              classes: 'qs-link',
              [Component.text('Read the full guide →')],
            ),
          ]),
        ]),
      ],
    );
  }

  @css
  static List<StyleRule> get styles => [
    css('.quickstart-section').styles(
      backgroundColor: Brand.navyLight,
      padding: Padding.symmetric(vertical: 5.rem),
    ),
    css('.quickstart-inner').styles(
      maxWidth: 860.px,
      margin: Margin.symmetric(horizontal: Unit.auto),
      padding: Padding.symmetric(horizontal: 2.rem),
    ),
    css('.quickstart-lead').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.05.rem,
      color: Brand.white70,
      textAlign: TextAlign.center,
      margin: Margin.only(bottom: 2.5.rem, top: 0.px),
      lineHeight: 1.7.em,
    ),
    css('.code-block-wrap').styles(
      position: Position.relative(),
      backgroundColor: Brand.navyDeep,
      radius: BorderRadius.circular(0.75.rem),
      border: Border.all(color: Color('rgba(255,255,255,0.09)'), width: 1.px),
      overflow: Overflow.hidden,
    ),
    css('.code-lang').styles(
      fontFamily: Brand.fontMono,
      fontSize: 0.75.rem,
      color: Brand.white50,
      padding: Padding.symmetric(vertical: 0.5.rem, horizontal: 1.25.rem),
      radius: BorderRadius.circular(0.px),
      border: Border.only(
        bottom: BorderSide(color: Color('rgba(255,255,255,0.07)'), width: 1.px),
      ),
      textTransform: TextTransform.upperCase,
      letterSpacing: 0.05.em,
    ),
    css('.code-pre').styles(
      margin: Margin.zero,
      padding: Padding.all(1.5.rem),
      overflow: Overflow.only(x: OverflowValue.auto),
    ),
    css('.code-inner').styles(
      fontFamily: Brand.fontMono,
      fontSize: 0.9.rem,
      color: Brand.white,
      lineHeight: 1.65.em,
      whiteSpace: WhiteSpace.pre,
      display: Display.block,
    ),
    css('.quickstart-cta').styles(
      fontFamily: Brand.fontSans,
      fontSize: 1.rem,
      color: Brand.white70,
      textAlign: TextAlign.center,
      margin: Margin.only(top: 2.rem, bottom: 0.px),
    ),
    css('.qs-link').styles(
      color: Brand.blueLight,
      textDecoration: TextDecoration.none,
      fontWeight: FontWeight.w600,
    ),
    css('.qs-link:hover').styles(
      textDecoration: TextDecoration(line: TextDecorationLine.underline),
    ),
  ];
}
