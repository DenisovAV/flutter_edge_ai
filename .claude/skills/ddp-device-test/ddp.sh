#!/usr/bin/env bash
# One Developer Device Platform (DDP) session at a time, kept in a state file.
# DDP bills per minute on krups-develop: cancel as soon as the run is done.
#
#   ddp.sh devices [pattern]        catalog (ID = <androidModelId>-<androidVersionId>)
#   ddp.sh reserve <id> [minutes]   e.g. ddp.sh reserve e1q-34 60; waits for ACTIVE
#   ddp.sh status                   state and expireTime of the saved session
#   ddp.sh extend <minutes>         new remaining lifetime from now
#   ddp.sh forward                  adb forwarder for the remaining lifetime (run it
#                                   in the background; it runs `adb connect` itself and
#                                   prints "listening on localhost:<port>")
#   ddp.sh cancel [session]         ends the session (billing stops) and deletes the state
#   ddp.sh sessions                 the project's latest sessions, from the server: finds
#                                   one the state file lost (cancel it by name)
#
# Env: DDP_PROJECT (default krups-develop), DDP_STATE (default ~/.ddp/session.json),
# DDP_FORWARDER_DIR (default ~/.ddp: Google's demo_adb_forwarder.py + .venv).
set -euo pipefail
PROJECT=${DDP_PROJECT:-krups-develop}
STATE=${DDP_STATE:-$HOME/.ddp/session.json}
FWD_DIR=${DDP_FORWARDER_DIR:-$HOME/.ddp}
API=https://devicestreaming.googleapis.com/v1

token() { gcloud auth print-access-token; }
field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }
name() {
  [[ -f $STATE ]] || { echo "no session in $STATE" >&2; exit 1; }
  field name <"$STATE"
}
get() { curl -fsS -H "Authorization: Bearer $(token)" "$API/$(name)"; }

# Runs "$@" and replaces $STATE with its output only if that names a session.
# `cmd >"$STATE"` empties the file before cmd runs, and a failed call would lose
# the one record of which session is billing.
save() {
  local tmp; tmp=$(mktemp "$STATE.XXXXXX")
  if "$@" >"$tmp" && [[ -n $(field name <"$tmp" 2>/dev/null) ]]; then
    mv "$tmp" "$STATE"
  else
    rm -f "$tmp"; echo "request failed; $STATE left as it was" >&2; return 1
  fi
}

remaining_seconds() {
  python3 - "$1" <<'EOF'
import datetime, sys
end = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
print(max(0, int((end - datetime.datetime.now(datetime.timezone.utc)).total_seconds())))
EOF
}

extend() {
  local seconds=$(( $1 * 60 ))
  # "${n}:cancel" style: in zsh "$n:c..." would apply a history modifier.
  save curl -fsS -X PATCH -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
    -d "{\"ttl\": \"${seconds}s\"}" "$API/$(name)?updateMask=ttl"
  echo "expireTime $(field expireTime <"$STATE")"
}

case ${1:-} in
  devices)
    gcloud beta device-run devices list --project "$PROJECT" | grep -E "${2:-.}" ;;
  reserve)
    id=${2:?device id, e.g. e1q-34}; minutes=${3:-60}
    if [[ -f $STATE ]]; then
      echo "a session is already saved in $STATE ($(name)): cancel it first" >&2; exit 1
    fi
    model=${id%-*}; version=${id##*-}
    mkdir -p "$(dirname "$STATE")"
    save curl -fsS -X POST -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
      -d "{\"androidDevice\": {\"androidModelId\": \"$model\", \"androidVersionId\": \"$version\"},
           \"clientInfo\": {\"client\": \"skills/cloud/developer-device-platform-basics\"}}" \
      "$API/projects/$PROJECT/deviceSessions" \
      || { echo "the session may still have been created: ddp.sh sessions" >&2; exit 1; }
    echo "reserved $(name) ($id); billed per minute until 'ddp.sh cancel'"
    for _ in $(seq 120); do
      save get || true   # a failed poll keeps the last state and polls again
      state=$(field state <"$STATE")
      [[ $state == ACTIVE ]] && break
      [[ $state == FINISHED || $state == ERROR || $state == UNAVAILABLE ]] && {
        echo "session ended as $state" >&2; cat "$STATE" >&2; rm -f "$STATE"; exit 1; }
      sleep 5
    done
    [[ $(field state <"$STATE") == ACTIVE ]] || { echo "not ACTIVE after 10 min; cancel it" >&2; exit 1; }
    # The default lifetime can be as short as 15 minutes: set it explicitly.
    extend "$minutes" ;;
  status)
    save get
    echo "$(name) $(field state <"$STATE") expires $(field expireTime <"$STATE")" ;;
  extend)
    extend "${2:?minutes}" ;;
  forward)
    save get
    ttl=$(remaining_seconds "$(field expireTime <"$STATE")")
    cd "$FWD_DIR"
    # --access_token: works when Application Default Credentials have expired.
    exec .venv/bin/python3 demo_adb_forwarder.py --device_session "$(name)" --ttl "$ttl" \
      --access_token "$(token)" ;;
  cancel)
    n=${2:-$(name)}
    curl -fsS -X POST -H "Authorization: Bearer $(token)" -H "Content-Type: application/json" \
      -d '{}' "$API/${n}:cancel" >/dev/null
    curl -fsS -H "Authorization: Bearer $(token)" "$API/${n}" | field state
    # Only the saved session's record goes; cancelling another one by name keeps it.
    if [[ -f $STATE && $(field name <"$STATE" 2>/dev/null) == "$n" ]]; then rm -f "$STATE"; fi ;;
  sessions)
    # The server's filter parameter answers 500 (2026-10-14): list, newest first.
    curl -fsS -H "Authorization: Bearer $(token)" "$API/projects/$PROJECT/deviceSessions?pageSize=10" |
      python3 -c 'import json,sys
for s in json.load(sys.stdin).get("deviceSessions", []):
    print(s["name"], s.get("state"), s.get("expireTime", ""), s.get("androidDevice", {}).get("androidModelId", ""))' ;;
  *)
    sed -n '2,17p' "$0"; exit 2 ;;
esac
