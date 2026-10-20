#!/usr/bin/env bash
# Build an integration test as app + androidTest APKs, install them on a DDP
# phone through the adb forwarder and run it with `am instrument`: `flutter test`
# cannot reach the Dart VM service through the forwarder.
#
#   SERIAL=localhost:<port> run_instrumented.sh <run-name> <integration_test/file.dart> [KEY=VALUE ...]
#
# KEY=VALUE pairs become --dart-define values; a key naming a token, key, secret
# or password is refused. Env: EXAMPLE (the Flutter app, default: this repo's
# packages/flutter_edge_ai/example), APP_ID (its applicationId), DDP_RUNS
# (where logs go, default $TMPDIR/ddp-runs), INSTRUMENT_TIMEOUT (seconds,
# default 1800).
#
# The verdict is the Dart summary (I/flutter "All tests passed" / "Some tests
# failed"), not INSTRUMENTATION_CODE: `am instrument` reports OK when a Dart
# setUpAll failed. Exit 0 = a passing summary and no native crash in the app.
set -uo pipefail
NAME=${1:?run name}; TARGET=${2:?integration_test/<file>.dart}; shift 2
SERIAL=${SERIAL:?SERIAL=localhost:<port> from ddp.sh forward}
TIMEOUT=${INSTRUMENT_TIMEOUT:-1800}
[[ $TIMEOUT =~ ^[0-9]+$ ]] || { echo "INSTRUMENT_TIMEOUT must be whole seconds, got '$TIMEOUT'"; exit 2; }
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
EXAMPLE=${EXAMPLE:-$ROOT/packages/flutter_edge_ai/example}
APP_ID=${APP_ID:-dev.flutterberlin.flutter_gemma_example}
OUT=${DDP_RUNS:-${TMPDIR:-/tmp}/ddp-runs}/$NAME
mkdir -p "$OUT"
export JAVA_HOME=${JAVA_HOME:-"/Applications/Android Studio.app/Contents/jbr/Contents/Home"}

defines=""
for kv in "$@"; do
  # A define is compiled into the APK, and the APK stays on a phone other
  # people use after us: stage gated models instead of passing a token.
  key=$(printf '%s' "${kv%%=*}" | tr '[:lower:]' '[:upper:]')
  if [[ $key =~ TOKEN|KEY|SECRET|PASSWORD ]]; then
    echo "refusing --dart-define ${kv%%=*}: it would be compiled into the APK on a shared phone"; exit 2
  fi
  defines="${defines:+$defines,}$(printf '%s' "$kv" | base64)"
done

# Any flutter command rewrites GeneratedPluginRegistrant.java, and a release or
# non-Android one leaves out dev_dependency plugins: integration_test among
# them. Without IntegrationTestPlugin the Dart side cannot hand its results to
# FlutterTestRunner and `am instrument` waits until the session expires (seen
# 2026-10-14). A debug config run writes the registrant this build needs; it
# also creates the Gradle wrapper in a fresh worktree.
(cd "$EXAMPLE" && flutter build apk --config-only --debug >"$OUT/config.log" 2>&1) \
  || { tail -30 "$OUT/config.log"; exit 1; }
grep -q IntegrationTestPlugin "$EXAMPLE/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java" \
  || { echo "GeneratedPluginRegistrant has no IntegrationTestPlugin: is integration_test a dev_dependency?"; exit 1; }

# Runs "$@" for at most $1 seconds: adb waits forever ("- waiting for device -")
# once the forwarder is gone.
with_timeout() {
  local secs=$1; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local watchdog=$!
  wait "$pid"; local rc=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  return $rc
}

echo "== build $TARGET"
(cd "$EXAMPLE/android" && ./gradlew -q app:assembleDebug app:assembleDebugAndroidTest \
  -Ptarget="$EXAMPLE/$TARGET" ${defines:+-Pdart-defines="$defines"}) >"$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log"; exit 1; }
APK=$EXAMPLE/build/app/outputs/apk/debug/app-debug.apk
TAPK=$EXAMPLE/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk
# Provenance: which native library this run actually tested. Hashing a missing
# entry would print the empty-input hash (e3b0c442...), which looks like one.
if unzip -l "$APK" lib/arm64-v8a/libLiteRtLm.so >/dev/null 2>&1; then
  echo "   libLiteRtLm sha256 $(unzip -p "$APK" lib/arm64-v8a/libLiteRtLm.so | shasum -a 256 | cut -c1-16)"
