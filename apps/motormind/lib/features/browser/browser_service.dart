import 'dart:async';
import 'dart:convert';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/log.dart';
import '../chat/chat_strings.dart';
import '../recipes/recipe_store.dart';

/// The web pane's state: what is loaded and whether it is still loading.
class BrowserState {
  const BrowserState({this.url, this.title, this.loading = false});

  final String? url;
  final String? title;
  final bool loading;

  BrowserState copyWith({String? url, String? title, bool? loading}) => BrowserState(
    url: url ?? this.url,
    title: title ?? this.title,
    loading: loading ?? this.loading,
  );
}

final browserProvider = NotifierProvider<BrowserService, BrowserState>(BrowserService.new);

/// Every listing read this session, from any site. Session-scoped on
/// purpose: nothing is cached beyond the app's lifetime.
final listingStoreProvider = Provider<ListingStore>((ref) => ListingStore());

/// Thrown when the page is a human-verification step. That step is the
/// person's to complete in the pane; Motormind reports it and reads again
/// afterwards. Nothing in the app tries to get around it.
class PageChallengeException implements Exception {
  const PageChallengeException();

  /// The sentence shown to the person and handed to the model.
  String get message => ChatStrings.humanCheck;

  @override
  String toString() => 'PageChallengeException: $message';
}

/// What `read_page` gets back from the page's JavaScript: the address, the
/// title, the share image, the visible text and the rendered HTML.
typedef _PageSnapshot = ({String url, String title, String? image, String text, String html});

/// Owns the one in-app webview (the one window on the web): navigation, load tracking and page
/// reading. The pane registers its controller here; tools call [readPage].
///
/// Reading is user- or Motormind-initiated, one page at a time. Nothing
/// is fetched in bulk and no page is loaded without a person behind it.
class BrowserService extends Notifier<BrowserState> {
  /// How long to wait for a navigation to finish before reading anyway.
  static const loadTimeout = Duration(seconds: 20);

  /// Listing sites paint their cards from a fetch after `load`. The reader
  /// probes the page once a second and stops when the text stops growing or
  /// listings appear; ten probes is the point past which a page that is
  /// still changing is not going to settle.
  static const _probeInterval = Duration(seconds: 1);
  static const _maxProbes = 10;

  /// Probes before "stable" counts: the first two readings are often the
  /// skeleton and the first batch of cards. One unchanged probe after that
  /// is enough.
  static const _minProbesBeforeStable = 2;
  static const _stableProbesNeeded = 1;

  /// Caps on what the bridge carries back: 60k characters of text (~15k
  /// tokens, more than any context window here) and 1.5 MB of HTML.
  static const _maxTextChars = 60000;
  static const _maxHtmlChars = 1500000;

  /// A scroll step is most of a screen, so nothing between steps is missed.
  static const _scrollScreenFraction = 0.9;

  /// The paced scroll after the app opens a results page: a screen at a time
  /// with a pause, so lazily rendered cards and images exist before the read.
  /// Six screens covers a first results page on every curated site.
  static const _scrollSteps = 6;
  static const _scrollPause = Duration(milliseconds: 450);
  static const _scrollReturnPause = Duration(milliseconds: 400);

  /// Only the title and the first part of the text decide whether a page is
  /// a bot check: the markers sit at the top of those pages.
  static const _challengeProbeLength = 400;
  static const _challengeMarkers = [
    'just a moment',
    'security verification',
    'verify you are',
    'are you a human',
    'checking your browser',
    'press & hold',
    'access denied',
  ];

  WebViewController? _controller;
  Completer<void>? _loaded;

  @override
  BrowserState build() => const BrowserState();

  /// The pane hands over its controller once mounted and takes it back in
  /// [detach] when it unmounts, so no JavaScript runs against a dead view.
  void attach(WebViewController controller) => _controller = controller;

  void detach(WebViewController controller) {
    if (identical(_controller, controller)) _controller = null;
  }

