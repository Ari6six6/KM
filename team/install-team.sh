#!/usr/bin/env bash
set -euo pipefail
TEAM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$TEAM_ROOT/homes/grok" "$TEAM_ROOT/homes/claude" "$TEAM_ROOT/homes/kimi"
mkdir -p "$BIN_DIR"
for name in grokpi claudepi kimipi; do
  chmod +x "$TEAM_ROOT/bin/$name"
  ln -sf "$TEAM_ROOT/bin/$name" "$BIN_DIR/$name"
  echo "  linked $BIN_DIR/$name"
done
echo "KM Team ready: grokpi / claudepi / kimipi"
echo "Each has isolated Pi home under team/homes/"
