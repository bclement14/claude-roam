#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034,SC2218,SC2317,SC2329
# SC1091: Not following sourced file — intentional, harness is relative
# SC2016: Expressions don't expand — FALSE POSITIVE in remote_sh() stubs
# SC2034: Appears unused — FALSE POSITIVE, test fixtures used via indirect calls
# SC2218: Function only defined later — FALSE POSITIVE, test stubs shadow sourced function
# SC2317: Command appears unreachable — FALSE POSITIVE, mock functions redefined intentionally
# SC2329: Function never invoked — FALSE POSITIVE, mock functions called indirectly
# Unit tests for bin/claude-roam. No network: ssh/rsync are stubbed as functions.
set -u
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$TEST_DIR")"
. "$TEST_DIR/harness.sh"

# Isolated environment: never touch the developer's real HOME or config.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/xdg"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
unset CLAUDE_ROAM_REMOTE CLAUDE_ROAM_PROJECTS CLAUDE_ROAM_REMOTE_PROJECTS 2>/dev/null || true

# Source the CLI: must define functions only (Task 2 guarantees this).
. "$REPO_DIR/bin/claude-roam"

# ---- tests appended by later tasks below this line ----

# ---- Task 3: config ----
CFG_DIR="$XDG_CONFIG_HOME/claude-roam"; mkdir -p "$CFG_DIR"

# helper: run a bash that sources the CLI, loads config, echoes a var
cfgval() { env -i HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" PATH="$PATH" ${2:+CLAUDE_ROAM_REMOTE="$2"} \
  bash -c ". '$REPO_DIR/bin/claude-roam'; load_config; printf %s \"\$$1\""; }

rm -f "$CFG_DIR/config"
assert_eq "default remote is empty" "" "$(cfgval CLAUDE_ROAM_REMOTE)"
printf 'CLAUDE_ROAM_REMOTE=cfghost\n' > "$CFG_DIR/config"
assert_eq "config sets remote" "cfghost" "$(cfgval CLAUDE_ROAM_REMOTE)"
assert_eq "env beats config" "envhost" "$(cfgval CLAUDE_ROAM_REMOTE envhost)"
assert_eq "empty env means unset" "cfghost" "$(env -i HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" PATH="$PATH" CLAUDE_ROAM_REMOTE= \
  bash -c ". '$REPO_DIR/bin/claude-roam'; load_config; printf %s \"\$CLAUDE_ROAM_REMOTE\"")"

# validation
rc=0; (validate_rel_path "../etc") >/dev/null 2>&1 || rc=$?
assert_rc "rel_path rejects dotdot" 1 "$rc"
rc=0; (validate_rel_path "/abs") >/dev/null 2>&1 || rc=$?
assert_rc "rel_path rejects absolute" 1 "$rc"
rc=0; (validate_rel_path "a b") >/dev/null 2>&1 || rc=$?
assert_rc "rel_path rejects space" 1 "$rc"
rc=0; (validate_rel_path "code/dev_docs") >/dev/null 2>&1 || rc=$?
assert_rc "rel_path accepts nested" 0 "$rc"
rc=0; (validate_remote_alias "-oProxyCommand=x") >/dev/null 2>&1 || rc=$?
assert_rc "alias rejects leading dash" 1 "$rc"

# empty arrays must not crash bash 3.2 under set -u
printf 'HOME_RELATIVE_EXTRAS=()\nPROJECT_ROOTS=()\n' > "$CFG_DIR/config"
rc=0; env -i HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" PATH="$PATH" \
  bash -c "set -u; . '$REPO_DIR/bin/claude-roam'; load_config" >/dev/null 2>&1 || rc=$?
assert_rc "empty config arrays load under set -u" 0 "$rc"
rm -f "$CFG_DIR/config"