  void onLoadStart(String? url) {
    _loaded ??= Completer<void>();
    state = state.copyWith(url: url, loading: true);
  }

  void onLoadStop(String? url, String? title) {
    state = state.copyWith(url: url, title: title, loading: false);
    final pending = _loaded;
    if (pending != null && !pending.isCompleted) pending.complete();
    _loaded = null;
  }

  /// Navigates the pane. The load completer is created here, not in
  /// [onLoadStart], so a read that follows an [open] waits for this load and
  /// not for whichever load happened before.
  Future<void> open(String url) async {
    _loaded = Completer<void>();
    state = state.copyWith(url: url, loading: true);
    final c = _controller;
    if (c == null) return; // the pane loads [state.url] when it mounts
    await c.loadRequest(Uri.parse(url));
  }

  /// Which curated site a URL belongs to, by host (exact or a subdomain).
  static String? siteIdFor(String? url) {
    final host = Uri.tryParse(url ?? '')?.host ?? '';
    for (final s in CuratedSites.all) {
      final base = Uri.parse(s.home).host.replaceFirst('www.', '');
      if (host == base || host.endsWith('.$base')) return s.id;
    }
    return null;
  }

  /// Reads the page: waits for the load, lets the cards render, scrolls once
  /// if the app itself opened the page, refuses a bot check, then reads with
  /// the site's recipe when one applies and passes its self-check, otherwise
  /// with the generic text patterns (ADR 0007).
  Future<PageExtract> readPage({String? url, Duration timeout = loadTimeout}) async {
    final appOpened = url != null && url != state.url;
    if (appOpened) await open(url);
    await _awaitLoad(timeout);
    final c = _controller;
    if (c == null) throw StateError('The web pane is not open.');

    var page = await _probeUntilRendered(c);
    if (appOpened && !_looksLikeChallenge(page)) {
      await _scrollToLoad(c);
      page = await _snapshot(c);
    }
    if (_looksLikeChallenge(page)) {
      state = state.copyWith(url: page.url, title: page.title);
      throw const PageChallengeException();
    }

    final now = DateTime.now();
    var listings = await _readWithRecipe(page, now);
    if (listings.isEmpty) {
      listings = const ListingExtractor().extract(page.text, sourceUrl: page.url, now: now);
    }
    ref.read(listingStoreProvider).addAll(listings);
    state = state.copyWith(url: page.url, title: page.title);
    logDev('read_page: ${page.text.length} chars, ${listings.length} listings from ${page.url}');
    return PageExtract(
      url: page.url,
      title: page.title,
      text: page.text,
      imageUrl: page.image,
      listings: listings,
    );
  }

  /// The page as the person sees it right now, for Capture: fresh HTML,
  /// title and URL. No navigation, no scrolling.
  Future<({String url, String title, String html, String text})> snapshot() async {
    final c = _controller;
    if (c == null) throw StateError('The web pane is not open.');
    final page = await _snapshot(c);
    return (url: page.url, title: page.title, html: page.html, text: page.text);
  }

  Future<void> _awaitLoad(Duration timeout) async {
    final pending = _loaded;
    if (pending != null && !pending.isCompleted) {
      await pending.future.timeout(timeout, onTimeout: () {});
    }
  }

  /// Probes the page until its visible text stops growing or listings
  /// appear, so a results page is read after its cards exist.
  Future<_PageSnapshot> _probeUntilRendered(WebViewController c) async {
    _PageSnapshot? page;
    var lastLength = -1;
    var stable = 0;
    for (var i = 0; i < _maxProbes; i++) {
      await Future<void>.delayed(_probeInterval);
      page = await _snapshot(c);
      final hasListings = const ListingExtractor()
          .extract(page.text, sourceUrl: '', now: DateTime.now())
          .isNotEmpty;
      stable = page.text.length == lastLength ? stable + 1 : 0;
      lastLength = page.text.length;
      if (hasListings || (stable >= _stableProbesNeeded && i >= _minProbesBeforeStable)) break;
    }
    return page!;
  }

