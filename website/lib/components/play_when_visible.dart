import 'package:jaspr/jaspr.dart';
import 'package:universal_web/js_interop.dart';
import 'package:universal_web/web.dart' as web;

/// Starts every `<video data-play-when-visible>` on the page when it scrolls
/// into view and pauses it when it leaves, so a demo is downloaded only once a
/// visitor gets to it and nothing decodes off screen.
///
/// The demos carry `preload="none"` and no `autoplay`; the `play()` call turns
/// preloading on. The hero keeps `autoplay` (it is above the fold and must run
/// without JavaScript) and is only paused by this component. Under
/// `prefers-reduced-motion: reduce` every video stays on its poster, since
/// none has controls to stop it with. Muted inline video may be started
/// without a user gesture in every current browser.
///
/// Renders nothing; place it once, after the videos.
@client
class PlayWhenVisible extends StatefulComponent {
  const PlayWhenVisible({super.key});

  @override
  State<PlayWhenVisible> createState() => PlayWhenVisibleState();
}

class PlayWhenVisibleState extends State<PlayWhenVisible> {
  web.IntersectionObserver? _observer;

  @override
  void initState() {
    super.initState();
    // The server prerenders this component too, and has no DOM.
    if (kIsWeb) _observeVideos();
  }

  void _observeVideos() {
    final found = web.document.querySelectorAll(
      'video[data-play-when-visible]',
    );
    final videos = [
      for (var i = 0; i < found.length; i++) found.item(i)! as web.HTMLVideoElement,
    ];
    if (videos.isEmpty) return;
    if (web.window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      for (final video in videos) {
        video.removeAttribute('autoplay');
        video.pause();
      }
      return;
    }
    final observer = web.IntersectionObserver(
      (
            JSArray<web.IntersectionObserverEntry> entries,
            web.IntersectionObserver _,
          ) {
            for (final entry in entries.toDart) {
              final video = entry.target as web.HTMLVideoElement;
              if (entry.isIntersecting) {
                if (video.preload == 'none') video.preload = 'auto';
                // Rejected when the browser refuses to play; the poster stays.
                video.play().toDart.ignore();
              } else if (!video.paused) {
                video.pause();
              }
            }
          }
          .toJS,
      web.IntersectionObserverInit(rootMargin: '200px 0px', threshold: 0.toJS),
    );
    for (final video in videos) {
      observer.observe(video);
    }
    _observer = observer;
  }

  @override
  void dispose() {
    _observer?.disconnect();
    super.dispose();
  }

  @override
  Component build(BuildContext context) => const Component.empty();
}
