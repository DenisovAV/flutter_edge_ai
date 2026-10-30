import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';

/// The `filename` a restored inference spec passes for an install recorded
/// under [filename]: [filename] when it is not [source]'s own file name (a
/// `fromNetwork(filename:)` install, whose name was checked when it was
/// installed), else null — a name the source gives was never checked as a
/// name of its own, and a restore does not start refusing it.
String? renamedFrom(ModelSource source, String filename) =>
    InferenceModelFile.fromSource(source).filename == filename
    ? null
    : filename;
