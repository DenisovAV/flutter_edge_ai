/// The `extra_context` that sets thinking for a LiteRT-LM conversation, the
/// one source for the native and the web path.
///
/// `enable_thinking` is what the templates read — Qwen3, Gemma 4, SmolLM3, and
/// upstream's own web chat app sends the same key. Always an explicit bool: a
/// Qwen3 template (`enable_thinking|default(true)`) thinks when the key is
/// absent, so sending nothing for "off" left those bundles reasoning —
/// Qwen3-0.6B_dynamic spent a 768-token budget on reasoning and never
/// answered. A template that ignores the key (the legacy Qwen3
/// prompt_templates) is unaffected, and Gemma 4 renders the same prompt for
/// `false` as for no key.
Map<String, Object> thinkingContext(bool enableThinking) => {
  'enable_thinking': enableThinking,
};
