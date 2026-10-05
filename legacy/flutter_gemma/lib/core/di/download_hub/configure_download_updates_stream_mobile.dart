import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_gemma/mobile/smart_downloader.dart';

/// Wires a host-provided download hub into [SmartDownloader] (mobile only).
void configureDownloadUpdatesStream(Stream<Object>? stream) {
  SmartDownloader.configureDownloadUpdatesStream(stream?.cast<TaskUpdate>());
}

/// Clears injected hub state (tests, registry [ServiceRegistry.reset]).
void clearDownloadUpdatesStream() {
  SmartDownloader.clearConfiguration();
}
