# Whether a --dart-define name looks like a secret. A define is compiled into
# the APK, and the APK stays on a phone other people use after us: stage
# gated models instead of passing a token. Matched as a whole word between
# underscores (or camelCase), so HF_TOKEN, API_KEY, APIKEY, accessToken or
# DB_PASSWORD are refused and a name that only contains such a word
# (STT_TOKENIZER_FILE) passes.
# Sourced by run_instrumented.sh and test_define_guard.sh.
is_secret_define() {
  local key
  # camelCase splits into words first: accessToken is ACCESS_TOKEN.
  key=$(printf '%s' "$1" | sed 's/\([a-z0-9]\)\([A-Z]\)/\1_\2/g' |
    tr '[:lower:]' '[:upper:]')
  # TOKEN without a plural: MAX_TOKENS is a token count, not a secret.
  [[ $key =~ (^|_)[A-Z0-9]*(TOKEN|SECRETS?|PASSWORDS?|PASSWD|CREDENTIALS?|KEYS?)(_|$) ]]
}
