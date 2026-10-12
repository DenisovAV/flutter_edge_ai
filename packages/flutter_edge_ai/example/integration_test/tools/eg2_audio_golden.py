"""The EmbeddingGemma 2 audio and combined-input golden (R5 §10.4), measured the
way the earlier EG2 goldens were (eg2_design_backup/measurements/eg2common.py,
RawEngine): Google's `litert-lm` 0.18.0 wheel from PyPI, its own native
library driven over the LiteRT-LM C API with ctypes, on the 740m bundle, CPU.

Engine settings mirror flutter_edge_ai_litertlm's `.litertlm` pass: backend
"cpu", NULL vision and audio backends (present towers run on the main one),
max_input_length 1024, 140 vision tokens per image, a writable cache dir;
options normalize on, special tokens on, overflow strategy 1 (truncate: what
the pass uses; nothing here is near the limit), output size unset.

With a second argument — our libLiteRtLm build — every item is embedded again
through it, in a separate process, and stored as `vector_native` next to the
wheel's `vector`: the wheel is the reference, our build is what the device
suites run (on macOS the device suite reproduces `vector_native` to 0.9999).
Our build and the wheel agree on text bit for bit but not on audio (measured:
cos 0.97-0.997 per clip), and the wheel does not even agree with itself on
audio: two runs of it give cos 0.99-0.9998 per clip, while our build is bit for
bit the same run to run and at any thread count. The cause is the model: the
740m's audio encoder quantizes its activations to int8 (120 QUANTIZE ops,
scales 0.1-0.3), so a last-bit fp32 difference — another XNNPACK kernel, the
wheel's thread-dependent sums, or one input sample changed by 1 — flips some
roundings (±1 LSB dither moves a clip by cos 0.95-0.997 in either build). So a
suite that only had the wheel's vectors could not tell a regression from that
noise. The wheel's own run-to-run spread is measured here (a second run in
another process) and recorded.

Reads the clips generate_eg2_audio_clips.py wrote (example/assets/eg2_audio/)
and two of the vision scenes (example/assets/eg2_vision/), and writes:
- integration_test/goldens/eg2_audio_golden.json
- integration_test/goldens/eg2_audio_golden.dart (the same JSON as a Dart
  string, so a phone can read it; example/test/eg2_audio_golden_test.dart
  checks the two agree and that the clips are the ones measured)

Vectors are base64 little-endian float32, as the image golden's.

usage: <venv with litert-lm==0.18.0 and numpy>/bin/python -I eg2_audio_golden.py \\
           <path to embeddinggemma-2-740m.litertlm> [<our libLiteRtLm>]
"""
import base64
import ctypes
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
from importlib.metadata import version

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
EXAMPLE = os.path.join(HERE, "..", "..")
AUDIO = os.path.join(EXAMPLE, "assets", "eg2_audio")
VISION = os.path.join(EXAMPLE, "assets", "eg2_vision")
GOLDENS = os.path.join(HERE, "..", "goldens")

sys.path.insert(0, HERE)
from generate_eg2_audio_clips import SPEECH  # noqa: E402

BUNDLE = {
    "repo": "litert-community/embeddinggemma-2-740m-litert-lm",
    "file": "embeddinggemma-2-740m.litertlm",
    "revision": "24d962e906c7d332c6428e71c9676855024569e2",
    "sha256": "e7a8a2204b91e0f96e92960e84a09a89212e1633dcb7575a9bf3378b4df77f4c",
}
# TaskType prefixes (core's TaskType.prefix; google/embeddinggemma-2
# config_sentence_transformers.json @914f7f89).
QUERY = "task: search result | query: "
DOCUMENT = "title: none | text: "

COMBINED = [
    # (id, text with its prefix, images, audio, what it is)
    ("text_image", DOCUMENT + "a red stop sign", ["stop_sign.png"], None,
     "retrievalDocument text + one image"),
    ("text_audio", DOCUMENT + "a voice command for the smart home", [], "kitchen_lights.wav",
     "retrievalDocument text + one clip"),
    ("image_audio", None, ["house_scene.png"], "weather_paris.wav", "one image + one clip"),
    ("text_image_audio", DOCUMENT + "a trip to Paris", ["house_scene.png"], "weather_paris.wav",
     "retrievalDocument text + one image + one clip"),
]
VARIANTS = ["kitchen_lights_44k_stereo.wav", "kitchen_lights.mp3", "kitchen_lights.flac"]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def b64(vector):
    return base64.b64encode(np.asarray(vector, dtype="<f4").tobytes()).decode()


