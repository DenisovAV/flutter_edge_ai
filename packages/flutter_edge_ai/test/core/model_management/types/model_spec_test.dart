@TestOn('!vm')
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/mobile/flutter_edge_ai_mobile.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';

void main() {
  group('ModelSpec Tests', () {
    group('InferenceModelSpec', () {
      test('creates valid inference model spec', () {
        final spec = InferenceModelSpec.fromLegacyUrl(
          name: 'test_model',
          modelUrl: 'https://example.com/model.bin',
        );

        expect(spec.type, ModelManagementType.inference);
        expect(spec.name, 'test_model');
        expect(spec.files.length, 1);
        expect(spec.files.first.filename, 'model.bin');
        expect(spec.files.first.isRequired, true);
        expect(spec.isValid, true);
      });

      test('creates inference model spec with LoRA', () {
        final spec = InferenceModelSpec.fromLegacyUrl(
          name: 'test_model',
          modelUrl: 'https://example.com/model.bin',
          loraUrl: 'https://example.com/lora.bin',
        );

        expect(spec.files.length, 2);
        expect(spec.files[0].filename, 'model.bin');
        // LoRA is a companion of the model — namespaced by the model's own
        // (unprefixed) basename so a shared LoRA filename can't collide
        // across two different base models.
        expect(spec.files[1].filename, 'model__lora.bin');
        expect(spec.files[0].isRequired, true);
        expect(spec.files[1].isRequired, false);
      });

      test('extracts filename from URL correctly', () {
        final spec = InferenceModelSpec.fromLegacyUrl(
          name: 'test_model',
          modelUrl:
              'https://huggingface.co/models/complex-path/model.bin?token=abc',
        );

        // Test via files list instead of deprecated getter
        expect(spec.files.first.filename, 'model.bin');
      });
    });

    group('EmbeddingModelSpec', () {
      test('creates valid embedding model spec', () {
        final spec = EmbeddingModelSpec.fromLegacyUrl(
          name: 'test_embedding',
          modelUrl: 'https://example.com/model.tflite',
          tokenizerUrl: 'https://example.com/tokenizer.json',
        );

        expect(spec.type, ModelManagementType.embedding);
        expect(spec.name, 'test_embedding');
        expect(spec.files.length, 2);
        expect(spec.files[0].filename, 'model.tflite');
        // Tokenizer is a companion — namespaced by the model's own basename.
        expect(spec.files[1].filename, 'model__tokenizer.json');
        expect(spec.files[0].isRequired, true);
        expect(spec.files[1].isRequired, true);
        expect(spec.isValid, true);
      });

      test('uses correct SharedPrefs keys', () {
        final spec = EmbeddingModelSpec.fromLegacyUrl(
          name: 'test_embedding',
          modelUrl: 'https://example.com/model.tflite',
          tokenizerUrl: 'https://example.com/tokenizer.json',
        );

        expect(spec.files[0].prefsKey, 'embedding_model_file');
        expect(spec.files[1].prefsKey, 'embedding_tokenizer_file');
      });
    });

    group('SttModelSpec', () {
      test('namespaces the tokenizer by the model, keeps model file plain', () {
        final spec = SttModelSpec(
          name: 'moonshine-tiny',
          modelSource: NetworkSource(
            'https://example.com/moonshine-tiny.tflite',
          ),
          tokenizerSource: NetworkSource('https://example.com/tokenizer.json'),
          sttModelType: SttModelType.moonshine,
        );

        expect(spec.type, ModelManagementType.stt);
        expect(spec.files.length, 2);
        expect(spec.files[0].filename, 'moonshine-tiny.tflite');
        expect(spec.files[1].filename, 'moonshine-tiny__tokenizer.json');
      });

      test(
        'moonshine and whisper tokenizers stay distinct despite the same basename',
        () {
          final moonshine = SttModelSpec(
            name: 'moonshine-tiny',
            modelSource: NetworkSource(
              'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_f32.tflite',
            ),
            tokenizerSource: NetworkSource(
              'https://huggingface.co/UsefulSensors/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json',
            ),
            sttModelType: SttModelType.moonshine,
          );
          final whisper = SttModelSpec(
            name: 'whisper-tiny',
            modelSource: NetworkSource(
              'https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_f32.tflite',
            ),
            tokenizerSource: NetworkSource(
              'https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json',
            ),
            sttModelType: SttModelType.whisper,
          );

          // Both source URLs end in literally 'tokenizer.json'.
          expect(
            moonshine.files[1].filename,
            isNot(equals(whisper.files[1].filename)),
          );
          expect(
            moonshine.files[1].filename,
            'moonshine_tiny_5s_f32__tokenizer.json',
          );
          expect(
            whisper.files[1].filename,
            'whisper_tiny_30s_f32__tokenizer.json',
          );
        },
      );
    });

    group(
      'Namespacing distinctness (embedding, the per-broad-type-would-fail case)',
      () {
        test('embeddinggemma and Gecko tokenizers stay distinct despite the SAME '
            'basename AND the same ModelManagementType.embedding', () {
          final embeddingGemma = EmbeddingModelSpec(
            name: 'embeddingGemma1024',
            modelSource: NetworkSource(
              'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/embeddinggemma-300M_seq1024_mixed-precision.tflite',
            ),
            tokenizerSource: NetworkSource(
              'https://huggingface.co/litert-community/embeddinggemma-300m/resolve/main/sentencepiece.model',
            ),
          );
          final gecko = EmbeddingModelSpec(
            name: 'Gecko_64_quant',
            modelSource: NetworkSource(
              'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/Gecko_64_quant.tflite',
            ),
            tokenizerSource: NetworkSource(
              'https://huggingface.co/litert-community/Gecko-110m-en/resolve/main/sentencepiece.model',
            ),
          );

          expect(
            embeddingGemma.files[1].filename,
            isNot(equals(gecko.files[1].filename)),
          );
          expect(
            embeddingGemma.files[1].filename,
            'embeddinggemma-300M_seq1024_mixed-precision__sentencepiece.model',
          );
          expect(
            gecko.files[1].filename,
            'Gecko_64_quant__sentencepiece.model',
          );
        });
      },
    );

    group('DownloadProgress', () {
      test('calculates overall progress correctly', () {
        // First file, 50% complete
        var progress = const DownloadProgress(
          currentFileIndex: 0,
          totalFiles: 2,
          currentFileProgress: 50,
          currentFileName: 'model.bin',
        );
        expect(progress.overallProgress, 25); // (0 + 0.5) / 2 * 100 = 25

        // Second file, 100% complete
        progress = const DownloadProgress(
          currentFileIndex: 1,
          totalFiles: 2,
          currentFileProgress: 100,
          currentFileName: 'tokenizer.json',
        );
        expect(progress.overallProgress, 100); // (1 + 1.0) / 2 * 100 = 100

        // All files complete
        progress = const DownloadProgress(
          currentFileIndex: 2,
          totalFiles: 2,
          currentFileProgress: 100,
          currentFileName: 'Complete',
        );
        expect(progress.overallProgress, 100);
      });

      test('handles edge cases', () {
        // No files
        var progress = const DownloadProgress(
          currentFileIndex: 0,
          totalFiles: 0,
          currentFileProgress: 0,
          currentFileName: 'none',
        );
        expect(progress.overallProgress, 0);

        // Progress over 100%
        progress = const DownloadProgress(
          currentFileIndex: 0,
          totalFiles: 1,
          currentFileProgress: 150,
          currentFileName: 'test',
        );
        expect(progress.overallProgress, 100); // Should be clamped
      });
    });
  });
}
