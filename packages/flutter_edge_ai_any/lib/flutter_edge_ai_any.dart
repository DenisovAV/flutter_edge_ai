/// flutter_edge_ai_any: the native layer only, so far.
///
/// libany_shim (native/any_shim) runs any-sync-sdk and an any-store local
/// index in process; lib/src/ffi binds it. Nothing is exported yet: the
/// public API (spaces, sync, the RAG provider) is a separate decision, and
/// so is the network it may use. See README.md.
library;
