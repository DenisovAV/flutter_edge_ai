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
# Vendored frozen snapshot from google-ai-edge/litert-samples (samples/litert/text_to_speech_lm/python/qwen3_tts_pipeline.py), pinned 2026-08-03, for citation/reproducibility only — not maintained here.
"""Qwen3-TTS text-to-speech on LiteRT (host-orchestrated Compiled Model loop).

Qwen3-TTS generates speech as 12.5 Hz frames of 16 codec tokens: a Qwen3-style
talker LM predicts the first (semantic) codebook, a small "MTP" transformer
autoregressively predicts the 15 residual codebooks of each frame, and a codec
decoder turns the accumulated codes into 24 kHz PCM. LiteRT-LM's Engine decode
loop cannot express this structure yet (multi-codebook embedding aggregation,
per-frame inner loop, audio output), so this sample drives the three converted
.tflite graphs from a host-side Python loop, the same pattern as the Matcha-TTS
sample in this repository.

The graphs and host-side tables are published at
https://huggingface.co/litert-community/Qwen3-TTS-12Hz-0.6B-Base and were
converted with the scripts in `models/qwen/qwen3_tts/converted/`. The host
loop reproduces the PyTorch reference implementation token-for-token under
greedy decoding (waveform correlation 1.0).
"""

import dataclasses
import time

import numpy as np
import tokenizers

from ai_edge_litert.compiled_model import CompiledModel
from ai_edge_litert.options import CpuOptions
from ai_edge_litert.options import Options

# Talker codec-token vocabulary layout (ids >= 2048 are control tokens).
_CODEC_VOCAB = 3072
_CODEC_PAD = 2148
_CODEC_BOS = 2149
_CODEC_EOS = 2150
_CODEC_THINK = 2154
_CODEC_THINK_BOS = 2156
_CODEC_THINK_EOS = 2157
_CODEC_NOTHINK = 2155

# Text-side special tokens (Qwen2 BPE vocabulary).
_TTS_BOS = 151672
_TTS_EOS = 151673
_TTS_PAD = 151671

# Language id map from the model config (talker_config.codec_language_id).
LANGUAGE_IDS = {
    'chinese': 2055,
    'english': 2050,
    'german': 2053,
    'italian': 2070,
    'portuguese': 2071,
    'spanish': 2054,
    'japanese': 2058,
    'korean': 2064,
    'french': 2061,
    'russian': 2069,
}

_HIDDEN = 1024
_NUM_CODE_GROUPS = 16
_FRAME_RATE_HZ = 12.5
_SAMPLE_RATE = 24000
_UPSAMPLE = 1920  # codec frames -> PCM samples
_NEG_INF = -1e9


@dataclasses.dataclass
class SynthesisResult:
    """Synthesized audio plus timing metadata.

    Attributes:
        waveform: Mono float32 PCM in [-1, 1] at 24 kHz.
        sample_rate: Output sample rate in Hz (always 24000).
        num_frames: Number of generated 12.5 Hz codec frames.
        prefill_seconds: Wall time of the prompt prefill.
        talker_seconds: Wall time spent in talker decode calls.
        mtp_seconds: Wall time spent in the MTP inner loops.
        codec_seconds: Wall time of codec decoding.
    """

    waveform: np.ndarray
    sample_rate: int
    num_frames: int
    prefill_seconds: float
    talker_seconds: float
    mtp_seconds: float
    codec_seconds: float

    @property
    def rtf(self) -> float:
        """Real-time factor (wall time / audio duration)."""
        wall = (self.prefill_seconds + self.talker_seconds +
                self.mtp_seconds + self.codec_seconds)
        return wall / (len(self.waveform) / self.sample_rate)