  /// Runs the site's recipe over the rendered HTML and records the verdict.
  /// Returns no listings when there is no recipe or the self-check failed,
  /// so the caller falls back to the text patterns.
  Future<List<VehicleListing>> _readWithRecipe(_PageSnapshot page, DateTime now) async {
    final siteId = siteIdFor(page.url);
    if (siteId == null || page.html.isEmpty) return const [];
    // The store loads its assets asynchronously; waiting for it is what makes
    // the recipe run on the very first read after launch.
    final recipes = await ref.read(recipeStoreProvider.future);
    final recipe = recipes[siteId];
    if (recipe == null) return const [];
    final r = const RecipeReader().read(page.html, recipe, sourceUrl: page.url, now: now);
    ref.read(recipeStoreProvider.notifier).recordCheck(siteId, r.check);
    logDev('recipe $siteId v${recipe.version}: ${r.check}');
    return r.check.ok ? r.listings : const [];
  }

  /// Scrolls the way a person would, a screen at a time with a pause, then
  /// returns to the top. Only right after the app itself opened a results
  /// page; never on a page the person is reading.
  Future<void> _scrollToLoad(WebViewController c) async {
    for (var i = 0; i < _scrollSteps; i++) {
      // runJavaScriptReturningResult returns a platform-typed Object; the
      // string compare is the portable way to read a JS boolean.
      final atBottom = await c.runJavaScriptReturningResult(_scrollStepJs);
      await Future<void>.delayed(_scrollPause);
      if (atBottom.toString() == 'true') break;
    }
    await c.runJavaScript('window.scrollTo({top: 0, behavior: "smooth"});');
    await Future<void>.delayed(_scrollReturnPause);
  }

  Future<_PageSnapshot> _snapshot(WebViewController c) async {
    final map = _decode(await c.runJavaScriptReturningResult(_extractJs));
    return (
      url: map['url'] as String? ?? state.url ?? '',
      title: (map['title'] as String? ?? '').trim(),
      image: map['image'] as String?,
      text: (map['text'] as String? ?? '').trim(),
      html: map['html'] as String? ?? '',
    );
  }

  static bool _looksLikeChallenge(_PageSnapshot page) {
    final head = page.text.length > _challengeProbeLength
        ? page.text.substring(0, _challengeProbeLength)
        : page.text;
    final probe = '${page.title}\n$head'.toLowerCase();
    return _challengeMarkers.any(probe.contains);
  }

  /// Android returns a JSON string (sometimes quoted twice); iOS returns the
  /// object. Both end up as one map.
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

  /// Scrolls down most of a screen and reports whether the bottom was reached
  /// (within a few pixels, so a sub-pixel overshoot does not loop).
  static const _scrollStepJs =
      '(function(){window.scrollBy({top: window.innerHeight * $_scrollScreenFraction, behavior: "smooth"});'
      'return (window.innerHeight + window.scrollY) >= document.body.scrollHeight - 10;})();';

  /// Visible text and rendered HTML in one call. The text comes from a clone
  /// of `body` with scripts, navigation, headers, footers and hidden elements
  /// removed; the clone is parked off-screen because `innerText` is empty for
  /// a detached node. The caps are [_maxTextChars] and [_maxHtmlChars].
  static final _extractJs =
      '''
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
  if (text.length > $_maxTextChars) { text = text.substring(0, $_maxTextChars); }
  var html = '';
  try { html = document.documentElement.outerHTML || ''; } catch (e) { html = ''; }
  if (html.length > $_maxHtmlChars) { html = html.substring(0, $_maxHtmlChars); }
  return JSON.stringify({ url: location.href, title: document.title, image: og ? og.getAttribute('content') : null, text: text, html: html });
})();
''';
}
