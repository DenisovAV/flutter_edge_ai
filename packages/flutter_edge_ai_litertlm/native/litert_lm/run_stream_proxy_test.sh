#!/usr/bin/env bash
# Builds the fake libraries and stream_proxy_test.c, and runs every scenario
# under ThreadSanitizer. POSIX only; CI runs it on ubuntu.
set -euo pipefail
cd "$(dirname "$0")"

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

cc -shared -fPIC -o "$D/libfake_ok.so" fake_litert_lm.c
cc -shared -fPIC -DFAKE_SHADOW -o "$D/libfake_shadow.so" fake_litert_lm.c
cc -g -Wall -fsanitize=thread -pthread -o "$D/stream_proxy_test" stream_proxy_test.c -ldl

# Some kernels use an mmap randomization ThreadSanitizer rejects ("unexpected
# memory mapping"); a fixed address layout avoids it.
run=("$D/stream_proxy_test")
if command -v setarch >/dev/null 2>&1 && setarch "$(uname -m)" -R true 2>/dev/null; then
  run=(setarch "$(uname -m)" -R "$D/stream_proxy_test")
fi

# The scenario list comes from the binary, through the same wrapper: if
# ThreadSanitizer aborts at startup, `list` fails too, and a run that ran no
# scenario must not pass.
scenarios="$("${run[@]}" list)" || { echo "FAIL: the test binary did not start (list)"; exit 1; }
fail=0
ran=0
for s in $scenarios; do
  ran=$((ran + 1))
  "${run[@]}" "$s" "$D" || { echo "FAIL $s"; fail=1; }
done
if [ "$ran" -eq 0 ]; then
  echo "FAIL: no scenario ran"
  exit 1
fi
echo "$ran scenario(s) run"
exit $fail
