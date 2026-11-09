/// Sends a showcase submission to the `submitShowcaseApp` function: the
/// browser implementation, or a stub for the prerendering server.
library;

export 'submit_api_stub.dart' if (dart.library.js_interop) 'submit_api_web.dart';
export 'submit_exception.dart';
