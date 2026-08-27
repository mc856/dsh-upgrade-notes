#!/usr/bin/env bash
# Boot `dsh web` from an installed version with its isolated DSH_HOME.
# Extra args pass through to the web app (e.g. --help).
set -euo pipefail
VER="${1:?usage: run-web.sh <version> [web-app args...]}"
shift || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="$ROOT/envs/$VER"
[ -x "$ENV_DIR/app/node_modules/.bin/dsh" ] || { echo "version $VER not installed; run install-tag.sh first" >&2; exit 1; }
export DSH_HOME="$ENV_DIR/home"
export DSH_TELEMETRY_DISABLED=1
exec "$ENV_DIR/app/node_modules/.bin/dsh" web "$@"
