author: Sasha Denisov
summary: On-Device RAG in Flutter — Embeddings and Vector Search
id: on-device-rag-flutter-gemma
categories: flutter, ai, gemma, rag
environments: android, ios, macos, windows, linux, web
status: Published

# On-Device RAG in Flutter: Embeddings and Vector Search

## Overview
Duration: 3

### What you'll build

A recipe assistant that answers from *your* documents, with the network
switched off at every step. It embeds a corpus with EmbeddingGemma, stores the
vectors in sqlite-vec, retrieves the relevant ones for each question, and hands
them to the on-device model as context.

By the end you will have an app that:

* embeds a corpus on-device and shows you what an embedding actually is
* writes the vectors into a vector store that survives a restart
* searches by meaning — "something warm with beans" finds ribollita, which
  never uses the word "warm"
* filters that search by cuisine, cooking time and diet, **inside** the query
* answers questions grounded in what it retrieved, and shows the sources

### What you'll learn

The code is short. What takes the hour is the handful of decisions RAG asks you
to make, and each step here is built around one of them:

* why an embedding model needs **two** files, and what `seq256` is not
* why the tokenizer is registered **separately from the backend**, and what
  breaks when you skip it
* why queries and documents are embedded with **different prefixes**, and why
  getting that wrong throws nothing
* what a vector store buys you over a `List<double>` — three answers, only one
  of which is speed
* why a filter field has to be **declared before** the first row is written
* where an index actually becomes durable, which is not the same place on
  every store

### What you'll need

* Flutter **3.47** or newer — higher than the rest of flutter_edge_ai asks for.
  `flutter_edge_ai_sqlite` 1.5.0 requires sqlite3 3.6.0, whose build
  toolchain wants `meta ^1.19.0`, and every Flutter 3.44.x pins `meta` to
  1.18.0 exactly. On 3.44 the Step 3 app will not resolve
* Any one of Flutter's six platforms: an arm64 Android device or emulator, an
  iOS device or simulator, an Apple-silicon Mac, a Windows or Linux desktop, or
  Chrome. Everything in this codelab runs on all six — including the web, which
  is the reason Step 3 picks the store it does
* About 0.8 GB free: the language model from the Getting Started codelab
  (0.6 GB) plus EmbeddingGemma (0.2 GB). On the web the language model is a
  different, larger build — about 2.2 GB in total
* A free Hugging Face account with the Gemma licence accepted. Both models sit
  behind the same gate, so one `--dart-define=HF_TOKEN=hf_...` covers both

**Watch out:** This codelab continues [Getting Started with On-Device LLMs](/codelabs/getting-started-flutter-gemma). Its finished app **is** this one's starter, byte for byte — a CI check enforces it. If you have not done that codelab, `step_01_starter` still runs on its own; you will just be meeting the download-and-chat code for the first time.

### Get the code

Every step of this codelab exists as a complete, runnable app, so you can join
at any point or check your work against the next one.

```bash
git clone --depth 1 https://github.com/DenisovAV/flutter_edge_ai.git
cd flutter_edge_ai/codelabs/on-device-rag-flutter-gemma
ls
```

```text
step_01_starter/     the chat app you start from
step_02_embed/       after Step 2 — the corpus, embedded
step_03_store/       after Step 3 — a real vector store
step_04_filters/     after Step 4 — filtered search
step_05_grounded/    after Step 5 — answers with sources
complete/            after Step 6 — the finished app
```

## Step 1: The starter app
Duration: 3

Open `step_01_starter` and run it.

```bash
cd step_01_starter
flutter run --dart-define=HF_TOKEN=hf_your_token
```

You get the finished app from Getting Started: it downloads a model once,
then chats with it offline. Nothing in it knows anything about your documents —
ask it about a recipe and you get whatever was in the weights.

That is the gap this codelab closes. RAG — retrieval-augmented generation — is
three moving parts, and the model is only the last one:

1. **Embed**: turn each document into a vector that captures its meaning.
2. **Retrieve**: given a question, find the documents whose vectors point in a
   similar direction.
3. **Generate**: hand those documents to the model as context, and let it
   answer from them.

Steps 2 to 5 build exactly those three, in order.

## Step 2: Embed your documents
Duration: 12

### The corpus

`lib/recipes.dart` is twelve recipes, in plain Dart — no asset bundle, no
network. A corpus you can read in one screen beats one you have to go fetch.

