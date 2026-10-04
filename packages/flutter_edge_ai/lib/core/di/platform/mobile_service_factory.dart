/// Mobile-platform service factory.
/// This file is only compiled on iOS/Android platforms.
/// Uses background_downloader for model downloads.
library;

import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/web_storage_mode.dart';
import '../../infrastructure/background_downloader_service.dart';
import '../../services/download_service.dart';
import '../../services/file_system_service.dart';

/// Creates the default DownloadService for mobile platforms
///
/// Mobile platforms use BackgroundDownloaderService which handles
/// actual file downloads using native platform APIs.
///
/// Parameters are ignored on mobile (web-only), but included for
/// interface compatibility with web_service_factory.
DownloadService createDownloadService(
  FileSystemService fileSystem,
  WebStorageMode webStorageMode,
  SharedPreferences prefs,
) {
  // All parameters ignored - mobile uses BackgroundDownloaderService standalone
  return BackgroundDownloaderService();
}
