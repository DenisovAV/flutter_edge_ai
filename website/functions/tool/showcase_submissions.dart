/// Reads and reviews the showcase submissions in Firestore.
///
/// Runs on the owner's machine with gcloud's Application Default
/// Credentials (`gcloud auth application-default login`):
///
/// ```sh
/// dart run tool/showcase_submissions.dart              # pending ones
/// dart run tool/showcase_submissions.dart --all        # every status
/// dart run tool/showcase_submissions.dart approve play:rw.flipper
/// dart run tool/showcase_submissions.dart reject play:rw.flipper
/// ```
///
/// Approving only records the decision: the app goes on the page as a
/// `ShowcaseApp` in `website/lib/showcase/showcase_apps.dart`, through a PR.
library;

import 'dart:io';

import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:google_cloud_firestore/google_cloud_firestore.dart' hide Credential;

/// The site's project; `GOOGLE_CLOUD_PROJECT` overrides it, e.g. for the
/// emulator together with `FIRESTORE_EMULATOR_HOST`.
final _projectId = Platform.environment['GOOGLE_CLOUD_PROJECT'] ?? 'aichat-c0c27';
const _collection = 'showcaseSubmissions';

Future<void> main(List<String> args) async {
  final app = FirebaseApp.initializeApp(
    options: AppOptions(credential: Credential.fromApplicationDefaultCredentials(), projectId: _projectId),
  );
  final submissions = app.firestore().collection(_collection);
  switch (args) {
    case [] || ['--all']:
      final snapshot = await submissions.get();
      final docs = [
        for (final doc in snapshot.docs)
          if (args.isNotEmpty || doc.data()['status'] == 'pending') doc,
      ]..sort((a, b) => _createdAt(a).compareTo(_createdAt(b)));
      if (docs.isEmpty) stdout.writeln('No ${args.isEmpty ? 'pending ' : ''}submissions.');
      for (final doc in docs) {
        stdout.writeln(_describe(doc.id, doc.data(), _createdAt(doc)));
      }
    case [final verb && ('approve' || 'reject'), final id]:
      final status = verb == 'approve' ? 'approved' : 'rejected';
      await submissions.doc(id).update({'status': status, 'reviewedAt': FieldValue.serverTimestamp});
      stdout.writeln('$id: $status');
    default:
      stderr.writeln('Usage: showcase_submissions.dart [--all] | approve <id> | reject <id>');
      exitCode = 64;
  }
  await app.close();
}

DateTime _createdAt(QueryDocumentSnapshot<DocumentData> doc) =>
    (doc.data()['createdAt'] as Timestamp?)?.toDate() ?? DateTime.fromMillisecondsSinceEpoch(0);

String _describe(String id, Map<String, Object?> data, DateTime createdAt) {
  final play = data['googlePlay'] as Map<String, Object?>?;
  final appStore = data['appStore'] as Map<String, Object?>?;
  return [
    '$id  [${data['status']}]  ${createdAt.toUtc().toIso8601String()}',
    '  name:       ${data['appName'] ?? appStore?['name'] ?? '-'}',
    if (play != null) '  play:       https://play.google.com/store/apps/details?id=${play['applicationId']}',
    if (appStore != null)
      '  app store:  https://apps.apple.com/app/id${appStore['id']} (${appStore['ratings']} ratings)',
    if (appStore?['artworkUrl'] case final String url) '  icon:       $url',
    '  packages:   ${(data['packages'] as List?)?.join(', ')}',
    if (data['source'] case {'repository': final repository, 'pubspecPath': final path, 'packages': final List found})
      '  source:     $repository ($path: ${found.join(', ')})',
    '  on device:  ${data['onDevice']}',
    '  contact:    ${data['email']}',
    '',
  ].join('\n');
}
