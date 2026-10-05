# gen_qwen3_goldens.py — run once; commits fixtures. Needs the recipe on PYTHONPATH
# and the talker_fp32 snapshot. Usage:
#   python gen_qwen3_goldens.py --recipe .../text_to_speech_lm/python --model_dir <snap> --out ../../test/golden/qwen3
import argparse, json, sys, time, numpy as np

def synthesize_logging(pipe, q, text, speaker, language, out, suffix='', write_frame0=True):
    """Verbatim copy of Qwen3TtsPipeline.synthesize (greedy) that also logs
    every frame and the frame-0 (hidden, cb0, residual).

    `suffix` picks the output basenames (`''` -> frames.json/waveform_f32.bin,
    the default 26-frame goldens; `'_long'` -> frames_long.json/
    waveform_long_f32.bin, the >128-frame multi-window codec golden) so both
    can be dumped from the same run without clobbering each other."""
    prefill, trailing, tts_pad = pipe._build_prompt(text, speaker, language)
    kv = {n: np.zeros(pipe._decode.get_input_details()[n]['shape'], np.float32) for n in pipe._kv_names}
    kv = pipe._run_prefill(kv, prefill)
    pos = prefill.shape[1] - 1
    logits, hidden, kv = pipe._run_decode(kv, prefill[0, -1], pos)
    suppress = np.zeros(q._CODEC_VOCAB, np.float32); suppress[2048:] = q._NEG_INF; suppress[q._CODEC_EOS] = 0.0
    frames, history, frame0 = [], set(), None
    while len(frames) < 512:
        scores = logits + suppress
        if len(frames) < 2: scores[q._CODEC_EOS] = q._NEG_INF
        for t in history:
            scores[t] = scores[t] / 1.05 if scores[t] > 0 else scores[t] * 1.05
        cb0 = int(np.argmax(scores)); history.add(cb0)
        if cb0 == q._CODEC_EOS: break
        residual = pipe._run_mtp(hidden, cb0, False, 50, 0.9, None)
        if frame0 is None:
            frame0 = {'hidden': [float(x) for x in hidden], 'cb0': cb0, 'residual': [int(x) for x in residual]}
        frames.append([cb0] + residual)
        embed = pipe._codec_emb[cb0] + pipe._mtp_emb[np.arange(15), residual].sum(0)
        step = len(frames) - 1
        embed += trailing[step] if step < len(trailing) else tts_pad
        pos += 1
        logits, hidden, kv = pipe._run_decode(kv, embed, pos)
    wav = pipe._decode_codes(np.array(frames, np.int32))
    json.dump({'frames': frames}, open(f'{out}/frames{suffix}.json','w'))
    if write_frame0:
        json.dump(frame0, open(f'{out}/frame0.json','w'))
    wav.astype(np.float32).tofile(f'{out}/waveform{suffix}_f32.bin')
    return wav, len(frames)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--recipe', required=True); ap.add_argument('--model_dir', required=True)
    ap.add_argument('--out', required=True); ap.add_argument('--text', default='Hello from on device text to speech.')
    # Longer paragraph for the codec multi-window golden (frames_long.json /
    # waveform_long_f32.bin / meta_long.json): greedy fp32 synthesis of this
    # text yields 135 frames (>128, so >64 = codecChunk, so `decodeCodes`'s
    # sliding-window loop runs 3 windows with a 25-frame left-context carry
    # between them, and the trailing window is a partial (< codecChunk)
    # window too) -- exercises the multi-window path the 26-frame golden
    # (well under codecChunk=64) never reaches.
    ap.add_argument(
        '--text_long',
        default=(
            'On-device text to speech lets an application turn written '
            'words into natural sounding audio.'
        ),
    )
    a = ap.parse_args(); sys.path.insert(0, a.recipe)
    import qwen3_tts_pipeline as q
    pipe = q.Qwen3TtsPipeline(a.model_dir, talker_file='talker_fp32.tflite', num_threads=8)
    speaker = np.load(f'{a.model_dir}/voices/demo_speaker.npy')

    tmpl = f'<|im_start|>assistant\n{a.text}<|im_end|>\n<|im_start|>assistant\n'
    ids = list(map(int, pipe._tokenizer.encode(tmpl).ids))
    json.dump({'template': tmpl, 'ids': ids}, open(f'{a.out}/ids.json','w'))

    # diverse BPE goldens — numbers, punctuation, unicode, contractions, multi-space, CJK
    cases = ["Hello, world!", "It's 3:47 PM — don't wait.", "Grüße aus München",
             "a   b\tc\nd", "1234567890", "naïve café", "你好，世界", "<|im_start|>plain</s>"]
    json.dump({c: list(map(int, pipe._tokenizer.encode(c).ids)) for c in cases},
              open(f'{a.out}/bpe_cases.json','w'))

    prefill, trailing, tts_pad = pipe._build_prompt(a.text, speaker, 'english')
    np.savez(f'{a.out}/prompt.npz', prefill=prefill.astype(np.float32),
             trailing=np.asarray(trailing, np.float32), tts_pad=tts_pad.astype(np.float32))
    np.save(f'{a.out}/embed_text.npy', pipe._embed_text(np.array(ids)).astype(np.float32))  # [len(ids)*? -> reshape [n,1024]]

    wav, nframes = synthesize_logging(pipe, q, a.text, speaker, 'english', a.out)
    json.dump({'text': a.text, 'language':'english', 'talker':'fp32', 'greedy':True,
               'speaker':'demo_speaker', 'num_frames': int(nframes), 'sample_rate': 24000},
              open(f'{a.out}/meta.json','w'))

    # Second, longer dump -- the >128-frame codec multi-window golden (see
    # the --text_long default's comment). Same fp32 talker, same greedy
    # decoding, same pipeline instance; only the output basenames differ.
    wav_long, nframes_long = synthesize_logging(
        pipe, q, a.text_long, speaker, 'english', a.out,
        suffix='_long', write_frame0=False)
    json.dump({'text': a.text_long, 'language':'english', 'talker':'fp32', 'greedy':True,
               'speaker':'demo_speaker', 'num_frames': int(nframes_long), 'sample_rate': 24000},
              open(f'{a.out}/meta_long.json','w'))

if __name__ == '__main__': main()
