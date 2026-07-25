#!/usr/bin/env bash
set -euo pipefail
TEAM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
mkdir -p "$TEAM_ROOT/homes/grok" "$TEAM_ROOT/homes/claude" "$TEAM_ROOT/homes/kimi"
mkdir -p "$BIN_DIR"

# seed the shared board (one file everyone reads and writes)
BOARD="$TEAM_ROOT/board/board.md"
mkdir -p "$TEAM_ROOT/board"
if [ ! -f "$BOARD" ]; then
  printf '# KM board\n\nThe shared channel. Paste here, or use `post`. Read with `board`.\n' > "$BOARD"
fi

for name in grokpi claudepi kimipi post board; do
  chmod +x "$TEAM_ROOT/bin/$name"
  ln -sf "$TEAM_ROOT/bin/$name" "$BIN_DIR/$name"
  echo "  linked $BIN_DIR/$name"
done

echo "KM Team ready: grokpi (challenger) / claudepi (coder) / kimipi (judge)"
echo "Board:  post <who> \"msg\"   ·   board   ·   board -f"
echo "Each worker has an isolated Pi home under team/homes/"
