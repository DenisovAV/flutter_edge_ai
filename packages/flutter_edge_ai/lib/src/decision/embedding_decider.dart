// The decider every EmbeddingModel gets: options as centroids of their
// embedded inputs, optionally a fitted linear layer, and a calibrated abstain
// threshold. Implemented once, over `embed`/`embedAll`, so every embedding
// backend has it. Not exported: apps receive it as a `Decider`.

import 'dart:async';
import 'dart:collection' show LinkedHashMap;
import 'dart:convert'
    show JsonUnsupportedObjectError, base64, jsonDecode, jsonEncode;
import 'dart:math' as math;
import 'dart:typed_data';

import '../embedding/common_embedding_model.dart'
    show CommonEmbeddingModel, EmbedderReplacement;
import '../embedding/embedding_exceptions.dart'
    show EmbedderClosedException, EmbeddingModalityNotLoadedException;
import '../embedding/embedding_input.dart';
import '../embedding/embedding_model.dart';
import '../embedding/task_type.dart';
import '../model_management/cancel_token.dart' show CancelToken;
import 'decider.dart';
import 'decider_embedding.dart';
import 'decider_exceptions.dart';
import 'decider_fit.dart';
import 'decider_method.dart';
import 'decider_option.dart';
import 'fit_runner_io.dart'
    if (dart.library.js_interop) 'fit_runner_web.dart'
    as runner;

/// The task every embedding decider embeds options and inputs with. The
/// EmbeddingGemma 2 model card: one prefix on every compared input.
///
/// Sentence similarity: of the EmbeddingGemma 2 prompts measured on CLINC150
/// and the example's Tiny Island catalog (2026-10-14) — classification,
/// question answering, a document prompt for the options, and Google
/// Decision Maker's `title: <option> | text:` candidates — it was the most
/// accurate on both, and its cross-fit refused the most out-of-scope
/// requests. On HWU64 classification was 2.6–4.3 points more accurate.
const deciderTaskType = TaskType.sentenceSimilarity;

/// The `format` of a decider artifact.
const deciderArtifactFormat = 'flutter_edge_ai.decider';

/// The artifact version this release writes and reads.
const deciderArtifactVersion = 1;

/// The embedding space of [embedder] as a decider names it: the model's
/// identity, its dimension, its backend and the task prefix. Two deciders
/// share vectors only within one space.
///
/// The identity is [embedderId] when given — the caller's name for the
/// weights, which REPLACES the installed-file guard below; otherwise the
/// installed files of a model core built: their names and, natively, their
/// sizes in bytes (file names and sizes, not the bytes themselves; on web the
/// names alone). Throws [ArgumentError] when neither exists.
///
/// The backend term is `embedder.activeBackend`. A model that does not
/// report one (null: LiteRT.js and ONNX on web, a custom subclass) is
/// refused without an [embedderId] — WebGPU and WASM would otherwise share
/// one space; with one, the id has no backend term and the caller's id must
/// tell those apart.
///
/// [images]: the decider was fitted on at least one image (an option example
/// or a labelled request). Then the id also carries the embedder's image
/// budget (`EmbeddingPassInfo.visionTokensPerImage`, when the engine reports
/// one): the same image gives another vector at 70 tokens than at 140. A
/// decider fitted on text alone leaves it out, so widening the embedder to
/// images does not move its space.
String deciderSpaceId(
  EmbeddingModel embedder, {
  String? embedderId,
  bool images = false,
}) {
  final String identity;
  if (embedderId != null) {
    if (embedderId.isEmpty) {
      throw ArgumentError.value(embedderId, 'embedderId', 'must not be empty');
    }
    identity = _escape(embedderId);
  } else if (embedder case CommonEmbeddingModel(:final installedFiles?)) {
    identity = installedFiles
        .map(
          (f) => f.bytes == null
              ? _escape(f.name)
              : '${_escape(f.name)}@${f.bytes}',
        )
        .join('+');
  } else {
    throw ArgumentError.value(
      null,
      'embedderId',
      'this ${embedder.runtimeType} was not built by '
          'FlutterEdgeAi.getActiveEmbedder(), so no installed file names its '
          'embedding space: pass embedderId, an id that changes whenever the '
          'weights do',
    );
  }
  final backend = embedder.activeBackend;
  if (backend == null && embedderId == null) {
    throw ArgumentError.value(
      null,
      'embedderId',
      'this ${embedder.runtimeType} does not report its backend '
          '(activeBackend is null), so the decider cannot tell its vectors '
          "from another backend's: pass embedderId, an id that names the "
          'weights and the backend they run on',
    );
  }
  final vision = images && embedder is CommonEmbeddingModel
      ? embedder.visionTokensPerImage
      : null;
  return 'model=$identity;dim=${embedder.dimension};'
      '${backend == null ? '' : 'backend=${backend.name};'}'
      '${vision == null ? '' : 'vision=$vision;'}'
      'prefix=${deciderTaskType.prefix}';
}

