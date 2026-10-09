import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../browser/browser_service.dart';
import '../chat/chat_service.dart';
import '../chat/result_card.dart' show money;
import 'listing_signals.dart';

/// The Cards stage's listing card (DD-R24, R25, R28): compact tiles with an
/// image, the facts read, and the source named on every tile ("like a Google
/// search"). A tap expands the tile in place (the detail, with "open on
/// `<site>`") and marks it viewed; a heart marks it liked. Both are signals
/// Motormind may learn from, never silently (DD-R29).
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
                  sites.map((s) => CuratedSites.byId(s)?.name ?? s).join(' + '),
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
              if (!signals.dismissed.contains(ListingSignalsNotifier.keyFor(l)))
                _ListingTile(
                  listing: l,
                  open: _open == ListingSignalsNotifier.keyFor(l),
                  viewed: signals.viewed.contains(ListingSignalsNotifier.keyFor(l)),
                  liked: signals.liked.contains(ListingSignalsNotifier.keyFor(l)),
                  onTap: () {
                    final k = ListingSignalsNotifier.keyFor(l);
                    setState(() => _open = _open == k ? null : k);
                    if (_open == k) signalsNotifier.viewed(l);
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
                      .send('What would the ${l['title']} cost me a month?'),
                ),
          ],
        ),
      ),
    );
  }
}

class _ListingTile extends StatelessWidget {
  const _ListingTile({
    required this.listing,
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
    final siteName = CuratedSites.byId(siteId ?? '')?.name ?? 'web';
    final readAt = DateTime.tryParse('${l['readAt']}');
    final age = readAt == null ? null : _age(DateTime.now().difference(readAt));
    final image = l['imageUrl']?.toString();
    final facts = [
      if (l['price'] != null) money(l['price'], cents: false),
      if (l['mileage'] != null) '${thousands(l['mileage'])} mi',
    ].join(' · ');
    return InkWell(
      key: Key('listing-${ListingSignalsNotifier.keyFor(l)}'),
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
                    width: 56,
                    height: 42,
                    child: image != null && image.startsWith('http')
                        ? Image.network(
                            image,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const _Placeholder(),
                          )
                        : const _Placeholder(),
                  ),
                ),
                const SizedBox(width: 10),
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
                  key: Key('like-${ListingSignalsNotifier.keyFor(l)}'),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(liked ? Icons.favorite : Icons.favorite_border, size: 18),
                  onPressed: onLike,
                ),
              ],
            ),
            if (open)
              Padding(
                padding: const EdgeInsets.only(left: 66, top: 2, bottom: 4),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    ActionChip(
                      key: Key('open-site-${ListingSignalsNotifier.keyFor(l)}'),
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

String thousands(Object? v) {
  final n = (v as num?)?.round();
  if (n == null) return '';
  return n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
}

/// Wraps a scrollable so a soft edge appears at the bottom while there is
/// more below (TQ69: the "cut" that says the content continues). The edge is
/// the affordance; the nudge is the display agent's call.
class ScrollCut extends StatefulWidget {
  const ScrollCut({super.key, required this.child, required this.controller});
  final Widget child;
  final ScrollController controller;

  @override
  State<ScrollCut> createState() => _ScrollCutState();
}

class _ScrollCutState extends State<ScrollCut> {
  bool _more = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!widget.controller.hasClients) return;
    final p = widget.controller.position;
    final more = p.maxScrollExtent > 0 && p.pixels < p.maxScrollExtent - 8;
    if (more != _more) setState(() => _more = more);
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surface;
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _check();
            return false;
          },
          child: widget.child,
        ),
        if (_more)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 28,
            child: IgnorePointer(
              child: DecoratedBox(
                key: const Key('scroll-cut'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [color.withValues(alpha: 0), color],
                  ),
                ),
                child: const Align(
                  alignment: Alignment.bottomCenter,
                  child: Icon(Icons.keyboard_arrow_down, size: 16),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