```dart
class Recipe {
  final String id;
  final String title;
  final String text;
  final String cuisine;
  final int minutes;
  final bool vegetarian;
}
```

The three fields after `text` are not decoration. Step 4 turns them into
filters, and between them they cover every condition the API has: a **string**,
a **number** and a **bool**.

**Good to know:** Only `text` is embedded. The vector is built from that string and nothing else, so anything you want the search to match on has to be *in* it — a title that lives only in a field beside it is invisible to retrieval.

### Add the packages

```bash
flutter pub add flutter_edge_ai_embeddings
```

One package, and it is not an engine. `flutter_edge_ai_litertlm` — already in the
app — supplies `LiteRtEmbeddingBackend`, the thing that runs the forward pass.
`flutter_edge_ai_embeddings` supplies the **tokenizers**. They are separate on
purpose, and Step 2's whole registration hinges on why.

### Register the backend and the tokenizer

In `lib/main.dart`:

```dart
await FlutterEdgeAi.initialize(
  inferenceEngines: [LiteRtLmEngine()],
  embeddingBackends: [LiteRtEmbeddingBackend()],
  embeddingTokenizers: [GemmaEmbeddingTokenizers()],
  // ...
);
```

Two lines, two packages, and the reason matters.

Which tokenizer an embedding model needs is a property of the **model**, not of
the engine that runs it: EmbeddingGemma wants SentencePiece whether LiteRT or
ONNX Runtime executes it, and a BERT-family model wants WordPiece under either.
That registry change shipped in the legacy `flutter_gemma` 1.9.0 package and is
part of the current `flutter_edge_ai`; the backend no longer carries a
tokenizer, and the app says which families it has.

**Watch out:** Leave `embeddingTokenizers` out and the first embedding throws a `StateError` naming the package to add. That is the design working: the alternative — falling back to one family and tokenizing with the wrong convention — returns vectors that are quietly the wrong point in the embedding space, and no test downstream can tell them from good ones.

### Pick an embedding model

```dart
static const embeddingGemma = EmbedderChoice(
  profileId: 'embeddinggemma-300m-seq256-mp-rev-29888fcee321-'
      'retrieval-prefix-meanpool-l2-v1',
  modelUrl: 'https://huggingface.co/litert-community/embeddinggemma-300m/'
      'resolve/29888fcee3216acadc7e844906e5fe0d79a61875/'
      'embeddinggemma-300M_seq256_mixed-precision.tflite',
  tokenizerUrl: 'https://huggingface.co/litert-community/embeddinggemma-300m/'
      'resolve/29888fcee3216acadc7e844906e5fe0d79a61875/'
      'sentencepiece.model',
  sizeLabel: '0.2 GB',
  requiresToken: true,
);
```

Two files, and both are required: the `.tflite` holds the weights,
`sentencepiece.model` turns text into the ids those weights expect. There is no
tokenizer baked into the graph — hand over only the first and the install
fails.

**Good to know:** `seq256` is the **sequence length in tokens**, not the embedding dimension. The vectors are 768 long either way; 256 is how much text fits into one forward pass before it is truncated. Every recipe here is comfortably shorter.

### Install it and embed

```dart
await FlutterEdgeAi.installEmbedder()
    .modelFromNetwork(e.modelUrl, token: hfToken)
    .tokenizerFromNetwork(e.tokenizerUrl, token: hfToken)
    .withModelProgress((p) => setState(() => _installProgress = p / 100))
    .install();

final embedder = await FlutterEdgeAi.getActiveEmbedder();
final vectors = await embedder.generateEmbeddings(
  kRecipes.map((r) => r.text).toList(),
  taskType: TaskType.retrievalDocument,
);
```

`install()` is idempotent — the bytes are fetched once, and the second run of
that button skips straight past the download. Progress is a link in the
builder chain, not an argument to `install()`.

One call for the whole corpus rather than a loop: the worker isolate is set up
once and the model stays resident between texts.

### The prefix that throws nothing

`taskType` is the part worth slowing down for. EmbeddingGemma was trained with
a different prefix for documents than for queries, and the enum is where that
lives:

```text
TaskType.retrievalDocument  ->  'title: none | text: '
TaskType.retrievalQuery     ->  'task: search result | query: '
```

Index your corpus with the query prefix and nothing errors. The vectors simply
land slightly off, every search afterwards is a little worse, and no exception
will ever point at it.