# ---- Task 4: translation ----
RHOME="/home/alice"; REMOTE="stub"   # inject seam; no ssh in unit tests
assert_eq "translate to-remote" "-home-alice-code-proj" "$(translate_dir "$(encode_path "$HOME")-code-proj" to-remote)"
assert_eq "translate to-local" "$(encode_path "$HOME")-code-proj" "$(translate_dir "-home-alice-code-proj" to-local)"
assert_eq "translate bare home" "-home-alice" "$(translate_dir "$(encode_path "$HOME")" to-remote)"
rc=0; (translate_dir "-Users-nothome-x" to-remote) >/dev/null 2>&1 || rc=$?
assert_rc "translate rejects outside home" 1 "$rc"
# prefix collision: -home-alice2-... must NOT match -home-alice
RHOME_SAVE="$RHOME"
rc=0; out="$( (translate_dir "$(encode_path "$HOME")2-code" to-remote) 2>&1 )" || rc=$?
assert_rc "translate rejects prefix collision" 1 "$rc"
RHOME="$RHOME_SAVE"; unset RHOME_SAVE

# ---- Task 4 fix: require_remote robustness ----
rc=0; out="$( (RHOME=""; unset CLAUDE_ROAM_REMOTE REMOTE_FLAG 2>/dev/null; require_remote) 2>&1 )" || rc=$?
assert_rc "require_remote dies when unconfigured" 1 "$rc"
assert_match "require_remote guidance mentions --remote" "--remote" "$out"
SSH_COUNT_FILE="$TMP/sshcount"; : > "$SSH_COUNT_FILE"
ssh() { echo x >> "$SSH_COUNT_FILE"; printf '/home/alice'; }
RHOME=""; REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE="stubhost"
require_remote; require_remote
assert_eq "require_remote caches (one ssh for two calls)" "1" "$(grep -c x "$SSH_COUNT_FILE")"
unset -f ssh
CLAUDE_ROAM_REMOTE=""; REMOTE_FLAG=""

