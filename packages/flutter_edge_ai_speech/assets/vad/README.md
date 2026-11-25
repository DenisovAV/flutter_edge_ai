# Silero VAD (bundled)

`silero_vad_16k_v6.2.3.tflite` is the 16 kHz model of
[silero-vad](https://github.com/snakers4/silero-vad) v6.2.3 (MIT, © Silero Team,
`LICENSE.silero_vad`), exported to LiteRT with its state as an explicit tensor by
anira-project: [huggingface.co/anira-project/silero-vad](https://huggingface.co/anira-project/silero-vad)
at revision `c302618523e14ea1a7a919df1b796096186513bb`, file `litert/silero_vad_16k.tflite`
(the export and its scripts are MIT too).

- 1,254,896 bytes, SHA-256 `dfb2e98438dede7718e33cb3a63863b333b82e486ba122ebb803551094d488e9`
  (held by `test/vad/vad_model_asset_test.dart`).
- One signature: `audio [1,1,512]` and `state [1,320]` in, `probability [1,1,1]` and
  `state [1,320]` out, float32. The state is the LSTM's h and c and the last 64 samples
  of the previous frame; a stream starts from zeros.
- On anira's test signal (float32) Google's Python LiteRT (`ai-edge-litert` 2.4.0) gives
  anira's ONNX Runtime golden within 1.9e-5 over 178 frames. Through this package (16-bit
  PCM in, `VoiceActivityDetector.probabilities`) it is checked against the same Python run
  on the same 16-bit samples by
  `packages/flutter_edge_ai/example/integration_test/vad_test.dart`.