**Watch out:** This is the one place in the codelab you have to get right by hand. From Step 3 on, `RagIndex.searchText(query:)` embeds the query for you and uses `retrievalQuery` by default — so the two halves stay matched as long as you index with `retrievalDocument`.

### Wire it into the app

`lib/embed_page.dart` is a new screen — the full file is in `step_02_embed`,
and the parts that matter are above. Two small changes put it in reach.

The Hugging Face token was a private constant in `main.dart`. Both the model
download and the embedder install need it now, and they live on different
pages, so it moves to `lib/model.dart` where both already import from:

```dart
// lib/model.dart
const hfToken = String.fromEnvironment('HF_TOKEN');
```

Then give the chat screen a way in — an action in its app bar:

```dart
// lib/chat_page.dart
import 'embed_page.dart';

// ...in the AppBar's actions, before the delete button:
IconButton(
  tooltip: 'Recipes',
  onPressed: () => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const EmbedPage(hfToken: hfToken),
    ),
  ),
  icon: const Icon(Icons.restaurant_menu),
),
```

### Web setup

Skip this unless you are running in Chrome — but do not skip it *and* then run
in Chrome, because the Embed button is the first thing that fails.

Embedding in a browser runs through LiteRT.js, which ships as four files in
`flutter_edge_ai_litertlm/web/`. Copy them into your own `web/`, the same way
`cache_api.js` was copied in Getting Started:

```text
litert.js   litert_embeddings.js   sentencepiece.js   tensorflow.js
```

Then load the entry point from `web/index.html`:

```html
<script type="module" src="litert_embeddings.js"></script>
```

That is all of it — the WASM runtime underneath is fetched from a CDN, so
there is nothing else to host.

### Run it

Tap the recipes icon in the app bar, then **Embed the corpus**. After the
download you get twelve green ticks and, at the bottom, what an embedding
actually is:

```text
768 dimensions
[-0.0147, 0.0412, -0.0038, 0.0221, 0.0095, -0.0176, ...]
```

That is the whole representation. Two recipes are "similar" when those two
lists of numbers point in a similar direction — which is all a vector search
ever computes.

Leave the page and come back. The ticks are gone. The vectors lived in a
`Map` in the widget, and that is what Step 3 is about.

## Step 3: Store and search
Duration: 14

### Why not just keep the Map

A `Map<String, List<double>>` and a hand-written cosine loop is where most RAG
tutorials stop, and it does work — on twelve documents, once. Three things are
wrong with it, and a bigger `Map` fixes none of them:

1. **It does not survive a restart.** Re-embedding twelve recipes takes
   seconds; re-embedding a real corpus on every cold start is not something you
   can ship.
2. **It costs twice what you think.** A Dart `double` is a *float64*, so one
   768-dimension vector is 768 × 8 = **6 KB** — not the 3 KB the model emits.
   Ten thousand documents is 60 MB of Dart heap, sitting beside an LLM that
   already wants a gigabyte or two.
3. **There is nothing to filter on.** "Italian, under 30 minutes" has to happen
   either before the search — and then it is not a nearest-neighbour search any
   more — or after it, and then your top-3 can come back empty.

A vector store fixes all three for the same reason: the vectors stop being a
Dart object and become rows in a database that knows they are vectors.

### Choose your store

RAG orchestration lives in `flutter_edge_ai_rag`; storage providers remain
replaceable packages. This codelab uses **sqlite-vec**, and the table says why.
The code from here on talks to `RagIndex`, so changing storage does not rewrite
the indexing, retrieval, filter, or grounding pipeline.

| | `flutter_edge_ai_sqlite` | `flutter_edge_ai_qdrant` |
|---|---|---|
| Platforms | all six, **including web** | five — **no web** |
| Search | exact KNN, always | exact below 10 000 points, approximate (HNSW) above |
| Scaling | brute force, linear in N | wins on large corpora |
| `flush()` | no-op on native, drains IndexedDB on web | **required** — points stay in memory until it is called |
| Schema timing | at table creation — a new filter field means re-creating and re-indexing | at write time — declare and re-index |
| Field names | `^[A-Za-z][A-Za-z0-9_]*$` | free-form UTF-8, no `.` |

