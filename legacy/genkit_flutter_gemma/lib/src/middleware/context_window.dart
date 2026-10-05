import 'dart:async';
import 'dart:developer' as developer;

import 'package:genkit/plugin.dart';

/// Registry name of the context-window trimmer. Shared by the plugin's
/// [GenkitPlugin.middleware] registration and the [trimContext] ref so the two
/// can never drift apart.
const kContextWindowMiddlewareName = 'flutter-gemma-context-window';

/// Context window assumed when a request carries no `maxTokens` config. Matches
/// flutter_gemma's own default and the `kv_cache_max_len` baked into every
/// supported `.litertlm` model.
const _kDefaultContextWindow = 1024;

/// Tokens held back from the context window for the model's response when the
/// input budget is derived rather than given explicitly.
const _kDefaultReserveOutputTokens = 256;

/// Flat per-media-part token estimate (images/audio don't have a text length to
/// measure; this keeps a long multimodal turn from being counted as ~free).
const _kMediaPartTokenEstimate = 256;

/// Middleware that trims the oldest conversation turns so a request fits the
/// on-device model's context window (KV-cache budget).
///
/// On-device Gemma runs with a fixed, small context window (`maxTokens`, 1024
/// for most `.litertlm` models). A long multi-turn chat silently overflows it
/// and the native runtime fails to allocate the KV cache mid-generation (see
/// the `maxTokens = CONTEXT window` note in the repo's CLAUDE.md). This
/// middleware drops the oldest **non-system** messages before the model call.
///
/// Guarantees:
///   * every system message is kept (instructions must survive);
///   * the most-recent message is kept (the current turn's query — trimming it
///     away would make the generation meaningless), even if it alone exceeds
///     the budget — so the kept total can exceed [maxInputTokens];
///   * a kept suffix that would otherwise start on a model/tool turn whose
///     partner was trimmed has that orphaned leading turn dropped, so the
///     retained non-system history normally begins on a `Role.user` turn and a
///     tool-call and its response are never split. The one exception is the
///     always-kept most-recent message: if it is itself a lone non-user turn
///     (e.g. a `tool` response mid tool-loop) it is retained, and a warning is
///     logged.
///
/// When even the pinned messages (all system + the most-recent turn) exceed the
/// budget, the request is forwarded over budget (dropping the query would be
/// worse) and a warning is logged — it does not claim to have fit.
///
/// Token counts are a rough `chars / 4` estimate (plus a flat cost per media
/// part). This undercounts CJK/dense-code text (often ≥ 1 token/char), so leave
/// headroom via [reserveOutputTokens] rather than treating the budget as exact.
class ContextWindowMiddleware extends GenerateMiddleware {
  ContextWindowMiddleware({this.maxInputTokens, int? reserveOutputTokens})
    : reserveOutputTokens =
          reserveOutputTokens ?? _kDefaultReserveOutputTokens {
    // Fail loud on nonsensical config rather than silently mis-trimming. A
    // non-positive explicit budget would keep only the last turn; a negative
    // reserve would *enlarge* the derived budget past the context window and
    // re-introduce the very KV-overflow crash this middleware prevents.
    if (maxInputTokens != null && maxInputTokens! <= 0) {
      throw ArgumentError.value(
        maxInputTokens,
        'maxInputTokens',
        'must be greater than 0',
      );
    }
    if (this.reserveOutputTokens < 0) {
      throw ArgumentError.value(
        this.reserveOutputTokens,
        'reserveOutputTokens',
        'must be greater than or equal to 0',
      );
    }
  }

  /// Explicit input-token budget; when null the budget is derived per request
  /// from `maxTokens` (the context window) minus [reserveOutputTokens].
  final int? maxInputTokens;

  /// Response headroom used only when [maxInputTokens] is null.
  final int reserveOutputTokens;

  @override
  Future<ModelResponse> model(
    ModelRequest request,
    ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    Future<ModelResponse> Function(
      ModelRequest request,
      ActionFnArg<ModelResponseChunk, ModelRequest, void> ctx,
    )
    next,
  ) {
    final contextWindow =
        (request.config?['maxTokens'] as num?)?.toInt() ??
        _kDefaultContextWindow;
    final budget = maxInputTokens ?? (contextWindow - reserveOutputTokens);
    if (budget <= 0) {
      // Only reachable via the derived path: reserveOutputTokens >= the
      // model's context window. Surfacing this beats silently deleting the
      // whole history down to the last turn.
      throw GenkitException(
        'Context-window trimmer: input budget is <= 0 (reserveOutputTokens '
        '$reserveOutputTokens >= context window $contextWindow). Lower '
        'reserveOutputTokens or set maxInputTokens explicitly.',
        status: StatusCodes.INVALID_ARGUMENT,
      );
    }

    request.messages = _trim(request.messages, budget);
    return next(request, ctx);
  }

