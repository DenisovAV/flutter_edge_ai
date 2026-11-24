// The default bound of `readBundleGenericData`, shared by its native arm and
// the web arm that refuses it (the signature is the same on both).

/// The largest section `readBundleGenericData` reads by default: a bigger
/// range is taken for a corrupt file rather than read into memory.
const maxGenericDataBytes = 4 << 20;