else
  echo "   no lib/arm64-v8a/libLiteRtLm.so in the APK"
fi

echo "== install"
adb -s "$SERIAL" install -r -t -g "$APK" >"$OUT/install.log" 2>&1 || { cat "$OUT/install.log"; exit 1; }
adb -s "$SERIAL" install -r -t "$TAPK" >>"$OUT/install.log" 2>&1 || { cat "$OUT/install.log"; exit 1; }

INSTRUMENT=""; LOGCAT=""
# Stops the app on the phone: killing the host-side `adb shell` is not known to
# stop the test there, and a test left running would overlap the next one.
stop_app() { with_timeout 30 adb -s "$SERIAL" shell am force-stop "$APP_ID" >/dev/null 2>&1; }
# Any exit, Ctrl-C included, takes the host jobs down, and the app if the test
# was still running.
cleanup() {
  if [[ -n $INSTRUMENT ]] && kill -0 "$INSTRUMENT" 2>/dev/null; then
    kill "$INSTRUMENT" 2>/dev/null; stop_app
  fi
  if [[ -n $LOGCAT ]]; then kill "$LOGCAT" 2>/dev/null; fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "== run"
adb -s "$SERIAL" logcat -c
adb -s "$SERIAL" logcat -v time >"$OUT/logcat.txt" 2>&1 &
LOGCAT=$!
T0=$(date +%s)
adb -s "$SERIAL" shell am instrument -w -r \
  "$APP_ID.test/androidx.test.runner.AndroidJUnitRunner" >"$OUT/instrument.txt" 2>&1 &
INSTRUMENT=$!
# DDP bills while we wait: stop waiting a minute after the Dart summary, or
# after INSTRUMENT_TIMEOUT seconds (default 1800) if no summary ever comes.
SUMMARY_AT=""
while kill -0 "$INSTRUMENT" 2>/dev/null; do
  now=$(date +%s)
  if [[ -z $SUMMARY_AT ]] && grep -qE "I/flutter.*(All tests passed|Some tests failed)" "$OUT/logcat.txt"; then
    SUMMARY_AT=$now
  fi
  if [[ -n $SUMMARY_AT && $(( now - SUMMARY_AT )) -gt 60 ]] \
     || [[ $(( now - T0 )) -gt $TIMEOUT ]]; then
    echo "!! am instrument did not return; stopped it (the Dart summary below is the verdict)"
    kill "$INSTRUMENT" 2>/dev/null
    stop_app
    break
  fi
  sleep 5
done
wait "$INSTRUMENT" 2>/dev/null
echo "   took $(( $(date +%s) - T0 )) s"
sleep 2
kill "$LOGCAT" 2>/dev/null; LOGCAT=""
with_timeout 30 adb -s "$SERIAL" logcat -d -b crash >"$OUT/crash.txt" 2>&1

grep -E "INSTRUMENTATION_(CODE|RESULT)|OK \(|FAILURES" "$OUT/instrument.txt" | tail -3
echo "== dart summary (I/flutter)"
grep -E "I/flutter.*(All tests passed|Some tests failed|\+[0-9]+.*:)" "$OUT/logcat.txt" | tail -6
crashed=""
if grep -qE "Fatal signal|SIGSEGV|SIGABRT" "$OUT/logcat.txt" "$OUT/crash.txt"; then
  echo "!! native crash: see $OUT/crash.txt"
  # logcat is the whole phone's: fail the run only on a crash in our process
  # (the tombstone names it as ">>> <process> <<<").
  if grep -qF ">>> $APP_ID <<<" "$OUT/logcat.txt" "$OUT/crash.txt"; then crashed=1; fi
fi
echo "== logs in $OUT"
summary=$(grep -E "I/flutter.*(All tests passed|Some tests failed)" "$OUT/logcat.txt" | tail -1)
[[ -z $crashed ]] || exit 1
[[ $summary == *"All tests passed"* ]] || { [[ -n $summary ]] || echo "!! no Dart summary"; exit 1; }
