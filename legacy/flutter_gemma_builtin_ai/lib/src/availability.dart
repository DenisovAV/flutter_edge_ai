import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_local_ai/flutter_local_ai.dart' show LocalAi;

import 'availability_types.dart';

/// App-facing entry point for probing and preparing the OS built-in model.
///
/// A forwarding facade over flutter_local_ai's [LocalAi]. Everything that used
/// to live here — the bounded availability probe, the feature-download
/// kick-off, the `DOWNLOAD_PROGRESS` plumbing and the poll loop that decides
/// when the model is actually ready — now lives in flutter_local_ai and is NOT
/// reimplemented here. Fix a bug in any of it there, not in this file.
///
/// It is a facade rather than a `typedef` of [LocalAi] because every [LocalAi]
/// method takes an extra `{LocalAiHost? host}` parameter for injecting a fake
/// host in tests. Forwarding by hand keeps this package's signatures exactly
/// as they were.
abstract final class BuiltInAi {
  /// How long to wait for the availability probe before treating the host as
  /// unavailable. On a device where the OS AI stack has never initialized
  /// (a freshly-provisioned / CI device where Android AICore has no Phenotype
  /// metadata yet), the native status call can block instead of returning a
  /// status. Bounding it keeps [availability] — and therefore any caller that
  /// gates on it — from hanging.
  ///
  /// Reads and writes [LocalAi.debugProbeTimeout] itself, so there is one
  /// value: setting it on either class bounds the same probe. Overridable only
  /// for tests.
  static Duration get debugProbeTimeout => LocalAi.debugProbeTimeout;

  static set debugProbeTimeout(Duration value) =>
      LocalAi.debugProbeTimeout = value;

  /// Current availability of the OS built-in model.
  ///
  /// Never throws and never hangs: a probe that does not return within
  /// [debugProbeTimeout] resolves to
  /// [BuiltInAiAvailability.unavailableOther] so callers can degrade or skip.
  static Future<BuiltInAiAvailability> availability() async => _isLinux
      ? BuiltInAiAvailability.unavailableDeviceUnsupported
      : LocalAi.availability();

  /// Ensures the OS model is ready to use, downloading the feature if the OS
  /// exposes it as [BuiltInAiAvailability.downloadable].
  ///
  /// - [BuiltInAiAvailability.available] → resolves immediately.
  /// - `unavailable*` → throws [BuiltInAiUnavailableException] (no download;
  ///   those states cannot be fixed by waiting).
  /// - [BuiltInAiAvailability.downloadable] → kicks the download off, then
  ///   polls until the model reports available.
  /// - [BuiltInAiAvailability.downloading] → joins the download already
  ///   running, without starting another.
  ///
  /// [onProgress] receives an integer percentage 0..100 as bytes arrive.
  /// [timeout] bounds the whole wait; a `TimeoutException` is thrown if the
  /// model is not ready in time.
  static Future<void> ensureReady({
    void Function(int percent)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (_isLinux) {
      throw BuiltInAiUnavailableException(
        BuiltInAiAvailability.unavailableDeviceUnsupported,
        'Linux has no OS built-in model.',
      );
    }
    return LocalAi.ensureReady(onProgress: onProgress, timeout: timeout);
  }

  // Linux has no OS built-in model, and flutter_local_ai registers no plugin
  // there, so its probe catches a MissingPluginException and answers
  // `unavailableOther`. 0.2.2 promised `unavailableDeviceUnsupported`, which
  // is the true reason and the one a fallback can branch on; keep it.
  static bool get _isLinux =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
}
