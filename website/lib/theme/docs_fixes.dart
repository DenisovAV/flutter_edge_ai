import 'package:jaspr/dom.dart';

/// Corrections to jaspr_content's `DocsLayout` styles.
///
/// Top-level on purpose: jaspr_builder puts a library's top-level `@css`
/// rules on every page even when nothing imports it, but class members only
/// when the library is imported.
@css
List<StyleRule> get docsFixes => [
  // jaspr_content 0.5.2 sets the page description under the title to
  // `font-size: 1.25rem; line-height: 1.25rem` — a line height of 1.0, so a
  // description that wraps has its lines touching. Its selector is (0,4,3);
  // the leading `html` makes this one (0,4,4), so it wins whatever order the
  // two style sheets come in.
  css(
    'html .docs .main-container main > div .content-container '
    '.content-header p',
  ).styles(lineHeight: 1.6.em),
  // A wide table (the model registry's nine columns, the models page's
  // matrices) pushed the whole page sideways on a phone. Below the desktop
  // layout it scrolls inside its own box; on desktop it keeps the table
  // display that stretches its rules to the column width.
  css.media(MediaQuery.screen(maxWidth: 1023.px), [
    css('html .docs .content table').styles(
      display: Display.block,
      overflow: Overflow.only(x: Overflow.auto),
    ),
    // So did a long identifier in running text or inline code. Paragraphs
    // and list items only: in a table cell `anywhere` would shrink the
    // column instead of letting the table scroll.
    css('html .docs .content :is(p, li)').styles(
      raw: {'overflow-wrap': 'anywhere'},
    ),
    css('html .docs .content :is(p, li) code').styles(
      raw: {'overflow-wrap': 'anywhere'},
    ),
    // A callout is a flex row, and its text column kept the default
    // `min-width: auto`, so it would not shrink below its longest word.
    css(
      'html .docs .content .callout > span:last-child',
    ).styles(minWidth: Unit.zero),
  ]),
];
