import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:universal_web/web.dart' as web;

import 'submit_exception.dart';

/// The Firebase JS SDK, loaded only by the submit form and only for App
/// Check; nothing else on the site uses Firebase in the browser.
const _firebaseSdk = 'https://www.gstatic.com/firebasejs/13.1.0';

/// The reCAPTCHA Enterprise key that App Check is registered with for the
/// site's web app (score-based, flutteredge.ai only). A site key is public by
/// design.
const _appCheckSiteKey = '6LdoNREuAAAAAM_rdOsaoltvqSrclARakTkBHfyC';

/// The `submitShowcaseApp` function (website/functions), through the Hosting
/// rewrite in firebase.json: a Dart function cannot be called by name from
/// the Firebase SDKs, only by URL, and the rewrite keeps it same-origin.
const _submitPath = '/api/submit-showcase-app';

/// Sends a showcase submission to the function, with an App Check token.
///
class ShowcaseSubmitApi {
  JSObject? _appCheckModule;
  JSObject? _appCheck;

  /// Returns the id of the stored submission, or throws [SubmitException].
  Future<String> submit(Map<String, Object?> data) async {
    final token = await _appCheckToken();
    final headers = web.Headers()
      ..set('content-type', 'application/json')
      ..set('x-firebase-appcheck', token);
    final response = await web.window
        .fetch(
          _submitPath.toJS,
          web.RequestInit(
            method: 'POST',
            headers: headers,
            body: jsonEncode({'data': data}).toJS,
          ),
        )
        .toDart;
    final text = (await response.text().toDart).toDart;
    final Object? body;
    try {
      body = jsonDecode(text);
    } on FormatException {
      throw SubmitException(
        'The server answered ${response.status}. Try again later.',
      );
    }
    // The callable protocol: `{"result": …}` on success, `{"error": …}` with a
    // message otherwise.
    return switch (body) {
      {'result': {'id': final String id}} => id,
      {'error': {'message': final String message}} => throw SubmitException(
        message,
      ),
      _ => throw SubmitException(
        'The server answered ${response.status}. Try again later.',
      ),
    };
  }

  Future<String> _appCheckToken() async {
    var appCheck = _appCheck;
    var module = _appCheckModule;
    if (appCheck == null || module == null) {
      // Hosting serves the web app's config, so none of it is in the source.
      final config = await (await web.window.fetch('/__/firebase/init.json'.toJS).toDart).json().toDart;
      final appModule = await importModule('$_firebaseSdk/firebase-app.js'.toJS).toDart;
      module = await importModule('$_firebaseSdk/firebase-app-check.js'.toJS).toDart;
      final app = appModule.callMethod<JSObject>('initializeApp'.toJS, config);
      final provider = module
          .getProperty<JSFunction>('ReCaptchaEnterpriseProvider'.toJS)
          .callAsConstructor<JSObject>(_appCheckSiteKey.toJS);
      final options = JSObject()
        ..setProperty('provider'.toJS, provider)
        ..setProperty('isTokenAutoRefreshEnabled'.toJS, false.toJS);
      appCheck = module.callMethod<JSObject>(
        'initializeAppCheck'.toJS,
        app,
        options,
      );
      _appCheckModule = module;
      _appCheck = appCheck;
    }
    final result = await module.callMethod<JSPromise<JSObject>>('getToken'.toJS, appCheck).toDart;
    return result.getProperty<JSString>('token'.toJS).toDart;
  }
}