**Good to know:** The precision row surprises people. qdrant's `fullScanThreshold` defaults to 10 000 points — below that it does a full scan and is exactly as precise as sqlite-vec. For a corpus that fits on a phone you are usually not choosing between exact and approximate at all; you are choosing between "runs in Chrome" and "grows better".

The last row is the one that quietly decides the others: the portable set is
sqlite's. If you might ever switch backends, stay inside it — which is why this
codelab's fields are named `cuisine`, `minutes` and `vegetarian` and not
`prep-time`.

```bash
flutter pub add flutter_edge_ai_rag flutter_edge_ai_sqlite path_provider
```

### Create one app-owned RAG service

```dart
final rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
```

`FlutterEdgeAiRag` is deliberately independent of `FlutterEdgeAi.initialize()`.
The provider chooses the native sqlite3/FFI implementation or the web
SQLite/WASM implementation internally. Keep one `RagStore` service and one
open `RagIndex` per location; on the web an open SQLite index owns an exclusive
Web Lock for that location.

### Web setup

One more file, and it needs no `<script>` tag. Copy the store's SQLite build
from `flutter_edge_ai_sqlite/web/rag/`:

```text
web/rag/sqlite3.wasm
```

`WebSqliteVectorStore` fetches it by that exact relative path. It is a SQLite
compiled with sqlite-vec linked in — which is why it comes from the package
rather than a CDN, and why the store is a package rather than a few lines of
SQL.

### Open, index, search

`lib/rag_store.dart` owns the orchestrator and caches one in-flight open:

```dart
final FlutterEdgeAiRag _rag = FlutterEdgeAiRag(
  providers: const [SqliteVectorStoreProvider()],
);
Future<RagIndex>? _opening;

Future<RagIndex> _index() => _opening ??= _openOnce();

Future<RagIndex> _openOnce() async {
  const embedder = Embedders.embeddingGemma;
  return _rag.open(
    spec: VectorStoreSpec(
      providerId: SqliteVectorStoreProvider.providerId,
      location: await databasePath(),
    ),
    embeddingProfile: EmbeddingProfile(id: embedder.profileId, dimension: 768),
    activeEmbedderProfileId: embedder.profileId,
  );
}
```

The runnable app uses the stable profile ID
`embeddinggemma-300m-seq256-mp-rev-29888fcee321-retrieval-prefix-meanpool-l2-v1`
and pins both Hugging Face URLs to revision `29888fcee3216acadc7e844906e5fe0d79a61875`.
The database name is `recipes-embeddinggemma-29888fcee321-unfiltered-v1.db`:
model/profile and physical schema changes get a new location instead of
silently mixing incompatible vectors. On web the bare name identifies an
IndexedDB-backed VFS; native platforms use a full documents-directory path.

Writing a row takes the vector you already have:

```dart
await (await _index()).addVector(
  id: r.id,
  content: r.text,
  embedding: vectors[i],
  metadata: jsonEncode({
    'title': r.title, 'cuisine': r.cuisine,
    'minutes': r.minutes, 'vegetarian': r.vegetarian,
  }),
);
```

**Good to know:** There is also `addText(content:)`, which embeds for you.
This codelab already batch-embeds twelve documents, so `addVector` avoids doing
that work twice. `id` is what a search result hands back, so it has to stay
stable across re-indexes.

And searching takes text, not a vector:

```dart
await (await _index()).searchText(
  query: query,
  topK: 3,
  threshold: 0.3,
);
```

The query is embedded for you, with `retrievalQuery` — the other half of Step
2's asymmetry, handled.

**Watch out:** `threshold` is not optional in spirit. Cosine similarity runs 0.0 to 1.0, and without a threshold a search always returns `topK` rows however bad they are — which reads as "found something" to every caller downstream, including the model in Step 5.

### The page

`lib/embed_page.dart` changes shape with the store under it, and the full file
is in `step_03_store`. Step 2's screen embedded and showed you a vector; this
one opens the store on `initState`, reports what is already in it, and adds a
search field:

```dart
@override
void initState() {
  super.initState();
  _open();          // RagStore.open() — the row count comes from a past run
}
```

The header now reads **12 rows · 768 dimensions** rather than counting ticks,
which is the whole difference: those numbers come from disk, not from this
session.

### Run it

Index once, then search for **something warm with beans**. Ribollita comes
first, at around 0.6 — and the word "warm" appears nowhere in it. That is the
difference between semantic search and `LIKE '%warm%'`.

