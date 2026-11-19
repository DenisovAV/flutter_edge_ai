# Whether a --dart-define name looks like a secret. A define is compiled into
# the APK, and the APK stays on a phone other people use after us: stage
# gated models instead of passing a token. Matched as a whole word between
# underscores, so HF_TOKEN, API_KEY, APIKEY or DB_PASSWORD are refused and a
# name that only contains such a word (STT_TOKENIZER_FILE) passes.
# Sourced by run_instrumented.sh and test_define_guard.sh.
is_secret_define() {
  local key
  key=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  [[ $key =~ (^|_)(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?|[A-Z]*KEY)(_|$) ]]
}
