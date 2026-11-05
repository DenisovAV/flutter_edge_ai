import 'package:firebase_functions/firebase_functions.dart';
import 'package:firebase_functions/logger.dart' as logger;
import 'package:google_cloud_firestore/google_cloud_firestore.dart' show FieldValue;
import 'package:http/http.dart' as http;
import 'package:showcase_functions/src/stores.dart';
import 'package:showcase_functions/src/submission.dart';

void main(List<String> args) async {
  final stores = StoreCheck(http.Client());
  await runFunctions((firebase) {
    // Called from flutteredge.ai/showcase/submit only: App Check refuses a
    // request without a token from the site, and the browser refuses every
    // other origin.
    firebase.https.onCall(
      name: 'submitShowcaseApp',
      options: const CallableOptions(
        region: Region(SupportedRegion.usCentral1),
        enforceAppCheck: EnforceAppCheck(true),
        cors: Cors(['https://flutteredge.ai']),
        maxInstances: Instances(2),
      ),
      (request, response) async {
        final Submission submission;
        final AppStoreApp? appStore;
        try {
          submission = Submission.parse(request.data);
          if (submission.googlePlayId case final id?) await stores.googlePlay(id);
          appStore = switch (submission.appStoreId) {
            final id? => await stores.appStore(id, country: submission.appStoreCountry),
            null => null,
          };
        } on SubmissionException catch (e) {
          throw HttpResponseException.badRequest(message: e.message);
        } on Exception catch (e, stackTrace) {
          logger.error('A store could not be checked', {'error': '$e'}, stackTrace);
          throw HttpResponseException.serviceUnavailable(message: 'The store could not be reached. Try again later.');
        }

        final document = firebase.adminApp.firestore().collection('showcaseSubmissions').doc(submission.documentId);
        try {
          await document.create({
            'status': 'pending',
            'createdAt': FieldValue.serverTimestamp,
            'email': submission.email,
            'appName': submission.appName,
            'packages': submission.packages.toList()..sort(),
            'onDevice': submission.onDevice,
            'googlePlay': switch (submission.googlePlayId) {
              final id? => {'applicationId': id},
              null => null,
            },
            'appStore': switch ((submission.appStoreId, appStore)) {
              (final id?, final app?) => {
                'id': id,
                'country': submission.appStoreCountry,
                'name': app.name,
                'ratings': app.ratings,
                'artworkUrl': app.artworkUrl,
              },
              _ => null,
            },
          });
        } catch (_) {
          // `create` refuses a document that exists, but the error is not the
          // same on every backend (ALREADY_EXISTS in Firestore, ABORTED in the
          // emulator), so the document itself says whether this was a repeat.
          if ((await document.get()).exists) {
            throw HttpResponseException.conflict(message: 'This app has already been submitted.');
          }
          rethrow;
        }
        return CallableResult({'id': submission.documentId});
      },
    );
  });
}
