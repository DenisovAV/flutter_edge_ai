import 'dart:convert';

import 'package:http/http.dart' as http;

import 'submission.dart';

/// A store or GitHub did not answer as expected, so the submission could not
/// be checked. [service] is named to the person; [detail] only in the log.
class StoreUnavailableException implements Exception {
  StoreUnavailableException(this.service, this.detail);

  final String service;

  final String detail;

  @override
  String toString() => 'StoreUnavailableException: $service: $detail';
}

/// What the App Store says about an app, from the iTunes Lookup API.
typedef AppStoreApp = ({String name, int ratings, String? artworkUrl});

/// Looks the app up in the stores its links name, and throws
/// [SubmissionException] when a store does not have it.
class StoreCheck {
  StoreCheck(this._client);

  final http.Client _client;

  static const _timeout = Duration(seconds: 10);

  /// Google Play has no public API: its details page answers 404 for an id
  /// it does not list.
  Future<void> googlePlay(String applicationId) async {
    final uri = Uri.https('play.google.com', '/store/apps/details', {
      'id': applicationId,
      'hl': 'en',
    });
    final response = await _client.get(uri).timeout(_timeout);
    if (response.statusCode == 404) throw SubmissionException('Google Play has no app $applicationId.');
    if (response.statusCode != 200) {
      throw StoreUnavailableException(
        'Google Play',
        'answered ${response.statusCode} for $applicationId',
      );
    }
  }

  /// [country] is the storefront from the link; the lookup only finds an app
  /// in a storefront that sells it, and defaults to the US one.
  Future<AppStoreApp> appStore(int id, {String? country}) async {
    final uri = Uri.https('itunes.apple.com', '/lookup', {
      'id': '$id',
      'country': ?country,
    });
    final response = await _client.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw StoreUnavailableException(
        'The App Store',
        'the iTunes Lookup API answered ${response.statusCode} for $id',
      );
    }
    final body = jsonDecode(response.body);
    if (body case {'results': [final Map<String, Object?> app, ...]}) {
      return (
        name: app['trackName'] as String,
        ratings: (app['userRatingCount'] as num?)?.toInt() ?? 0,
        artworkUrl: app['artworkUrl512'] as String?,
      );
    }
    throw SubmissionException(
      'The App Store has no app id$id${country == null ? '' : ' in the $country storefront'}.',
    );
  }
}
