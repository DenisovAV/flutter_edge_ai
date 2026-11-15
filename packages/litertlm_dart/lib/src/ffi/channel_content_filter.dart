/// Whether LiteRT-LM may strip a completed reply's channel content (a
/// thought) from the KV cache: only when the conversation is known to rewind,
/// i.e. not on the NPU ([npu]) and on a model known to keep no linear
/// attention state ([linearAttentionState] false; null, unread, counts as
/// cannot rewind).
///
/// LiteRT-LM 0.19 strips it eagerly: as soon as a reply that carries a
/// channel completes (a thought; Gemma 4 26B emits one even with thinking
/// off), it rewinds the session to the checkpoint taken before the reply and
/// prefills the reply again without it
/// (`Conversation::RewindAndGetInputDataVector`). That rewind spans the whole
/// reply, and the NPU executor rolls back one token at most
/// (`LlmLiteRtNpuCompiledModelExecutor::SetCurrentStep`: "only supports
/// rolling back one token at the end of decode"), so on the NPU the first
/// such reply failed with INVALID_ARGUMENT; a rewind cannot restore linear
/// attention state either, and it runs inside the native send, before Dart
/// could rebuild the conversation instead.
///
/// The cost where the filter is off: the thoughts stay in the native KV cache
/// while core's history and the replay record only the visible reply, so a
/// long chat fills its context faster than its history suggests, and a
/// conversation rebuilt after a stop or a full context resumes without the
/// earlier thoughts.
bool liteRtLmFiltersChannelContent({
  required bool npu,
  required bool? linearAttentionState,
}) => !npu && linearAttentionState == false;