# ---- Task 5: transport ----
assert_eq "shq plain" "'abc'" "$(shq abc)"
assert_eq "shq embedded quote" "'a'\\''b'" "$(shq "a'b")"
# remote_sh passes args as argv even with hostile content:
ssh() { # stub: last arg is the assembled "bash -s -- ..." string; execute locally
  local cmd="${*: -1}"; shift $(($#-1)) 2>/dev/null || true
  bash -c "$cmd" < /dev/stdin
}
out="$(remote_sh 'printf "%s|%s" "$1" "$2"' "a b" "c'd")"
assert_eq "remote_sh preserves argv" "a b|c'd" "$out"
unset -f ssh
rc=0; (validate_path "/ok/path_1.x") >/dev/null 2>&1 || rc=$?
assert_rc "validate_path accepts sane" 0 "$rc"
for bad in "/has space" "/has'quote" '/has$dollar' "/has\`tick" "-leading-dash"; do
  rc=0; (validate_path "$bad") >/dev/null 2>&1 || rc=$?
  assert_rc "validate_path rejects [$bad]" 1 "$rc"
done

# ---- Task 5 fix: widened validate_path ----
for bad in "/has;semi" "/has&and" "/has|pipe" "/has(paren" "/has<redir" "/has*glob" "/has?q" "/has[br" "relative/path"; do
  rc=0; (validate_path "$bad") >/dev/null 2>&1 || rc=$?
  assert_rc "validate_path rejects [$bad]" 1 "$rc"
done
rc=0; (validate_path "") >/dev/null 2>&1 || rc=$?
assert_rc "validate_path rejects empty" 1 "$rc"

# ---- Task 6: lookup/compare ----
PROJECTS="$TMP/projects"
mkdir -p "$PROJECTS/$(encode_path "$HOME")-code-p1" "$PROJECTS/$(encode_path "$HOME")-code-p2"
printf '{}\n' > "$PROJECTS/$(encode_path "$HOME")-code-p1/aaa.jsonl"
assert_eq "find_local_session finds one" \
  "$PROJECTS/$(encode_path "$HOME")-code-p1/aaa.jsonl" "$(find_local_session aaa)"
printf '{}\n' > "$PROJECTS/$(encode_path "$HOME")-code-p2/aaa.jsonl"
rc=0; out="$( (find_local_session aaa) 2>&1 )" || rc=$?
assert_rc "find_local_session dies on ambiguity" 1 "$rc"
assert_match "ambiguity lists candidates" "code-p2" "$out"
rm "$PROJECTS/$(encode_path "$HOME")-code-p2/aaa.jsonl"
rc=0; (find_local_session zzz) >/dev/null 2>&1 || rc=$?
assert_rc "find_local_session dies on missing" 1 "$rc"

# compare_mtimes with stubbed remote_stat
LF="$PROJECTS/$(encode_path "$HOME")-code-p1/aaa.jsonl"
remote_stat() { printf '%s' "$STUB_RSTAT"; }
STUB_RSTAT=""
assert_eq "remote-missing" "remote-missing" "$(compare_mtimes "$LF" /r/f)"
STUB_RSTAT="1 1"
assert_eq "local-newer" "local-newer" "$(compare_mtimes "$LF" /r/f)"
STUB_RSTAT="9999999999 1"
assert_eq "remote-newer" "remote-newer" "$(compare_mtimes "$LF" /r/f)"
STUB_RSTAT="$(local_mtime "$LF") $(local_size "$LF")"
assert_eq "equal" "equal" "$(compare_mtimes "$LF" /r/f)"
STUB_RSTAT="$(local_mtime "$LF") 999999"
assert_eq "diverged" "diverged" "$(compare_mtimes "$LF" /r/f)"
assert_eq "local-missing" "local-missing" "$(compare_mtimes /no/file /r/f)"
unset -f remote_stat

# ---- Task 7: push/pull ----
# Stub everything remote so cmd_push exercises only decision logic.
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-p1/aaa.jsonl"; }
remote_sh() { :; }   # mkdir no-op
RSYNC_LOG="$TMP/rsynclog"; : > "$RSYNC_LOG"
rsync() { printf '%s\n' "$*" >> "$RSYNC_LOG"; }
FORCE=0

STUB_CMP="remote-newer"
compare_mtimes() { printf '%s' "$STUB_CMP"; }
rc=0; (cmd_push aaa) >/dev/null 2>&1 || rc=$?
assert_rc "push refuses remote-newer" 1 "$rc"
STUB_CMP="diverged"
rc=0; (cmd_push aaa) >/dev/null 2>&1 || rc=$?
assert_rc "push refuses diverged" 1 "$rc"
STUB_CMP="local-newer"
rc=0; out="$(cmd_push aaa 2>&1)" || rc=$?
assert_rc "push proceeds local-newer" 0 "$rc"
assert_match "push rsyncs the jsonl" "aaa.jsonl" "$(cat "$RSYNC_LOG")"
STUB_CMP="local-newer"; FORCE=0
rc=0; (cmd_pull aaa) >/dev/null 2>&1 || rc=$?
assert_rc "pull refuses local-newer" 1 "$rc"
unset -f compare_mtimes rsync remote_sh find_remote_session require_remote

# ---- Task 8: cwd/list ----
SDIR="$PROJECTS/$(encode_path "$HOME")-code-p1"
printf '{"type":"x","cwd":"%s/code/p1"}\n{"cwd":"/wrong/later"}\n' "$HOME" > "$SDIR/bbb.jsonl"
assert_eq "session_cwd_local reads first cwd" "$HOME/code/p1" "$(session_cwd_local bbb)"
require_remote() { :; }
RHOME="/home/alice"
assert_eq "session_cwd_remote translates" "/home/alice/code/p1" "$(session_cwd_remote bbb)"
printf '{"nocwd":true}\n' > "$SDIR/ccc.jsonl"
rc=0; (session_cwd_local ccc) >/dev/null 2>&1 || rc=$?
assert_rc "session_cwd_local dies without cwd" 1 "$rc"
out="$(cmd_recent 5)"
assert_match "recent lists fixture" "bbb.jsonl" "$out"
unset -f require_remote

# ---- Task 8 fix: cmd_recent pipefail/SIGPIPE at scale ----
BIGP="$TMP/bigprojects/$(encode_path "$HOME")-code-big"
mkdir -p "$BIGP"
i=0
while [ $i -lt 800 ]; do printf '{}' > "$BIGP/s$i.jsonl"; i=$((i+1)); done
rc=0; CLAUDE_ROAM_PROJECTS="$TMP/bigprojects" "$REPO_DIR/bin/claude-roam" recent 5 >/dev/null 2>&1 || rc=$?
assert_rc "recent survives pipefail at 800 sessions" 0 "$rc"

# ---- Task 9: sync-extras ----
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
SYNCLOG="$TMP/synclog"; : > "$SYNCLOG"
rsync() { printf '%s\n' "$*" >> "$SYNCLOG"; }
remote_sh() { :; }
mkdir -p "$HOME/code/p1/.claude/plans" "$SDIR/memory"
HOME_RELATIVE_EXTRAS=(); PROJECT_CLAUDE_EXTRAS=(plans); SESSION_DIR_EXTRAS=(memory)
rc=0; cmd_sync_extras bbb to-remote >/dev/null 2>&1 || rc=$?
assert_rc "sync-extras runs with empty HOME_RELATIVE_EXTRAS" 0 "$rc"
assert_match "plans synced" "code/p1/.claude/plans" "$(cat "$SYNCLOG")"
assert_match "memory synced" "memory" "$(cat "$SYNCLOG")"
PROJECT_CLAUDE_EXTRAS=(); SESSION_DIR_EXTRAS=(); HOME_RELATIVE_EXTRAS=()
rc=0; cmd_sync_extras bbb to-remote >/dev/null 2>&1 || rc=$?
assert_rc "sync-extras all-empty arrays no crash" 0 "$rc"
unset -f rsync remote_sh require_remote
load_config   # restore defaults for later tasks
PROJECTS="$TMP/projects"

# ---- Task 10: sync-all ----
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects
# remote has one session dir we don't have, plus one shared:
remote_sh() {
  case "$1" in
    *find*-maxdepth\ 1*) printf '%s\n' "-home-alice-code-p1" "-home-alice-code-remoteonly" ;;
    *) : ;;
  esac
}
out="$(union_session_dirs)"
assert_match "union has local dir" "$(encode_path "$HOME")-code-p1" "$out"
assert_match "union discovers remote-only (translated)" "$(encode_path "$HOME")-code-remoteonly" "$out"
# failure summary: a failing step must not abort the sweep
FAILED_N=0
sync_try false || true
assert_eq "sync_try counts failure" "1" "$FAILED_N"
unset -f remote_sh require_remote

