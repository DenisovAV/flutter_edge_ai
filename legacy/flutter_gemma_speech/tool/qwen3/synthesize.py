# Copyright 2026 The Google AI Edge Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ==============================================================================
# Vendored frozen snapshot from google-ai-edge/litert-samples
# (samples/litert/text_to_speech_lm/python/synthesize.py), pinned 2026-08-03,
# for reference/reproducibility only — not maintained here.
r"""CLI for Qwen3-TTS on LiteRT.

Example:
    python synthesize.py \
        --text "Hello from LiteRT running fully on device." \
        --output hello.wav

The first run downloads ~1.4 GB (int4 talker + fp32 MTP/codec + tables) from
https://huggingface.co/litert-community/Qwen3-TTS-12Hz-0.6B-Base.
"""

import argparse
import time

import numpy as np
import soundfile

import qwen3_tts_pipeline

_HF_REPO = 'litert-community/Qwen3-TTS-12Hz-0.6B-Base'
_DEFAULT_FILES = [
    'talker_int4.tflite',
    'mtp_fp32.tflite',
    'codec_decoder_fp32.tflite',
    'tokenizer.json',
    'tables/*',
    'voices/*',
]


def _parse_args() -> argparse.Namespace:
    """Parses the command-line arguments.

    Returns:
        The parsed argparse namespace.
    """
    parser = argparse.ArgumentParser(description='Qwen3-TTS on LiteRT (CPU).')
    parser.add_argument('--text', required=True, help='Text to speak.')
    parser.add_argument('--output', default='output.wav',
                        help='Output wav path.')
    parser.add_argument('--model_dir', default=None,
                        help='Local model dir; downloads from Hugging Face '
                             'if omitted.')
    parser.add_argument('--language', default='english',
                        help='"auto" or one of: %s' %
                             ', '.join(sorted(
                                 qwen3_tts_pipeline.LANGUAGE_IDS)))
    parser.add_argument('--speaker', default=None,
                        help='Speaker x-vector .npy; defaults to the bundled '
                             'demo voice.')
    parser.add_argument('--talker', default='int4', choices=['int4', 'fp32'],
                        help='Talker variant. fp32 is bit-exact vs the '
                             'PyTorch reference under --greedy.')
    parser.add_argument('--greedy', action='store_true',
                        help='Deterministic greedy decoding instead of '
                             'sampling.')
    parser.add_argument('--seed', type=int, default=None,
                        help='Sampling seed.')
    parser.add_argument('--threads', type=int, default=8,
                        help='XNNPACK threads for talker/codec.')
    return parser.parse_args()


def main() -> None:
    """Synthesizes speech for --text and writes it to --output."""
    args = _parse_args()

    model_dir = args.model_dir
    if model_dir is None:
        import huggingface_hub  # Deferred: only needed for auto-download.
        files = list(_DEFAULT_FILES)
        if args.talker == 'fp32':
            files[0] = 'talker_fp32.tflite'
        model_dir = huggingface_hub.snapshot_download(
            _HF_REPO, allow_patterns=files)

    t0 = time.time()
    pipeline = qwen3_tts_pipeline.Qwen3TtsPipeline(
        model_dir, talker_file=f'talker_{args.talker}.tflite',
        num_threads=args.threads)
    print(f'Loaded in {time.time() - t0:.1f}s')

    speaker_path = args.speaker or f'{model_dir}/voices/demo_speaker.npy'
    speaker = np.load(speaker_path)

    result = pipeline.synthesize(args.text, speaker,
                                 language=args.language,
                                 do_sample=not args.greedy, seed=args.seed)
    soundfile.write(args.output, result.waveform, result.sample_rate)

    duration = len(result.waveform) / result.sample_rate
    print(f'Wrote {args.output}: {duration:.2f}s audio, '
          f'{result.num_frames} frames, RTF {result.rtf:.2f} '
          f'(prefill {result.prefill_seconds:.2f}s, '
          f'talker {result.talker_seconds:.2f}s, '
          f'mtp {result.mtp_seconds:.2f}s, '
          f'codec {result.codec_seconds:.2f}s)')


if __name__ == '__main__':
    main()
