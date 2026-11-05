/// A request to list an app on flutteredge.ai/showcase, as the site's form
/// sends it, checked field by field.
library;

/// A submission that does not pass the checks. [message] is shown to the
/// person who sent it, so it names the field and says what is wrong.
class SubmissionException implements Exception {
  SubmissionException(this.message);

  final String message;

  @override
  String toString() => 'SubmissionException: $message';
}

/// The packages an app on the showcase can be built with.
const showcasePackages = {'flutter_edge_ai', 'flutter_gemma'};

class Submission {
  Submission._({
    required this.googlePlayId,
    required this.appStoreId,
    required this.appStoreCountry,
    required this.appName,
    required this.packages,
    required this.onDevice,
    required this.email,
  });

  /// Checks [data], the callable's payload, and throws [SubmissionException]
  /// on the first field that does not pass.
  factory Submission.parse(Object? data) {
    if (data is! Map) throw SubmissionException('The request has no fields.');
    final googlePlayUrl = _optionalString(data, 'googlePlayUrl', maxLength: 300);
    final appStoreUrl = _optionalString(data, 'appStoreUrl', maxLength: 300);
    if (googlePlayUrl == null && appStoreUrl == null) {
      throw SubmissionException('Give a Google Play or an App Store link.');
    }
    final appStore = appStoreUrl == null ? null : parseAppStoreUrl(appStoreUrl);
    final packages = data['packages'];
    if (packages is! List || packages.isEmpty || !packages.every(showcasePackages.contains)) {
      throw SubmissionException('Choose flutter_edge_ai, flutter_gemma or both.');
    }
    final onDevice = _optionalString(data, 'onDevice', maxLength: 500);
    if (onDevice == null) throw SubmissionException('Say what the app runs on the device.');
    final email = _optionalString(data, 'email', maxLength: 254);
    if (email == null || !_email.hasMatch(email)) throw SubmissionException('Give an email address to reach you at.');
    if (data['isDeveloper'] != true) throw SubmissionException('Only the app\'s developer or publisher can submit it.');
    if (data['consent'] != true) throw SubmissionException('Agree to show the app on the showcase.');
    return Submission._(
      googlePlayId: googlePlayUrl == null ? null : parseGooglePlayUrl(googlePlayUrl),
      appStoreId: appStore?.id,
      appStoreCountry: appStore?.country,
      appName: _optionalString(data, 'appName', maxLength: 100),
      packages: {for (final p in packages) p as String},
      onDevice: onDevice,
      email: email,
    );
  }

  /// The application id from the Google Play link, e.g. `rw.flipper`.
  final String? googlePlayId;

  /// The numeric id from the App Store link (`id1591978405`).
  final int? appStoreId;

  /// The storefront from the App Store link (`/us/app/…`), if it names one.
  final String? appStoreCountry;

  /// The name to show instead of the store's, if any.
  final String? appName;

  final Set<String> packages;

  /// What the app runs on the device, in the submitter's words.
  final String onDevice;

  final String email;

  /// One document per app, so a second submission of the same app is
  /// refused instead of stored twice. The Google Play id wins when both
  /// links are given.
  String get documentId => googlePlayId != null ? 'play:$googlePlayId' : 'appstore:$appStoreId';

  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
}

/// The application id from a Google Play details link, or
/// [SubmissionException].
String parseGooglePlayUrl(String url) {
  final uri = Uri.tryParse(url);
  final id = uri?.queryParameters['id'];
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'play.google.com' ||
      uri.path != '/store/apps/details' ||
      id == null ||
      !_applicationId.hasMatch(id)) {
    throw SubmissionException('The Google Play link should look like https://play.google.com/store/apps/details?id=…');
  }
  return id;
}

/// The id and the storefront from an App Store link, or
/// [SubmissionException].
({int id, String? country}) parseAppStoreUrl(String url) {
  final uri = Uri.tryParse(url);
  final segments = uri?.pathSegments ?? const <String>[];
  final match = segments.isEmpty ? null : _appStoreId.firstMatch(segments.last);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'apps.apple.com' ||
      !segments.contains('app') ||
      match == null) {
    throw SubmissionException('The App Store link should look like https://apps.apple.com/…/app/…/id…');
  }
  final country = segments.first.length == 2 ? segments.first : null;
  return (id: int.parse(match.group(1)!), country: country);
}

/// Android's rules for an application id: two or more segments, each
/// starting with a letter.
final _applicationId = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$');

final _appStoreId = RegExp(r'^id(\d{1,12})$');

String? _optionalString(Map<Object?, Object?> data, String field, {required int maxLength}) {
  final value = data[field];
  if (value == null) return null;
  if (value is! String) throw SubmissionException('$field should be text.');
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > maxLength) throw SubmissionException('$field is longer than $maxLength characters.');
  return trimmed;
}
