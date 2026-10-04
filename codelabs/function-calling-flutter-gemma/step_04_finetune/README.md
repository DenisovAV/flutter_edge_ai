# Step 4 — fine-tune the model on these tools

Not a Flutter app. This directory holds the two inputs a
[litetune](https://litetune.dev) run needs, for the four
tools the rest of this codelab declares:

```text
tools.json    the four declarations, the same ones lib/tools.dart holds
raw.jsonl     90 prompt -> tool-call rows to train and score on
```

The commands below are verified against **litetune 0.3.0**, the current PyPI
release. It pins LiteRT-LM 0.17.1 for verification and the matching 0.17.1
builder for conversion. The project source is also available on
[GitHub](https://github.com/DenisovAV/litetune).

`tool/check_codelabs.sh` discovers step apps by their `pubspec.yaml`. There is
none here on purpose, so this directory is not analyzed, tested or built — it
is data and commands.

## What you need

**Access to the base model, requested before you start.** Three of the five
commands below name `google/functiongemma-270m-it`, and that repository is
gated with **manual** approval — an anonymous fetch of its `config.json`
returns `401`, and a person grants access rather than a checkbox, so it can
take hours or days. Request it on
[the model page](https://huggingface.co/google/functiongemma-270m-it), then
`hf auth login` (or export `HF_TOKEN`) once it is granted. Without it command 1
fails on the tokenizer download and you never reach command 2. Nothing else in
this codelab needs a token: the `.litertlm` the app downloads comes from the
ungated `sasha-denisov/function-gemma-270M-it`.

`pip install litetune` — **Linux, macOS or Windows**, Python 3.10–3.12.
`convert` specifically needs Linux x86_64 or an Apple Silicon Mac; Windows runs
`prepare`, `tune`, `verify` and `bundle`, but not `convert`. Python 3.13 runs
`prepare`, `tune` and `bundle` but not `convert` or `verify`, because the export
toolchain pins `numpy==2.0.2` and that stops publishing wheels after 3.12. On
Linux also `sudo apt-get install -y libvulkan1`, or every invocation — `--help`
included — dies in under a second.

By default, `tune` and the float-reference side of `verify` choose CUDA, then
Apple's Metal (`mps`), then CPU. The commands below set
`LITETUNE_DEVICE=cpu` for a reproducible 270M run; CPU is workable at that
size. `convert` always runs on CPU, while the converted side of `verify` has
its own `--backend` flag. The stage environments are cached and they are
large: `convert` pulls ~1.6 GB, `tune` 588 MB and `verify` about 740 MB across
its two environments. `litetune env` shows what is on disk and `litetune env
--clean` removes it.

This is alpha software, and it states what it has measured: six models end to
end — `google/functiongemma-270m-it` with the tool-call scorer, plus
`google/gemma-3-270m-it`, `google/gemma-3-1b-it`, `Qwen/Qwen3-0.6B`,
`Qwen/Qwen2.5-0.5B-Instruct` and `google/gemma-4-E2B-it` with `exact-text` on a
77-way intent task. The first is exactly the model and the task this codelab is
on.

**You can skip this step.** The app in `complete/` works on the stock
FunctionGemma and on Gemma 4 without any of it.

## The five commands

Run them from this directory. Each is separate because each fails differently.

```bash
# Keep this tutorial's measurements reproducible. Unset it to let litetune
# auto-select CUDA, then MPS, then CPU.
export LITETUNE_DEVICE=cpu

# 1. Split, and reject rows that cannot be scored. Seconds.
litetune prepare --data raw.jsonl --output-dir data --context-length 1024 \
                 --tokenizer google/functiongemma-270m-it \
                 --base-model google/functiongemma-270m-it \
                 --declarations tools.json

# 2. Fine-tune. One epoch at 1e-5 — a twentieth of the default rate — because
#    72 rows that are all tool calls will happily eat the rest of the model;
#    see "How hard to train" below. On a CPU add --dtype float32:
#    bfloat16 has no hardware behind it there and ran 165x slower.
litetune tune --model google/functiongemma-270m-it --data data/train.jsonl \
              --output-dir tuned --method lora --epochs 1 \
              --learning-rate 1e-5 --dtype float32 \
              --prompt-mode runtime_rendered --declarations tools.json

# 3. Convert, sweeping recipes rather than trusting a default.
litetune convert --model tuned/model --output-dir artifacts \
                 --train-metrics tuned/metrics.json \
                 --recipe dynamic_wi8_afp32 --recipe weight_only_wi8_afp32

# 4. Measure what the conversion cost, against the float twin.
#    `convert` names the artifact; look the filename up rather than build it.
#    The prompt mode comes from the record `tune` left beside the checkpoint.
litetune verify --model artifacts/weight_only_wi8_afp32/<name>.litertlm \
                --reference tuned/model --data data/heldout.jsonl \
                --declarations tools.json --scorer tool-call \
                --backend cpu --json > manifest.json

# 5. Package the artifact with what was measured about it.
litetune bundle --output-dir bundle \
                --model artifacts/weight_only_wi8_afp32/<name>.litertlm \
                --declarations tools.json --prompt-mode runtime_rendered \
                --base-model google/functiongemma-270m-it \
                --base-model-revision <commit-sha> \
                --adapter tuned/adapter \
                --train-metrics tuned/metrics.json \
                --verify-manifest manifest.json
```

`--prompt-mode runtime_rendered`, and `tools.json` passed to every stage, because
that is how this app calls the model: the declarations go to LiteRT-LM, which
renders them and parses the call back out. Train the other mode — `prerendered`,
where the application writes the declarations into the prompt text — and the
model is served a prompt it never saw. The value must be the **same** everywhere;
the wrong one produces a fluent wrong answer rather than an error.

`tools.json` is these four declarations in the shape `complete/lib/tools.dart`
sends them. `prepare` refuses shapes the runtime and the model's own chat
template render differently, which is why no declaration here carries an empty
`properties` map, and why every `multiply` row sends numbers rather than the
strings they used to be.

`--recipe` has no default, and litetune's own line for why is worth keeping:
*"A sweep of one is not a comparison."*

## Then open it in the app

Command 3 above — not the codelab's Step 3 — already gives you a `.litertlm`
per recipe under `artifacts/<recipe>/`.
Run `complete/`, choose **Open a .litertlm from disk**, and paste the absolute
path. Nothing in `lib/` changes — it is a `.litertlm`, and the app opens it the
way it opens the two it downloads.

On macOS the app is sandboxed, so a path under `~/Downloads` or in a scratch
directory is not readable from inside it. Copy the file into the app's own
documents directory — `~/Library/Containers/dev.fluttergemma.functioncalling/Data/Documents/`
— and paste that path.

## What this run actually measured

This timing and score snapshot was recorded with litetune 0.1.7 and its
LiteRT-LM 0.16.1 runtime; 0.3.0 uses a newer runtime, so rerun before comparing
new artifacts to these historical numbers. On a MacBook Pro M4 Pro: `prepare`
a second, `tune` 82s,
`convert` 84s for `weight_only_wi8_afp32`, `verify` 52s. The held-out split is
18 rows, scored through the runtime's tool path — a call counts only when the
operation name and every argument match.

| | picks the right tool |
|---|---|
| the published FunctionGemma this codelab downloads | 13 / 18 |
| tuned here, one epoch at 1e-5 | 18 / 18 |

The gain is in one place, and it is the place that matters: the base answers
*"which system am I using?"* with a refusal in prose and never calls
`get_device_info` — four of its five misses are that one tool. After training it
calls, every time.

Colours it already got right — a separate check, not part of the 18: asked for
each of the six in six different phrasings, the stock model called
`change_background_color` with the right colour every time. Measure the base
first; the rows worth writing are the ones it gets wrong.

## How hard to train, and why gently is enough

One epoch at 1e-5 is a twentieth of litetune's default, and it is not timidity:
on this task it is already the whole gain. The held-out score is 18/18 at 1e-5,
at 5e-5 and at three epochs of 2e-4 — the tool choice is learned in the first
pass, and everything after that is spent on something else.

What it is spent on is worth knowing before you spend it. FunctionGemma is an
action model: `google/mobile-actions`, the corpus it was tuned on, is 9654 rows (8693 train, 961 eval)
of *developer, user, call* and **not one** row where the assistant writes a
sentence after a tool result. Ending a turn at the call is what this model is
for. The base still answers in prose now and then — that is residual Gemma 3
behind the task tuning, not a promise — and more training on calls leaves less
of it: at 1e-5 `multiply` is still narrated and the colour is not, at 5e-5
neither is.

So train for the thing the model is for, and keep the rate low because there is
nothing further to gain by raising it. If you want a model that *talks* about
what the tool returned, that is Gemma 4's job, and `complete/` ships it.

Either way the app stays correct: it renders the tool's own result rather than
waiting for the model to describe it, which is why the screen repaints whether
or not a sentence follows.

## Check the model you got, not the number

`verify` scores tool calls. Before you ship the artifact, ask it one thing that
is not one:

> hello, who are you?

with no tools in the session, and *"make the background blue"* with them. You
are looking for a model that still behaves like the base did where you did not
train it — the base's own answers are the bar, not a chat model's. If the first
answer is worse than the stock model's, the rate was too high for what you
gained; halve it and convert again.

18 held-out rows is also too few to resolve anything: litetune says so on every
run, and the interval it prints spans more than the difference it measures.
Treat the pipeline as rehearsed and the numbers as a direction, then bring your
own data.
