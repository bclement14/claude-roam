#!/usr/bin/env bash
# claude-roam installer: symlink CLI + skill, seed config, verify. Idempotent.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '%s\n' "$*"; }
link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then log "  ok   $dst"; return; fi
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    local backup
    backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
    log "  backup $dst -> $backup"; mv "$dst" "$backup"
  fi
  ln -sfn "$src" "$dst"
  log "  link $dst -> $src"
}

log "Installing claude-roam from $DIR"
mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills"
link "$DIR/bin/claude-roam" "$HOME/.local/bin/claude-roam"
link "$DIR/skill/claude-roam" "$HOME/.claude/skills/claude-roam"

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-roam"
CFG="$CFG_DIR/config"
if [ -f "$CFG" ]; then
  log "  ok   $CFG (existing config preserved)"
else
  mkdir -p "$CFG_DIR"
  cp "$DIR/examples/config.example" "$CFG"
  chmod 600 "$CFG"   # sourced as shell — keep it owner-only, per docs/configuration.md
  log "  seeded $CFG — EDIT IT: set CLAUDE_ROAM_REMOTE to your SSH host alias"
fi

log "Verifying..."
"$HOME/.local/bin/claude-roam" --help >/dev/null || { echo "FAIL: claude-roam --help"; exit 1; }
case ":$PATH:" in
  *":$HOME/.local/bin:"*) : ;;
  *) log "NOTE: add ~/.local/bin to PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
log "Done. Next: edit $CFG, then run: claude-roam doctor"
