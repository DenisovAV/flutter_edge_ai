---
name: flutter-edge-ai-decisions
description: Use when an on-device app must pick one of N options for an input — an intent, an action, a screen, a route, a label, or the few tools out of hundreds to offer a small function-calling model — and say "none of these" instead of guessing, with flutter_edge_ai's experimental Decider API (EmbeddingModel.createDecider, InferenceModel.createDecider, DeciderOption, EmbeddingDeciderCalibration, DeciderAnswer, Decider.chooseAll, toArtifact/loadDecider). Also use for Jev Choice JSON on device, when DeciderSpaceMismatchException or DeciderUnsupportedException is thrown, when choose() always abstains or never does, when createDecider refuses a calibration, and when a decider stops working because the embedder was closed. For semantic search over documents, use flutter-edge-ai-rag.
---

# Deciders: pick one of N options on device

Experimental since `flutter_edge_ai` 2.4.0: names may change in a minor release.
Every type and member is `@experimental`, so code using them gets the analyzer
warning `experimental_member_use`; add
`// ignore_for_file: experimental_member_use` to those files rather than let a
CI that fails on warnings fail.

## Rules

1. A decider comes from a model: `EmbeddingModel.createDecider` works with every
   embedding backend. `InferenceModel.createDecider(question:, options:,
   calibration:)` needs a small LLM TRAINED on that one decision (a `.litertlm`
   tuned by LiteTune, which writes the decision into the file), natively, on
   the CPU (`flutter_edge_ai_litertlm` 1.16.0) or the GPU (1.20.0); the NPU,
   any other model, and every model on the web throw
   `DeciderUnsupportedException`. The file's calibration is fitted on the
   CPU: load with `preferredBackend: PreferredBackend.cpu` to use it as
   fitted (a load without it tries the GPU first). Its scoring self-check runs
   in debug and profile builds only (litertlm 1.20.0; release scores in a
   fixed mode): run the decider once in debug on the target hardware. Both return a `Decider` whose `DeciderAnswer` reads the same, so code
   that reads answers (choice, ranked, abstainReason, provenance) needs no
   change when one replaces the other; check `decider.capabilities`
   (`supportsAmong`, `storable`, `calibratedProbabilities`, `modalities`, `questionType`)
   before using what only one kind has.
2. Options and requests are embedded with `TaskType.sentenceSimilarity`. Give
   each option 5–30 example requests (`examples:`); a `description` alone is
   zero-shot and much weaker (CLINC150, 150 options: 0.75 accuracy from label
   names alone, 0.92–0.94 from 5–10 examples per option, centroid).
3. Abstaining is the hard part, and a softmax cannot do it: with two options any
   request looks confident. The abstain signal is the request's highest cosine
   to an option centroid (`answer.provenance.abstainSignal`, of the kind
   `AbstainSignalKind.topCosine`). The default
   `EmbeddingDeciderCalibration.crossFit()` fits its threshold from the
   options' own inputs and needs at least two inputs per option. A zero-shot
   option set (descriptions only) cannot cross-fit: use
   `EmbeddingDeciderCalibration.none()`, or
   `EmbeddingDeciderCalibration.minSimilarity(t)` with a `t` you MEASURED for
   your model file and prompt — never a guessed value.
   With ~5 examples per option among many options the cross-fit's error on
   answered requests can exceed a 5 % budget (CLINC150, 150 options: 6.0 %
   with `DeciderMethod.linear`; not measured, and possibly higher, with the
   default centroid);
   there, calibrate with `fromLabelled` on held-out requests. It sees only
   requests that belong to an option, so check that its threshold still
   refuses the ones that fit none. An audio request against text options
   scores lower than the same request typed (EmbeddingGemma 2 740m: 0.745
   against 0.866 for about the same error), so give spoken requests a decider
   of their own, calibrated on spoken requests. Always handle
   `answer.choice == null`.
4. A raw score is not a probability. `RankedOption.probability`,
   `DeciderAnswer.probabilities` and `DeciderAnswer.confidence` are null unless
   the decider was calibrated with `EmbeddingDeciderCalibration.fromLabelled`
   on held-out labelled requests. `fromLabelled` refuses (`ArgumentError`)
   rows it cannot calibrate on — all answered right with room to spare, or a
   single row — so give it real, partly hard, requests. It also refuses rows
   answered too poorly: it sorts them by their highest cosine to an option
   centroid and looks for a cut that answers the rows above it with at most
   `maxError` (default 0.05) of them wrong (top option not their label); when
   no cut does, add examples per option, use the linear method, or raise
   `maxError`.
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
   option's. `DeciderInput.context` must be empty for every decider in this
   release, or `choose` throws `DeciderUnsupportedException`.
8. `ScoreKind`, `AbstainReason`, `AbstainSignalKind`, `DeciderMethod` and
   `DeciderQuestionType` are classes with constant values, not enums: a
   `switch` over them needs a default branch. Describe an abstention from `abstainSignalKind`, not by
   assuming a cosine: a language-model decider abstains on a probability
   (`topProbability`) or with `AbstainReason.noneOption`.

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
        'cosine ${answer.provenance.abstainSignal}');
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
  calibration: const EmbeddingDeciderCalibration.none(),
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
  calibration: const EmbeddingDeciderCalibration.none(),
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
- `EmbeddingDeciderCalibration.crossFit({keep: 0.95})` (default),
  `.minSimilarity(t)`, `.none()`, and `.fromLabelled(rows, maxError: 0.05)`,
  which also fits a softmax temperature, so answers carry `probabilities` and
  a Jev `confidence`.
