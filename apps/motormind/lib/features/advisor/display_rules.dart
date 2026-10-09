import 'package:advisor_core/advisor_core.dart';

import '../../services/log.dart';

/// What the display decisions see: the screen state, not the conversation.
/// This is the input a display agent (DD-R33) would get; today a table of
/// rules consumes it, and every decision is logged so the rules can be
/// compared against an agent later (DD-R21).
class DisplayContext {
  const DisplayContext({
    required this.surface,
    required this.filtersSet,
    required this.keyboardOpen,
    this.userExpandedFilters,
  });

  final SurfaceState surface;

  /// True once any search filter has a value.
  final bool filtersSet;
  final bool keyboardOpen;

  /// The person's last explicit choice on the filters card, if any; it wins
  /// over the rule until the context changes (DD-R13).
  final bool? userExpandedFilters;
}

enum FiltersCardMode { expanded, summary, hidden }

/// The decision table from DYNAMIC_DESIGN Section 6, one function per row.
/// Rules are deliberately small and named so a display agent can replace them
/// one at a time once the harness shows it choosing at least as well.
abstract final class DisplayRules {
  /// The filters card: full while nothing is set or in fullscreen; one
  /// summary line with a funnel once a filter is chosen in the docked panel;
  /// out of the way while typing (DD-R32, DD-R7).
  static FiltersCardMode filtersCard(DisplayContext c) {
    final FiltersCardMode mode;
    if (c.keyboardOpen) {
      mode = FiltersCardMode.hidden;
    } else if (c.userExpandedFilters != null) {
      mode = c.userExpandedFilters! ? FiltersCardMode.expanded : FiltersCardMode.summary;
    } else if (!c.filtersSet || c.surface == SurfaceState.fullscreen) {
      mode = FiltersCardMode.expanded;
    } else {
      mode = FiltersCardMode.summary;
    }
    _log('filtersCard', c, mode.name);
    return mode;
  }

  /// Transcript notes ("Looking for … 8 listings read") only when there is
  /// room to read them (Q65).
  static bool showSearchNotes(DisplayContext c) {
    final show = c.surface == SurfaceState.fullscreen;
    _log('searchNotes', c, show ? 'shown' : 'hidden');
    return show;
  }

  static String? _last;
  static void _log(String rule, DisplayContext c, String decision) {
    final line =
        '[motormind] display $rule -> $decision (surface=${c.surface.name}, filters=${c.filtersSet}, keyboard=${c.keyboardOpen}, user=${c.userExpandedFilters})';
    if (line == _last) return; // rules run on every build; log changes only
    _last = line;
    logDev(line);
  }
}
