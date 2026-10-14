---
name: flutter-edge-ai-decisions
description: Use when an on-device app must pick one of N options for an input — an intent, an action, a screen, a route, a label, or the few tools out of hundreds to offer a small function-calling model — and say "none of these" instead of guessing, with flutter_edge_ai's experimental Decider API (EmbeddingModel.createDecider, DeciderOption, DeciderCalibration, DeciderAnswer, Decider.chooseAll, toArtifact/loadDecider). Also use for Jev Choice JSON on device, when DeciderSpaceMismatchException or DeciderUnsupportedException is thrown, when choose() always abstains or never does, when createDecider refuses a calibration, and when a decider stops working because the embedder was closed. For semantic search over documents, use flutter-edge-ai-rag.
---

# Deciders: pick one of N options on device

Experimental in `flutter_edge_ai` 2.4.0: names may change in a minor release.
Every type and member is `@experimental`, so code using them gets the analyzer
warning `experimental_member_use`; add
`// ignore_for_file: experimental_member_use` to those files rather than let a
CI that fails on warnings fail.

## Rules

1. A decider comes from a model: `EmbeddingModel.createDecider` works with every
   embedding backend. `InferenceModel.createDecider` throws
   `DeciderUnsupportedException` — no engine scores options yet.
2. Options and requests are embedded with `TaskType.sentenceSimilarity`. Give
   each option 5–30 example requests (`examples:`); a `description` alone is
   zero-shot and much weaker (CLINC150, 150 options: 0.75 accuracy from label
   names alone, 0.92–0.94 from 5–10 examples per option, centroid).
3. Abstaining is the hard part, and a softmax cannot do it: with two options any
   request looks confident. The abstain signal is the request's highest cosine
   to an option centroid. The default `DeciderCalibration.crossFit()` fits its
   threshold from the options' own inputs and needs at least two inputs per
   option. A zero-shot option set (descriptions only) cannot cross-fit: use
   `DeciderCalibration.none()`, or `DeciderCalibration.minSimilarity(t)` with a
   `t` you MEASURED for your model file and prompt — never a guessed value.
   Always handle `answer.choice == null`.
4. A raw score is not a probability. `RankedOption.probability`,
   `DeciderAnswer.probabilities` and `DeciderAnswer.confidence` are null unless
   the decider was calibrated with `DeciderCalibration.fromLabelled` on held-out
   labelled requests. `fromLabelled` refuses (`ArgumentError`) rows it cannot
   calibrate on — all answered right with room to spare, or a single row —
   so give it real, partly hard, requests.
5. A decider borrows its embedder and never closes it. On an embedder
   `FlutterEdgeAi.getActiveEmbedder()` returned, the decider follows core: when
   that embedder is closed (core widened it for images or audio, another
   backend, a re-install, a dead worker, or the app closed it), the next
   `choose` takes core's active embedder and retries — or throws
   `DeciderSpaceMismatchException` when that one is another embedding space.
   On a custom `EmbeddingModel` it fails with `EmbedderClosedException` and
   `decider.isClosed` turns true: `loadDecider(toArtifact())` on the new
   embedder, no re-embedding.
6. An artifact is pinned to an embedding space: the installed files (names and,
   natively, sizes — not the bytes), dimension, backend, task prefix, and —
   for a decider fitted on an image — the image budget (EG2: 140 or 70
   tokens). A decider fitted on the CPU file is refused on an NPU bundle
   (`DeciderSpaceMismatchException`); fit it again there. A model that reports
   no backend (LiteRT.js and ONNX on web) and any custom `EmbeddingModel` need
   `embedderId:`, which then names the space instead of the files.
7. Inputs are never truncated: an over-long request fails with
   `EmbeddingInputTooLongException`, naming the option and input when it is an
   option's. `DeciderInput.context` must be empty for an embedding decider, or
   `choose` throws `DeciderUnsupportedException`.
8. `ScoreKind`, `AbstainReason` and `DeciderMethod` are classes with constant
   values, not enums: a `switch` over them needs a default branch.

## Route requests to actions

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

const eg2Revision = '9be6e8b90982095dc05c2bd162e4b954ee4dbac7';

