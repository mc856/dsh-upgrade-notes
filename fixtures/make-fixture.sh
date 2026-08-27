#!/usr/bin/env bash
# Create a reproducible session fixture inside an installed version's DSH_HOME,
# driving the web server's HTTP API end to end (no UI, no native dialogs):
#   workspace.create -> session.create -> session.prompt -> wait -> shutdown.
#
# Requires an OpenAI-compatible endpoint if the profile's model needs one;
# export the provider env vars (e.g. OPENAI_API_KEY / DEEPSEEK_API_KEY) before calling.
set -uo pipefail
VER="${1:?usage: make-fixture.sh <version> <port> [platform-label]}"
PORT="${2:?usage: make-fixture.sh <version> <port> [platform-label]}"
PLATFORM="${3:-macos}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/envs/$VER"
WS_DIR="$ENV_DIR/workspace"
LOG="$ROOT/logs/$PLATFORM/fixture-$VER.log"
BASE="http://127.0.0.1:$PORT"
PROMPT_TEXT="Create a file named hello.txt in the workspace with the content 'hello from $VER fixture', then briefly summarize what you did."
mkdir -p "$WS_DIR" "$(dirname "$LOG")"

say() { echo "[fixture] $*" | tee -a "$LOG"; }
rpc() { # rpc <method> <payload-json>
  curl -sS -m 30 -X POST "$BASE/api/$1" \
    -H 'content-type: application/json' -H "origin: $BASE" \
    -d '{"type":"client-request","rpcId":"fx-'"$RANDOM"'","method":"'"$1"'","payload":'"$2"'}'
}

say "=== make-fixture $VER on port $PORT ==="
date -u +"%Y-%m-%dT%H:%M:%SZ" | tee -a "$LOG"

# 1. boot server
export DSH_HOME="$ENV_DIR/home"
export DSH_TELEMETRY_DISABLED=1
"$ENV_DIR/app/node_modules/.bin/dsh" web --no-open --port "$PORT" >>"$LOG" 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null' EXIT
for _ in $(seq 1 60); do curl -sS -o /dev/null -m 2 "$BASE/" 2>/dev/null && break; sleep 1; done
curl -sS -o /dev/null -m 2 "$BASE/" || { say "server did not come up"; exit 1; }
say "server up (pid $SERVER_PID)"

# 2. workspace + session
WS_RESP=$(rpc workspace.create '{"path":"'"$WS_DIR"'"}')
say "workspace.create -> $WS_RESP"
WS_ID=$(echo "$WS_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['value']['workspace']['workspaceId'])") || exit 1
SES_RESP=$(rpc session.create '{"workspaceId":"'"$WS_ID"'"}')
say "session.create -> $SES_RESP"
SES_ID=$(echo "$SES_RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['value']['sessionId'])") || exit 1

# 3. prompt
PROMPT_JSON=$(python3 -c "import json;print(json.dumps({'sessionId':'$SES_ID','mode':'queue','content':[{'type':'text','text':'''$PROMPT_TEXT'''}]}))")
say "session.prompt -> $(rpc session.prompt "$PROMPT_JSON")"

# 4. wait until the session log stops growing (completion heuristic), max 180s
# (the log file appears shortly after the prompt is accepted, so locate it inside the loop)
SES_FILE=""; LAST=0; STABLE=0
for _ in $(seq 1 90); do
  [ -z "$SES_FILE" ] && SES_FILE=$(find "$ENV_DIR/home/sessions" -name 'session.jsonl*' -path "*$SES_ID*" 2>/dev/null | head -1)
  SIZE=$(stat -f%z "$SES_FILE" 2>/dev/null || stat -c%s "$SES_FILE" 2>/dev/null || echo 0)
  if [ "$SIZE" = "$LAST" ] && [ "$SIZE" -gt 1000 ]; then STABLE=$((STABLE+1)); else STABLE=0; fi
  [ "$STABLE" -ge 5 ] && break
  LAST=$SIZE; sleep 2
done
say "session file: $SES_FILE"
say "session log settled at $LAST bytes"

# 5. verify + shutdown
ls -la "$WS_DIR" | tee -a "$LOG"
[ -f "$WS_DIR/hello.txt" ] && say "hello.txt: $(cat "$WS_DIR/hello.txt")"
kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null
trap - EXIT
say "done: sessionId=$SES_ID workspaceId=$WS_ID"