# ---- Task 2: skeleton ----
assert_eq "encode_path root-strip" "-Users-alice" "$(encode_path /Users/alice)"
assert_eq "encode_path nested" "-home-alice-code-proj" "$(encode_path /home/alice/code/proj)"
rc=0; (validate_sid "abc-123.DEF_x") >/dev/null 2>&1 || rc=$?
assert_rc "validate_sid accepts uuid-ish" 0 "$rc"
rc=0; (validate_sid "bad;id") >/dev/null 2>&1 || rc=$?
assert_rc "validate_sid rejects semicolon" 1 "$rc"
rc=0; (validate_sid "") >/dev/null 2>&1 || rc=$?
assert_rc "validate_sid rejects empty" 1 "$rc"
rc=0; (validate_int "12x") >/dev/null 2>&1 || rc=$?
assert_rc "validate_int rejects non-digit" 1 "$rc"
# Sourcing safety: sourcing must not enable -e/-u in this shell.
case "$-" in *e*) t_fail "sourcing leaks set -e" "opts=$-" ;; *) t_ok "sourcing does not leak set -e" ;; esac

# ---- Task 11: handoff ordering ----
CALLS="$TMP/calls"; : > "$CALLS"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_local_session() { printf '%s' "$SDIR/bbb.jsonl"; }
find_remote_pane() { printf 'OK main:1.0'; }
compare_mtimes() { echo preflight >> "$CALLS"; printf '%s' "$STUB_CMP"; }
stop_remote_claude() { echo stop >> "$CALLS"; }
cmd_push() { echo push >> "$CALLS"; }
cmd_repo_pull() { echo repopull >> "$CALLS"; }
cmd_sync_extras() { echo extras >> "$CALLS"; }
restart_remote_claude() { echo restart >> "$CALLS"; }
session_cwd_local() { printf '%s' "$HOME/code/p1"; }
NO_EXTRAS=0; NO_STOP=0; FORCE=0

STUB_CMP="remote-newer"
rc=0; (cmd_handoff bbb) >/dev/null 2>&1 || rc=$?
assert_rc "handoff dies on remote-newer preflight" 1 "$rc"
assert_eq "handoff did NOT stop before preflight refusal" "preflight" "$(tr '\n' ' ' < "$CALLS" | sed 's/ *$//')"

