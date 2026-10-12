/// `dart:js_interop` helpers for the web arms of engine packages.
///
/// Import only from files that compile for web alone: the web arm of a
/// conditional import or export. Usually that is the DEFAULT branch of a
/// directive whose condition is `dart.library.ffi` or `dart.library.io` (false
/// on web), e.g. `export 'src/engine_web.dart' if (dart.library.ffi)
/// 'src/engine_io.dart';`; sometimes it is the `if (dart.library.js_interop)`
/// branch. It imports `dart:js_interop`, so keep it off native code paths. The
/// web-safe engine SPI is `engine.dart`; `tool/check_web_graph.dart` walks the
/// web branch of every public library.
library;

export 'src/web/web_model_source.dart'
    show
        BlobUrlModelSource,
        OpfsStreamModelSource,
        WebModelSource,
        WebModelSourceResolver;
export 'src/web/web_model_url.dart' show resolveWebModelUrl;
