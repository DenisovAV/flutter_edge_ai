import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/foundation.dart';

import 'dart:convert';

import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The web pane's state: what is loaded and whether it is still loading.
class BrowserState {
  const BrowserState({this.url, this.title, this.loading = false, this.lastExtract});

  final String? url;
  final String? title;
  final bool loading;
  final PageExtract? lastExtract;

  BrowserState copyWith({
    String? url,
    String? title,
    bool? loading,
    PageExtract? lastExtract,
    bool clearExtract = false,
  }) => BrowserState(
    url: url ?? this.url,
    title: title ?? this.title,
    loading: loading ?? this.loading,
    lastExtract: clearExtract ? null : (lastExtract ?? this.lastExtract),
  );
}

final browserProvider = NotifierProvider<BrowserService, BrowserState>(BrowserService.new);
final listingStoreProvider = Provider<ListingStore>((ref) => ListingStore());

/// Thrown when the page is a human-verification step; the person completes
/// it in the pane and the advisor reads again.
class PageChallengeException implements Exception {
  const PageChallengeException();
  @override
  String toString() =>
      'The site is asking you to confirm you are a person. Complete the check in the web pane, then ask me to read the page again.';
}

bool _looksLikeChallenge(String title, String text) {
  final t = '$title\n${text.length > 400 ? text.substring(0, 400) : text}'.toLowerCase();
  return t.contains('just a moment') ||
      t.contains('security verification') ||
      t.contains('verify you are') ||
      t.contains('are you a human') ||
      t.contains('checking your browser') ||
      t.contains('press & hold') ||
      t.contains('access denied');
}

/// Owns the one in-app webview (VA-6.1): navigation, load tracking and page
/// reading. The widget registers its controller here; tools call [readPage].
///
/// Reading is user- or advisor-initiated, one page at a time, text only
/// (Q31). Nothing is fetched in bulk.
class BrowserService extends Notifier<BrowserState> {
  WebViewController? _controller;
  Completer<void>? _loaded;

  @override
  BrowserState build() => const BrowserState();

  void attach(WebViewController c) => _controller = c;

  void onLoadStart(String? url) {
    _loaded = Completer<void>();
    state = state.copyWith(url: url, loading: true);
  }

  void onLoadStop(String? url, String? title) {
    state = state.copyWith(url: url, title: title, loading: false);
    if (!(_loaded?.isCompleted ?? true)) {
      _loaded!.complete();
    }
  }

  Future<void> open(String url) async {
    state = state.copyWith(url: url, loading: true, clearExtract: true);
    final c = _controller;
    if (c == null) return; // the pane will load [state.url] when it mounts
    await c.loadRequest(Uri.parse(url));
  }

  /// Waits for the current load (or [timeout]), then extracts the page's
  /// visible text, title, og:image and any listings it contains.
  Future<PageExtract> readPage({
    String? url,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (url != null && url != state.url) {
      await open(url);
      // The webview's onLoadStart fires asynchronously; give it a beat.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final pending = _loaded;
    if (pending != null && !pending.isCompleted) {
      await pending.future.timeout(timeout, onTimeout: () {});
    }
    final c = _controller;
    if (c == null) {
      throw StateError('The web pane is not open.');
    }
    // Listing sites render their cards after load, from a fetch. Poll until
    // the visible text stops growing or listings appear, up to ~10 s.
    Object? raw;
    var lastLength = -1;
    var stable = 0;
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      raw = await c.runJavaScriptReturningResult(_extractJs);
      final probeText = _decode(raw)['text'] as String? ?? '';
      final hasListings = const ListingExtractor()
          .extract(probeText, sourceUrl: '', now: DateTime.now())
          .isNotEmpty;
      stable = probeText.length == lastLength ? stable + 1 : 0;
      lastLength = probeText.length;
      if (hasListings || (stable >= 1 && i >= 2)) break;
    }
    final map = _decode(raw);
    final text = (map['text'] as String? ?? '').trim();
    final pageUrl = map['url'] as String? ?? state.url ?? '';
    final title = (map['title'] as String? ?? '').trim();
    if (_looksLikeChallenge(title, text)) {
      // The site is asking the person to prove they are human. That is theirs
      // to answer in the pane; the advisor only reports it and reads again
      // afterwards. Nothing here tries to get around it.
      final extract = PageExtract(
        url: pageUrl,
        title: title,
        text: '',
        listings: const [],
        imageUrl: null,
      );
      state = state.copyWith(lastExtract: extract, url: pageUrl, title: title);
      throw const PageChallengeException();
    }
    final listings = const ListingExtractor().extract(
      text,
      sourceUrl: pageUrl,
      now: DateTime.now(),
    );
    ref.read(listingStoreProvider).addAll(listings);
    final extract = PageExtract(
      url: pageUrl,
      title: (map['title'] as String? ?? '').trim(),
      text: text,
      imageUrl: map['image'] as String?,
      listings: listings,
    );
    state = state.copyWith(lastExtract: extract, url: pageUrl, title: extract.title);
    if (kDebugMode) {
      debugPrint(
        '[motormind] read_page: ${text.length} chars, ${listings.length} listings from $pageUrl',
      );
      final sample = text.length > 1200 ? text.substring(0, 1200) : text;
      debugPrint('[motormind] read_page sample: ${sample.replaceAll('\n', ' | ')}');
    }
    return extract;
  }

  /// Android returns a JSON string (sometimes quoted twice); iOS returns the object.
  static Map<String, Object?> _decode(Object? raw) {
    Object? decoded = raw;
    for (var i = 0; i < 2 && decoded is String; i++) {
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        break;
      }
    }
    return decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{};
  }

  /// Visible text only: scripts, styles, nav, header, footer and hidden
  /// elements removed before `innerText` (TQ36 option c, first cut).
  static const _extractJs = r'''
(function () {
  function visibleText() {
    var clone = document.body.cloneNode(true);
    var kill = clone.querySelectorAll('script,style,noscript,svg,nav,header,footer,iframe,[aria-hidden="true"],[role="navigation"],[role="banner"],[role="contentinfo"]');
    for (var i = 0; i < kill.length; i++) kill[i].remove();
    var holder = document.createElement('div');
    holder.style.position = 'fixed'; holder.style.left = '-99999px'; holder.style.top = '0';
    holder.appendChild(clone);
    document.body.appendChild(holder);
    var t = clone.innerText || '';
    holder.remove();
    return t;
  }
  var og = document.querySelector('meta[property="og:image"]');
  var text = '';
  try { text = visibleText(); } catch (e) { text = document.body.innerText || ''; }
  if (text.length > 60000) {
    text = text.substring(0, 60000);
  }
  return JSON.stringify({ url: location.href, title: document.title, image: og ? og.getAttribute('content') : null, text: text });
})();
''';
}
