#!/usr/bin/env bash
# One upgrade hop: restore a DSH_HOME snapshot, boot a *different* version
# against it (simulating an in-place upgrade), probe the five questions over
# the HTTP API, emit a machine-readable summary, and snapshot the resulting
# home for the next hop in the chain.
#
#   usage: upgrade-hop.sh <snapshot-label> <to-version> <port> [platform-label]
#
# Reads  fixtures/snapshots/home-<snapshot-label>.tar.gz
# Writes logs/<platform>/hop-<snapshot-label>-to-<to-version>.log
#        logs/<platform>/hop-<snapshot-label>-to-<to-version>.summary.json
#        fixtures/snapshots/home-chain-<to-version>.tar.gz
set -uo pipefail
FROM="${1:?usage: upgrade-hop.sh <snapshot-label> <to-version> <port> [platform]}"
TO="${2:?}"
PORT="${3:?}"
PLATFORM="${4:-macos}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAP="$ROOT/fixtures/snapshots/home-$FROM.tar.gz"
APP="$ROOT/envs/$TO/app/node_modules/.bin/dsh"
HOP_HOME="$ROOT/envs/$TO/home-from-$FROM"
LOG="$ROOT/logs/$PLATFORM/hop-$FROM-to-$TO.log"
SUMMARY="$ROOT/logs/$PLATFORM/hop-$FROM-to-$TO.summary.json"
BASE="http://127.0.0.1:$PORT"
mkdir -p "$(dirname "$LOG")"
say() { echo "[hop] $*" | tee -a "$LOG"; }
rpc() { curl -sS -m 30 -X POST "$BASE/api/$1" -H 'content-type: application/json' \
        -H "origin: $BASE" \
        -d '{"type":"client-request","rpcId":"hop-'"$RANDOM"'","method":"'"$1"'","payload":'"$2"'}'; }

[ -f "$SNAP" ] || { echo "missing snapshot $SNAP" >&2; exit 1; }
[ -x "$APP" ] || { echo "version $TO not installed" >&2; exit 1; }

say "=== hop: home[$FROM] booted by dsh@$TO ($(uname -srm), node $(node -v)) ==="
date -u +"%Y-%m-%dT%H:%M:%SZ" | tee -a "$LOG"

# 1. restore snapshot into a fresh hop home
rm -rf "$HOP_HOME"; mkdir -p "$HOP_HOME"
tar -xzf "$SNAP" -C "$HOP_HOME"
SES_ID=$(find "$HOP_HOME/sessions" -maxdepth 2 -type d -name 'session-*' | head -1 | xargs basename 2>/dev/null)
say "restored snapshot; fixture session: ${SES_ID:-<none>}"

# best-effort: recreate the workspace paths the snapshot's registry points at
# (absent on a different machine, e.g. a CI runner restoring a foreign snapshot)
python3 -c "
import json
d = json.load(open('$HOP_HOME/storages/workspace.json'))
for w in d.get('tables', {}).get('workspaces', {}).values():
    print(w['path'])" 2>/dev/null | while read -r p; do
  [ -d "$p" ] || mkdir -p "$p" 2>/dev/null || say "note: cannot create workspace path $p"
done

# 2. boot target version against it
export DSH_HOME="$HOP_HOME"
export DSH_TELEMETRY_DISABLED=1
"$APP" web --no-open --port "$PORT" >>"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null' EXIT
BOOT=fail
for _ in $(seq 1 90); do
  curl -sS -o /dev/null -m 2 "$BASE/" 2>/dev/null && { BOOT=pass; break; }
  kill -0 $SERVER_PID 2>/dev/null || break
  sleep 1
done
say "Q-boot: $BOOT"

WS=fail; SLIST=fail; HIST=fail; SETTINGS=fail; EVENTS=0
if [ "$BOOT" = pass ]; then
  # Q: workspace registry survives
  R=$(rpc workspace.list '{}'); echo "workspace.list -> $R" >>"$LOG"
  echo "$R" | grep -q '"workspaceId"' && WS=pass
  # Q: session listed (projection/index layer)
  R=$(rpc session.list '{}'); echo "session.list -> $R" >>"$LOG"
  [ -n "${SES_ID:-}" ] && echo "$R" | grep -q "$SES_ID" && SLIST=pass
  # Q: session log readable (persistence layer)
  if [ -n "${SES_ID:-}" ]; then
    R=$(rpc session.history '{"sessionId":"'"$SES_ID"'"}')
    echo "session.history -> $(echo "$R" | head -c 2000)" >>"$LOG"
    EVENTS=$(echo "$R" | python3 -c "import json,sys
try:
  d=json.load(sys.stdin); v=d['result'].get('value') or {}
  print(len(v.get('events') or []))
except Exception: print(0)")
    [ "$EVENTS" -ge 20 ] && HIST=pass
  fi
  # Q: user settings layer still honored — match only the fixture's own custom
  # marker (its provider baseURL), which cannot come from shipped defaults
  R=$(rpc settings.describe '{}'); echo "settings.describe -> $(echo "$R" | head -c 3000)" >>"$LOG"
  echo "$R" | grep -q '127.0.0.1:8765' && SETTINGS=pass
fi

# 3. persist resulting home for the next hop in the chain
kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; trap - EXIT
tar -czf "$ROOT/fixtures/snapshots/home-chain-$TO.tar.gz" -C "$HOP_HOME" \
  --exclude 'profiles/node_modules' --exclude 'profiles/*/node_modules' .

cat > "$SUMMARY" <<EOF
{"hop":"$FROM->$TO","platform":"$PLATFORM","boot":"$BOOT","workspace_list":"$WS","session_list":"$SLIST","session_history":"$HIST","history_events":$EVENTS,"settings":"$SETTINGS"}
EOF
say "summary: $(cat "$SUMMARY")"
