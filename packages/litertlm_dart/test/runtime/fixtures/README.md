# Prompt template fixtures

`gemma4_litert_community_chat_template.jinja` is `LlmMetadata.jinja_prompt_template`
of `litert-community/gemma-4-E2B-it-litert-lm`, `gemma-4-E2B-it.litertlm`
(sha256 `18193810…`), byte for byte (11995 bytes, sha256 `02b3091a…`). The same
bytes are that repository's `chat_template.jinja`, and the template of its
Google Tensor G5/G6, Qualcomm QCS8275, Intel LNL/PTL and `-web` E2B files and
of `gemma-4-E4B-it.litertlm`. Apache License
2.0 (Google).

To regenerate, read field 7 of the bundle's `LlmMetadataProto` section, e.g.
with `llmMetadataJinjaTemplate` from `lib/src/bundle/litertlm_bundle_sampler.dart`.
