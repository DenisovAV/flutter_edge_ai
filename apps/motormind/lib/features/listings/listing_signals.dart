import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the person did with listings: viewed (opened the detail), liked,
/// dismissed. These are the signals Motormind may learn from (DD-R29): it
/// proposes a sort or filter after enough evidence, never silently.
class ListingSignals {
  const ListingSignals({this.viewed = const {}, this.liked = const {}, this.dismissed = const {}});

  final Set<String> viewed;
  final Set<String> liked;
  final Set<String> dismissed;

  ListingSignals copyWith({Set<String>? viewed, Set<String>? liked, Set<String>? dismissed}) =>
      ListingSignals(
        viewed: viewed ?? this.viewed,
        liked: liked ?? this.liked,
        dismissed: dismissed ?? this.dismissed,
      );
}

final listingSignalsProvider = NotifierProvider<ListingSignalsNotifier, ListingSignals>(
  ListingSignalsNotifier.new,
);

class ListingSignalsNotifier extends Notifier<ListingSignals> {
  @override
  ListingSignals build() => const ListingSignals();

  /// Keys are "title|price" so the same car read twice counts once.
  static String keyFor(Map l) => '${l['title']}|${l['price']}';

  void viewed(Map l) => state = state.copyWith(viewed: {...state.viewed, keyFor(l)});

  void toggleLiked(Map l) {
    final k = keyFor(l);
    final liked = {...state.liked};
    if (!liked.remove(k)) liked.add(k);
    state = state.copyWith(liked: liked, dismissed: {...state.dismissed}..remove(k));
  }

  void dismiss(Map l) {
    final k = keyFor(l);
    state = state.copyWith(dismissed: {...state.dismissed, k}, liked: {...state.liked}..remove(k));
  }

  /// A short line for the model's context ("viewed 3, liked 1: Honda, Honda").
  /// Makes only; nothing the model could turn into a number.
  String? summary(List<Map> listings) {
    if (state.viewed.isEmpty && state.liked.isEmpty) return null;
    final likedMakes = <String>[
      for (final l in listings)
        if (state.liked.contains(keyFor(l)) && l['make'] != null) '${l['make']}',
    ];
    final viewedMakes = <String>[
      for (final l in listings)
        if (state.viewed.contains(keyFor(l)) && l['make'] != null) '${l['make']}',
    ];
    final parts = <String>[
      if (state.viewed.isNotEmpty)
        'viewed ${state.viewed.length}${viewedMakes.isEmpty ? '' : ' (${viewedMakes.toSet().join(', ')})'}',
      if (state.liked.isNotEmpty)
        'liked ${state.liked.length}${likedMakes.isEmpty ? '' : ' (${likedMakes.toSet().join(', ')})'}',
    ];
    return parts.join('; ');
  }
}