class Qwen3TtsPipeline:
    """Host-orchestrated Qwen3-TTS pipeline over three LiteRT graphs.

    The pipeline owns the tokenizer, the embedding tables (kept host-side as
    NumPy arrays) and three compiled models: talker (prefill_32 + decode
    signatures with an explicit KV cache), MTP decode step, and the codec
    decoder. `synthesize()` runs the full text-to-waveform loop.
    """

    def __init__(self,
                 model_dir: str,
                 talker_file: str = 'talker_int4.tflite',
                 num_threads: int = 8,
                 mtp_threads: int = 1):
        """Loads graphs and host tables.

        Args:
            model_dir: Directory with the published model files (see the
                Hugging Face repo layout).
            talker_file: Talker .tflite file name; `talker_int4.tflite`
                (smaller, faster) or `talker_fp32.tflite` (bit-exact vs the
                PyTorch reference under greedy decoding).
            num_threads: XNNPACK threads for the talker and codec graphs.
            mtp_threads: XNNPACK threads for the small MTP graph (1 is
                fastest in practice; its matmuls are too small to scale).
        """
        self._tokenizer = tokenizers.Tokenizer.from_file(
            f'{model_dir}/tokenizer.json')

        self._codec_emb = _load_fp32(
            f'{model_dir}/tables/codec_embedding_fp32.npy')
        self._mtp_emb = _load_fp32(
            f'{model_dir}/tables/mtp_embeddings_fp16.npy')
        # The 1.2 GB (fp32) text embedding stays memory-mapped; rows are
        # up-cast on lookup.
        self._text_emb = np.load(
            f'{model_dir}/tables/text_embedding_fp16.npy', mmap_mode='r')
        proj = np.load(f'{model_dir}/tables/text_projection_fp32.npz')
        self._proj_w1, self._proj_b1 = proj['w1'], proj['b1']
        self._proj_w2, self._proj_b2 = proj['w2'], proj['b2']

        talker = CompiledModel.from_file(f'{model_dir}/{talker_file}',
                                         options=_cpu_options(num_threads))
        self._prefill = _SignatureRunner(talker, 'prefill_32')
        self._decode = _SignatureRunner(talker, 'decode')
        self._kv_names = [n for n in self._decode.get_input_details()
                          if n.startswith('kv_cache')]
        self._cache_len = self._decode.get_input_details()['mask']['shape'][-1]

        mtp = CompiledModel.from_file(f'{model_dir}/mtp_fp32.tflite',
                                      options=_cpu_options(mtp_threads))
        self._mtp = _SignatureRunner(mtp)
        self._mtp_cache_len = self._mtp.get_input_details()['args_2'][
            'shape'][-1]
        self._mtp_kv_shape = self._mtp.get_input_details()['args_3']['shape']

        codec = CompiledModel.from_file(
            f'{model_dir}/codec_decoder_fp32.tflite',
            options=_cpu_options(num_threads))
        self._codec = _SignatureRunner(codec)
        self._codec_chunk = self._codec.get_input_details()['args_0'][
            'shape'][-1]

    def synthesize(self,
                   text: str,
                   speaker_embedding: np.ndarray,
                   language: str = 'english',
                   do_sample: bool = True,
                   top_k: int = 50,
                   temperature: float = 0.9,
                   repetition_penalty: float = 1.05,
                   max_frames: int = 512,
                   seed: int | None = None) -> SynthesisResult:
        """Synthesizes speech for `text` in the given voice.

        Args:
            text: Text to speak.
            speaker_embedding: 1024-d x-vector of the target voice (see
                `models/qwen/qwen3_tts/converted/extract_speaker_embedding.py`
                to enroll a new voice from ~3 s of reference audio).
            language: One of LANGUAGE_IDS keys, or 'auto'.
            do_sample: Sample with top-k/temperature (the model default) if
                True; greedy argmax (deterministic, matches the PyTorch
                reference token-for-token) if False.
            top_k: Top-k for sampling on both talker and MTP.
            temperature: Sampling temperature on both talker and MTP.
            repetition_penalty: HF-semantics penalty over the generated
                first-codebook history.
            max_frames: Frame cap (512 frames = ~41 s of audio).
            seed: RNG seed for sampling.

        Returns:
            A SynthesisResult with the waveform and stage timings.

        Raises:
            ValueError: If `language` is not supported.
        """
        if language != 'auto' and language.lower() not in LANGUAGE_IDS:
            raise ValueError(
                f'language must be "auto" or one of {sorted(LANGUAGE_IDS)}')
        rng = np.random.default_rng(seed)

        prefill, trailing, tts_pad = self._build_prompt(
            text, speaker_embedding, language)

        t0 = time.time()
        kv = {n: np.zeros(self._decode.get_input_details()[n]['shape'],
                          np.float32) for n in self._kv_names}
        kv = self._run_prefill(kv, prefill)
        pos = prefill.shape[1] - 1
        logits, hidden, kv = self._run_decode(kv, prefill[0, -1], pos)
        prefill_s = time.time() - t0

        suppress = np.zeros(_CODEC_VOCAB, np.float32)
        suppress[2048:] = _NEG_INF
        suppress[_CODEC_EOS] = 0.0

        frames = []
        history = set()
        talker_s = mtp_s = 0.0
        while len(frames) < max_frames:
            scores = logits + suppress
            if len(frames) < 2:  # min_new_tokens=2
                scores[_CODEC_EOS] = _NEG_INF
            for token in history:
                scores[token] = (scores[token] / repetition_penalty
                                 if scores[token] > 0
                                 else scores[token] * repetition_penalty)
            cb0 = _pick(scores, do_sample, top_k, temperature, rng)
            history.add(cb0)
            if cb0 == _CODEC_EOS:
                break

            t0 = time.time()
            residual = self._run_mtp(hidden, cb0, do_sample, top_k,
                                     temperature, rng)
            mtp_s += time.time() - t0
            frames.append([cb0] + residual)

            embed = (self._codec_emb[cb0] +
                     self._mtp_emb[np.arange(15), residual].sum(0))
            step = len(frames) - 1
            embed += trailing[step] if step < len(trailing) else tts_pad
            pos += 1
            t0 = time.time()
            logits, hidden, kv = self._run_decode(kv, embed, pos)
            talker_s += time.time() - t0

        t0 = time.time()
        waveform = self._decode_codes(np.array(frames, np.int32))
        codec_s = time.time() - t0

        return SynthesisResult(waveform=waveform, sample_rate=_SAMPLE_RATE,
                               num_frames=len(frames),
                               prefill_seconds=prefill_s,
                               talker_seconds=talker_s, mtp_seconds=mtp_s,
                               codec_seconds=codec_s)

    def _project_text(self, rows: np.ndarray) -> np.ndarray:
        """Applies the 2048->1024 text projection MLP (SiLU)."""
        h = rows @ self._proj_w1.T + self._proj_b1
        h = h / (1.0 + np.exp(-h))  # SiLU: x * sigmoid(x)
        return (h @ self._proj_w2.T + self._proj_b2).astype(np.float32)

    def _embed_text(self, ids: np.ndarray) -> np.ndarray:
        """Looks up and projects text-embedding rows to talker space."""
        rows = np.asarray(self._text_emb[ids], np.float32)
        return self._project_text(rows)

    def _build_prompt(self, text: str, speaker_embedding: np.ndarray,
                      language: str):
        """Builds prefill embeddings and the streamed text conditioning.

        Mirrors the reference `Qwen3TTSForConditionalGeneration.generate`
        prompt assembly for x-vector voice cloning in streaming mode.

        Returns:
            (prefill [1, P, 1024], trailing [L, 1024], tts_pad [1024]).
        """
        ids = np.array(self._tokenizer.encode(
            f'<|im_start|>assistant\n{text}<|im_end|>\n'
            '<|im_start|>assistant\n').ids)

        tts_bos, tts_eos, tts_pad = self._embed_text(
            np.array([_TTS_BOS, _TTS_EOS, _TTS_PAD]))
        if language == 'auto':
            control = [_CODEC_NOTHINK, _CODEC_THINK_BOS, _CODEC_THINK_EOS]
        else:
            control = [_CODEC_THINK, _CODEC_THINK_BOS,
                       LANGUAGE_IDS[language.lower()], _CODEC_THINK_EOS]
        codec_pre = np.concatenate([
            self._codec_emb[control],
            speaker_embedding.reshape(1, _HIDDEN).astype(np.float32),
            self._codec_emb[[_CODEC_PAD, _CODEC_BOS]],
        ], 0)

        role = self._embed_text(ids[:3])  # <|im_start|>assistant\n
        pads = np.repeat(tts_pad[None], len(codec_pre) - 2, 0)
        body = np.concatenate([pads, tts_bos[None]], 0) + codec_pre[:-1]
        first_text = self._embed_text(ids[3:4]) + codec_pre[-1:]
        prefill = np.concatenate([role, body, first_text], 0)[None]
        trailing = np.concatenate(
            [self._embed_text(ids[4:-5]), tts_eos[None]], 0)
        return prefill.astype(np.float32), trailing, tts_pad

    def _run_prefill(self, kv, prefill: np.ndarray):
        """Prefills the talker KV cache (32-token signature, right-padded)."""
        p = prefill.shape[1]
        if p > 32:
            raise ValueError(f'prompt too long for prefill_32: {p}')
        buf = np.zeros((1, 32, _HIDDEN), np.float32)
        buf[:, :p] = prefill
        mask = np.full((1, 1, 32, self._cache_len), _NEG_INF, np.float32)
        for i in range(32):
            mask[0, 0, i, :min(i, p - 1) + 1] = 0.0
        out = self._prefill(embeddings=buf,
                            input_pos=np.arange(32, dtype=np.int32),
                            mask=mask, **kv)
        return out

    def _run_decode(self, kv, embed: np.ndarray, pos: int):
        """One talker decode step; returns (cb0 logits, hidden, new kv)."""
        mask = np.full((1, 1, 1, self._cache_len), _NEG_INF, np.float32)
        mask[..., :pos + 1] = 0.0
        out = self._decode(
            embeddings=embed.reshape(1, 1, _HIDDEN).astype(np.float32),
            input_pos=np.array([pos], np.int32), mask=mask, **kv)
        logits = out.pop('logits')[0, 0]
        # The exported lm_head is [codec logits (3072) | identity (1024)]:
        # the tail carries the last hidden state, which seeds the MTP.
        return logits[:_CODEC_VOCAB], logits[_CODEC_VOCAB:], out

    def _run_mtp(self, hidden: np.ndarray, cb0: int, do_sample: bool,
                 top_k: int, temperature: float, rng) -> list[int]:
        """Runs the 15-step MTP inner loop for one frame.

        The MTP graph is a single decode step over a 17-slot KV cache; it is
        invoked 17 times per frame: two seed feeds (talker hidden state, cb0
        embedding), then one feed per residual codebook. Step k uses
        embedding table k-1 and lm_head k (the graph outputs all 15 heads;
        the host picks).

        Args:
            hidden: Talker last hidden state for this frame [1024].
            cb0: Sampled first-codebook token id.
            do_sample: Sampling vs greedy for the residual codebooks.
            top_k: Top-k for sampling.
            temperature: Sampling temperature.
            rng: NumPy random generator.

        Returns:
            The 15 residual codebook token ids.
        """
        cache = self._mtp_cache_len
        k_all = np.zeros(self._mtp_kv_shape, np.float32)
        v_all = np.zeros_like(k_all)
        feeds = [hidden, self._codec_emb[cb0]]
        codes = []
        for t in range(_NUM_CODE_GROUPS):
            embed = (feeds[t] if t < 2 else
                     self._mtp_emb[t - 2][codes[-1]]).reshape(1, 1, _HIDDEN)
            mask = np.where(np.arange(cache) <= t, 0.0,
                            _NEG_INF).astype(np.float32).reshape(1, 1, 1, -1)
            out = self._mtp(args_0=embed.astype(np.float32),
                            args_1=np.array([t], np.int32), args_2=mask,
                            args_3=k_all, args_4=v_all)
            k_all, v_all = out['output_1'], out['output_2']
            if t >= 1:
                codes.append(_pick(out['output_0'][t - 1], do_sample, top_k,
                                   temperature, rng))
        return codes

    def _decode_codes(self, codes: np.ndarray) -> np.ndarray:
        """Decodes [T, 16] codec frames to PCM with chunking + left context."""
        chunk, ctx = self._codec_chunk, 25
        pieces = []
        i = 0
        while i < len(codes):
            c = min(ctx, i)
            # Window = left context + new frames must fit the fixed-T graph, so
            # advance by at most (chunk - c) new frames per step.
            j = min(i + chunk - c, len(codes))
            window = codes[i - c:j]
            buf = np.zeros((1, _NUM_CODE_GROUPS, chunk), np.int32)
            buf[0, :, :len(window)] = window.T
            out = self._codec(args_0=buf)
            wav = next(iter(out.values()))[0, 0]
            pieces.append(wav[c * _UPSAMPLE:len(window) * _UPSAMPLE])
            i = j
        return np.concatenate(pieces)


