---
name: ddp-device-test
description: Run an Android integration test on a real phone through Google's Developer Device Platform (DDP) — reserve the device, forward adb, stage models, run with am instrument, read the result, cancel. The only Android device lab for this repo; Firebase Test Lab is no longer used.
user_invocable: true
---

# Android device tests on DDP

Every Android test that needs a real phone — GPU (OpenCL on Adreno and Mali),
Qualcomm NPU, memory, a release gate — runs on DDP. Firebase Test Lab is not
used any more (owner, 2026-10-14). The pieces here:

| File | What it does |
|---|---|
| `ddp.sh` | One session at a time: `devices`, `reserve`, `status`, `extend`, `forward`, `cancel` |
| `run_instrumented.sh` | Builds the example's app + androidTest APKs for one `integration_test/` file, installs, runs `am instrument`, saves logcat and the crash buffer |

**DDP bills per minute on `krups-develop`.** Tell the owner before reserving,
say roughly how long, keep one session open at a time, and `ddp.sh cancel` the
moment the run is done — also after a failure.

## One-time setup

1. `gcloud components install beta` and, in the browser, `gcloud auth login`.
   When gcloud says "Reauthentication required", ask the owner to run
   `! gcloud auth login`: the scripts use `gcloud auth print-access-token`, so
   expired Application Default Credentials do not matter.
2. Google's forwarder lives outside the repo, in `~/.ddp` (it ships with
   Google's `developer-device-platform-basics` skill, without a licence header,
   so it is not vendored here):
   ```bash
   mkdir -p ~/.ddp && cd ~/.ddp   # put demo_adb_forwarder.py + requirements.txt here
   python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
   ```

## Which phone

| Need | DDP id | Phone | SoC / GPU |
|---|---|---|---|
| Adreno GPU | `e1q-34` | Galaxy S24 | SM8650, Adreno 750 |
| Mali GPU | `akita-35` | Pixel 8a | Tensor G3, Mali-G715 |
| Mali GPU, the #545 crash device | `a34x-36` | Galaxy A34 | Dimensity 1080, Mali-G68 |
| Qualcomm NPU, HTP V75 | `e1q-34` | Galaxy S24 | SM8650 |
| Qualcomm NPU, HTP V79 | `pa3q-35` | Galaxy S25 Ultra | SM8750 |
| Qualcomm NPU, HTP V81 | `m2q-36` | Galaxy S26+ | SM8850 |

