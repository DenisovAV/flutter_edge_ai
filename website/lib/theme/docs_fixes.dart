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
];
