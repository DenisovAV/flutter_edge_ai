import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../browser/browser_service.dart';
import '../chat/cards/formatting.dart';
import '../chat/chat_service.dart';
import '../chat/chat_strings.dart';
import 'listing_signals.dart';

/// The Cards stage's listing card: compact tiles with an image, the facts
/// read, and the source named on every tile, so a mixed-site stage reads like
/// a search engine's results and never pretends to be one inventory. A tap
/// expands the tile in place (open on the site, monthly cost, not this one)
/// and marks it viewed; a heart marks it liked. Both are signals Motormind
/// may learn from, and it only ever proposes, never narrows silently.
class ListingCards extends ConsumerStatefulWidget {
  const ListingCards({super.key, required this.shown});
  final ShownComponent shown;

  @override
  ConsumerState<ListingCards> createState() => _ListingCardsState();
}

class _ListingCardsState extends ConsumerState<ListingCards> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.shown.result?.result ?? const {};
    final listings = (r['listings'] as List?)?.cast<Map>() ?? const [];
    final signals = ref.watch(listingSignalsProvider);
    final signalsNotifier = ref.read(listingSignalsProvider.notifier);
    final sites = {
      for (final l in listings) BrowserService.siteIdFor('${l['sourceUrl']}') ?? 'web',
    };
    return Card(
      key: const Key('card-vehicle_card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.shown.request.title ??
                        (listings.isEmpty ? 'No listings yet' : 'Listings'),
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  sites.map(CuratedSites.nameFor).join(' + '),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            if (listings.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${r['note'] ?? 'Open a listings page and Motormind can read it.'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            for (final l in listings)
              if (ListingSignalsNotifier.keyFor(l) case final key
                  when !signals.dismissed.contains(key))
                _ListingTile(
                  listing: l,
                  signalKey: key,
                  open: _open == key,
                  viewed: signals.viewed.contains(key),
                  liked: signals.liked.contains(key),
                  onTap: () {
                    setState(() => _open = _open == key ? null : key);
                    if (_open == key) signalsNotifier.markViewed(l);
                  },
                  onLike: () => signalsNotifier.toggleLiked(l),
                  onDismiss: () => signalsNotifier.dismiss(l),
                  onOpenSite: () {
                    final url = '${l['detailUrl'] ?? l['sourceUrl'] ?? ''}';
                    if (url.startsWith('http')) {
                      ref.read(browserProvider.notifier).open(url);
                    }
                  },
                  onAsk: () => ref
                      .read(chatServiceProvider.notifier)
                      .send(ChatStrings.monthlyCostOf('${l['title']}')),
                ),
          ],
        ),
      ),
    );
  }
}

class _ListingTile extends StatelessWidget {
  /// Thumbnail box; the image is decoded at twice this width for sharpness.
  static const _thumbWidth = 56.0;
  static const _thumbHeight = 42.0;
  static const _thumbGap = 10.0;

  const _ListingTile({
    required this.listing,
    required this.signalKey,
    required this.open,
    required this.viewed,
    required this.liked,
    required this.onTap,
    required this.onLike,
    required this.onDismiss,
    required this.onOpenSite,
    required this.onAsk,
  });

  final Map listing;
  final String signalKey;
  final bool open;
  final bool viewed;
  final bool liked;
  final VoidCallback onTap;
  final VoidCallback onLike;
  final VoidCallback onDismiss;
  final VoidCallback onOpenSite;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = listing;
    final siteId = BrowserService.siteIdFor('${l['sourceUrl']}');
    final siteName = siteId == null ? 'web' : CuratedSites.nameFor(siteId);
    // The age is computed at build time; it refreshes when the card rebuilds,
    // which is enough for a session-scoped list.
    final readAt = DateTime.tryParse('${l['readAt']}');
    final age = readAt == null ? null : _age(DateTime.now().difference(readAt));
    final image = l['imageUrl']?.toString();
    final facts = [
      if (l['price'] != null) money(l['price'], cents: false),
      if (l['mileage'] != null) '${thousands(l['mileage'])} mi',
    ].join(' · ');
    return InkWell(
      key: Key('listing-$signalKey'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: _thumbWidth,
                    height: _thumbHeight,
                    child: image != null && image.startsWith('http')
                        ? Image.network(
                            image,
                            fit: BoxFit.cover,
                            cacheWidth: (_thumbWidth * 2).round(),
                            errorBuilder: (_, _, _) => const _Placeholder(),
                          )
                        : const _Placeholder(),
                  ),
                ),
                const SizedBox(width: _thumbGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${l['title']}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: viewed ? FontWeight.normal : FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        [facts, siteName, ?age].where((s) => s.isNotEmpty).join(' · '),
                        style: theme.textTheme.labelSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: Key('like-$signalKey'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(liked ? Icons.favorite : Icons.favorite_border, size: 18),
                  onPressed: onLike,
                ),
              ],
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.only(left: _thumbWidth + _thumbGap, top: 2, bottom: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    ActionChip(
                      key: Key('open-site-$signalKey'),
                      label: Text('Open on $siteName'),
                      visualDensity: VisualDensity.compact,
                      onPressed: onOpenSite,
                    ),
                    ActionChip(
                      label: const Text('Monthly cost?'),
                      visualDensity: VisualDensity.compact,
                      onPressed: onAsk,
                    ),
                    ActionChip(
                      label: const Text('Not this one'),
                      visualDensity: VisualDensity.compact,
                      onPressed: onDismiss,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _age(Duration d) {
    if (d.inMinutes < 1) return 'just read';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: const Icon(Icons.directions_car_outlined, size: 20),
  );
}