- `createDecider(cancelToken:, onProgress:)`: the token stops the embedding and
  the fit (`DeciderCancelledException`, no decider); `onProgress(done,
  total)` counts the embedded inputs for a progress bar, not the fit after
  them. `choose(cancelToken:)` and `Decider.chooseAll(cancelToken:)` fail with
  `DeciderCancelledException` too, as does a `choose` running when its
  decider is closed.

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

A decider of your own (or a test fake) is a `final class … extends Decider`
(or `base`; `Decider` is `abstract base`, so a plain `class` does not compile,
and `implements Decider` does not compile outside core) and implements
`decide(DeciderRequest request)` with `capabilities`, `options`, `isClosed`
and `close()`; `toArtifact()` defaults to throwing
`DeciderUnsupportedException`. Core does not check `isClosed` for you:
`decide` throws `StateError` once the decider is closed, and fails with
`DeciderCancelledException` when `close()` lands while it runs. Do not
override `choose`: it is core's
(`@nonVirtual`), checks the request against `capabilities` (`among`, context,
input modalities, `topK`, the cancel token) and then calls `decide` with the
candidates as option ids. An input modality the decider does not take is a
`DeciderUnsupportedException` for every decider.

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
// measured value, use EmbeddingDeciderCalibration.none() and never abstain.
const measuredThreshold = 0.87;
final jevDecider = await embedder.createDecider(
  options: jevOptions,
  calibration: EmbeddingDeciderCalibration.minSimilarity(measuredThreshold),
);
final jevAnswer = await jevDecider.choose(
  DeciderInput(EmbeddingInput.text(question)),
);
final json = jevAnswer.toJevJson(); // {type, choice, probabilities?, confidence?}
```

`fromJevChoice` reads Choice questions only; `noul` and `score` throw
`ArgumentError`. A `null` criterion uses the option name as its description.
An abstained answer has `"choice": null`, which Jev itself never sends.
`toJevJson()` writes the answer's own `questionType`: a language-model decider
trained on a Noul or Score question returns `{"type": "noul", "noul": p}` or
`{"type": "score", "score": …, "legend": {…}, "probabilities": {…},
"confidence": …}`.

## A language model trained on the decision

For a few options that are a property of the text — a tone, an emotion, yes or
no, a level — a small LLM tuned on exactly that question can decide by scoring
each option's id as its reply. The model is an ordinary `.litertlm`; LiteTune
(0.5.0 or later) writes the decision into it (a `litetune.decision` section:
question, options, temperature, threshold). Pass the question and the trained
options; take the rest from the file with
`InferenceDeciderCalibration.fromModel()`. LiteTune 0.5.0's `bundle` prints
only the `options:` part of the call; the question is in its `contract.json`.
A file from LiteTune 0.6.0 records its scoring `method` and needs
`flutter_edge_ai` 2.5.2; a `fresh_engine` one (LiteTune's Qwen 3.5 rule) is
refused by name.

```dart
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';

await FlutterEdgeAi.initialize(inferenceEngines: const [LiteRtLmEngine()]);
await FlutterEdgeAi.installModel(
  modelType: ModelType.gemmaIt,
  fileType: ModelFileType.litertlm,
).fromFile(path).install();
// CPU or GPU; the NPU is refused. The file's temperature and threshold are
// fitted on CPU probabilities: on the GPU the top option matched the CPU's
// on 97-100 % of rows measured (Metal, Adreno 830, yes/no questions only);
// Mali, Linux and Windows GPUs and the abstain threshold on the GPU are not
// measured. The CPU keeps the calibration as fitted.
final llm = await FlutterEdgeAi.getActiveModel(
  preferredBackend: PreferredBackend.cpu,
);
final emotion = await llm.createDecider(
  question: 'Which emotion does the text express?',
  options: [
    DeciderOption('sadness'), DeciderOption('joy'), DeciderOption('love'),
    DeciderOption('anger'), DeciderOption('fear'), DeciderOption('surprise'),
  ],
  calibration: const InferenceDeciderCalibration.fromModel(),
);
const userText = 'im feeling far more mellow than normal';
final answer = await emotion.choose(DeciderInput(EmbeddingInput.text(userText)));
switch (answer.questionType) {
  case DeciderQuestionType.noul:
    print('P(yes) = ${answer.noul}');
  case DeciderQuestionType.score:
    print('level ${answer.expectedLevel} of ${answer.legend}');
  default:
    print(answer.choice ?? 'none of these (${answer.abstainReason})');
}
```

- The call must be the trained one: another question, a missing or extra
  option, or another description (one equal to the id is fine) throws
  `ArgumentError` naming the trained value. Option order is free.
- Prefer `fromModel()`: explicit temperature, threshold and `noneOption` must
  equal the file's, which pins the app to one build of the model.
- A model trained with a "none of these" option: with `fromModel()` it may be
  left out of `options:` (the decider lists it last); when it ranks first the
  answer abstains with `AbstainReason.noneOption`.
- The decider borrows the active model: when core closes it (another model or
  another `maxTokens` requested), the decider is closed too; create it again.
  On a model from `FlutterEdgeAi.openModel`, closing that model closes it.
- Options carry no `examples:`: a language-model decider refuses them with
  `ArgumentError`.
- A decision whose question and options alone exceed `maxTokens` fails
  `createDecider` with `DeciderUnsupportedException`; load the model with a
  larger `maxTokens`.
- Noul (`no`/`yes`) and Score (levels `0`…`K − 1`) questions never abstain.
- Text input only, no `among`, no `context`. Input containing chat-template
  control text (`<start_of_turn>`, `<end_of_turn>`, `<bos>`, …), or whose
  prompt does not fit `maxTokens`, throws `ArgumentError` — never truncated.
- One decision costs one scoring pass per option (176 ms for 6 options on an
  Apple M4 Pro CPU; LiteTune measured 5.0 s for 55 and 7.2 s for 151 on a server
  CPU). Many options by topic belong to an embedding decider.
