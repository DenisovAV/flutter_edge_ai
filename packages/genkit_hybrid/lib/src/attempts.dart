import 'dart:async';

import 'package:genkit/genkit.dart';

/// Whether [error] is a transient/availability failure that justifies trying
/// the next branch. Permanent errors (bad request, bad auth) must NOT trigger
/// fallback — the next branch would get the same bad request and also fail,
/// masking the real cause. Non-GenkitException throwables (network, timeout,
/// OOM) are treated as transient.
bool isTransient(Object error) {
  if (error is! GenkitException) return true;
  switch (error.status) {
    case StatusCode.unavailable:
    case StatusCode.deadlineExceeded:
    case StatusCode.resourceExhausted:
    case StatusCode.internal:
      return true;
    default:
      return false;
  }
}

/// Runs [order] against [branches] with [request]/[context], NON-STREAMING.
///
/// Falls to the next branch on a transient error (permanent errors rethrow).
/// When [accept] is given, a successful but rejected response also advances to
/// the next branch (cascade escalation); the LAST branch's successful response
/// is returned regardless of [accept]. When [accept] is null every success is
/// accepted (plain fallback).
Future<ModelResponse> runInOrder(
  List<String> order,
  Map<String, Model> branches,
  ModelRequest request,
  ActionFnArg<ModelResponseChunk, ModelRequest, void> context, {
  FutureOr<bool> Function(ModelResponse)? accept,
}) async {
  for (var i = 0; i < order.length; i++) {
    final isLast = i == order.length - 1;
    ModelResponse resp;
    try {
      resp = await callBranch(branches[order[i]]!, request, context);
    } catch (e) {
      if (isLast || !isTransient(e)) rethrow;
      continue; // transient failure, not the last branch -> try the next one
    }
    // accept is evaluated OUTSIDE the branch-error catch: a throwing predicate
    // is a caller bug, not a branch failure, and must propagate — never be
    // mistaken for a transient branch error and silently escalate.
    if (isLast || accept == null || await accept(resp)) return resp;
    // accepted == false and not last -> escalate to the next branch.
  }
  throw StateError('unreachable'); // loop always returns or rethrows.
}

/// Runs [model] for [request] the way any caller runs a model, carrying
/// [context]'s streaming, request context and cancellation. Genkit 1.0 no
/// longer exposes an action's function, so a branch is called as an action and
/// gets its own trace span.
Future<ModelResponse> callBranch(
  Model model,
  ModelRequest request,
  ActionFnArg<ModelResponseChunk, ModelRequest, void> context,
) => model(
  request,
  onChunk: context.streamingRequested ? context.sendChunk : null,
  context: context.context,
  cancel: context.cancel,
);