def cos(a, b):
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def _bind(lib):
    """C signatures for a libLiteRtLm loaded with ctypes (the wheel's own
    loader sets the same ones)."""
    vp, cp, i, b, sz = ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_bool, ctypes.c_size_t
    for name, (res, args) in {
        "litert_lm_get_last_error_code": (i, []),
        "litert_lm_get_last_error_message": (cp, []),
        "litert_lm_clear_last_error": (None, []),
        "litert_lm_embedding_engine_settings_create": (vp, [cp, cp, cp, cp]),
        "litert_lm_embedding_engine_settings_delete": (None, [vp]),
        "litert_lm_embedding_engine_settings_set_cache_dir": (None, [vp, cp]),
        "litert_lm_embedding_engine_settings_set_max_input_length": (None, [vp, i]),
        "litert_lm_embedding_engine_settings_set_vision_tokens_per_image": (None, [vp, i]),
        "litert_lm_embedding_engine_create": (vp, [vp]),
        "litert_lm_embedding_engine_delete": (None, [vp]),
        "litert_lm_embedding_options_create": (vp, []),
        "litert_lm_embedding_options_delete": (None, [vp]),
        "litert_lm_embedding_options_set_normalize": (None, [vp, b]),
        "litert_lm_embedding_options_set_insert_special_tokens": (None, [vp, b]),
        "litert_lm_embedding_options_set_input_overflow_strategy": (None, [vp, i]),
        "litert_lm_input_data_create": (vp, [i, cp, sz]),
        "litert_lm_input_data_delete": (None, [vp]),
        "litert_lm_embedding_engine_compute_embedding": (vp, [vp, ctypes.POINTER(vp), sz, vp]),
        "litert_lm_embedding_response_get_size": (sz, [vp]),
        "litert_lm_embedding_response_get_values": (ctypes.POINTER(ctypes.c_float), [vp]),
        "litert_lm_embedding_response_delete": (None, [vp]),
    }.items():
        f = getattr(lib, name)
        f.restype, f.argtypes = res, args
    return lib


class Engine:
    """A libLiteRtLm over the C API (the RawEngine of the measurements), with
    the pass's settings: the wheel's own library, or [dylib]."""

    def __init__(self, model_path, cache_dir, dylib=None):
        from litert_lm._ffi import InputDataType, _get_lib

        lib = _bind(_get_lib() if dylib is None else ctypes.CDLL(dylib))
        self.lib, self.types = lib, InputDataType
        s = lib.litert_lm_embedding_engine_settings_create(model_path.encode(), b"cpu", None, None)
        if not s:
            raise RuntimeError(self._error("settings_create"))
        try:
            lib.litert_lm_embedding_engine_settings_set_cache_dir(s, cache_dir.encode())
            lib.litert_lm_embedding_engine_settings_set_max_input_length(s, 1024)
            lib.litert_lm_embedding_engine_settings_set_vision_tokens_per_image(s, 140)
            self.engine = lib.litert_lm_embedding_engine_create(s)
            if not self.engine:
                raise RuntimeError(self._error("engine_create"))
        finally:
            lib.litert_lm_embedding_engine_settings_delete(s)

    def _error(self, where):
        message = self.lib.litert_lm_get_last_error_message()
        return f"{where}: code {self.lib.litert_lm_get_last_error_code()} {message!r}"

    def embed(self, text=None, images=(), audio=None):
        """One vector: the text part, then the images, then the audio — the
        order of flutter_edge_ai_litertlm's embeddingParts."""
        lib, t = self.lib, self.types
        parts = []
        if text is not None:
            parts.append((t.TEXT, text.encode("utf-8")))
        parts += [(t.IMAGE, image) for image in images]
        if audio is not None:
            parts.append((t.AUDIO, audio))
        options = lib.litert_lm_embedding_options_create()
        created = []
        try:
            lib.litert_lm_embedding_options_set_normalize(options, True)
            lib.litert_lm_embedding_options_set_insert_special_tokens(options, True)
            lib.litert_lm_embedding_options_set_input_overflow_strategy(options, 1)
            for kind, data in parts:
                created.append(lib.litert_lm_input_data_create(kind, data, len(data)))
            array = (ctypes.c_void_p * len(created))(*created)
            lib.litert_lm_clear_last_error()
            response = lib.litert_lm_embedding_engine_compute_embedding(self.engine, array, len(created), options)
            if not response:
                raise RuntimeError(self._error("compute_embedding"))
            try:
                n = lib.litert_lm_embedding_response_get_size(response)
                values = lib.litert_lm_embedding_response_get_values(response)
                return np.array([values[i] for i in range(n)], dtype=np.float32)
            finally:
                lib.litert_lm_embedding_response_delete(response)
        finally:
            lib.litert_lm_embedding_options_delete(options)
            for handle in created:
                lib.litert_lm_input_data_delete(handle)

    def close(self):
        self.lib.litert_lm_embedding_engine_delete(self.engine)