Now kill the app and reopen the recipes page. The header still says
**12 rows · 768 dimensions**, and searching works without embedding anything
again. The index is on disk.

## Step 4: Filters
Duration: 12

Search finds things by meaning. "Italian, under half an hour, no meat" is not a
question about meaning — it is three predicates, and they belong inside the
query rather than around it.

### Declare what is filterable

```dart
final ragStore = RagStore(
  databaseName: 'recipes-embeddinggemma-29888fcee321-filters-v1.db',
  filterSchema: FilterSchema(
    fields: [
      FilterField(name: 'cuisine', type: FilterFieldType.string),
      FilterField(name: 'minutes', type: FilterFieldType.number),
      FilterField(name: 'vegetarian', type: FilterFieldType.bool),
    ],
  ),
);
```

`FilterFieldType` has exactly three values, and the corpus uses all three.
The schema is part of `VectorStoreSpec` when `RagStore` opens its index, and that
timing is the whole point on sqlite-vec: each declared field becomes a real
typed `vec0` column, and vec0 has no `ALTER`. Adding a filter field later means
using a new schema-versioned location and re-indexing the corpus.

**Watch out:** A `Filter` over a field that was never declared is **silently dropped**. The search comes back unfiltered — no error, no log in a release build, just more results than you asked for. Declare what you might filter on, not only what you filter on today.

### Build a filter

```dart
Filter? buildFilter({
  Set<String> cuisines = const {},
  int? maxMinutes,
  bool vegetarianOnly = false,
}) {
  final must = <Condition>[
    if (cuisines.isNotEmpty)
      FieldMatchAny(key: 'cuisine', values: cuisines.toList()),
    if (maxMinutes != null)
      FieldRange(key: 'minutes', lte: maxMinutes.toDouble()),
    if (vegetarianOnly) FieldEquals(key: 'vegetarian', value: true),
  ];
  return must.isEmpty ? null : Filter(must: must);
}
```

Three conditions, which is all of them:

* **`FieldMatchAny`** — `metadata[key] in values`. Set membership, so "italian
  or greek" is one condition rather than two ORed together.
* **`FieldRange`** — inclusive `gte` / `lte`, either of which may be null.
* **`FieldEquals`** — one value, any of the three field types.

They combine by where they sit: `must` is AND, `should` is OR, `mustNot` is
NOT. An empty `Filter` is not "match nothing" — the store checks `isEmpty` and
skips filtering entirely.

### Pass it to the search

```dart
await (await _index()).searchText(
  query: query,
  topK: 3,
  threshold: 0.3,
  filter: filter,
);
```

**Good to know:** The filter is applied **inside** the store, as part of the same query that ranks by distance. That is what makes it different from filtering the results afterwards: `topK` still means three, and all three cleared the predicates.

### The controls

One control per declared field, above the results — the full widget is in
`step_04_filters`:

```dart
for (final c in const ['italian', 'greek', 'indian', 'japanese'])
  FilterChip(
    label: Text(c),
    selected: _cuisines.contains(c),
    onSelected: (on) =>
        setState(() => on ? _cuisines.add(c) : _cuisines.remove(c)),
  ),
```

plus one for **under 30 min** and one for **vegetarian**, which set
`_maxMinutes` and `_vegetarianOnly`. Those three pieces of state are exactly
what `buildFilter` above takes.

### Run it

Search for **something warm with beans** with no filters: ribollita, then
gigantes plaki. Now tick **under 30 min** and search again — both are gone, and
what comes back is whatever bean-adjacent recipe is quick. Tick **japanese**
and the corpus has no beans at all in that cuisine, so you get nothing: an
empty result, not a bad one.

## Step 5: Ground the answer
Duration: 8

Retrieval on its own gives a list. Grounding is handing that list to the model
and constraining it to answer from there.

```dart
final hits = await widget.ragStore.search(text);

final prompt = hits.isEmpty
    ? text
    : '''
Answer the question using only the recipes below. If they do not contain the
answer, say so rather than inventing one.

${hits.map((h) => '- ${RagStore.recipeFor(h)?.title}: ${h.content}').join('\n')}

Question: $text''';

await chat.addQueryChunk(Message.text(text: prompt, isUser: true));
```

The model never sees the vector store. It sees text — the retrieved recipes,
and the question, in one turn.

