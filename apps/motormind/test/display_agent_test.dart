import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/advisor/display_agent.dart';
import 'package:motormind/features/advisor/display_rules.dart';
import 'package:motormind/features/advisor/stage.dart';

const _defaults = DisplayDecision(
  filters: FiltersCardMode.expanded,
  notes: false,
  stage: StageMode.web,
  split: StageSplit.half,
);

ScreenState _screen({
  SurfaceState surface = SurfaceState.docked,
  bool keyboardOpen = false,
  bool filtersSet = false,
  int cardCount = 0,
  int listingCount = 0,
  StageMode stageMode = StageMode.web,
  bool userStageMode = false,
  bool? userExpandedFilters,
}) => ScreenState(
  surface: surface,
  keyboardOpen: keyboardOpen,
  filtersSet: filtersSet,
  filtersSummary: 'SUV',
  cardCount: cardCount,
  listingCount: listingCount,
  stageMode: stageMode,
  userStageMode: userStageMode,
  userExpandedFilters: userExpandedFilters,
  lastUserText: '',
  busy: false,
);

void main() {
  group('rules', () {
    test('the filters card collapses once something is set, unless fullscreen', () {
      expect(RulesDisplayAgent.apply(_screen()).filters, FiltersCardMode.expanded);
      expect(RulesDisplayAgent.apply(_screen(filtersSet: true)).filters, FiltersCardMode.summary);
      expect(
        RulesDisplayAgent.apply(_screen(filtersSet: true, surface: SurfaceState.fullscreen))
            .filters,
        FiltersCardMode.expanded,
      );
      expect(
        RulesDisplayAgent.apply(_screen(filtersSet: true, keyboardOpen: true)).filters,
        FiltersCardMode.hidden,
      );
    });

    test('the person\'s expand wins over the rule', () {
      expect(
        RulesDisplayAgent.apply(_screen(filtersSet: true, userExpandedFilters: true)).filters,
        FiltersCardMode.expanded,
      );
    });

    test('cards come forward when there is a card; a manual flip to web holds', () {
      expect(RulesDisplayAgent.apply(_screen(cardCount: 1)).stage, StageMode.cards);
      expect(
        RulesDisplayAgent.apply(_screen(cardCount: 1, userStageMode: true)).stage,
        StageMode.web,
      );
    });

    test('the split follows the keyboard and the listings', () {
      expect(RulesDisplayAgent.apply(_screen()).split, StageSplit.half);
      expect(RulesDisplayAgent.apply(_screen(keyboardOpen: true)).split, StageSplit.typing);
      expect(
        RulesDisplayAgent.apply(_screen(cardCount: 1, listingCount: 3)).split,
        StageSplit.twoThirds,
      );
    });
  });

  group('model answer parsing', () {
    test('a JSON object sets every slot it names and keeps the defaults otherwise', () {
      final d = ModelDisplayAgent.parse(
        'Sure: {"filters":"summary","stage":"cards","cue":"You were looking at SUVs"} done',
        _defaults,
      );
      expect(d.filters, FiltersCardMode.summary);
      expect(d.stage, StageMode.cards);
      expect(d.notes, _defaults.notes);
      expect(d.split, _defaults.split);
      expect(d.cue, 'You were looking at SUVs');
      expect(d.by, DecidedBy.model);
    });

    test('an unreadable answer keeps the defaults and says so', () {
      final d = ModelDisplayAgent.parse('I would collapse the filters.', _defaults);
      expect(d.filters, _defaults.filters);
      expect(d.by, DecidedBy.modelFallback);
      expect(ModelDisplayAgent.parse('{not json}', _defaults).by, DecidedBy.modelFallback);
    });

    test('a cue is capped to one line and "null" means none', () {
      final long = 'x' * 100;
      expect(
        ModelDisplayAgent.parse('{"cue":"$long"}', _defaults).cue,
        hasLength(DisplayDecision.maxCueLength),
      );
      expect(ModelDisplayAgent.parse('{"cue":"null"}', _defaults).cue, isNull);
      expect(ModelDisplayAgent.parse('{"cue":""}', _defaults).cue, isNull);
    });

    test('unknown slot values fall back to the defaults', () {
      final d = ModelDisplayAgent.parse('{"filters":"giant","split":"quarter"}', _defaults);
      expect(d.filters, _defaults.filters);
      expect(d.split, _defaults.split);
    });
  });
}
