import 'package:advisor_core/advisor_core.dart';

/// What the display rules see: the screen state, never the conversation.
/// This is the same input a display agent gets, so rules and agent can be
/// compared on equal terms.
class DisplayContext {
  const DisplayContext({
    required this.surface,
    required this.filtersSet,
    required this.keyboardOpen,
    this.userExpandedFilters,
  });

  /// Collapsed, docked or fullscreen.
  final SurfaceState surface;

  /// True once any search filter has a value.
  final bool filtersSet;

  /// True while the soft keyboard is up.
  final bool keyboardOpen;

  /// The person's last explicit choice on the filters card, if any; it wins
  /// over the rule until the context changes.
  final bool? userExpandedFilters;
}

/// How the filters card is shown.
enum FiltersCardMode {
  /// Every chip row visible.
  expanded,

  /// One line with the current filters and a funnel to reopen.
  summary,

  /// Out of the way (while typing).
  hidden,
}

/// The decision table from the design notes, one pure function per row. The
/// rules are small and named so a display agent can replace them one at a
/// time once a harness shows it choosing at least as well. Logging happens
/// where a whole decision is made, not here.
abstract final class DisplayRules {
  /// The filters card: full while nothing is set or in fullscreen; one
  /// summary line with a funnel once a filter is chosen in the docked panel;
  /// out of the way while typing.
  static FiltersCardMode filtersCard(DisplayContext c) {
    if (c.keyboardOpen) return FiltersCardMode.hidden;
    if (c.userExpandedFilters case final expanded?) {
      return expanded ? FiltersCardMode.expanded : FiltersCardMode.summary;
    }
    if (!c.filtersSet || c.surface == SurfaceState.fullscreen) return FiltersCardMode.expanded;
    return FiltersCardMode.summary;
  }

  /// Transcript notes ("Looking for … 8 matched") only when there is room
  /// to read them.
  static bool showSearchNotes(DisplayContext c) => c.surface == SurfaceState.fullscreen;
}
