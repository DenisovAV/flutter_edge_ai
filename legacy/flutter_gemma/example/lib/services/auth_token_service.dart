import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gemma_example/constants/app_keys.dart';

/// Centralized authentication token management service.
///
/// This service provides a single source of truth for managing HuggingFace
/// authentication tokens in the example app. It eliminates code duplication
/// and ensures consistent token handling across all download services.
///
/// Used by:
/// - ModelDownloadService
/// - EmbeddingModelDownloadService
class AuthTokenService {
  // Private constructor to prevent instantiation
  AuthTokenService._();

  /// Load the stored HuggingFace authentication token.
  ///
  /// Returns the token string if found, or null if no token is saved.
  /// Priority: 1) dart-define (HUGGINGFACE_TOKEN), 2) SharedPreferences
  ///
  /// dart-define token always takes precedence and is saved to SharedPreferences.
  static Future<String?> loadToken() async {
    final prefs = await SharedPreferences.getInstance();

    // Priority 1: dart-define (HUGGINGFACE_TOKEN) - always takes precedence
    const envToken = String.fromEnvironment('HUGGINGFACE_TOKEN');

    if (envToken.isNotEmpty) {
      await prefs.setString(AppKeys.authToken, envToken);
      return envToken;
    }

    // Priority 2: SharedPreferences (fallback only if no dart-define)
    return prefs.getString(AppKeys.authToken);
  }

  /// Save a HuggingFace authentication token.
  ///
  /// The token will be persisted to SharedPreferences and available
  /// for subsequent model downloads.
  static Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppKeys.authToken, token);
  }

  /// Clear the stored authentication token.
  ///
  /// Removes the token from SharedPreferences, useful for logout functionality.
  static Future<void> clearToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppKeys.authToken);
  }

  /// Check if a token exists.
  ///
  /// Returns true if a token is currently stored, false otherwise.
  static Future<bool> hasToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(AppKeys.authToken);
  }
}