/// Jev's confidence, `(N · pmax − 1) / (N − 1)`, for [n] ≥ 2 candidates,
/// held to [0, 1]: a uniform distribution's `n · (1/n)` can round below 1
/// (49 · (1/49) is 0.9999999999999999), which made it −2e-18.
double deciderConfidence(double pmax, int n) =>
    ((n * pmax - 1) / (n - 1)).clamp(0.0, 1.0);

/// Percent-encodes the characters that would let two identities spell one
/// space id.
String _escape(String part) {
  final out = StringBuffer();
  for (final unit in part.codeUnits) {
    if (unit <= 0x1F ||
        unit == 0x25 ||
        unit == 0x2B ||
        unit == 0x3B ||
        unit == 0x40) {
      out.write('%${unit.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

/// `EmbeddingModel.createDecider`.
Future<Decider> createEmbeddingDecider(
  EmbeddingModel embedder, {
  required List<DeciderOption> options,
  required DeciderMethod method,
  required EmbeddingDeciderCalibration calibration,
  String? embedderId,
  CancelToken? cancelToken,
  void Function(int done, int total)? onProgress,
}) async {
  final opts = List<DeciderOption>.unmodifiable(options);
  // Read once: an unmodifiable copy the calibration made.
  final labelledRows = labelledRowsOf(calibration);
  _validateOptions(opts, method, calibration, labelledRows);
  final images =
      opts.any((o) => o.examples.any((e) => e.images.isNotEmpty)) ||
      (labelledRows?.any((row) => row.input.images.isNotEmpty) ?? false);
  final spaceId = deciderSpaceId(
    embedder,
    embedderId: embedderId,
    images: images,
  );
  final d = embedder.dimension;

  final inputs = <EmbeddingInput>[];
  final labels = <int>[];
  final ranks = <int>[];
  for (var o = 0; o < opts.length; o++) {
    var rank = 0;
    final option = opts[o];
    if (option.description case final description?) {
      inputs.add(EmbeddingInput.text(description));
      labels.add(o);
      ranks.add(rank++);
    }
    for (final example in option.examples) {
      inputs.add(example);
      labels.add(o);
      ranks.add(rank++);
    }
  }
  String optionInput(int i) {
    final option = opts[labels[i]];
    final example = ranks[i] - (option.description == null ? 0 : 1);
    return example < 0
        ? 'Option "${option.id}", its description'
        : 'Option "${option.id}", example $example';
  }

  final labelledLabels = <int>[];
  if (labelledRows != null) {
    final index = {for (var o = 0; o < opts.length; o++) opts[o].id: o};
    // Every text the options are made of: a held-out row equal to one of
    // them is not held out.
    final optionTexts = {
      for (final option in opts) ...[
        ?option.description,
        for (final example in option.examples)
          if (example.modalities.length == 1 && example.text != null)
            example.text!,
      ],
    };
    for (final row in labelledRows) {
      final o =
          index[row.optionId] ??
          (throw ArgumentError.value(
            row.optionId,
            'calibration',
            'a labelled row names an option this decider does not have',
          ));
      final text = row.input.text;
      if ((row.input.modalities.length == 1 &&
              text != null &&
              optionTexts.contains(text)) ||
          opts.any((op) => op.examples.any((e) => identical(e, row.input)))) {
        throw ArgumentError.value(
          text ?? row.input,
          'calibration',
          'a labelled row repeats an option input (an example or a '
              'description); held-out rows must be new requests or the '
              'threshold is fitted on data the decider already knows',
        );
      }
      labelledLabels.add(o);
    }
  }

  final total = inputs.length + (labelledRows?.length ?? 0);
  var done = 0;
  final void Function()? embedded = onProgress == null
      ? null
      : () => onProgress(++done, total);
  onProgress?.call(0, total);

  final x = await embedDeciderRows(
    embedder,
    inputs,
    taskType: deciderTaskType,
    dimension: d,
    name: optionInput,
    cancelToken: cancelToken,
    onEmbedded: embedded,
  );

  Float64List? labelledX;
  if (labelledRows != null) {
    labelledX = await embedDeciderRows(
      embedder,
      [for (final row in labelledRows) row.input],
      taskType: deciderTaskType,
      dimension: d,
      name: (i) => 'Labelled row $i',
      cancelToken: cancelToken,
      onEmbedded: embedded,
    );
  }

  // The runner checks the token before it starts the fit, and during it.
  final fit = await runner.runDeciderFit(
    cancelToken: cancelToken,
    DeciderFitRequest(
      dimension: d,
      optionCount: opts.length,
      optionIds: [for (final option in opts) option.id],
      inputs: x,
      labels: Int32List.fromList(labels),
      ranks: Int32List.fromList(ranks),
      linear: identical(method, DeciderMethod.linear),
      calibration: calibration.kind,
      keep: calibration.keep,
      fixedThreshold: calibration.threshold,
      maxError: calibration.maxError,
      labelledInputs: labelledX,
      labelledLabels: labelledRows == null
          ? null
          : Int32List.fromList(labelledLabels),
    ),
  );

  // A cancel that lands as the fit returns still fails the call: a cancelled
  // createDecider never hands back a decider.
  if (cancelToken?.isCancelled ?? false) {
    throw const DeciderCancelledException('createDecider was cancelled.');
  }
  final decider = EmbeddingDecider(
    embedder: embedder,
    embedderId: embedderId,
    images: images,
    options: opts,
    method: method,
    calibration: calibration.kind,
    calibrationParameter: calibration.keep ?? calibration.maxError,
    spaceId: spaceId,
    dimension: d,
    centroids: fit.centroids,
    weights: fit.weights,
    bias: fit.bias,
    threshold: fit.threshold,
    temperature: fit.temperature,
    fitTime: fit.fitTime,
    linearIterations: fit.linearIterations,
  );
  // The embedder may have been closed while the fit ran. A decider that
  // could never answer is not returned; one on a model core built takes
  // core's replacement at its first choose.
  if (decider.isClosed) {
    throw const EmbedderClosedException(
      'The embedding model was closed while the decider was being created.',
    );
  }
  return decider;
}

void _validateOptions(
  List<DeciderOption> options,
  DeciderMethod method,
  EmbeddingDeciderCalibration calibration,
  List<({EmbeddingInput input, String optionId})>? labelledRows,
) {
  if (identical(method, DeciderMethod.optionScoring)) {
    throw ArgumentError.value(
      method,
      'method',
      'optionScoring is an InferenceModel method: it scores options with a '
          'language model. An EmbeddingModel decides by centroid or linear',
    );
  }
  if (options.isEmpty) {
    throw ArgumentError.value(options, 'options', 'must not be empty');
  }
  final ids = <String>{};
  for (final option in options) {
    if (!ids.add(option.id)) {
      throw ArgumentError.value(
        option.id,
        'options',
        'two options share the id "${option.id}"',
      );
    }
    if (option.description == null && option.examples.isEmpty) {
      throw ArgumentError.value(
        option.id,
        'options',
        'option "${option.id}" has neither a description nor examples: '
            'nothing to embed',
      );
    }
  }
  if (identical(method, DeciderMethod.linear) && options.length < 2) {
    throw ArgumentError.value(
      options.length,
      'options',
      'the linear method needs at least two options',
    );
  }
  switch (calibration.kind) {
    case 'crossFit':
      final keep = calibration.keep!;
      if (!(keep > 0 && keep <= 1)) {
        throw ArgumentError.value(
          keep,
          'calibration.keep',
          'must be in (0, 1]',
        );
      }
      for (final option in options) {
        final count =
            option.examples.length + (option.description == null ? 0 : 1);
        if (count < 2) {
          throw ArgumentError.value(
            option.id,
            'calibration',
            'EmbeddingDeciderCalibration.crossFit holds each input out against the '
                'others, so every option needs at least two inputs '
                '(description plus examples); option "${option.id}" has '
                '$count. Add examples, or calibrate with '
                'EmbeddingDeciderCalibration.minSimilarity(threshold) or '
                'EmbeddingDeciderCalibration.none()',
          );
        }
      }
    case 'minSimilarity':
      final threshold = calibration.threshold!;
      if (!(threshold >= -1 && threshold <= 1)) {
        throw ArgumentError.value(
          threshold,
          'calibration.threshold',
          'a cosine threshold must be in [-1, 1]',
        );
      }
    case 'labelled':
      final maxError = calibration.maxError!;
      if (!(maxError >= 0 && maxError < 1)) {
        throw ArgumentError.value(
          maxError,
          'calibration.maxError',
          'must be in [0, 1)',
        );
      }
      if (labelledRows!.isEmpty) {
        throw ArgumentError.value(
          0,
          'calibration',
          'EmbeddingDeciderCalibration.fromLabelled needs labelled rows',
        );
      }
  }
}

/// `Decider.chooseAll`: one embedding per embedder, shared by its deciders.
Future<List<DeciderAnswer>> chooseAllWithSharedEmbeddings(
  DeciderInput input,
  List<Decider> deciders, {
  required int topK,
  CancelToken? cancelToken,
}) async {
  final all = List<Decider>.of(deciders);
  final answers = List<DeciderAnswer?>.filled(all.length, null);
  final groups = LinkedHashMap<EmbeddingModel, List<int>>.identity();
  final others = <int>[];
  for (var i = 0; i < all.length; i++) {
    final decider = all[i];
    if (decider is EmbeddingDecider) {
      decider._checkUsable(input, topK);
      (groups[decider._embedder] ??= []).add(i);
    } else {
      others.add(i);
    }
  }
  _checkCancelled(cancelToken);
  for (final MapEntry(key: embedder, value: members) in groups.entries) {
    final first = all[members.first] as EmbeddingDecider;
    final (vector, encodeTime, used) = await first._embed(input);
    _checkCancelled(cancelToken);
    for (final i in members) {
      final decider = all[i] as EmbeddingDecider;
      // Checked usable above, before the embedding; closed since then is a
      // cancel, as for choose.
      decider._checkNotClosedDuringChoose();
      // The first decider moved to the embedder core serves in place of a
      // closed one; the others of its group follow, each checking its own
      // space id.
      if (!identical(decider._embedder, used)) {
        assert(identical(decider._embedder, embedder));
        decider._adopt(used);
      }
      answers[i] = decider._score(
        vector,
        decider._allCandidates,
        topK,
        encodeTime,
      );
    }
  }
  for (final i in others) {
    answers[i] = await all[i].choose(
      input,
      topK: topK,
      cancelToken: cancelToken,
    );
  }
  return [for (final answer in answers) answer!];
}

/// Fails a decision whose [token] was cancelled.
void _checkCancelled(CancelToken? token) {
  if (token?.isCancelled ?? false) {
    throw const DeciderCancelledException('The decision was cancelled.');
  }
}

/// The decider of an `EmbeddingModel`. Holds no native resource: the model is
/// borrowed and never closed here.
///
/// On a model core built (`getActiveEmbedder`), a request that fails with
/// `EmbedderClosedException` — the model was replaced (wider media, another
/// backend, a re-install) or its worker died, so the request never ran —
/// takes the embedder core serves in its place, once, through the shell
/// entry point the model was built through, and is retried there when that
/// embedder's space id is this decider's; another space is a
/// [DeciderSpaceMismatchException]. On any other model the exception
/// arrives unchanged.
final class EmbeddingDecider extends Decider {
  EmbeddingDecider({
    required this._embedder,
    required this.embedderId,
    required this.images,
    required List<DeciderOption> options,
    required this.method,
    required this.calibration,
    required this.calibrationParameter,
    required this.spaceId,
    required this.dimension,
    required this.centroids,
    required this.weights,
    required this.bias,
    required this.threshold,
    required this.temperature,
    this.fitTime,
    this.linearIterations,
    this.storedMediaExamples,
  }) : options = List.unmodifiable(options),
       _index = {for (var o = 0; o < options.length; o++) options[o].id: o},
       _allCandidates = List.unmodifiable(
         List<int>.generate(options.length, (o) => o),
       );

  /// The embedder this decider uses: the one it was created from, or the one
  /// core served in its place.
  EmbeddingModel get embedder => _embedder;
  EmbeddingModel _embedder;

  /// The caller's `embedderId`, or null: the space id of a replacement is
  /// computed with it.
  final String? embedderId;

  /// Whether the fit saw an image (an option example or a labelled request):
  /// then [spaceId] carries the embedder's image budget, and a replacement
  /// must have the same one.
  final bool images;

  /// The replacement in flight, shared by every request that found the
  /// embedder closed.
  Future<EmbeddingModel>? _replacing;

  @override
  final List<DeciderOption> options;

  final DeciderMethod method;

  /// The calibration kind, and its keep or maxError.
  final String calibration;
  final double? calibrationParameter;

  final String spaceId;
  final int dimension;

  /// options × dimension, unit rows.
  final Float32List centroids;

  /// The linear layer: options × dimension, and options.
  final Float32List? weights;
  final Float32List? bias;

  final double? threshold;
  final double? temperature;

  /// How long the fit took, and the L-BFGS iterations of a linear fit; null
  /// for a decider loaded from an artifact.
  final Duration? fitTime;
  final int? linearIterations;

  /// For a decider loaded from an artifact: how many media examples each
  /// option had when it was fitted (the artifact does not store media).
  final List<int>? storedMediaExamples;

  final Map<String, int> _index;
  final List<int> _allCandidates;
  bool _closed = false;

  @override
  DeciderCapabilities get capabilities => DeciderCapabilities(
    modalities: _embedder.modalities,
    calibratedProbabilities: temperature != null,
    supportsContext: false,
    supportsAmong: true,
    storable: true,
  );

  /// True after [close], and when the embedder is closed and core cannot
  /// serve another in its place (a model core did not build). A decider on a
  /// replaced core embedder is not closed: its next [choose] takes the
  /// replacement.
  @override
  bool get isClosed =>
      _closed || (_embedder.isClosed && _replacementOf(_embedder) == null);

  @override
  Future<DeciderAnswer> choose(
    DeciderInput input, {
    Iterable<String>? among,
    int topK = 5,
    CancelToken? cancelToken,
  }) async {
    _checkUsable(input, topK);
    _checkCancelled(cancelToken);
    final candidates = among == null ? _allCandidates : _candidates(among);
    if (candidates.isEmpty) {
      // Nothing to embed, but the answer must not depend on that: a request
      // that fails with candidates fails without them too.
      var model = _embedder;
      if (model.isClosed) {
        final resolve =
            _replacementOf(model) ?? (throw const EmbedderClosedException());
        model = await _replace(model, resolve);
        _checkCancelled(cancelToken);
        _checkNotClosedDuringChoose();
      }
      final loaded = model.modalities;
      for (final modality in input.input.modalities) {
        if (!loaded.contains(modality)) {
          throw EmbeddingModalityNotLoadedException(
            'The input carries ${modality.name}, which this model was not '
            'loaded for (it embeds ${loaded.map((m) => m.name).join(' and ')}).',
            modality: modality,
            loaded: loaded,
          );
        }
      }
      return DeciderAnswer(
        choice: null,
        ranked: const [],
        scoreKind: _scoreKind,
        margin: 0,
        abstainReason: AbstainReason.noCandidates,
        provenance: _provenance(Duration.zero, Duration.zero, null),
      );
    }
    final (vector, encodeTime, _) = await _embed(input);
    // The embedding is not interrupted: a cancel or a close that came while
    // it ran drops its result.
    _checkCancelled(cancelToken);
    _checkNotClosedDuringChoose();
    return _score(vector, candidates, topK, encodeTime);
  }

  /// A [close] that came while a decision ran fails it as a cancel.
  void _checkNotClosedDuringChoose() {
    if (_closed) {
      throw const DeciderCancelledException(
        'The decider was closed while it was deciding.',
      );
    }
  }

  void _checkUsable(DeciderInput input, int topK) {
    if (_closed) throw StateError('The decider is closed.');
    if (input.context.isNotEmpty) {
      throw const DeciderUnsupportedException(
        'An embedding decider takes no conversation context: '
        'DeciderInput.context must be empty (capabilities.supportsContext is '
        'false). It is refused rather than ignored.',
      );
    }
    if (topK < 1) {
      throw ArgumentError.value(topK, 'topK', 'must be at least 1');
    }
  }

  List<int> _candidates(Iterable<String> among) {
    final chosen = <int>{};
    for (final id in among) {
      chosen.add(
        _index[id] ??
            (throw ArgumentError.value(
              id,
              'among',
              'is not an option of this decider',
            )),
      );
    }
    return chosen.toList()..sort();
  }

  /// [input]'s unit vector, the time its embedding took and the embedder
  /// that made it.
  Future<(Float64List, Duration, EmbeddingModel)> _embed(
    DeciderInput input,
  ) async {
    var model = _embedder;
    final watch = Stopwatch()..start();
    List<double> raw;
    try {
      raw = await model.embed(input.input, taskType: deciderTaskType);
    } on EmbedderClosedException {
      // The request never ran: the model was closed before it started. On a
      // model core built, take the one core serves in its place and retry
      // there, once; a second EmbedderClosedException arrives unchanged.
      final resolve = _replacementOf(model);
      if (resolve == null) rethrow;
      model = await _replace(model, resolve);
      watch.reset();
      raw = await model.embed(input.input, taskType: deciderTaskType);
    }
    final elapsed = watch.elapsed;
    final vector = Float64List(dimension);
    unitRowInto(raw, dimension, vector, 0, 'the input');
    return (vector, elapsed, model);
  }

  /// How core replaces [model], or null when it does not (a model core did
  /// not build).
  static EmbedderReplacement? _replacementOf(EmbeddingModel model) =>
      model is CommonEmbeddingModel ? model.replacement : null;

  /// The embedder core serves in place of [closed], adopted when its space
  /// id is this decider's. One resolution for every request that found
  /// [closed] closed; a request that comes after another one moved on gets
  /// the embedder already adopted.
  Future<EmbeddingModel> _replace(
    EmbeddingModel closed,
    EmbedderReplacement resolve,
  ) {
    final current = _embedder;
    if (!identical(current, closed) && !current.isClosed) {
      return Future.value(current);
    }
    final pending = _replacing;
    if (pending != null) return pending;
    final replacing = Future.sync(() async {
      final next = await resolve();
      _adopt(next);
      return next;
    });
    _replacing = replacing;
    unawaited(
      replacing
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() {
            if (identical(_replacing, replacing)) _replacing = null;
          }),
    );
    return replacing;
  }

  /// Uses [next] from now on — when its embedding space is this decider's.
  void _adopt(EmbeddingModel next) {
    final actual = deciderSpaceId(next, embedderId: embedderId, images: images);
    if (actual != spaceId) {
      throw DeciderSpaceMismatchException(
        'The embedder core now serves in place of this decider\'s is in '
        'another embedding space (another model file, dimension, backend or '
        'task prefix): its vectors do not compare with this decider\'s. Fit '
        'the decider again on it.',
        expected: spaceId,
        actual: actual,
      );
    }
    _embedder = next;
  }

  ScoreKind get _scoreKind =>
      weights == null ? ScoreKind.cosine : ScoreKind.logprob;

  DeciderAnswer _score(
    Float64List v,
    List<int> candidates,
    int topK,
    Duration encodeTime,
  ) {
    final watch = Stopwatch()..start();
    final n = candidates.length;
    final d = dimension;
    final cosines = Float64List(n);
    var similarity = double.negativeInfinity;
    for (var i = 0; i < n; i++) {
      final cos = _dot(v, centroids, candidates[i] * d, d);
      cosines[i] = cos;
      if (cos > similarity) similarity = cos;
    }

    // Raw scores: cosines, or the linear layer's log-softmax over the
    // candidates. `raw` is what a calibrated temperature divides.
    final Float64List raw;
    final Float64List scores;
    final w = weights;
    if (w == null) {
      raw = cosines;
      scores = cosines;
    } else {
      raw = Float64List(n);
      var m = double.negativeInfinity;
      for (var i = 0; i < n; i++) {
        final o = candidates[i];
        final z = _dot(v, w, o * d, d) + bias![o];
        raw[i] = z;
        if (z > m) m = z;
      }
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += math.exp(raw[i] - m);
      }
      final logSum = m + math.log(sum);
      scores = Float64List(n);
      for (var i = 0; i < n; i++) {
        scores[i] = raw[i] - logSum;
      }
    }

    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) {
        final byScore = scores[b].compareTo(scores[a]);
        return byScore != 0 ? byScore : a.compareTo(b);
      });

    Float64List? probabilities;
    double? confidence;
    final temp = temperature;
    if (temp != null) {
      probabilities = Float64List(n);
      var m = double.negativeInfinity;
      for (var i = 0; i < n; i++) {
        if (raw[i] / temp > m) m = raw[i] / temp;
      }
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        final e = math.exp(raw[i] / temp - m);
        probabilities[i] = e;
        sum += e;
      }
      var pmax = 0.0;
      for (var i = 0; i < n; i++) {
        probabilities[i] /= sum;
        if (probabilities[i] > pmax) pmax = probabilities[i];
      }
      if (n >= 2) confidence = deciderConfidence(pmax, n);
    }

    final margin = n >= 2
        ? scores[order[0]] - scores[order[1]]
        : double.infinity;
    final limit = threshold;
    final abstain = limit != null && similarity < limit;
    final ranked = [
      for (final i in order.take(topK))
        RankedOption(
          id: options[candidates[i]].id,
          score: scores[i],
          probability: probabilities?[i],
        ),
    ];
    final scoreTime = watch.elapsed;
    return DeciderAnswer(
      choice: abstain ? null : options[candidates[order[0]]].id,
      ranked: ranked,
      scoreKind: _scoreKind,
      margin: margin,
      confidence: confidence,
      abstainReason: abstain ? AbstainReason.belowThreshold : null,
      probabilities: probabilities == null
          ? null
          : {
              for (var i = 0; i < n; i++)
                options[candidates[i]].id: probabilities[i],
            },
      provenance: _provenance(encodeTime, scoreTime, similarity),
    );
  }

  /// The abstain signal is [similarity], the top cosine over the candidates:
  /// null only when there was no candidate.
  DeciderProvenance _provenance(
    Duration encodeTime,
    Duration scoreTime,
    double? similarity,
  ) => DeciderProvenance(
    method: method,
    calibration: calibration,
    spaceId: spaceId,
    encodeTime: encodeTime,
    scoreTime: scoreTime,
    threshold: threshold,
    abstainSignal: similarity,
    abstainSignalKind: similarity == null ? null : AbstainSignalKind.topCosine,
  );

  @override
  Map<String, Object?> toArtifact() {
    final d = dimension;
    return {
      'format': deciderArtifactFormat,
      'version': deciderArtifactVersion,
      'kind': 'embedding',
      'spaceId': spaceId,
      if (images) 'imageInputs': true,
      'dimension': d,
      'taskType': deciderTaskType.name,
      'method': method.name,
      'calibration': {
        'kind': calibration,
        if (calibration == 'crossFit') 'keep': calibrationParameter,
        if (calibration == 'labelled') 'maxError': calibrationParameter,
        'threshold': ?threshold,
        'temperature': ?temperature,
      },
      if (weights != null) 'linear': {'weightDecay': linearWeightDecay},
      'options': [
        for (var o = 0; o < options.length; o++)
          {
            'id': options[o].id,
            'description': ?options[o].description,
            'examples': [
              for (final example in options[o].examples)
                if (example.modalities.length == 1 && example.text != null)
                  example.text,
            ],
            if ((storedMediaExamples?[o] ?? _mediaExamples(options[o]))
                case final media when media > 0)
              'mediaExamples': media,
            if (options[o].metadata case final metadata?)
              'metadata': _jsonCopy(metadata, options[o].id),
            'centroid': _encodeFloat32(centroids, o * d, d),
            if (weights case final w?) 'weights': _encodeFloat32(w, o * d, d),
            if (bias case final b?) 'bias': b[o],
          },
      ],
    };
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  String toString() =>
      'EmbeddingDecider(${options.length} options, ${method.name}, '
      '$calibration, $spaceId)';
}

