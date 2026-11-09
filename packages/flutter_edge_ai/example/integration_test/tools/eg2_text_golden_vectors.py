"""Re-records the native vectors of the EmbeddingGemma 2 text golden
(integration_test/goldens/eg2_text_golden.json) on a new LiteRT-LM.

The strings, prefixes and `vector_st_fp32` (Sentence Transformers) stay as the
measurement run wrote them. `vector` is embedded again through our
libLiteRtLm build and `vector_python_wheel` through Google's `litert-lm` wheel
in this venv, both with eg2_audio_golden.py's Engine (the pass's settings, CPU,
over the LiteRT-LM C API 1.0); each item's cosines, `measured_spread`,
`native_library` and `runtime` are rewritten to match. Then regenerate the
Dart twin (UPDATE_GOLDENS=1 flutter test test/eg2_text_golden_test.dart) and
the llama example's copy (flutter_edge_ai_llama/test/golden_copy_test.dart).

usage: <venv with litert-lm==0.19.0 and numpy>/bin/python -I eg2_text_golden_vectors.py \\
           <path to embeddinggemma-2-text-270m.litertlm> <our libLiteRtLm> <its build> [<its tag>]
"""

import json
import os
import platform
import subprocess
import sys
import tempfile
from importlib.metadata import version

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from eg2_audio_golden import GOLDENS, Engine, cos, sha256  # noqa: E402

PATH = os.path.join(GOLDENS, "eg2_text_golden.json")


def embed_all(model_path, dylib, inputs):
    engine = Engine(model_path, tempfile.mkdtemp(prefix="eg2_text_golden_"),
                    None if dylib == "wheel" else dylib, vision_tokens_per_image=None)
    try:
        return [[float(v) for v in engine.embed(text=text)] for text in inputs]
    finally:
        engine.close()


def separate_run(model_path, library, inputs):
    # A separate process: two libLiteRtLm builds in one would share symbols.
    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "in.json"), os.path.join(tmp, "out.json")
        with open(src, "w") as f:
            json.dump(inputs, f)
        subprocess.run([sys.executable, "-I", os.path.abspath(__file__), "--run", model_path, library, src, out],
                       check=True)
        with open(out) as f:
            return json.load(f)


def main(model_path, dylib, build, tag=None):
    with open(PATH, encoding="utf-8") as f:
        golden = json.load(f)
    if sha256(model_path) != golden["model"]["bundle_sha256"]:
        raise SystemExit(f"{model_path} is not the pinned 270m bundle")
    items = golden["items"]
    inputs = [item["input"] for item in items]
    native = separate_run(model_path, dylib, inputs)
    wheel = separate_run(model_path, "wheel", inputs)
    for item, n, w in zip(items, native, wheel):
        item["vector"] = n
        item["vector_python_wheel"] = w
        item["cos_native_vs_wheel"] = cos(n, w)
        item["cos_native_vs_st_fp32"] = cos(n, item["vector_st_fp32"])
        item["cos_wheel_vs_st_fp32"] = cos(w, item["vector_st_fp32"])
    spread = golden["measured_spread"]
    for key, field in (("native_vs_wheel_min_cos", "cos_native_vs_wheel"),
                       ("native_vs_st_fp32_min_cos", "cos_native_vs_st_fp32"),
                       ("wheel_vs_st_fp32_min_cos", "cos_wheel_vs_st_fp32")):
        spread[key] = min(item[field] for item in items)
    wheel_version = version("litert-lm")
    golden["description"] = (
        "EmbeddingGemma 2 text golden vectors for the flutter_edge_ai EG2 integration test. "
        f"'vector' comes from {build} libLiteRtLm (CPU); 'vector_python_wheel' from litert-lm "
        f"{wheel_version} (PyPI); 'vector_st_fp32' from sentence-transformers fp32. The native vectors "
        "are re-recorded by integration_test/tools/eg2_text_golden_vectors.py."
    )
    golden["native_library"] = {
        "tag": tag or build,
        "build": build,
        "file": os.path.basename(dylib),
        "dylib_sha256": sha256(dylib),
        "cache_dir": "a fresh temporary directory",
    }
    golden["runtime"].update({
        "litert-lm": wheel_version,
        "litert-lm-api": version("litert-lm-api"),
        "input_overflow_strategy": 1,
        "host": f"{platform.system()} {platform.machine()}",
    })
    with open(PATH, "w", encoding="utf-8") as f:
        f.write(json.dumps(golden, indent=1, ensure_ascii=False))
    print(json.dumps(spread, indent=1))


if __name__ == "__main__":
    if sys.argv[1] == "--run":
        model, library, src, out = sys.argv[2:6]
        with open(src) as f:
            texts = json.load(f)
        with open(out, "w") as f:
            json.dump(embed_all(model, library, texts), f)
    else:
        main(*sys.argv[1:5])