: > "$CALLS"; STUB_CMP="local-newer"
rc=0; (cmd_handoff bbb) >/dev/null 2>&1 || rc=$?
assert_rc "handoff succeeds local-newer" 0 "$rc"
assert_eq "handoff order preflight,stop,push,repopull,extras,restart" \
  "preflight stop push repopull extras restart" "$(tr '\n' ' ' < "$CALLS" | sed 's/ *$//')"

# trap recovery: failure after stop must still attempt restart
: > "$CALLS"; cmd_repo_pull() { echo repopull >> "$CALLS"; return 1; }
rc=0; (cmd_handoff bbb) >/dev/null 2>&1 || rc=$?
assert_rc "handoff propagates failure" 1 "$rc"
assert_match "trap attempted restart after failure" "restart" "$(cat "$CALLS")"
unset -f require_remote find_local_session find_remote_pane compare_mtimes \
  stop_remote_claude cmd_push cmd_repo_pull cmd_sync_extras restart_remote_claude session_cwd_local

# ---- Task 12: doctor ----
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE=""
rc=0; out="$(cmd_doctor 2>&1)" || rc=$?
assert_rc "doctor local-only exits 0 with no remote" 0 "$rc"
assert_match "doctor reports bash" "bash" "$out"
assert_match "doctor notes missing remote" "no remote configured" "$out"

# ---- Task 12 extra: remote FAIL must propagate through the counter (subshell-counter fix) ----
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
remote_sh() { printf 'ok   remote rsync present\nFAIL remote git missing\nok   remote find present\n'; }
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE="stubhost"
rc=0; out="$(cmd_doctor 2>&1)" || rc=$?
assert_rc "doctor exits non-zero when remote reports a FAIL line" 1 "$rc"
assert_match "doctor surfaces the remote FAIL detail" "FAIL remote git missing" "$out"
unset -f require_remote remote_sh
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE=""

# ---- final-review fixes ----

# I2 + M2: handback must preflight (compare_mtimes) BEFORE stopping the
# remote claude, so a refusal (e.g. local-newer) never strands a stopped
# remote writer. Mirrors the handoff ordering test above.
STOPFILE="$TMP/handback_stop_calls"; : > "$STOPFILE"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-p1/bbb.jsonl"; }
find_remote_pane() { printf 'OK main:1.0'; }
compare_mtimes() { printf 'local-newer'; }
stop_remote_claude() { echo "stop $*" >> "$STOPFILE"; }
cmd_pull() { echo "pull should not run" >> "$STOPFILE"; }
PROJECTS="$TMP/projects"; NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; (cmd_handback bbb) >/dev/null 2>&1 || rc=$?
assert_rc "handback dies on local-newer preflight" 1 "$rc"
assert_eq "handback did not stop remote before preflight refusal" "" "$(cat "$STOPFILE")"
unset -f require_remote find_remote_session find_remote_pane compare_mtimes stop_remote_claude cmd_pull

# I3: sync_try must isolate a die-exit (e.g. validate_path inside
# _sync_to/_sync_from) from the caller — without the subshell fix, `die`'s
# `exit` would kill this entire test script, not just the failed step.
FAILED_N=0
f_dies() { die boom; }
sync_try f_dies || true
assert_eq "sync_try isolates a die-exit and still counts it as failed" "1" "$FAILED_N"
unset -f f_dies

# I1: --help must lead with the tool description, not the shellcheck
# pragma block.
out="$(bash "$REPO_DIR/bin/claude-roam" --help)"
first_line="$(printf '%s\n' "$out" | head -1)"
assert_match "help header mentions claude-roam" "claude-roam" "$first_line"
case "$first_line" in
  *shellcheck*) t_fail "help output leaks shellcheck pragma" "first line: $first_line" ;;
  *)            t_ok "help output does not leak shellcheck pragma" ;;
esac

# ---- stranger-test fixes ----

# 1: push reports "already in sync" for a no-op (equal) state, but still
# says "pushed <sid>" for a real transfer (local-newer) — Task 7-style stubs.
# Re-source first: Task 11 overwrote cmd_push with a stub and then
# `unset -f`'d it, which drops the override entirely rather than restoring
# the original — so the real cmd_push must be brought back before reuse.
. "$REPO_DIR/bin/claude-roam"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-p1/aaa.jsonl"; }
remote_sh() { :; }
rsync() { printf '%s\n' "$*" >> "$TMP/rsynclog_stranger"; }
FORCE=0