int _mediaExamples(DeciderOption option) => option.examples
    .where((e) => !(e.modalities.length == 1 && e.text != null))
    .length;

Object? _jsonCopy(Map<String, Object?> metadata, String id) {
  try {
    return jsonDecode(jsonEncode(metadata));
  } on JsonUnsupportedObjectError catch (e) {
    throw StateError(
      'The metadata of option "$id" is not JSON-encodable, so the decider '
      'cannot be stored: ${e.unsupportedObject.runtimeType}.',
    );
  }
}

double _dot(Float64List v, Float32List m, int offset, int d) {
  var s = 0.0;
  for (var j = 0; j < d; j++) {
    s += v[j] * m[offset + j];
  }
  return s;
}

String _encodeFloat32(Float32List values, int offset, int length) {
  final bytes = ByteData(length * 4);
  for (var i = 0; i < length; i++) {
    bytes.setFloat32(i * 4, values[offset + i], Endian.little);
  }
  return base64.encode(bytes.buffer.asUint8List());
}

/// `EmbeddingModel.loadDecider`.
Future<Decider> loadEmbeddingDecider(
  EmbeddingModel embedder,
  Map<String, Object?> artifact, {
  String? embedderId,
}) async {
  if (artifact['format'] != deciderArtifactFormat) {
    throw FormatException(
      'Not a decider artifact: format is ${artifact['format']}, expected '
      '$deciderArtifactFormat.',
    );
  }
  final version = artifact['version'];
  if (version != deciderArtifactVersion) {
    throw FormatException(
      'Decider artifact version $version; this release reads version '
      '$deciderArtifactVersion only.',
    );
  }
  final kind = artifact['kind'];
  if (kind != 'embedding') {
    throw FormatException(
      'A "$kind" decider artifact cannot be loaded by an EmbeddingModel.',
    );
  }
  final taskType = _field<String>(artifact, 'taskType');
  if (taskType != deciderTaskType.name) {
    throw FormatException(
      'Decider artifact taskType "$taskType": this release embeds options and '
      'inputs with "${deciderTaskType.name}" only.',
    );
  }
  final expected = _field<String>(artifact, 'spaceId');
  final images = artifact['imageInputs'] ?? false;
  if (images is! bool) {
    throw const FormatException('Decider artifact imageInputs is not a bool.');
  }
  final actual = deciderSpaceId(
    embedder,
    embedderId: embedderId,
    images: images,
  );
  if (expected != actual) {
    throw DeciderSpaceMismatchException(
      'The decider was fitted in another embedding space: its vectors do not '
      'compare with this embedder\'s. Fit it again on this embedder.',
      expected: expected,
      actual: actual,
    );
  }
  if (embedder.isClosed) throw const EmbedderClosedException();
  final d = _field<int>(artifact, 'dimension');
  if (d != embedder.dimension) {
    throw FormatException(
      'Decider artifact dimension $d does not match its space id.',
    );
  }
  final methodName = _field<String>(artifact, 'method');
  final method =
      deciderMethodByName(methodName) ??
      (throw FormatException('Unknown decider method "$methodName".'));
  if (identical(method, DeciderMethod.optionScoring)) {
    throw const FormatException(
      'An optionScoring decider stores no artifact: an embedding decider '
      'artifact is centroid or linear.',
    );
  }
  final calibration = _field<Map<String, Object?>>(artifact, 'calibration');
  final calibrationKind = _field<String>(calibration, 'kind');
  if (!const {
    'none',
    'crossFit',
    'minSimilarity',
    'labelled',
  }.contains(calibrationKind)) {
    throw FormatException('Unknown calibration kind "$calibrationKind".');
  }
  final threshold = _optionalDouble(calibration, 'threshold');
  final temperature = _optionalDouble(calibration, 'temperature');
  if (calibrationKind != 'none' && threshold == null) {
    throw FormatException('A $calibrationKind calibration needs a threshold.');
  }
  if (calibrationKind == 'none' && threshold != null) {
    throw const FormatException(
      'A none calibration never abstains, so it has no threshold.',
    );
  }
  if (calibrationKind == 'labelled' && temperature == null) {
    throw const FormatException(
      'A labelled calibration needs its temperature.',
    );
  }
  if (calibrationKind != 'labelled' && temperature != null) {
    throw FormatException(
      'Only a labelled calibration has a temperature; this one is '
      '$calibrationKind.',
    );
  }
  if (temperature != null && !(temperature > 0)) {
    throw const FormatException('A calibration temperature must be positive.');
  }
  final linear = identical(method, DeciderMethod.linear);

  final rawOptions = _field<List<Object?>>(artifact, 'options');
  if (rawOptions.isEmpty) {
    throw const FormatException('A decider artifact needs options.');
  }
  final c = rawOptions.length;
  if (linear && c < 2) {
    throw const FormatException(
      'A linear decider artifact needs at least two options.',
    );
  }
  final options = <DeciderOption>[];
  final mediaExamples = <int>[];
  final centroids = Float32List(c * d);
  final weights = linear ? Float32List(c * d) : null;
  final bias = linear ? Float32List(c) : null;
  for (var o = 0; o < c; o++) {
    final raw = rawOptions[o];
    if (raw is! Map<String, Object?>) {
      throw FormatException('Option $o of the decider artifact is not a map.');
    }
    final id = raw['id'];
    if (id is! String) {
      throw FormatException('Option $o: "id" is ${id.runtimeType}, not text.');
    }
    final description = raw['description'];
    if (description != null && description is! String) {
      throw FormatException(
        'Option $o: "description" is ${description.runtimeType}, not text.',
      );
    }
    final examples = raw['examples'];
    if (examples is! List<Object?>) {
      throw FormatException(
        'Option $o: "examples" is ${examples.runtimeType}, not a list.',
      );
    }
    final texts = <EmbeddingInput>[];
    for (final text in examples) {
      if (text is! String) {
        throw FormatException(
          'Option $o: "examples" holds a ${text.runtimeType}, not text.',
        );
      }
      texts.add(EmbeddingInput.text(text));
    }
    final metadata = raw['metadata'];
    if (metadata != null && metadata is! Map<String, Object?>) {
      throw FormatException('Option $o: "metadata" is not a map.');
    }
    try {
      options.add(
        DeciderOption(
          id,
          description: description as String?,
          examples: texts,
          metadata: metadata as Map<String, Object?>?,
        ),
      );
    } on ArgumentError catch (e) {
      throw FormatException('Option $o of the decider artifact: ${e.message}');
    }
    final media = raw['mediaExamples'] ?? 0;
    if (media is! int || media < 0) {
      throw FormatException('Option $o: mediaExamples is not a count.');
    }
    mediaExamples.add(media);
    final centroid = _decodeFloat32(raw['centroid'], d, o);
    var norm = 0.0;
    for (final v in centroid) {
      norm += v * v;
    }
    // A centroid is stored unit length as float32: within 1e-3 of 1 is
    // rounding; further is another vector, and its cosines would be scaled.
    if ((math.sqrt(norm) - 1).abs() > 1e-3) {
      throw FormatException(
        'Option $o: its centroid is not unit length (norm '
        '${math.sqrt(norm)}).',
      );
    }
    centroids.setAll(o * d, centroid);
    if (linear) {
      weights!.setAll(o * d, _decodeFloat32(raw['weights'], d, o));
      final b = raw['bias'];
      if (b is! num || !b.toDouble().isFinite) {
        throw FormatException('Option $o has no finite bias.');
      }
      bias![o] = b.toDouble();
    }
  }
  if (options.map((o) => o.id).toSet().length != c) {
    throw const FormatException('Two options of the artifact share an id.');
  }

  return EmbeddingDecider(
    embedder: embedder,
    embedderId: embedderId,
    images: images,
    options: options,
    method: method,
    calibration: calibrationKind,
    calibrationParameter:
        _optionalDouble(calibration, 'keep') ??
        _optionalDouble(calibration, 'maxError'),
    spaceId: actual,
    dimension: d,
    centroids: centroids,
    weights: weights,
    bias: bias,
    threshold: threshold,
    temperature: temperature,
    storedMediaExamples: mediaExamples,
  );
}

T _field<T>(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! T) {
    throw FormatException(
      'Decider artifact field "$key" is ${value.runtimeType}, expected $T.',
    );
  }
  return value;
}

double? _optionalDouble(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! num || !value.toDouble().isFinite) {
    throw FormatException('Decider artifact field "$key" is not a number.');
  }
  return value.toDouble();
}

Float32List _decodeFloat32(Object? encoded, int d, int option) {
  if (encoded is! String) {
    throw FormatException('Option $option has no encoded vector.');
  }
  final Uint8List bytes;
  try {
    bytes = base64.decode(encoded);
  } on FormatException {
    throw FormatException('Option $option: a vector is not valid base64.');
  }
  if (bytes.length != d * 4) {
    throw FormatException(
      'Option $option: a vector has ${bytes.length ~/ 4} values, '
      'expected $d.',
    );
  }
  final data = ByteData.sublistView(bytes);
  final out = Float32List(d);
  for (var j = 0; j < d; j++) {
    final v = data.getFloat32(j * 4, Endian.little);
    if (!v.isFinite) {
      throw FormatException('Option $option: a vector value is not finite.');
    }
    out[j] = v;
  }
  return out;
}
