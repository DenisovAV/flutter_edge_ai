/// Application-level SharedPreferences keys for the example app.
///
/// IMPORTANT: Never use inline string keys! Always use constants from this class
/// to ensure consistency and prevent typos.
///
/// This follows the project standard documented in CLAUDE.md:
/// "No Inline String Keys/Magic Strings"
class AppKeys {
  // Private constructor to prevent instantiation
  AppKeys._();

  /// HuggingFace authentication token key.
  ///
  /// Used for storing user's HuggingFace access token to download gated models.
  /// Used in:
  /// - model_download_service.dart
  /// - embedding_download_service.dart
  static const String authToken = 'auth_token';
}