STUB_CMP="equal"
compare_mtimes() { printf '%s' "$STUB_CMP"; }
out="$(cmd_push aaa 2>&1)"
assert_match "push equal-state reports already in sync" "already in sync" "$out"

STUB_CMP="local-newer"
out="$(cmd_push aaa 2>&1)"
assert_match "push local-newer still reports pushed" "pushed aaa" "$out"

unset -f compare_mtimes rsync remote_sh find_remote_session require_remote

# 2: doctor self-identification — prints which binary is running even with
# no remote configured.
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE=""
out="$(cmd_doctor 2>&1)" || true
assert_match "doctor identifies its own binary" "this claude-roam:" "$out"

# ---- polish wave ----

# sid column: cmd_recent must print the bare sid as its own token, flanked
# by spaces, distinct from the timestamp before it and the path after it.
# PROJECTS was last set to "$TMP/projects" above (Task 9 / final-review
# fixes) — the bbb fixture from Task 8 still lives there.
PROJECTS="$TMP/projects"
out="$(cmd_recent 5)"
assert_match "recent prints sid as its own column" "  bbb  " "$out"

# ---- final-review fixes: data-loss guards ----
# Prior blocks `unset -f` the REAL compare_mtimes/find_remote_session (they
# share names with stubs). Re-source to restore the genuine functions; the
# source guard means this only redefines functions, it never runs main.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
GENC="$PROJECTS/$(encode_path "$HOME")-code-guard"; mkdir -p "$GENC"
printf '0123456789' > "$GENC/gg.jsonl"   # 10 bytes

# H2: a transport failure must NOT read as "remote file missing" (the
# permissive/overwrite branch) — it must surface as remote-unknown.
remote_stat() { return 3; }              # simulate ssh/remote-script failure
assert_eq "compare_mtimes: ssh failure -> remote-unknown" "remote-unknown" "$(compare_mtimes "$GENC/gg.jsonl" /r/f)"
remote_stat() { printf 'MISSING'; }      # ssh ok, file genuinely absent
assert_eq "compare_mtimes: MISSING sentinel -> remote-missing" "remote-missing" "$(compare_mtimes "$GENC/gg.jsonl" /r/f)"
unset -f remote_stat

# H1+H3: the size-shrink guard refuses overwriting a larger dest with a
# smaller src (skew/fork signal), skips when dest size is unknown.
rc=0; ( refuse_if_dest_shrinks 10 20 ) >/dev/null 2>&1 || rc=$?
assert_rc "shrink guard: larger dest -> refuse" 1 "$rc"
rc=0; ( refuse_if_dest_shrinks 20 10 ) >/dev/null 2>&1 || rc=$?
assert_rc "shrink guard: smaller dest -> allow" 0 "$rc"
rc=0; ( refuse_if_dest_shrinks 10 "" ) >/dev/null 2>&1 || rc=$?
assert_rc "shrink guard: unknown dest -> skip" 0 "$rc"

# M4: remote session lookup dies on ambiguity, mirroring the local side.
# (real find_remote_session, restored by the re-source above; stub remote_sh)
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
remote_sh() { printf '%s\n%s\n' "/home/alice/.claude/projects/-home-alice-code-p1/dup.jsonl" "/home/alice/.claude/projects/-home-alice-code-p2/dup.jsonl"; }
rc=0; out="$( (find_remote_session dup) 2>&1 )" || rc=$?
assert_rc "find_remote_session dies on remote ambiguity" 1 "$rc"
assert_match "remote ambiguity lists candidates" "code-p2" "$out"
unset -f remote_sh

# push/pull must refuse (not overwrite) on remote-unknown.
find_local_session() { printf '%s' "$GENC/gg.jsonl"; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-guard/gg.jsonl"; }
remote_sh() { :; }
rsync() { :; }
FORCE=0
compare_mtimes() { printf 'remote-unknown'; }
rc=0; (cmd_push gg) >/dev/null 2>&1 || rc=$?
assert_rc "push refuses remote-unknown" 1 "$rc"
rc=0; (cmd_pull gg) >/dev/null 2>&1 || rc=$?
assert_rc "pull refuses remote-unknown" 1 "$rc"
unset -f compare_mtimes rsync remote_sh find_remote_session find_local_session require_remote

t_summary
