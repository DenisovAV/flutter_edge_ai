#!/usr/bin/env bash
# Checks is_secret_define (define_guard.sh): secret-like names are refused,
# names that only contain such a word pass. Run: bash test_define_guard.sh
set -u
. "$(dirname "$0")/define_guard.sh"
failed=0
for name in HF_TOKEN hf_token TOKEN GITHUB_TOKEN_VALUE API_KEY APIKEY OPENAI_API_KEY \
  DB_PASSWORD CLIENT_SECRET SECRET GCP_CREDENTIALS accessToken githubToken \
  clientSecret dbPassword openAiApiKey HFTOKEN ACCESSTOKEN DBPASSWORD CLIENTSECRET; do
  if ! is_secret_define "$name"; then echo "FAIL: $name passed"; failed=1; fi
done
for name in STT_TOKENIZER_FILE TOKENIZER MTK_MODEL STT_MODEL_FILE TTS_VOICE KEYWORD_LIST \
  sttTokenizerFile MAX_TOKENS NPU_MAX_TOKENS; do
  if is_secret_define "$name"; then echo "FAIL: $name refused"; failed=1; fi
done
[ "$failed" = 0 ] && echo "define guard: ok"
exit "$failed"
