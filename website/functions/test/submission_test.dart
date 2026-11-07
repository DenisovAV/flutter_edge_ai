import 'package:showcase_functions/src/submission.dart';
import 'package:test/test.dart';

Map<String, Object?> _valid([Map<String, Object?> changes = const {}]) => {
  'googlePlayUrl': 'https://play.google.com/store/apps/details?id=rw.flipper',
  'packages': ['flutter_gemma'],
  'onDevice': 'Gemma 3 1B answers questions about the shop.',
  'email': 'dev@example.com',
  'isDeveloper': true,
  'consent': true,
  ...changes,
};

Matcher _refused(String message) => throwsA(
  isA<SubmissionException>().having(
    (e) => e.message,
    'message',
    contains(message),
  ),
);

void main() {
  test('a Google Play submission', () {
    final s = Submission.parse(_valid());
    expect(s.googlePlayId, 'rw.flipper');
    expect(s.appStoreId, isNull);
    expect(s.documentId, 'play:rw.flipper');
    expect(s.packages, {'flutter_gemma'});
  });

  test('an App Store submission takes the id and the storefront', () {
    final s = Submission.parse(
      _valid({
        'googlePlayUrl': null,
        'appStoreUrl': 'https://apps.apple.com/us/app/homiletics/id1591978405',
      }),
    );
    expect(s.appStoreId, 1591978405);
    expect(s.appStoreCountry, 'us');
    expect(s.documentId, 'appstore:1591978405');
  });

  test('an App Store link without a storefront', () {
    final s = Submission.parse(
      _valid({
        'appStoreUrl': 'https://apps.apple.com/app/homiletics/id1591978405',
      }),
    );
    expect(s.appStoreCountry, isNull);
    // The Google Play id names the document when both links are given.
    expect(s.documentId, 'play:rw.flipper');
  });

  test('an optional GitHub link', () {
    expect(Submission.parse(_valid()).source, isNull);
    final s = Submission.parse(
      _valid({'sourceUrl': 'https://github.com/yegobox/flipper'}),
    );
    expect(s.source?.owner, 'yegobox');
    expect(s.source?.repo, 'flipper');
    expect(
      () => Submission.parse(_valid({'sourceUrl': 'https://example.com/x'})),
      _refused('GitHub link'),
    );
  });

  test('blank text counts as missing and is trimmed', () {
    final s = Submission.parse(
      _valid({'appName': '   ', 'email': '  dev@example.com '}),
    );
    expect(s.appName, isNull);
    expect(s.email, 'dev@example.com');
  });

  test('refuses a request without either link', () {
    expect(
      () => Submission.parse(_valid({'googlePlayUrl': ' '})),
      _refused('Google Play or an App Store link'),
    );
  });

  test('refuses links that are not store details pages', () {
    for (final url in [
      'http://play.google.com/store/apps/details?id=rw.flipper',
      'https://play.google.com.evil.example/store/apps/details?id=rw.flipper',
      'https://play.google.com/store/apps/dev?id=123',
      'https://play.google.com/store/apps/details?id=flipper',
      'https://play.google.com/store/apps/details?id=rw.1flipper',
    ]) {
      expect(
        () => Submission.parse(_valid({'googlePlayUrl': url})),
        _refused('Google Play link'),
        reason: url,
      );
    }
    for (final url in [
      'https://apps.apple.com/us/developer/thirteen-one/id1591978405',
      'https://apps.apple.com.evil.example/us/app/x/id1',
      'https://apps.apple.com/us/app/homiletics',
    ]) {
      expect(
        () => Submission.parse(_valid({'appStoreUrl': url})),
        _refused('App Store link'),
        reason: url,
      );
    }
  });

  test('refuses packages outside the showcase', () {
    expect(
      () => Submission.parse(_valid({'packages': []})),
      _refused('Choose'),
    );
    expect(
      () => Submission.parse(
        _valid({
          'packages': ['tflite_flutter'],
        }),
      ),
      _refused('Choose'),
    );
    expect(
      () => Submission.parse(_valid({'packages': 'flutter_gemma'})),
      _refused('Choose'),
    );
  });

  test('refuses a missing description, a bad email and unticked boxes', () {
    expect(
      () => Submission.parse(_valid({'onDevice': ''})),
      _refused('runs on the device'),
    );
    expect(
      () => Submission.parse(_valid({'email': 'not an email'})),
      _refused('email'),
    );
    expect(
      () => Submission.parse(_valid({'isDeveloper': 'yes'})),
      _refused('developer or publisher'),
    );
    expect(
      () => Submission.parse(_valid({'consent': false})),
      _refused('Agree'),
    );
  });

  test('refuses text over its limit and values that are not text', () {
    expect(
      () => Submission.parse(_valid({'onDevice': 'x' * 501})),
      _refused('longer than 500'),
    );
    expect(
      () => Submission.parse(_valid({'appName': 42})),
      _refused('appName should be text'),
    );
    expect(() => Submission.parse('not a map'), _refused('no fields'));
  });
}
