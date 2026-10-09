import 'package:advisor_core/advisor_core.dart';

import 'chat_state.dart';

/// The prompts the app itself places in the conversation, so the screen
/// responds before the model has said a word (Q43, DD principle 3). Each is
/// validated through the same [PresentRequest] path the model uses, so a
/// starter can never show something the registry would refuse.
abstract final class Starters {
  /// The opening choice, by option id: the shopping mode it sets and the
  /// sentence sent to the model on the person's behalf.
  static const Map<String, (ShoppingMode, String)> openingChoices = {
    'mode-browsing': (ShoppingMode.browsing, 'I\'m just looking for now.'),
    'mode-practical': (ShoppingMode.practical, 'I want practical options that fit my budget.'),
    'mode-buying': (ShoppingMode.buying, 'I\'m buying now and want to work through the numbers.'),
    'mode-dreaming': (ShoppingMode.dreaming, 'Let\'s have some fun and look at a dream car.'),
  };

  /// Told once per session, after the first cards, so the person learns the
  /// screen is negotiable without being reminded (Q64).
  static const negotiableNote = 'You can ask Motormind to show, hide or change anything here.';

  /// Option id prefix for the dream-car kinds; the suffix is a body style.
  static const kindPrefix = 'kind-';

  /// The shopping-mode question. A returning profile gets a "pick up" wording.
  static ShownComponent openingPrompt(BuyerProfile profile) => _validated({
    'component': 'choice',
    'props': {
      'question': profile.mode == null
          ? 'How are you shopping today?'
          : 'Pick up where you left off, or change how you\'re shopping:',
      'options': [
        {'id': 'mode-browsing', 'label': 'Just looking'},
        {'id': 'mode-practical', 'label': 'Practical options'},
        {'id': 'mode-buying', 'label': 'Buying now'},
        {'id': 'mode-dreaming', 'label': 'Dream car'},
      ],
    },
  })!;

  /// The app-owned live filters card (DD-R2b, R17b).
  static ShownComponent filtersCard() => _validated({'component': 'search_filters'})!;

  /// What joins the conversation under the filters card for each mode.
  /// Dreaming clears the price ceiling and says so with a choice; practical
  /// and buying get the numbers form; browsing gets nothing extra (Q64, Q66).
  static ShownComponent? forMode(ShoppingMode mode) => switch (mode) {
    ShoppingMode.dreaming => _validated({
      'component': 'choice',
      'props': {
        'question': 'No price ceiling for a dream car. Start with a kind, or name it below?',
        'options': [
          {'id': '${kindPrefix}coupe', 'label': 'Sports / coupe'},
          {'id': '${kindPrefix}convertible', 'label': 'Convertible'},
          {'id': '${kindPrefix}suv', 'label': 'A big SUV'},
          {'id': '${kindPrefix}pickup', 'label': 'A truck'},
        ],
      },
    }),
    ShoppingMode.practical || ShoppingMode.buying => _validated({
      'component': 'input_form',
      'props': {
        'title': 'The numbers that matter most',
        'fields': [
          {'id': 'payment', 'label': 'Monthly payment you can live with (\$)', 'type': 'currency'},
          {'id': 'down', 'label': 'Cash down (\$)', 'type': 'currency'},
          {
            'id': 'credit',
            'label': 'Credit: excellent, good, fair, poor or rebuilding',
            'type': 'text',
          },
          {'id': 'term', 'label': 'Loan length in months (48, 60, 72)', 'type': 'number'},
        ],
      },
    }),
    ShoppingMode.browsing => null,
  };

  static ShownComponent? _validated(Map<String, Object?> args) {
    final v = PresentRequest.validate(args, resultTool: null);
    assert(v.request != null, 'starter rejected by the registry: ${v.errors}');
    final request = v.request;
    return request == null ? null : ShownComponent(request: request);
  }
}