**Good to know:** A search that returns nothing is not an error and not a reason to stop. The model still answers, from its own weights; the UI says so by showing no sources under the reply. Refusing to answer at all would be a worse app than one that is occasionally ungrounded and visibly says which.

### Show the sources

```dart
if (_sources.isNotEmpty)
  Wrap(children: [
    for (final h in _sources)
      Chip(label: Text('${RagStore.recipeFor(h)?.title} · '
          '${h.similarity.toStringAsFixed(2)}')),
  ]),
```

A grounded answer the user cannot check is not obviously better than an
ungrounded one. The chips are the difference between "trust me" and "here is
where this came from, and how close it was".

### Run it

Ask **what can I make with beans that isn't Italian?** The sources strip shows
gigantes plaki, and the answer talks about it rather than about ribollita. Ask
something the corpus has no answer to — **how do I make sourdough?** — and
watch the model say so instead of inventing one, because the prompt told it to
and because no recipe cleared the threshold.

## Step 6: Survive a restart
Duration: 5

The index is on disk from Step 3, but the app must not let each page open its
own handle. Create one app-owned service at startup and pass it to both chat and
the recipes page. The first caller opens it lazily, so the first question can be
grounded without visiting the recipes page first:

```dart
await FlutterEdgeAi.initialize(/* inference and embedding runtimes */);
final ragStore = RagStore(
  databaseName: 'recipes-embeddinggemma-29888fcee321-filters-v1.db',
  filterSchema: FilterSchema(fields: [
    FilterField(name: 'cuisine', type: FilterFieldType.string),
    FilterField(name: 'minutes', type: FilterFieldType.number),
    FilterField(name: 'vegetarian', type: FilterFieldType.bool),
  ]),
);

runApp(QuickstartApp(ragStore: ragStore));
```

The app passes that same service through its widget tree. `RagStore.open()` is
single-flight, so the first page or query opens the index and concurrent callers
join it. At shutdown dispose the index before the core runtime whose active
embedder it borrows:

```dart
await ragStore.dispose();
await FlutterEdgeAi.dispose();
```

### Where an index actually becomes durable

`flush()` is the one call whose meaning changes with the store underneath it:

* **sqlite-vec, native** — a no-op. Every statement was on disk when it
  returned.
* **sqlite-vec, web** — drains the IndexedDB VFS and waits for it. The VFS
  writes asynchronously and its `xSync` is a documented no-op, so without this
  the last batch can still be in flight when the tab goes away.
* **qdrant-edge** — **required**. New points stay in memory until the store is
  flushed or closed. An index built without either is lost when the process
  ends, and an Android app killed in the background is the ordinary case, not
  the edge one.

Which is why `RagStore.index()` calls it unconditionally rather than behind
`if (kIsWeb)`: it costs nothing where it is a no-op, and it is the difference
between a saved index and a lost one everywhere else.

**Watch out:** `close()` persists too, but it reports differently: on qdrant-edge a failed save is only logged, while `flush()` throws it. If you want to know that the index was saved, flush.

### Run it offline

Index the corpus, then turn the network off — airplane mode, or your Wi-Fi
switch. Ask the app anything about the recipes.

The download is the only thing that ever needed a connection. Embedding,
search, filtering and generation all run on the device, which is the claim this
codelab set out to make good on.

## What's next
Duration: 3

Three parts, all local: a model that turns text into vectors, a database that
knows those vectors are vectors, and a prompt that keeps the answer honest.

* **Swap the store.** Add `QdrantVectorStoreProvider()` to the orchestrator and
  select its provider ID in `VectorStoreSpec`. The `RagIndex` calls stay the
  same. You give up the web and gain HNSW on large corpora.
* **Bring your own corpus.** Nothing here is recipe-shaped except
  `recipes.dart`. Twelve constants become a folder of Markdown, and the only
  real design decision is what goes into `text` versus what becomes a filter
  field.
* **[Hybrid AI with Genkit](/codelabs/hybrid-ai-flutter-genkit)** puts the same
  RAG behind a router that decides per message whether the cloud or the device
  should answer.

### Reference

* [Embeddings & RAG documentation](/docs/embeddings-and-rag) — the full filter
  grammar, the store comparison, and the per-store `flush()` table
* [flutter_edge_ai_sqlite on pub.dev](https://pub.dev/packages/flutter_edge_ai_sqlite)
* [Source and this codelab's code](https://github.com/DenisovAV/flutter_edge_ai)
