import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'browser_service.dart';

/// The web pane on the stage: a curated-site chip row, a slim address line and
/// the webview. The advisor reads from it; the person browses it, including
/// answering any human-verification step a site shows.
class BrowserPane extends ConsumerStatefulWidget {
  const BrowserPane({super.key});

  @override
  ConsumerState<BrowserPane> createState() => _BrowserPaneState();
}

class _BrowserPaneState extends ConsumerState<BrowserPane> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    final service = ref.read(browserProvider.notifier);
    final initial = ref.read(browserProvider).url ?? CuratedSites.defaultSite.home;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) => service.onLoadStart(url),
          onPageFinished: (url) async => service.onLoadStop(url, await _controller.getTitle()),
          // Read-only browsing policy (VA-6.1.1): web pages only; no external
          // schemes, no downloads.
          onNavigationRequest: (req) =>
              req.url.startsWith('http') ? NavigationDecision.navigate : NavigationDecision.prevent,
        ),
      )
      ..loadRequest(Uri.parse(initial));
    service.attach(_controller);
  }

  @override
  Widget build(BuildContext context) {
    final browser = ref.watch(browserProvider);
    final theme = Theme.of(context);
    return Column(
      key: const Key('browser-pane'),
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final s in CuratedSites.all)
                Padding(
                  padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                  child: ActionChip(
                    key: Key('site-${s.id}'),
                    label: Text(s.name),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => ref.read(browserProvider.notifier).open(s.home),
                  ),
                ),
            ],
          ),
        ),
        if (browser.loading) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Text(
            browser.url ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ),
        Expanded(child: WebViewWidget(controller: _controller)),
      ],
    );
  }
}