await FlutterEdgeAi.initialize(
  embeddingBackends: const [LiteRtEmbeddingBackend()],
);
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(
      'https://huggingface.co/litert-community/'
      'embeddinggemma-2-text-270m-litert-lm/resolve/$eg2Revision/'
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
      metadata: {'screen': '/timer'},
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
switch (answer.choice) {
  case null:
    // "None of these": answer.abstainReason says why.
    print('abstained: ${answer.abstainReason}');
  case final id:
    print('$id, margin ${answer.margin}, '
        'cosine ${answer.provenance.similarity}');
}
```

`answer.ranked` lists the best `topK` candidates (default 5) with their raw
scores; `answer.margin` is best minus runner-up. `choose(..., among: [...])`
restricts the candidates to some option ids; an empty `among` abstains with
`AbstainReason.noCandidates`.

## Narrow hundreds of tools for a small function-calling model

FunctionGemma 270M has a 1024-token context: it cannot read hundreds of tool
declarations. Let a decider pick the few likely tools, and give only those to
the chat. Keep each tool's declaration in the option's `metadata` or in a map
keyed by option id.

```dart
final toolDecider = await embedder.createDecider(
  options: [
    for (final tool in myTools)
      DeciderOption(tool.name, description: tool.description),
  ],
  calibration: const DeciderCalibration.none(),
);
final picked = await toolDecider.choose(
  DeciderInput(EmbeddingInput.text(prompt)),
  topK: 3,
);
final shortlist = picked.choice == null
    ? <Tool>[]
    : [
        for (final r in picked.ranked)
          myTools.firstWhere((t) => t.name == r.id),
      ];
final toolChat = await model.createChat(
  tools: shortlist,
  supportsFunctionCalls: true,
  modelType: ModelType.functionGemma,
);
```

Descriptions alone cannot cross-fit, so this router never abstains
(`none()`): it always offers the three nearest tools. To let it say "no tool",
give each tool a few example requests and keep the default cross-fit; then
`choice == null` means none fits, and the code above already offers no tool.

## Several decisions over one request

`Decider.chooseAll` answers several deciders for the same input; deciders made
from one `EmbeddingModel` share one embedding of it.

```dart
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
```

## Methods and calibrations

- `DeciderMethod.centroid` (default): cosine to each option's centroid. No
  fitting.
- `DeciderMethod.linear`: softmax regression on the frozen embeddings, weight
  decay 1e-5, fitted when the decider is created. The most accurate with 5–30
  examples per option. Fit time grows with options × inputs: about 0.3 s at
  20 options × 10 examples and 50 s at 150 × 30 on an Apple M4 Pro, release
  (AOT) build; memory about 2 · 20 · (dimension · options + options) · 8 bytes
  (37 MB at 768 × 150, ~0.5 GB at 2000 options). Natively the fit runs on an
  isolate of its own; on web it runs on the page's thread in 4 ms slices,
  yielding to the event loop between them, so the page keeps drawing while it
  fits (Chrome 155, M4 Pro, release build, 150 × 10 synthetic rows:
  10.2–10.8 s dart2js / 11.4–11.8 s wasm, longest 16 ms-timer gap 20–23 ms).
  Scores are log-probabilities (`ScoreKind.logprob`).
- `DeciderCalibration.crossFit({keep: 0.95})` (default), `.minSimilarity(t)`,
  `.none()`, and `.fromLabelled(rows, maxError: 0.05)`, which also fits a
  softmax temperature, so answers carry `probabilities` and a Jev `confidence`.
- `createDecider(cancelToken:, onProgress:)`: the token stops the embedding and
  the fit (`EmbeddingCancelledException`, no decider); `onProgress(done,
  total)` counts the embedded inputs for a progress bar, not the fit after
  them.

## Store and restore

```dart
final fitted = await embedder.createDecider(options: [
  DeciderOption('yes', examples: [
    EmbeddingInput.text('sure'),
    EmbeddingInput.text('go ahead'),
  ]),
  DeciderOption('no', examples: [
    EmbeddingInput.text('stop'),
    EmbeddingInput.text('not now'),
  ]),
]);
final artifact = fitted.toArtifact(); // JSON-encodable, versioned
// …persist jsonEncode(artifact), later jsonDecode it…
final restored = await embedder.loadDecider(artifact);
```

`loadDecider` embeds nothing. It throws `DeciderSpaceMismatchException` for
another embedding space and `FormatException` for an artifact this release
cannot read or that contradicts itself. A model that
`FlutterEdgeAi.getActiveEmbedder()` did not build (a custom subclass, a test
fake) has no installed files to name its space, and a model that reports no
backend cannot tell WebGPU from WASM: pass `embedderId:` to both
`createDecider` and `loadDecider` — an id that names the weights (and the
backend, when the model reports none). It replaces the installed-file check.

A decider of your own (or a test fake) `extends Decider`; `toArtifact()`
defaults to throwing `DeciderUnsupportedException`.

## Jev Choice JSON

```dart
final jevOptions = DeciderOption.fromJevChoice({
  'type': 'choice',
  'instructions': 'Which department should handle this?',
  'criteria': {
    'returns': 'Exchanges, wrong or damaged items',
    'billing': null,
  },
});
// Criteria are descriptions only, so the default cross-fit does not apply.
// PLACEHOLDER — measure the threshold for your model file and prompt; this
// value is not one (0.875 was measured for EmbeddingGemma 2 int4 text 270m
// with 5–10 examples per option, not for descriptions alone). Without a
// measured value, use DeciderCalibration.none() and never abstain.
const measuredThreshold = 0.87;
final jevDecider = await embedder.createDecider(
  options: jevOptions,
  calibration: DeciderCalibration.minSimilarity(measuredThreshold),
);
final jevAnswer = await jevDecider.choose(
  DeciderInput(EmbeddingInput.text(question)),
);
final json = jevAnswer.toJevJson(); // {type, choice, probabilities?, confidence?}
```

Choice questions only; `noul` and `score` throw `ArgumentError`. A `null`
criterion uses the option name as its description. An abstained answer has
`"choice": null`, which Jev itself never sends.
