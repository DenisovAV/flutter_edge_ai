import 'package:flutter/material.dart';

import '../listings/listing_cards.dart';
import '../search/search_filters_card.dart';
import 'cards/interaction_cards.dart';
import 'cards/page_extract_card.dart';
import 'cards/payment_cards.dart';
import 'chat_state.dart';

/// Renders a presented component by its registry id. Result components read
/// only from the tool result (ADR 0002); interaction components read from the
/// model's props; app-owned components read from app state.
class ResultCard extends StatelessWidget {
  const ResultCard({super.key, required this.shown, required this.onChoice});

  final ShownComponent shown;

  /// Called when the person answers a choice or submits a form.
  final void Function(String id, String label) onChoice;

  @override
  Widget build(BuildContext context) {
    return switch (shown.request.component.id) {
      'choice' || 'multi_choice' => ChoiceCard(shown: shown, onChoice: onChoice),
      'input_form' => FormCard(shown: shown, onSubmit: (text) => onChoice('form', text)),
      'search_filters' => const SearchFiltersCard(),
      'payment_summary' => PaymentSummaryCard(shown: shown),
      'payment_breakdown' => PaymentBreakdownCard(shown: shown),
      'trade_equity_card' => TradeEquityCard(shown: shown),
      'vehicle_card' => ListingCards(shown: shown),
      'page_extract' => PageExtractCard(shown: shown),
      _ => OutputsCard(shown: shown),
    };
  }
}
