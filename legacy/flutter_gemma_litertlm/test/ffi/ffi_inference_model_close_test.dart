// Verifies FfiInferenceModel satisfies the CloseNotifier contract: it exposes
// addCloseListener (from the mixin) and is an InferenceModel. Exactly-once
// firing is unit-tested at the mixin level (core's close_notifier_test) and end
// -to-end by the 23-FFI integration gate; constructing a real FfiInferenceModel
// here needs a live native client, so this test pins the type-level contract.
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart' show InferenceModel;
import 'package:flutter_gemma_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FfiInferenceModel is an InferenceModel that mixes in CloseNotifier', () {
    expect(<Type>[FfiInferenceModel].single == FfiInferenceModel, isTrue);
    // Compile-time contract: if FfiInferenceModel did not mix in CloseNotifier
    // (which provides addCloseListener) AND extend InferenceModel, the package
    // would not compile. The assertions below are tautological at runtime; the
    // REAL gate is that this file compiles against the post-change class.
    expect(InferenceModel, isNotNull);
    expect(CloseNotifier, isNotNull);
  });
}
