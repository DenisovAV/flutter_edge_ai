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
runs on device, costs one embedding per input, and needs no training.

<Warning>

Experimental in `flutter_edge_ai` 2.4.0. Every type and member is
`@experimental`: names and behaviour may change in a minor release, and code
that uses them gets the analyzer warning `experimental_member_use`. Add
`// ignore_for_file: experimental_member_use` to the files that use it.

</Warning>

## Packages

```
dependencies:
  flutter_edge_ai: ^2.4.0
  flutter_edge_ai_litertlm: ^1.13.2 # EmbeddingGemma 2 (.litertlm) and 1 (.tflite)
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
   once, at `createDecider`, with `TaskType.classification`. The input to
   decide on gets the same prefix: EmbeddingGemma 2's model card asks for one
   prefix on every compared input.
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
   `choice: null` and `AbstainReason.belowThreshold`.

`answer.ranked` holds the best `topK` candidates (default 5), best first; on a
tie the option given first ranks first. `answer.margin` is best minus
runner-up. `choose(input, among: [...])` restricts the candidates to some
option ids: an unknown id throws `ArgumentError`, an empty set abstains with
`AbstainReason.noCandidates` without embedding anything.

### A raw score is not a probability

A cosine of 0.83 does not mean 83 %. `RankedOption.probability`,
`DeciderAnswer.probabilities` and `DeciderAnswer.confidence` are **null**
unless the decider was calibrated on held-out labelled requests
(`DeciderCalibration.fromLabelled`), which fits a softmax temperature. One
formula decodes every method's raw scores: `softmax(score / T)` over the
candidates. `confidence` is Jev's spread measure, `(N · pmax − 1) / (N − 1)`:
0 for a uniform distribution, 1 when one option takes everything. It is not an
accuracy.

## Calibration: when to say "none of these"

| Calibration | Threshold | Needs |
|---|---|---|
| `DeciderCalibration.crossFit({keep: 0.95})` — default | The options' own inputs: 5-fold cross-fit (input `i` of each option in fold `i % 5`), each held-out input scored against the other folds' centroids, threshold keeps `keep` of them | Two inputs per option |
| `DeciderCalibration.minSimilarity(t)` | A fixed cosine `t` | A value measured for your model file and prompt |
| `DeciderCalibration.fromLabelled(rows, maxError: 0.05)` | The lowest cosine at which labelled rows keep their error within `maxError`; plus a temperature → probabilities | Held-out labelled requests, not the examples |
| `DeciderCalibration.none()` | Never abstains | — |

A softmax probability cannot abstain: with two options any request looks
confident. Measured with EmbeddingGemma 2 on CLINC150 (k = 10 examples per
option), a 5 %-budget threshold on the softmax rejects 2.7–21.7 % of
out-of-subset requests at 2–20 options; the cross-fitted cosine rejects
87–99 %.

## Measured accuracy

All numbers: Google's int4 `embeddinggemma-2-text-270m.litertlm` through
LiteRT-LM 0.18.0's EmbeddingEngine on a CPU, the classification prompt,
CLINC150 (its own out-of-scope rows as "none of these"). They are the
decision measurements this API reproduces numerically; one data set, English,
one-sentence requests.

| Setting | Result |
|---|---|
| 150 options, label names only (zero-shot) | 0.685–0.756 accuracy |
| 150 options, centroid, 5 / 10 examples | 0.887–0.895 / 0.899–0.910 |
| 150 options, linear, 5 / 10 / 30 examples | 0.907–0.913 / 0.927–0.933 / 0.946 |
| 2–20 options, linear, 5 examples | argmax accuracy 0.981–0.997 |
| 2–20 options, linear, cross-fit, 10 examples | 90–94 % of in-scope answered, ≤ 0.8 % error on them, 87–99 % of out-of-subset and 96–99.5 % of CLINC out-of-scope refused |
| 150 options, linear, cross-fit, 5 / 10 / 30 examples | out-of-scope refused 80 / 85 / 90 %; error on answered 6.8 / 4.9 / 3.6 % |
| Linear, fixed cosine 0.825–0.85, 2–20 options | about as good as the cross-fit for this file and prompt |

Which inputs are answered and refused depends only on the abstain signal and
its threshold, the same for both methods; the error on the answered ones was
measured with `linear`, and `centroid` makes more (it is less accurate). At 150
options with 5 examples, the cross-fit's error (6.8 %) is over a 5 % budget:
calibrate with `fromLabelled` there. Not measured yet: another data set
for "none of the above", requests longer than a sentence, languages other than
English, and accuracy on platforms other than Android and a cloud CPU.

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

Fitting `linear` (softmax regression, float64 L-BFGS on a background isolate)
on an Apple M4 Pro, release (AOT) build:

| Options × examples | Fit |
|---|---|
| 2 × 10 | 4 ms |
| 10 × 10 | 0.1 s |
| 20 × 10 | 0.3 s |
| 50 × 10 | 1.9 s |
| 150 × 5 / 10 / 30 | 7.2 / 16.4 / 50 s |

`centroid` fits nothing; its default cross-fit took 0.2 s at 150 × 30. On web
the fit runs inline and blocks the page while it runs.

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
    calibration: const DeciderCalibration.none(),
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
    calibration: const DeciderCalibration.minSimilarity(0.6),
  );
  final picked = await router.choose(
    DeciderInput(EmbeddingInput.text(request)),
    topK: 3,
  );
  return model.createChat(
    tools: [
      for (final r in picked.ranked) tools.firstWhere((t) => t.name == r.id),
    ],
    supportsFunctionCalls: true,
    modelType: ModelType.functionGemma,
  );
}
```