def read(directory, name):
    with open(os.path.join(directory, name), "rb") as f:
        return f.read()


def measure_native(model_path, dylib, out_path):
    """Every item through [dylib], as base64 vectors keyed like the golden."""
    engine = Engine(model_path, tempfile.mkdtemp(prefix="eg2_audio_native_"),
                    None if dylib == "wheel" else dylib)
    try:
        out = {
            "clips": {n: b64(engine.embed(audio=read(AUDIO, f"{n}.wav"))) for n, _, _ in SPEECH},
            "variants": {f: b64(engine.embed(audio=read(AUDIO, f))) for f in VARIANTS},
            "combined": {
                cid: b64(engine.embed(
                    text=text,
                    images=[read(VISION, image) for image in images],
                    audio=None if audio is None else read(AUDIO, audio),
                ))
                for cid, text, images, audio, _ in COMBINED
            },
        }
    finally:
        engine.close()
    with open(out_path, "w") as f:
        json.dump(out, f)


def main(model_path, dylib=None):
    if sha256(model_path) != BUNDLE["sha256"]:
        raise SystemExit(f"{model_path} is not the pinned 740m bundle")
    def separate_run(library):
        # A separate process: two libLiteRtLm builds in one would share
        # symbols, and a second wheel run must not reuse the first's engine.
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "run.json")
            subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "--native", model_path, library, out],
                           check=True)
            with open(out) as f:
                return json.load(f)

    native = None if dylib is None else separate_run(dylib)
    wheel_again = separate_run("wheel")
    cache = tempfile.mkdtemp(prefix="eg2_audio_golden_")
    engine = Engine(model_path, cache)
    try:
        clips, vectors = {}, {}
        for name, said, query in SPEECH:
            file = f"{name}.wav"
            vectors[name] = engine.embed(audio=read(AUDIO, file))
            clips[name] = {
                "file": file,
                "sha256": sha256(os.path.join(AUDIO, file)),
                "said": said,
                "query": query,
                "vector": b64(vectors[name]),
            }
            if native:
                clips[name]["vector_native"] = native["clips"][name]

        # Text -> audio retrieval with the wheel, both query conventions.
        names = [name for name, _, _ in SPEECH]
        retrieval = {}
        for label, prefix in (("raw", ""), ("retrieval_query", QUERY)):
            q = {n: engine.embed(text=prefix + clips[n]["query"]) for n in names}
            top1, margins = 0, []
            for n in names:
                scores = {d: cos(q[n], vectors[d]) for d in names}
                best = max(scores, key=scores.get)
                top1 += best == n
                margins.append(scores[n] - max(v for d, v in scores.items() if d != n))
            retrieval[label] = {"top1": top1, "of": len(names), "min_margin": round(min(margins), 4),
                                "mean_margin": round(float(np.mean(margins)), 4)}

        variants = {}
        for file in VARIANTS:
            vector = engine.embed(audio=read(AUDIO, file))
            variants[file] = {
                "sha256": sha256(os.path.join(AUDIO, file)),
                "cos_to_kitchen_lights_wav": round(cos(vector, vectors["kitchen_lights"]), 5),
                "vector": b64(vector),
            }
            if native:
                variants[file]["vector_native"] = native["variants"][file]

        combined = {}
        for cid, text, images, audio, what in COMBINED:
            vector = engine.embed(
                text=text,
                images=[read(VISION, image) for image in images],
                audio=None if audio is None else read(AUDIO, audio),
            )
            combined[cid] = {
                "what": what,
                "text": text,
                "images": images,
                "audio": audio,
                "vector": b64(vector),
            }
            if native:
                combined[cid]["vector_native"] = native["combined"][cid]
    finally:
        engine.close()

    golden = {
        "description": (
            "EmbeddingGemma 2 740m audio and combined-input vectors from Google's litert-lm 0.18.0 "
            "wheel (PyPI), its own native library over the LiteRT-LM C API, CPU. Clips: "
            "example/assets/eg2_audio (generate_eg2_audio_clips.py, eSpeak NG 1.52.0 + FFmpeg 9.0.2); "
            "images: example/assets/eg2_vision. Written by integration_test/tools/eg2_audio_golden.py. "
            "Vectors are base64 little-endian float32."
        ),
        "bundle": BUNDLE,
        "runtime": {
            "litert-lm": version("litert-lm"),
            "litert-lm-api": version("litert-lm-api"),
            "host": f"{platform.system()} {platform.machine()}",
            "backend": "cpu",
            "vision_backend": None,
            "audio_backend": None,
            "max_input_length": 1024,
            "vision_tokens_per_image": 140,
            "normalize": True,
            "insert_special_tokens": True,
            "input_overflow_strategy": 1,
        },
        "native_library": None if dylib is None else {
            "what": "vector_native: flutter_edge_ai's own libLiteRtLm build, same settings, over ctypes",
            "build": "native-v0.18.0-e (patch_c_api.sh sections 13-14; build_macos.sh), local build",
            "file": os.path.basename(dylib),
            "sha256": sha256(dylib),
            "host": f"{platform.system()} {platform.machine()}",
            "spread": spread(native, clips, variants, combined),
        },
        "wheel_run_to_run": {
            "what": "cos(this run, a second wheel run in another process): the wheel is not deterministic on audio",
            "spread": spread(wheel_again, clips, variants, combined),
        },
        "part_order": "text (with its task prefix), then the images in order, then the audio",
        "prefixes": {"query": QUERY, "document": DOCUMENT},
        "clips": clips,
        "wheel_text_to_audio_retrieval": retrieval,
        "variants": variants,
        "combined": combined,
    }
    text = json.dumps(golden, indent=1, ensure_ascii=False) + "\n"
    with open(os.path.join(GOLDENS, "eg2_audio_golden.json"), "w", encoding="utf-8") as f:
        f.write(text)
    with open(os.path.join(GOLDENS, "eg2_audio_golden.dart"), "w", encoding="utf-8") as f:
        f.write(
            "// GENERATED by integration_test/tools/eg2_audio_golden.py from Google's\n"
            "// litert-lm 0.18.0 wheel — do not edit. Same content as\n"
            "// eg2_audio_golden.json (test/eg2_audio_golden_test.dart checks it).\n"
            "//\n"
            "// EmbeddingGemma 2 740m audio and combined-input golden for\n"
            "// integration_test/embeddinggemma2_audio_test.dart.\n"
            "library;\n\n"
            "const eg2AudioGoldenJson = r'''\n" + text + "''';\n"
        )
    print(json.dumps({"retrieval": retrieval,
                      "variants": {k: v["cos_to_kitchen_lights_wav"] for k, v in variants.items()}}, indent=1))


def spread(native, clips, variants, combined):
    """cos(native, wheel), per group: min and the items."""
    def decode(v):
        return np.frombuffer(base64.b64decode(v), dtype="<f4")
    out = {}
    for group, items in (("clips", clips), ("variants", variants), ("combined", combined)):
        values = {k: round(cos(decode(native[group][k]), decode(v["vector"])), 5) for k, v in items.items()}
        out[group] = {"min": min(values.values()), "items": values}
    return out


if __name__ == "__main__":
    if sys.argv[1] == "--native":
        measure_native(*sys.argv[2:5])
    else:
        main(*sys.argv[1:3])
