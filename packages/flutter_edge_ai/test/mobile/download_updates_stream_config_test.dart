import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_edge_ai/mobile/smart_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(SmartDownloader.clearConfiguration);

  test('clearConfiguration resets injected hub state', () {
    SmartDownloader.configureDownloadUpdatesStream(
      const Stream<TaskUpdate>.empty(),
    );
    SmartDownloader.clearConfiguration();
    SmartDownloader.configureDownloadUpdatesStream(null);
    expect(SmartDownloader.debugResolveUpdatesStream(), isNotNull);
  });

  test('wraps single-subscription injected stream for multiple listeners', () {
    final singleSub = StreamController<TaskUpdate>();
    SmartDownloader.configureDownloadUpdatesStream(singleSub.stream);

    final resolved = SmartDownloader.debugResolveUpdatesStream();
    final sub1 = resolved.listen((_) {});
    final sub2 = resolved.listen((_) {});

    expect(sub1.isPaused, isFalse);
    expect(sub2.isPaused, isFalse);

    sub1.cancel();
    sub2.cancel();
    unawaited(singleSub.close());
  });

  test('broadcast injected stream is not double-wrapped', () {
    final hub = StreamController<TaskUpdate>.broadcast();
    SmartDownloader.configureDownloadUpdatesStream(hub.stream);

    final first = SmartDownloader.debugResolveUpdatesStream();
    final second = SmartDownloader.debugResolveUpdatesStream();

    expect(identical(first, second), isTrue);

    unawaited(hub.close());
  });

  test('hub stream error is observable on a second listener', () async {
    final hub = StreamController<TaskUpdate>.broadcast();
    SmartDownloader.configureDownloadUpdatesStream(hub.stream);

    final resolved = SmartDownloader.debugResolveUpdatesStream();
    final errors = <Object>[];
    // Both listeners must supply onError: on a broadcast stream an error is
    // delivered to every listener, and any handler-less listener turns it into
    // an uncaught zone error. SmartDownloader's own listen sites are all
    // onError-guarded; mirror that here.
    final sub1 = resolved.listen((_) {}, onError: (_) {});
    final sub2 = resolved.listen((_) {}, onError: errors.add);

    hub.addError(StateError('hub failure'));
    await Future<void>.delayed(Duration.zero);

    expect(errors, isNotEmpty);

    await sub1.cancel();
    await sub2.cancel();
    await hub.close();
  });
}