class _SignatureRunner:
    """Callable wrapper over one CompiledModel signature.

    Runs a signature as a plain function call (NumPy arrays in by input name,
    dict of NumPy arrays out by output name) on top of the CompiledModel
    named-buffer API. The tensor buffers are created once and rewritten on
    every invocation, which keeps the per-step decode loops allocation-free.
    """

    def __init__(self, model: CompiledModel,
                 signature_key: str | None = None):
        if signature_key is None:
            signature_key = next(iter(model.get_signature_list()))
        self._model = model
        self._signature_key = signature_key
        self._input_details = model.get_input_tensor_details(signature_key)
        self._output_details = model.get_output_tensor_details(signature_key)
        self._input_buffers = {
            name: model.create_input_buffer_by_name(signature_key, name)
            for name in self._input_details}
        self._output_buffers = {
            name: model.create_output_buffer_by_name(signature_key, name)
            for name in self._output_details}

    def get_input_details(self) -> dict:
        """Returns input tensor details (shape, dtype) keyed by input name."""
        return self._input_details

    def __call__(self, **inputs: np.ndarray) -> dict[str, np.ndarray]:
        for name, array in inputs.items():
            self._input_buffers[name].write(np.ascontiguousarray(array))
        self._model.run_by_name(self._signature_key, self._input_buffers,
                                self._output_buffers)
        outputs = {}
        for name, detail in self._output_details.items():
            shape = detail['shape']
            outputs[name] = self._output_buffers[name].read(
                int(np.prod(shape)), np.dtype(detail['dtype'])).reshape(shape)
        return outputs


