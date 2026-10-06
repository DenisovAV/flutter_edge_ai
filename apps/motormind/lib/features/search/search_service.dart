import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../advisor/stage.dart';
import '../browser/browser_service.dart';
import '../chat/chat_service.dart';

/// The live search (Q: "as soon as the price goes in, the filter is applied").
class SearchState {
  const SearchState({
    this.query = const SearchQuery(),
    this.siteId = 'echopark',
    this.applying = false,
    this.lastCount,
    this.lastSource,
    this.note,
  });

  final SearchQuery query;

  /// The curated site the search applies to. The person picks it in the
  /// filters card and it sticks until changed.
  final String siteId;
  final bool applying;
  final int? lastCount;
  final String? lastSource;
  final String? note;

  SearchState copyWith({
    SearchQuery? query,
    String? siteId,
    bool? applying,
    int? lastCount,
    String? lastSource,
    String? note,
    bool clearNote = false,
  }) => SearchState(
    query: query ?? this.query,
    siteId: siteId ?? this.siteId,
    applying: applying ?? this.applying,
    lastCount: lastCount ?? this.lastCount,
    lastSource: lastSource ?? this.lastSource,
    note: clearNote ? null : (note ?? this.note),
  );
}

/// Reads a page for the search: default is the web pane; tests inject a fake.
typedef PageReader = Future<PageExtract> Function(String url);

final pageReaderProvider = Provider<PageReader>(
  (ref) =>
      (url) => ref.read(browserProvider.notifier).readPage(url: url),
);

final searchProvider = NotifierProvider<SearchService, SearchState>(SearchService.new);

/// Owns the query, applies it to the curated site the moment it changes
/// (debounced), reads the results, and puts a listings card on the stage.
/// The model changes the query through `update_search`; the filters card's chips
/// change it directly; free text goes through `inferSearchArgs` first so the
/// obvious cases never wait on the model.
class SearchService extends Notifier<SearchState> {
  Timer? _debounce;
  int _generation = 0;

  @override
  SearchState build() {
    ref.onDispose(() => _debounce?.cancel());
    return const SearchState();
  }

  CuratedSite get site => CuratedSites.byId(state.siteId) ?? CuratedSites.defaultSite;

  /// Called after every applied search so the conversation can note it.
  void Function(SearchState)? onApplied;

  /// Choose where to look. Opens the site's home if nothing is filtered yet,
  /// or re-applies the current filters there.
  void selectSite(String id) {
    if (CuratedSites.byId(id) == null) return;
    state = state.copyWith(siteId: id, clearNote: true);
    if (state.query.isEmpty) {
      ref.read(browserProvider.notifier).open(site.home);
      ref.read(stageProvider.notifier).showWeb();
    } else {
      scheduleApply(delay: Duration.zero);
    }
  }

  /// Merge [args] (update_search shape) and apply. Returns the new query.
  SearchQuery update(Map<String, Object?> args, {bool applyNow = true}) {
    final q = state.query.applyArgs(args);
    state = state.copyWith(query: q, clearNote: true);
    if (applyNow) scheduleApply();
    return q;
  }

  /// Infer from a sentence and apply what was found. Returns the fields found.
  Map<String, Object?> updateFromText(String text) {
    final found = inferSearchArgs(text);
    if (found.isNotEmpty) update(found);
    return found;
  }

  void scheduleApply({Duration delay = const Duration(milliseconds: 500)}) {
    _debounce?.cancel();
    _debounce = Timer(delay, apply);
  }

  /// Navigate the pane to the site's results for the query, read it, and show
  /// what was found. Safe to call repeatedly; a newer call wins.
  Future<void> apply() async {
    final gen = ++_generation;
    final q = state.query;
    final url = site.urlFor(q);
    state = state.copyWith(applying: true, lastSource: url, clearNote: true);
    ref.read(stageProvider.notifier).showWeb();
    try {
      final extract = await ref.read(pageReaderProvider)(url);
      if (gen != _generation) return; // superseded
      final store = ref.read(listingStoreProvider)..addAll(extract.listings); // idempotent
      final results = store.searchQuery(q, limit: 8);
      state = state.copyWith(applying: false, lastCount: results.length);
      _showResults(results, extract.url, q);
      onApplied?.call(state);
    } on PageChallengeException catch (e) {
      if (gen == _generation) state = state.copyWith(applying: false, note: e.toString());
    } catch (e) {
      if (gen == _generation) {
        state = state.copyWith(applying: false, note: 'Could not read the page: $e');
      }
    }
  }

  void _showResults(List<VehicleListing> results, String source, SearchQuery q) {
    final result = ToolResult(
      id: 'search-${DateTime.now().millisecondsSinceEpoch}',
      tool: AdvisorTools.findVehicles,
      args: q.toJson(),
      result: {
        'count': results.length,
        'source': source,
        'query': q.describe(),
        'listings': [for (final l in results) l.toJson()],
        if (results.isEmpty) 'note': 'No listings matched on the page that is open. Change a filter, or scroll the site and ask me to read again.',
      },
    );
    final v = PresentRequest.validate({
      'component': 'vehicle_card',
      'result_id': result.id,
      'title': 'Listings · ${q.describe()}',
    }, resultTool: AdvisorTools.findVehicles);
    if (v.request == null) return;
    // Results replace earlier results cards (same tool); the stage keys by result id,
    // so clear the previous search card first.
    final stage = ref.read(stageProvider.notifier);
    stage.removeWhere((s) => s.result?.tool == AdvisorTools.findVehicles);
    stage.show(ShownComponent(request: v.request!, result: result), bringForward: false);
  }

  /// What the model sees after update_search / find_vehicles.
  Map<String, Object?> toModelJson() => {
    'query': state.query.describe(),
    'count': state.lastCount,
    if (state.note != null) 'note': state.note,
  };
}
