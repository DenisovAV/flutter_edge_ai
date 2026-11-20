// The AnyNative of this platform: the FFI runtime where dart:ffi exists, a
// refusing one on the web.
export 'web_runtime.dart'
    if (dart.library.ffi) 'ffi_runtime.dart'
    show createAnyNative;
