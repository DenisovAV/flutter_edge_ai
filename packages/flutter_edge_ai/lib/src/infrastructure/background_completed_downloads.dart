import 'package:flutter_edge_ai/src/mobile/smart_downloader.dart';
import 'package:flutter_edge_ai/src/services/completed_downloads.dart';

/// [CompletedDownloads] over background_downloader (#873): the completions
/// `resumeFromBackground()` replays for core's download group, on Android.
final class BackgroundCompletedDownloads implements CompletedDownloads {
  const BackgroundCompletedDownloads();

  @override
  Future<({int? totalBytes})?> completedWhileAway(
    String url,
    String targetPath,
  ) async {
    final completion = await SmartDownloader.completedWhileAway(
      url,
      targetPath,
    );
    return completion == null ? null : (totalBytes: completion.totalBytes);
  }
}
