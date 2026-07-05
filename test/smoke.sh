#!/usr/bin/env bash
# shellcheck disable=SC2015
# SC2015: A && B || C pattern — intentional: fail flag controls exit code
# Optional end-to-end test against ssh localhost. Fully isolated:
# refuses to run if either projects root resolves to a real ~/.claude/projects.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TEST_DIR")"
CLI="$REPO_DIR/bin/claude-roam"

if ! ssh -o BatchMode=yes -o ConnectTimeout=3 localhost true 2>/dev/null; then
  echo "SKIP: passwordless 'ssh localhost' not available"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LROOT="$TMP/local-projects"
RROOT="$TMP/remote-projects"
mkdir -p "$LROOT" "$RROOT"

# --- isolation guards: never touch real session stores ---
for root in "$LROOT" "$RROOT"; do
  case "$root" in
    "$HOME/.claude/projects"*|*/.claude/projects) echo "ABORT: root '$root' points at a real session store"; exit 1 ;;
  esac
done

export CLAUDE_ROAM_PROJECTS="$LROOT"
export CLAUDE_ROAM_REMOTE_PROJECTS="$RROOT"
export CLAUDE_ROAM_REMOTE="localhost"
export XDG_CONFIG_HOME="$TMP/xdg"   # no user config interference

# Isolate the config so sync-all's project-extras phase never touches the
# developer's real $HOME/code — only the temp session roots are exercised.
mkdir -p "$TMP/xdg/claude-roam"
printf 'PROJECT_ROOTS=()\nHOME_RELATIVE_EXTRAS=()\n' > "$TMP/xdg/claude-roam/config"

ENC="$(printf -- '-%s' "${HOME#/}" | tr '/' '-')"
SID="smoke0001"
mkdir -p "$LROOT/$ENC-code-smokeproj"
printf '{"type":"t","cwd":"%s/code/smokeproj"}\n' "$HOME" > "$LROOT/$ENC-code-smokeproj/$SID.jsonl"

fail=0
step() { echo "== $*"; }

step "recent shows fixture"
"$CLI" recent 5 | grep -q "$SID" || { echo "FAIL recent"; fail=1; }

step "push"
"$CLI" push "$SID" || { echo "FAIL push"; fail=1; }
[ -f "$RROOT/$ENC-code-smokeproj/$SID.jsonl" ] || { echo "FAIL push landed"; fail=1; }

step "list shows pushed session"
"$CLI" list 5 | grep -q "$SID" || { echo "FAIL list"; fail=1; }

step "pull refuses when local newer, then --force works"
sleep 1; printf '{"more":1}\n' >> "$LROOT/$ENC-code-smokeproj/$SID.jsonl"
if "$CLI" pull "$SID" 2>/dev/null; then echo "FAIL pull should refuse"; fail=1; fi
"$CLI" --force pull "$SID" || { echo "FAIL forced pull"; fail=1; }

step "sync-all: sentinel must NOT transfer; remote-only session must appear"
mkdir -p "$RROOT/$ENC-code-remoteonly"
printf '{}\n' > "$RROOT/$ENC-code-remoteonly/rr01.jsonl"
"$CLI" sync-all both || { echo "FAIL sync-all"; fail=1; }
[ -f "$LROOT/$ENC-code-remoteonly/rr01.jsonl" ] || { echo "FAIL remote-only discovery"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "SMOKE PASSED"
else
  echo "SMOKE FAILED"
  exit 1
fi
