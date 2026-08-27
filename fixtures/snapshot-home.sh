#!/usr/bin/env bash
# Snapshot a version's DSH_HOME as an upgrade fixture (tar, excluding the
# profile's node_modules — it is reinstalled by the target version on boot).
# Restoring the tar into the next version's env simulates an in-place upgrade
# of the same home directory.
set -euo pipefail
VER="${1:?usage: snapshot-home.sh <version> [label]}"
LABEL="${2:-$VER}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$ROOT/envs/$VER/home"
OUT_DIR="$ROOT/fixtures/snapshots"
mkdir -p "$OUT_DIR"
[ -d "$HOME_DIR" ] || { echo "no home for $VER" >&2; exit 1; }

# secrets guard: refuse to snapshot if anything key-like is in settings
if grep -rE "sk-[A-Za-z0-9]{8}|apiKey:" "$HOME_DIR/settings.yaml" 2>/dev/null | grep -v apiKeyEnv; then
  echo "possible secret in settings.yaml — aborting" >&2; exit 1
fi

tar -czf "$OUT_DIR/home-$LABEL.tar.gz" -C "$HOME_DIR" \
  --exclude 'profiles/node_modules' --exclude 'profiles/*/node_modules' .
tar -tzf "$OUT_DIR/home-$LABEL.tar.gz" > "$OUT_DIR/home-$LABEL.manifest.txt"
echo "snapshot: $OUT_DIR/home-$LABEL.tar.gz ($(du -h "$OUT_DIR/home-$LABEL.tar.gz" | cut -f1))"
