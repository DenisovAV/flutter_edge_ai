/// Test-only checkpoint between profile resolution and a low-level operation.
///
/// It is intentionally absent from the package barrel. Production code leaves
/// it null; lifecycle regression tests use it to force a transition at the
/// otherwise single-isolate scheduling boundary.
Future<void> Function(String operation)?
qdrantProfileOperationCheckpointForTesting;