A GPU gate is **one Adreno and one Mali**: they take different paths through
the same accelerator (#545 crashed only on Mali). Write the DDP id and the GPU
in every result row; "Galaxy S24" alone does not say which GPU ran. Gemma 4
needs 6 GB+ of RAM. `ddp.sh devices <pattern>` shows the catalog and how
available each phone is (`LOW` can mean a long wait).

## A run

```bash
D=.claude/skills/ddp-device-test
$D/ddp.sh reserve e1q-34 60          # waits for ACTIVE, then sets a 60-minute lifetime
$D/ddp.sh forward > ~/.ddp/forwarder.log 2>&1 & FWD=$!   # in the background
for _ in $(seq 60); do                 # the port appears within ~1 min
  SERIAL=$(grep -m1 -o 'localhost:[0-9]*' ~/.ddp/forwarder.log) && break
  kill -0 $FWD 2>/dev/null || break    # the forwarder died: read its log
  sleep 2
done
export SERIAL=${SERIAL:?no port: read ~/.ddp/forwarder.log}   # it ran `adb connect` itself
adb devices                            # localhost:<port>  device
adb -s $SERIAL shell getprop ro.soc.model

# Stage models where the tests look for them: the example's tests read
# /data/local/tmp/flutter_gemma_test/ (stagedModelPath), the hybrid-AI
# codelab's smoke test reads /data/local/tmp/flutter_edge_ai_test/.
adb -s $SERIAL shell mkdir -p /data/local/tmp/flutter_gemma_test
adb -s $SERIAL shell test -x /system/bin/curl && echo curl || echo no-curl   # Pixels have none
# with curl (Samsung):
adb -s $SERIAL shell "nohup /system/bin/curl --capath /system/etc/security/cacerts -sSL -C - \
  -o /data/local/tmp/flutter_gemma_test/<file> '<public URL>' \
  > /data/local/tmp/curl_<file>.log 2>&1 &"
adb -s $SERIAL shell ls -l /data/local/tmp/flutter_gemma_test/   # poll the size; pidof curl must stay set
# without curl (Pixel): from a local copy
adb -s $SERIAL push <local file> /data/local/tmp/flutter_gemma_test/<file>

$D/run_instrumented.sh <run-name> integration_test/<file>.dart [KEY=VALUE ...]
$D/ddp.sh cancel
```

`run_instrumented.sh` exits 0 only on a passing Dart summary with no native
crash in the app's process.

## What goes wrong

- **The forwarder serves one adb client.** It runs `adb connect` itself; do not
  add your own `adb connect` or `adb wait-for-device`. If its log shows two
  `Client connected` lines and then `ConnectionResetError: Connection lost`, the
  local adb server is stale (seen 2026-10-14 with a server up for days):
  `adb kill-server && adb start-server`, then `ddp.sh forward` again.
- **The default session lifetime can be 15 minutes.** `reserve` sets it; for a
  longer run `ddp.sh extend <minutes>`, then restart `forward`, since the
  forwarder's own lifetime is fixed when it starts.
- **The forwarder can drop after ~30 minutes**, and it takes a running
  `adb push` with it (1.4–5.4 MB/s measured). Where the phone has `curl`,
  download with it under `nohup` as above (3–7 MB/s, survives a drop, `-C -`
  resumes). Use public URLs only: never put an HF token on a shared phone; for
  a gated file use a short-lived signed URL.
- **No secrets as `KEY=VALUE`.** A dart-define is compiled into the APK, and the
  APK stays on a phone other people use after us. `run_instrumented.sh` refuses
  a name containing TOKEN, KEY, SECRET or PASSWORD. Stage gated models instead;
  a test that needs a cloud key (the hybrid-AI codelab's cloud half) runs on a
  device of your own.
- **Not every phone has `curl`.** Samsung images ship `/system/bin/curl`; the
  Pixel 8a (`akita-35`) does not, and `nohup` only says so in the log file while
  a size poll waits for nothing (2026-10-14, 16 billed minutes). Check
  `test -x /system/bin/curl` first, poll `pidof curl` along with the size, and
  on a Pixel `adb push` a local copy: 284 MB took 50 s (5.4 MB/s), well inside
  the forwarder's ~30.
- **`flutter test -d` cannot attach** through the forwarder (no Dart VM service).
  Use `run_instrumented.sh`. Dart defines go through `-Pdart-defines` as base64,
  which the script does for `KEY=VALUE` pairs.
- **`am instrument` can wait forever.** Any flutter command rewrites
  `GeneratedPluginRegistrant.java`, and a release or non-Android one drops
  dev_dependency plugins, `integration_test` among them. The Dart log then ends
  with "integration_test plugin was not detected", `FlutterTestRunner` never
  gets a result, and the session bills until it expires (2026-10-14, 23 minutes).
  `run_instrumented.sh` regenerates the registrant in debug, refuses to run
  without `IntegrationTestPlugin`, and stops waiting a minute after the Dart
  summary.
- **`am instrument` says OK when a Dart `setUpAll` failed.** The verdict is the
  `I/flutter` summary line, which the script prints; Rule 6b (no `setUp` that
  can throw) applies here too.
- **A native crash ends the process with no Dart error.** The script saves
  `logcat -b crash` to `crash.txt` and flags `Fatal signal`/`SIGSEGV`; a signal
  is not an exception, so the engine's CPU fallback never sees it.
- **zsh:** write `"${name}:cancel"`, never `"$name:cancel"` — `:c` is a history
  modifier and the request 404s. `ddp.sh` already does this.
- **A session left open keeps billing.** `ddp.sh status` before reserving; the
  state file is `~/.ddp/session.json`, and a failed call leaves it as it was.
  If it is lost anyway, or `reserve` failed after the request went out,
  `ddp.sh sessions` lists the project's latest sessions from the server and
  `ddp.sh cancel <name>` ends one by name.