def _cpu_options(num_threads: int) -> Options:
    """Builds CPU compilation options with the given XNNPACK thread count.

    Args:
        num_threads: Number of XNNPACK threads.

    Returns:
        LiteRT compilation Options targeting the CPU.
    """
    return Options(cpu_options=CpuOptions(num_threads=num_threads))


def _load_fp32(path: str) -> np.ndarray:
    """Loads an .npy table, up-casting fp16 storage to fp32.

    Args:
        path: Path to the .npy file.

    Returns:
        The table as a float32 numpy array.
    """
    return np.load(path).astype(np.float32)


def _pick(logits: np.ndarray, do_sample: bool, top_k: int,
          temperature: float, rng) -> int:
    """Greedy argmax or top-k/temperature sampling over logits.

    Args:
        logits: 1-D array of unnormalized token scores.
        do_sample: If False, returns the argmax.
        top_k: Keep only the top_k highest logits when sampling (0 = all).
        temperature: Softmax temperature used when sampling.
        rng: numpy random Generator used when sampling.

    Returns:
        The selected token id as a Python int.
    """
    if not do_sample:
        return int(np.argmax(logits))
    scaled = logits.astype(np.float64) / max(temperature, 1e-6)
    if top_k and top_k < len(scaled):
        kth = np.partition(scaled, -top_k)[-top_k]
        scaled = np.where(scaled < kth, -np.inf, scaled)
    scaled -= scaled.max()
    probs = np.exp(scaled)
    probs /= probs.sum()
    return int(rng.choice(len(probs), p=probs))
