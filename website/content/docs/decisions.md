---
title: Decisions
description: "Pick one of N options on device — an intent, an action, a route, a tool — or abstain, with flutter_edge_ai's experimental Decider API over any embedding model."
meta:
  - property: og:image
    content: https://flutteredge.ai/images/og-image.png
---

A **decider** maps an input onto one of the options your app defines — an
intent, an action, a screen, a label, a route, the few tools worth offering a
small function-calling model — and says "none of these" when nothing fits. It
runs on device, costs one embedding per input, and needs no training. A small
language model trained on the decision can decide too
([below](#deciders-from-a-language-model)).

<Warning>

Experimental since `flutter_edge_ai` 2.4.0. Every type and member is
`@experimental`: names and behaviour may change in a minor release, and code
that uses them gets the analyzer warning `experimental_member_use`. Add
`// ignore_for_file: experimental_member_use` to the files that use it.

</Warning>

## Packages

```
dependencies:
  flutter_edge_ai: ^2.5.0
  flutter_edge_ai_litertlm: ^1.15.0 # EmbeddingGemma 2 (.litertlm) and 1 (.tflite); option scoring
```

Any embedding model works: `EmbeddingModel.createDecider` is implemented once in
core over `embed`, so every embedding backend has it. The numbers on this page
are EmbeddingGemma 2 text 270m (`embeddinggemma-2-text-270m.litertlm`).

## Quick start

```dart
// ignore_for_file: experimental_member_use
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

Future<void> decide() async {
  await FlutterEdgeAi.initialize(
    embeddingBackends: const [LiteRtEmbeddingBackend()],
  );
  await FlutterEdgeAi.installEmbedder()
      .modelFromNetwork(
        'https://huggingface.co/litert-community/'
        'embeddinggemma-2-text-270m-litert-lm/resolve/'
        '9be6e8b90982095dc05c2bd162e4b954ee4dbac7/'
        'embeddinggemma-2-text-270m.litertlm',
      )
      .install();
  final embedder = await FlutterEdgeAi.getActiveEmbedder();

  final decider = await embedder.createDecider(
    options: [
      DeciderOption(
        'set_timer',
        description: 'Start a countdown timer',
        examples: [
          EmbeddingInput.text('set a timer for ten minutes'),
          EmbeddingInput.text('wake me in half an hour'),
          EmbeddingInput.text('countdown 5 minutes'),
        ],
      ),
      DeciderOption(
        'call_contact',
        description: 'Phone someone from the contacts',
        examples: [
          EmbeddingInput.text('call mum'),
          EmbeddingInput.text('ring Alex on his mobile'),
          EmbeddingInput.text('phone the office'),
        ],
      ),
    ],
  );

  final answer = await decider.choose(
    DeciderInput(EmbeddingInput.text('remind me in 20 minutes')),
  );
  if (answer.choice == null) {
    print('none of these: ${answer.abstainReason}');
  } else {
    print('${answer.choice} (margin ${answer.margin})');
  }
}
```

## How it decides

1. Every option input — its `description`, then its `examples` — is embedded
   once, at `createDecider`, with `TaskType.sentenceSimilarity`. The input to
   decide on gets the same prefix: EmbeddingGemma 2's model card asks for one
   prefix on every compared input. Why this prompt: see
   [Measured accuracy](#measured-accuracy).
2. An option is the **centroid** of its inputs (their normalised mean). A
   description alone is zero-shot.
3. `choose` embeds the input and scores every candidate:
   - `DeciderMethod.centroid` (default): cosine to the option's centroid
     (`ScoreKind.cosine`);
   - `DeciderMethod.linear`: a softmax regression fitted on the frozen
     embeddings at `createDecider`, weight decay fixed at 1e-5
     (`ScoreKind.logprob`).
4. The **abstain signal** is the input's highest cosine to a candidate's
   centroid — for both methods. Below the calibrated threshold the answer has
   `choice: null` and `AbstainReason.belowThreshold`. The answer reports both:
   `answer.provenance.abstainSignal` (its kind,
   `AbstainSignalKind.topCosine`, in `abstainSignalKind`) and
   `answer.provenance.threshold`.

`answer.ranked` holds the best `topK` candidates (default 5), best first; on a
tie the option given first ranks first. `answer.margin` is best minus
runner-up. `choose(input, among: [...])` restricts the candidates to some
option ids: an unknown id throws `ArgumentError`, an empty set abstains with
`AbstainReason.noCandidates` without embedding anything (a closed embedder or
an input the model was not loaded for still fails, as with candidates).

`ScoreKind`, `AbstainReason`, `AbstainSignalKind` and `DeciderMethod` are
classes with constant values, not enums, so a value added in a later release
does not break your `switch` — give it a default branch. A `DeciderAnswer`
checks itself: exactly one of `choice` and `abstainReason`; a `choice` first
in a non-empty `ranked`; `ranked` highest first, each option once, no NaN
score; `margin` not negative; `confidence` in [0, 1] and only with
`probabilities`; `probabilities` in [0, 1], summing to 1 and matching every
ranked option's `probability`; a choice only with the abstain signal at or
above the threshold and `belowThreshold` only below it. A language-model decider whose
"none of these" option ranks first abstains with `noneOption` whatever its
signal.

### A raw score is not a probability

A cosine of 0.83 does not mean 83 %. `RankedOption.probability`,
`DeciderAnswer.probabilities` and `DeciderAnswer.confidence` are **null**
unless the decider was calibrated on held-out labelled requests
(`EmbeddingDeciderCalibration.fromLabelled`), which fits a softmax temperature. One
formula decodes every method's raw scores: `softmax(score / T)` over the
candidates. `confidence` is Jev's spread measure, `(N · pmax − 1) / (N − 1)`:
0 for a uniform distribution, 1 when one option takes everything. It is not an
accuracy.

## Calibration: when to say "none of these"

| Calibration | Threshold | Needs |
|---|---|---|
| `EmbeddingDeciderCalibration.crossFit({keep: 0.95})` — default | The options' own inputs: 5-fold cross-fit (input `i` of each option in fold `i % 5`), each held-out input scored against the other folds' centroids, threshold keeps `keep` of them | Two inputs per option |
| `EmbeddingDeciderCalibration.minSimilarity(t)` | A fixed cosine `t` | A value measured for your model file and prompt |
| `EmbeddingDeciderCalibration.fromLabelled(rows, maxError: 0.05)` | The lowest cosine at which labelled rows keep their error within `maxError` (rows of one cosine counted together); plus a temperature → probabilities | Held-out labelled requests — not the examples or descriptions — some of them hard |
| `EmbeddingDeciderCalibration.none()` | Never abstains | — |

`fromLabelled` refuses (`ArgumentError`) rows it cannot calibrate on: when no
threshold keeps their error within `maxError`, and when the best temperature
is an end of its grid — rows all answered right with room to spare would make
a near-tie look certain (one row always ends up refused one way or the other).
The rows are copied when the calibration is made.

A softmax probability cannot abstain: with two options any request looks
confident. Measured with EmbeddingGemma 2 on CLINC150 (k = 10 examples per
option), a 5 %-budget threshold on the softmax rejects 2.9–18.4 % of
out-of-subset requests at 2–20 options; the cross-fitted cosine rejects
92–99 %.

`fromLabelled` sees only requests that belong to an option, so its threshold
is set by in-scope errors alone, and it falls as the decider gets more
accurate. On CLINC150 at 150 options (`centroid`) it refused 94 % of the
out-of-scope requests with 5 examples per option, 85 % with 10 and 4 % with 30;
the cross-fit refused 89 / 90 / 94 %. When requests that fit no option matter,
keep the cross-fit, or check that the threshold `fromLabelled` picked still
refuses them.

An input of another modality than the options needs its own threshold. A
spoken request compared with text options reaches lower cosines than the same
request typed: in the example's Tiny Island (EmbeddingGemma 2 740m, synthetic
speech) typed requests calibrate at 0.866 and spoken ones at 0.745 for about
the same error. One decider has one threshold, so Tiny Island keeps a second
decider over the same options for spoken requests, with
`minSimilarity(0.745)` measured on spoken requests.

## Measured accuracy

All numbers: Google's int4 `embeddinggemma-2-text-270m.litertlm` through
LiteRT-LM 0.18.0's EmbeddingEngine on a CPU (Apple M4 Pro), the decider's
sentence similarity prompt, CLINC150 (its own out-of-scope rows as "none of
these"). The measurement code is the one this API reproduces numerically;
English, one-sentence requests.

| Setting | Result |
|---|---|
| 150 options, label names only (zero-shot) | 0.753 accuracy |
| 150 options, centroid, 5 / 10 / 30 examples | 0.916 / 0.938 / 0.948 |
| 150 options, linear, 5 / 10 / 30 examples | 0.927 / 0.951 / 0.960 |
| 2–20 options, linear, 5 examples | argmax accuracy 0.987–0.999 |
| 2–20 options, linear, cross-fit, 10 examples | 90–94 % of in-scope answered, ≤ 0.6 % error on them, 92–99 % of out-of-subset and 98–99.8 % of CLINC out-of-scope refused |
| 150 options, linear, cross-fit, 5 / 10 / 30 examples | out-of-scope refused 89 / 90 / 94 %; error on answered 6.0 / 3.8 / 3.1 % |
| Linear, fixed cosine 0.875, 2–20 options, 5–10 examples | about as good as the cross-fit for this file and prompt |
| Tiny Island (the example app): 184 actions, centroid, 5 examples each; 144 held-out paraphrases (141 English, 3 German) and 30 out-of-scope requests; EmbeddingGemma 2 text 270m, macOS CPU | cross-fit: 93.8 % answered, 3.0 % error on them, 30 of 30 out-of-scope refused. `fromLabelled(maxError: 0.05)`, two folds: 98.6 / 100 % answered, 4.2 / 4.2 % error (6 of 143 answers wrong over both), 30 of 30 refused; `linear` gave the same answers and adds 15 s to the fit |

Which inputs are answered and refused depends only on the abstain signal and
its threshold, the same for both methods; the error on the answered ones was
measured with `linear`, and `centroid` makes more (it is less accurate). At 150
options with 5 examples, the cross-fit's error (6.0 %) is over a 5 % budget:
calibrate with `fromLabelled` there. On Tiny Island the cross-fit stays within
it (3.0 %); the app calibrates with `fromLabelled` anyway, which answers more of
the requests (99 % against 94 %) at 4.2 % error.

**The prompt.** Sentence similarity was the most accurate EmbeddingGemma 2
prompt on CLINC150 and on the example app's Tiny Island catalog (184 actions),
against classification, question answering, a document prompt for the
options and Google Decision Maker's `title: <option> | text:` candidates:

| | classification | sentence similarity |
|---|---|---|
| CLINC150, centroid, 5 / 10 / 30 examples | 0.891 / 0.901 / 0.920 | 0.916 / 0.938 / 0.948 |
| CLINC150, cross-fit, 10 examples: out-of-scope refused | 86 % | 90 % |
| HWU64 (64 options), centroid, 5 / 10 examples | **0.929 / 0.935** | 0.887 / 0.909 |
| Tiny Island (740m), typed requests: right / answered at a 5 % error budget | 0.896 / 74 % | 0.958 / 93 % |
| Tiny Island (740m), spoken requests (audio): right / answered | 0.592 / 18 % | 0.772 / 54 % |

On HWU64 classification was ahead with every method, and so it is not best
everywhere. Not measured yet: requests longer than a sentence, a large set in
languages other than English, and accuracy on a phone or an NPU.

## Speed

`choose` costs one embedding plus one dot product per candidate.

Measured on an Apple M4 Pro (macOS 26.5.1), EmbeddingGemma 2 text 270m on the
CPU, the example app's `integration_test/decider_benchmark_test.dart` (debug
build), zero-shot options from descriptions, two runs of 60 `choose` calls per
N; medians:

| Options | `createDecider` | `choose`: embedding | `choose`: scoring, debug | scoring loop, release (AOT) |
|---|---|---|---|---|
| 10 | 0.35–0.41 s | 37–43 ms | 0.03 ms | 0.005 ms |
| 150 | 5.2–5.8 s | 42–44 ms | 0.12–0.14 ms | 0.09 ms |
| 500 | 22–27 s | 73–76 ms | 0.64–0.72 ms | 0.29 ms |
| 2000 | 96–119 s | 33–53 ms | 1.4–1.6 ms | 1.2 ms |

The embedding of the input dominates, and it does not depend on N: the fastest
single query took 30–31 ms at every N. The N = 500 rows were slower in both runs
(fastest query 47–62 ms), which this run does not explain. `createDecider` embeds
one input per option, one after another (35–60 ms each). Phones and NPUs are not
measured yet.

Fitting `linear` (softmax regression, float64 L-BFGS on an isolate of its
own) on an Apple M4 Pro, release (AOT) build:

| Options × examples | Fit |
|---|---|
| 2 × 10 | 4 ms |
| 10 × 10 | 0.1 s |
| 20 × 10 | 0.3 s |
| 50 × 10 | 1.9 s |
| 150 × 5 / 10 / 30 | 7.2 / 16.4 / 50 s |

`centroid` fits nothing; its default cross-fit took 0.2 s at 150 × 30. The
optimiser keeps a history of 20 pairs of parameter-sized vectors: about
2 · 20 · (768 · C + C) · 8 bytes — 37 MB at 150 options, ~0.5 GB at 2000 —
on top of the inputs.

On web there is no isolate to spare: the fit runs on the page's thread in
slices of 4 ms and yields to the event loop between them (and checks the
cancel token there), so the page keeps drawing and taking input while it
fits. Measured on an Apple M4 Pro in Chrome 155 (headless), release builds
(`flutter build web`, dart2js and `--wasm`), synthetic unit rows (768
dimensions, 10 per option), cross-fit calibration; two runs:

| Options × 10 | `centroid` fit, dart2js / wasm | `linear` fit, dart2js / wasm | Longest gap between ticks of a 16 ms timer, `linear` (`centroid`) |
|---|---|---|---|
| 10 | 5–16 / 8 ms | 46–48 / 60–63 ms | 20–22 ms (fit shorter than a tick) |
| 50 | 15–17 / 17–18 ms | 0.89–0.91 / 1.04–1.05 s | 20–24 ms (15–18 ms) |
| 150 | 113–114 / 121–129 ms | 10.2–10.8 / 11.4–11.8 s | 20–23 ms (21–23 ms) |

Run without yielding, the same fits held the page for their whole length —
10.1–11.0 s (dart2js) and 11.4–11.7 s (wasm) at 150 `linear`; the yields
cost less than the run-to-run spread (±2 %). The web fit computes the same
numbers as the VM: `test/web/decider_web_test.dart` holds it to the VM's
results in the browser.

## Many decisions over one input

`Decider.chooseAll(input, deciders)` answers several deciders, in order.
Deciders created from one `EmbeddingModel` share **one** embedding of the
input:

```dart
// ignore_for_file: experimental_member_use
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

Future<void> triage(EmbeddingModel embedder) async {
  final intent = await embedder.createDecider(options: [
    DeciderOption('buy', examples: [
      EmbeddingInput.text('I want to order this'),
      EmbeddingInput.text('add it to my cart'),
    ]),
    DeciderOption('return', examples: [
      EmbeddingInput.text('this arrived broken'),
      EmbeddingInput.text('how do I send it back'),
    ]),
  ]);
  final tone = await embedder.createDecider(
    options: [
      DeciderOption('calm', description: 'calm, neutral wording'),
      DeciderOption('upset', description: 'angry or upset wording'),
    ],
    calibration: const EmbeddingDeciderCalibration.none(),
  );
  final answers = await Decider.chooseAll(
    DeciderInput(EmbeddingInput.text('the box was crushed, I am furious')),
    [intent, tone],
  );
  print('${answers[0].choice} / ${answers[1].choice}');
}
```

## Tool routing for function calling

FunctionGemma 270M has a 1024-token context: hundreds of tool declarations do
not fit. A decider narrows them to the few likely ones, and only those go to the
chat:

```dart
// ignore_for_file: experimental_member_use
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

Future<InferenceChat> chatWithLikelyTools(
  EmbeddingModel embedder,
  InferenceModel model,
  List<Tool> tools,
  String request,
) async {
  final router = await embedder.createDecider(
    options: [
      for (final tool in tools)
        DeciderOption(tool.name, description: tool.description),
    ],
    calibration: const EmbeddingDeciderCalibration.none(),
  );
  final picked = await router.choose(
    DeciderInput(EmbeddingInput.text(request)),
    topK: 3,
  );
  return model.createChat(
    tools: picked.choice == null
        ? <Tool>[]
        : [
            for (final r in picked.ranked)
              tools.firstWhere((t) => t.name == r.id),
          ],
    supportsFunctionCalls: true,
    modelType: ModelType.functionGemma,
  );
}
```

Descriptions alone cannot cross-fit, so this router never abstains: it
always offers the three nearest tools. To let it say "no tool", give each tool
a few example requests and keep the default cross-fit; `choice == null` then
offers none. A fixed `minSimilarity` threshold belongs to one model file and
one prompt: use one only after measuring it for yours.

## Store and restore

`toArtifact()` returns a JSON-encodable, versioned map: the options (ids,
descriptions, text examples, metadata), each option's centroid (and linear
weights) as base64 little-endian float32, the method, the calibration and the
embedding-space id. `EmbeddingModel.loadDecider(artifact)` rebuilds the decider
without embedding anything.

```dart
// ignore_for_file: experimental_member_use
import 'dart:convert';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';

Future<Decider> restore(EmbeddingModel embedder, String stored) =>
    embedder.loadDecider(jsonDecode(stored) as Map<String, Object?>);
```

The artifact is pinned to its **embedding space**: the model's installed
files, the dimension, the backend and the task prefix. The files are named by
their install names and, natively, their sizes in bytes — file names and
sizes, not the bytes themselves, so install new weights under a new name (on
web, where core does not read sizes, the names alone). A decider fitted on the
CPU file is refused on a per-SoC NPU bundle with
`DeciderSpaceMismatchException`: EmbeddingGemma 2's NPU vectors against its
CPU file's measured cosine 0.83 on average for short texts, rising to 0.995 at
400 words, and 0.86–0.88 for images. A decider fitted on at least one image
(an option example or a labelled request) also carries the embedder's image
budget — EmbeddingGemma 2 encodes an image into 140 tokens, or 70 with
`LiteRtEmbeddingBackend(visionTokensPerImage: 70)`, and the same photo gives
another vector under the other budget — so it is refused at the other budget
too; a decider fitted on text alone is not, and an embedder widened to images
does not move its space. A malformed or newer artifact, or one
that contradicts itself, is a `FormatException`. Media examples are not stored
(their count is); a restored option lists its text examples.

A model that `FlutterEdgeAi.getActiveEmbedder()` did not build (a custom
subclass, a test fake) has no installed files to name its space, and a model
that reports no backend (`activeBackend` null: LiteRT.js and ONNX on web)
cannot tell WebGPU from WASM — both are refused with `ArgumentError` unless
you pass `embedderId:` to `createDecider` and `loadDecider`. An `embedderId`
replaces the installed-file check: you own the identity, so change it whenever
the weights (or, for a model without a backend, the backend) change.

A decider borrows its embedder and never closes it. On an embedder
`getActiveEmbedder()` returned, it follows core: when that embedder is closed
— core widened it for images or audio, another backend, a re-install, a
worker that died, or the app closed it — the next `choose` asks core for the
active embedder again (with the backend and media the old one was built with,
under the cache's usual reuse rule, so it may load the model again) and
retries there. If that embedder is another embedding space, `choose` throws
`DeciderSpaceMismatchException`. On a custom model it fails with
`EmbedderClosedException` and `decider.isClosed` is true: load the artifact
on the new model.

## Progress, cancel and your own deciders

`createDecider(onProgress: (done, total) => …)` counts the inputs it embeds —
each option's description and examples, then `fromLabelled`'s rows — from
`(0, total)` to `(total, total)`. It does not cover the fit after them, which
for `linear` at 150 options takes seconds. `cancelToken:` stops the embedding
and the fit (natively the fit's isolate is killed, on web it stops at the next
yield): `DeciderCancelledException`, and no decider. A failed option input
names its option and input: `Option "returns", example 3: …`, with the
exception's type and fields kept.

`choose(input, cancelToken:)` and `Decider.chooseAll(input, deciders,
cancelToken:)` fail with `DeciderCancelledException` too, and so does a
`choose` still running when its decider is closed. The decider checks before
it embeds the input, before core replaces a closed embedder (a decision
cancelled by then never loads the model again; one cancelled while the model
loads has its answer dropped), and when the embedding returns: an embedding
already sent is not interrupted, and its vector is dropped.

A decider of your own, or a test fake, `extends Decider` (an abstract base
class) and implements `decide(DeciderRequest request)`, `capabilities`,
`options`, `isClosed` and `close()`; `toArtifact()` defaults to throwing
`DeciderUnsupportedException`. `choose` is core's and cannot be overridden:
it checks every request against `capabilities` — `among` without
`supportsAmong`, context without `supportsContext`, an input modality not in
`modalities` (each a `DeciderUnsupportedException`), unknown `among` ids, a
`topK` below 1, a cancelled token — and only then calls `decide`, with the
candidates as option ids in option order. It checks the token again when
`decide` returns, so a decider that ignores it still has its answer dropped. An
option `choose` gains in a later release reaches `decide` as a new field of
`DeciderRequest`, so your decider keeps compiling. `storable` says whether
`toArtifact()` returns an artifact.

## Deciders from a language model

`InferenceModel.createDecider(question:, options:, calibration:)` is the other
kind of decider: a small LLM trained on one question and its options lists
them in a prompt and scores each option's id as its reply
(`DeciderMethod.optionScoring`). `flutter_edge_ai_litertlm` 1.15.0 implements
it for `.litertlm` models on the CPU backend, on native platforms; on the web
`createDecider` throws `DeciderUnsupportedException`.

The model is an ordinary generative `.litertlm`, tuned for the decision by
[LiteTune](https://pypi.org/project/litetune/) 0.5.0 or later. When its verify
passes, `litetune bundle` writes a `litetune.decision` section into the file:
the question, the options, the softmax temperature and the abstain threshold
fitted for it. Pass the question and the trained options, and take the rest
from the file with `InferenceDeciderCalibration.fromModel()`:

```dart
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
).fromFile(path).install();
final model = await FlutterEdgeAi.getActiveModel(
  preferredBackend: PreferredBackend.cpu,
);
final decider = await model.createDecider(
  question: 'Which emotion does the text express?',
  options: [
    DeciderOption('sadness'), DeciderOption('joy'), DeciderOption('love'),
    DeciderOption('anger'), DeciderOption('fear'), DeciderOption('surprise'),
  ],
  calibration: const InferenceDeciderCalibration.fromModel(),
);
final answer = await decider.choose(
  DeciderInput(EmbeddingInput.text('im feeling far more mellow than normal')),
);
```

LiteTune 0.5.0's `bundle` prints only the `options:` part of that call
(`model.createDecider(options: [...])`); add the `question:`, which its
`contract.json` and the section carry, and the `fromModel()` calibration.

The call must match the decision, because the temperature and the threshold
mean nothing for another question or another option list:

- another question, an option the model was not trained on, a subset of its
  options, or another description (one equal to the id is accepted, as
  `DeciderOption.fromJevChoice` sets it) fails with `ArgumentError`, naming
  the trained value;
- with `fromModel()`, a model trained with a "none of these" option may leave
  it out of `options:` — the decider lists it last (`decider.options`);
- explicit `InferenceDeciderCalibration` values must be the file's — they pin
  the app to one build of the model, so a retrained model is refused; with
  them the none option is listed among the options and named in
  `noneOption`, and a file threshold of 0 is `abstainBelow: null`;
- the options may come in any order: the prompt lists them as trained;
- a file without the section is an ordinary chat model:
  `DeciderUnsupportedException`.

Each decision renders the prompt with the model's own chat template, prefills
it once, and scores every option on its shortest unique prefix, rewinding to
the prompt between options. Before the first decision on a loaded model,
LiteRT-LM checks how its version scores right after a prefill (0.18.0 drops
the prompt's second-to-last token, LiteRT-LM #3561, and the decider prefills
the last token again to match); an engine whose check gives neither answer,
or whose scores are not repeatable, is refused rather than guessed. An input
whose prompt does not fit the model's `maxTokens` is refused with
`ArgumentError`, never truncated, and a decision that cannot fit even with a
one-character input is refused when the decider is created. A cancel stops a
decision between two options.

The decider borrows the model. Core keeps one active inference model, and
closes it when another one is requested (another file, another `maxTokens`):
the decider is then closed too, and `choose` throws `StateError`. Create it
again on the new model.

Three kinds of question, from the section:

| Question | Options | Answer |
|---|---|---|
| Choice | the trained ids, and the none option if the model has one | `choice`, or an abstention: `noneOption` when the none option ranks first, `belowThreshold` when the top probability is below the threshold |
| Noul | `no`, `yes` | `noul` = P(yes); `choice` is the likelier one; never abstains |
| Score | levels `0` … `K − 1`, each with its text | `expectedLevel` = Σ pᵢ · i and the `legend`; `choice` is the likeliest level; never abstains |

`answer.questionType` says which, and `toJevJson()` writes each type's Jev shape
(below).

Its answers have the same shape as an embedding decider's, with these values:

| Member | Embedding decider | Language-model decider |
|---|---|---|
| `scoreKind` | `cosine` (centroid) or `logprob` (linear) | `logprob`, normalised over the candidates |
| `probabilities`, `confidence` | with `fromLabelled` only | always: `softmax(s / T)` with the trained temperature |
| `provenance.abstainSignalKind` | `topCosine` | `topProbability` |
| `abstainReason` | `belowThreshold`, `noCandidates` | `belowThreshold`, `noneOption` (Choice only) |
| `provenance.encodeTime` | the input's embedding | the prompt's render and prefill |
| `provenance.spaceId` | the embedding space | null |
| `capabilities.supportsAmong`, `storable` | true, true | false, false |

Not in this release: `among`, `DeciderInput.context`, images and audio, the
GPU and NPU (refused: option scoring is measured on the CPU only), and the web
(refused). Measured on macOS (Apple M4 Pro); Android, iOS, Linux and Windows
use the same C calls and are not measured yet. An input
that contains a chat template's control text (`<start_of_turn>`,
`<end_of_turn>`, `<bos>`, …) is refused with `ArgumentError`: the model was
never trained on such a prompt.

**Measured.** On an Apple M4 Pro CPU, with LiteTune's golden packs (24
held-out rows each, google/gemma-3-270m-it tuned by LiteTune, int8): emotion
(Choice, 6 options), SST-2 (Noul) and SST-5 (Score, 5 levels). The prompt's
tokens equal LiteTune's on every row; the top option is the PyTorch
reference's on 24, 23 and 21 rows, the others near-ties on which LiteTune's
own run disagrees with the reference too; a decision takes 120–190 ms
(median). LiteTune measured the same
method on a server CPU at 0.38 s for 6 options, 5.0 s for 55 and 7.2 s for 151:
one scoring pass per option, against one embedding whatever the number of
options for an embedding decider. So a language-model decider is for a few
options that are a property of the text (a tone, an emotion, yes or no, a
level), and an embedding decider for many options by topic.

## Jev Choice JSON

`DeciderOption.fromJevChoice(question)` turns a Jev (TypeSafe AI) Choice
question — `{"type": "choice", "criteria": {name: description}}` — into
options; a `null` criterion uses the name as its description. It reads Choice
questions only: `noul` and `score` throw `ArgumentError`.

`toJevJson()` writes the answer's own type:

- Choice: `{"type": "choice", "choice": …, "probabilities": …, "confidence": …}`,
  with `probabilities` and `confidence` only when calibrated. Jev has no
  abstention; an abstained answer has `"choice": null`.
- Noul: `{"type": "noul", "noul": p}`, the probability of `yes`.
- Score: `{"type": "score", "score": …, "legend": {…}, "probabilities": {…},
  "confidence": …}`, `score` the expected level.

## Errors

| Failure | Thrown |
|---|---|
| `InferenceModel.createDecider`: a blank question, an option with examples, a calibration value out of range or a `noneOption` that is not an option, or any of them other than the model was trained with; no options, duplicate ids, an option with nothing to embed, a calibration the options or labelled rows cannot support, an unknown `among` id, a model without installed files or a backend and no `embedderId` | `ArgumentError` |
| A language-model decider's input that is empty, contains a chat template's control text, or renders to a prompt longer than the model's `maxTokens` | `ArgumentError` |
| `DeciderInput.context` to a decider without `supportsContext` (none in this release); `among` to one without `supportsAmong`; an input modality not in `capabilities.modalities` | `DeciderUnsupportedException` |
| `InferenceModel.createDecider` on a model whose engine does not score options (every model on the web), a file without a `litetune.decision` section or with one this release does not read, a backend other than the CPU, a tokenizer that splits the options otherwise than the calibration saw, a decision that cannot fit the model's `maxTokens`, an engine whose scoring self-check gives no answer; a language-model decider's engine returning scores that are not log-probabilities; `toArtifact()` on a decider with nothing to store | `DeciderUnsupportedException` |
| `DeciderMethod.optionScoring` given to `EmbeddingModel.createDecider` | `ArgumentError` |
| An artifact from another embedding space; core's replacement embedder in another space | `DeciderSpaceMismatchException` |
| A malformed, contradictory or newer artifact | `FormatException` |
| An input longer than the model's limit — never truncated | `EmbeddingInputTooLongException` |
| `createDecider`, `choose` or `chooseAll` cancelled; a `choose` running when its decider is closed | `DeciderCancelledException` |
| A vector that is not finite or has the wrong length; an option whose inputs cancel out; `choose` after `close` | `StateError` |

Every error arrives as a failed future.
