#!/usr/bin/env bash
# Install one @deepseek-ai/dsh version into an isolated prefix under envs/<version>/app,
# with its own DSH_HOME at envs/<version>/home. Raw log goes to logs/<platform>/install-<version>.log.
set -uo pipefail
VER="${1:?usage: install-tag.sh <version> [platform-label]}"
PLATFORM="${2:-macos}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/envs/$VER"
LOG="$ROOT/logs/$PLATFORM/install-$VER.log"
mkdir -p "$ENV_DIR/app" "$ENV_DIR/home" "$(dirname "$LOG")"

{
  echo "=== npm install @deepseek-ai/dsh@$VER ==="
  date -u +"%Y-%m-%dT%H:%M:%SZ"
  echo "node $(node -v) / npm $(npm -v) / $(uname -srm)"
  echo "NODE_OPTIONS=${NODE_OPTIONS:-<unset>}"
  echo "registry=$(npm config get registry)"
} | tee "$LOG"

# /usr/bin/time -l (macOS) / -v (Linux) records the npm process peak RSS —
# the process that the community OOM reports point at. Degrade gracefully when
# GNU time is absent (e.g. stock ubuntu CI runners without `apt install time`).
TIME_CMD=()
if [ "$(uname -s)" = "Darwin" ]; then TIME_CMD=(/usr/bin/time -l)
elif [ -x /usr/bin/time ]; then TIME_CMD=(/usr/bin/time -v)
else echo "note: /usr/bin/time not available; no peak-RSS measurement" | tee -a "$LOG"; fi

"${TIME_CMD[@]}" npm install --prefix "$ENV_DIR/app" --no-fund --no-audit \
  "@deepseek-ai/dsh@$VER" 2>&1 | tee -a "$LOG"
STATUS=$?
echo "npm exit status: $STATUS" | tee -a "$LOG"

"$ENV_DIR/app/node_modules/.bin/dsh" --version 2>&1 | tee -a "$LOG"
exit $STATUS
