# Silero VAD (bundled)

`silero_vad_16k_v6.3.tflite` is the 16 kHz model of
[silero-vad](https://github.com/snakers4/silero-vad) v6.3 (MIT, © Silero Team,
`LICENSE.silero_vad`, copied from the same tag), exported to LiteRT for this package with
the state as an explicit tensor.

- Source: `src/silero_vad/data/silero_vad.jit` and `silero_vad.onnx` at silero-vad tag `v6.3`
  (commit `63d4a2a7bfce8cd9bb39ed8fa0afcb5236d73e01`; git blob ids `3d1aa724` and `f3aa68d9`
  checked against that tree).
- Export: anira-project's scripts (MIT), [anira-project/models](https://github.com/anira-project/models)
  `models/silero-vad/export/` at `04edd100eaf3d49e30160a47048b21f35102d882`:
  `export.py` (torch 2.12.0, onnx 1.23.2, onnxruntime 1.32.0) rebuilds the model in eager
  PyTorch from the TorchScript weights and checks it, then `export_litert.py` (litert-torch
  0.10.0, torch 2.14.1, ai-edge-litert 2.3.0) writes the `.tflite`.
- Checks the export printed: eager vs upstream TorchScript 1.19e-7 and vs upstream ONNX 1.55e-6
  (probabilities 0.002-0.992 on anira's test signal); this `.tflite` vs the exported ONNX 2.44e-6.
- 1,254,896 bytes, SHA-256 `01efcddffbff805ec147dba7983fc07cfd54464fbacfaf021877e991ae52b3b9`
  (held by `test/vad/vad_model_asset_test.dart`).
- One signature: `audio [1,1,512]` and `state [1,320]` in, `probability [1,1,1]` and
  `state [1,320]` out, float32. The state is the LSTM's h and c and the last 64 samples
  of the previous frame; a stream starts from zeros.
- Through this package (16-bit PCM in, `VoiceActivityDetector.probabilities`) it is checked
  against ai-edge-litert 2.3.0 running this file on the same 16-bit samples of anira's test
  signal by `packages/flutter_edge_ai/example/integration_test/vad_test.dart`.