  /// Keeps all system messages and the most recent message; drops the oldest
  /// non-system messages until the estimated total fits [budget].
  static List<Message> _trim(List<Message> messages, int budget) {
    if (messages.isEmpty) return messages;

    // Fast path: already fits → return the original list untouched.
    final total = messages.fold<int>(0, (sum, m) => sum + _estimateTokens(m));
    if (total <= budget) return messages;

    final system = <Message>[];
    final rest = <Message>[]; // non-system, original order
    for (final m in messages) {
      (m.role == Role.system ? system : rest).add(m);
    }
    if (rest.isEmpty) return messages; // only system messages — nothing to trim

    final systemCost = system.fold<int>(0, (s, m) => s + _estimateTokens(m));

    // Walk newest→oldest, keeping a contiguous suffix that fits. The most recent
    // message is always kept even if it alone blows the budget.
    final keptReversed = <Message>[];
    var used = systemCost;
    for (var i = rest.length - 1; i >= 0; i--) {
      final cost = _estimateTokens(rest[i]);
      final isMostRecent = i == rest.length - 1;
      if (isMostRecent || used + cost <= budget) {
        keptReversed.add(rest[i]);
        used += cost;
      } else {
        break; // first older message that overflows → drop it and all older
      }
    }

    // Never split a turn pair: the kept suffix can start on a model/tool turn
    // whose partner (the user turn it answered, or the model tool-call it
    // responds to) was just trimmed. Drop such orphaned leading turns so the
    // retained history begins on a user turn — but never drop the most-recent
    // message.
    final chronological = keptReversed.reversed.toList();
    var start = 0;
    while (start < chronological.length - 1 &&
        chronological[start].role != Role.user) {
      start++;
    }
    final kept = chronological.sublist(start);
    final result = [...system, ...kept];

    // Report honestly: the pinned messages (all system + the most-recent turn)
    // can still exceed the budget, in which case the request is forwarded over
    // budget. Never log "fit budget" when it didn't — a misleading success line
    // sends a debugging engineer the wrong way.
    final finalTotal = result.fold<int>(0, (s, m) => s + _estimateTokens(m));
    const logName = 'genkit.flutter_gemma.context_window';
    if (finalTotal > budget) {
      developer.log(
        'could not fit budget $budget: pinned system + most-recent messages '
        'total ~$finalTotal tokens; forwarding over budget',
        name: logName,
        level: 900, // WARNING
      );
    } else if (result.length < messages.length) {
      developer.log(
        'trimmed ${messages.length - result.length} of ${messages.length} '
        'messages to fit budget $budget (~$finalTotal tokens)',
        name: logName,
      );
    }

    return result;
  }

  /// Rough token estimate: total text characters / 4, plus a flat cost per
  /// non-text (media) part.
  ///
  /// Uses [PartExtension.isText] / [PartExtension.text] rather than an
  /// `is TextPart` check: `Message.content` reconstructs every element as a
  /// base [Part] (via `Part.fromJson`), so a subtype test never matches and
  /// would miscount every text part as media.
  static int _estimateTokens(Message message) {
    var chars = 0;
    var mediaParts = 0;
    for (final part in message.content) {
      if (part.isText) {
        chars += (part.text ?? '').length;
      } else {
        mediaParts++;
      }
    }
    return (chars / 4).ceil() + mediaParts * _kMediaPartTokenEstimate;
  }
}

/// The middleware definition to register from the plugin's
/// [GenkitPlugin.middleware] hook.
///
/// The config is a plain `Map<String, dynamic>` (`{maxInputTokens?,
/// reserveOutputTokens?}`) rather than a schemantic type. Genkit serializes a
/// middleware ref's config through `_configToMap` (which calls `toJson()`)
/// before it reaches the factory on the reflection/Dev-UI path; a Map survives
/// that verbatim, whereas a plain value class with no `toJson()` would be
/// nulled out and drop every [trimContext] argument. A Map keeps the config
/// intact on **both** the in-process and serialized paths with no code
/// generation.
GenerateMiddlewareDef<Map<String, dynamic>> contextWindowMiddlewareDef() {
  return defineMiddleware<Map<String, dynamic>>(
    name: kContextWindowMiddlewareName,
    create: (config, ctx) => ContextWindowMiddleware(
      maxInputTokens: (config?['maxInputTokens'] as num?)?.toInt(),
      reserveOutputTokens: (config?['reserveOutputTokens'] as num?)?.toInt(),
    ),
  );
}

/// Reference the context-window trimmer in a generate call:
///
/// ```dart
/// await ai.generate(
///   model: flutterGemma.model('gemma-3-nano'),
///   prompt: '…',
///   use: [trimContext(maxInputTokens: 800)],
/// );
/// ```
///
/// With no arguments the budget is derived from the request's `maxTokens`
/// (the model's context window) minus 256 tokens of response headroom.
GenerateMiddlewareRef<Map<String, dynamic>> trimContext({
  int? maxInputTokens,
  int? reserveOutputTokens,
}) {
  return middlewareRef<Map<String, dynamic>>(
    name: kContextWindowMiddlewareName,
    config: {
      'maxInputTokens': ?maxInputTokens,
      'reserveOutputTokens': ?reserveOutputTokens,
    },
  );
}
