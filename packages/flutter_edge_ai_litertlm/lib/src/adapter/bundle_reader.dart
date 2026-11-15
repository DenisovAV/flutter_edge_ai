// The public `readLiteRtLmBundleInfo`, natively: the runtime's reader
// (bundle/litertlm_bundle_reader.dart) under the package's public types.

import 'package:litertlm_dart/litertlm_dart.dart';
import 'bundle_info.dart';

/// What the `.litertlm` file at [path] says about itself: its container
/// version, system metadata and sections, each `TFLiteModel` section with the
/// NPU it was compiled for. Reads the header and a few hundred bytes per
/// compiled section, never the weights.
///
/// A file shorter than its sections (a download that stopped early) is read
/// as far as it goes: [LiteRtLmBundleInfo.isComplete] is false, and the
/// sections past its end carry no NPU target.
///
/// Throws `FileSystemException` when the file cannot be opened, and
/// `LiteRtLmBundleException` when it is not a `.litertlm` container
/// (`LiteRtLmBundleProblem.notLitertlm`), is of a container version this
/// package does not read (`unsupportedVersion`), ends inside its own header
/// (`incomplete`), or has a header or compiler stamp out of range
/// (`malformed`).
Future<LiteRtLmBundleInfo> readLiteRtLmBundleInfo(String path) async =>
    LiteRtLmBundleInfo.of(await readBundleInfo(path));