A fixed threshold belongs to one model file and one prompt; measure yours, or
give each tool a few example requests and keep the default cross-fit.

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

The artifact is pinned to its **embedding space**: the model's installed file
names, the dimension, the backend and the task prefix. A decider fitted on the
CPU file is refused on a per-SoC NPU bundle with
`DeciderSpaceMismatchException` — their vectors sit at cosine 0.8–0.9 to each
other. A malformed or newer artifact is a `FormatException`. Media examples are
not stored (their count is); a restored option lists its text examples.

A decider borrows its embedder and never closes it. When core replaces the
active embedder — another backend, image or audio support — `choose` fails with
`EmbedderClosedException`: load the artifact on the new embedder.

A model that `FlutterEdgeAi.getActiveEmbedder()` did not build (a custom
subclass, a test fake) has no installed files to name its space; pass
`embedderId:` to `createDecider` and `loadDecider`.

## Jev Choice JSON

`DeciderOption.fromJevChoice(question)` turns a Jev (TypeSafe AI) Choice
question — `{"type": "choice", "criteria": {name: description}}` — into
options; a `null` criterion uses the name as its description. `toJevJson()`
returns `{"type": "choice", "choice": …, "probabilities": …, "confidence": …}`,
with `probabilities` and `confidence` only when calibrated. Choice questions
only: `noul` and `score` throw `ArgumentError`. Jev has no abstention; an
abstained answer has `"choice": null`.

## Errors

| Failure | Thrown |
|---|---|
| No options, duplicate ids, an option with nothing to embed, a calibration the options cannot support, an unknown `among` id | `ArgumentError` |
| `DeciderInput.context` given to an embedding decider | `DeciderUnsupportedException` |
| `InferenceModel.createDecider` (no engine scores options yet) | `DeciderUnsupportedException` |
| An artifact from another embedding space | `DeciderSpaceMismatchException` |
| A malformed or newer artifact | `FormatException` |
| An input longer than the model's limit — never truncated | `EmbeddingInputTooLongException` |
| A vector that is not finite or has the wrong length; `choose` after `close` | `StateError` |

Every error arrives as a failed future.
