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

# ---- second hardening wave: H1, H3, H7, M2 ----
# Prior block unset -f'd the real find_local_session/compare_mtimes/
# remote_sh/rsync/require_remote it had restored -- re-source to bring back
# the genuine cmd_push/cmd_pull/_sync_from/sid_to_ere before exercising them.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"

# H1 + H3: a real cmd_push must propagate a failing rsync as a nonzero
# return -- NOT let the later unconditional `log "pushed $sid"` (or
# equivalent) make the function return 0. Before the fix, cmd_push being
# invoked as `... || return $?` (as cmd_handoff does) disabled errexit for
# the whole function body, so a stubbed rsync failure (23, matching the
# review's reproduction) was silently followed by a "success" return.
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_local_session() { printf '%s' "$SDIR/bbb.jsonl"; }
compare_mtimes() { printf 'local-newer'; }
remote_sh() { :; }
RSYNC_FAIL_LOG="$TMP/rsync_fail_calls"; : > "$RSYNC_FAIL_LOG"
rsync() { printf '%s\n' "$*" >> "$RSYNC_FAIL_LOG"; return 23; }
rc=0; out="$( (FORCE=1 cmd_push bbb) 2>&1 )" || rc=$?
assert_rc "H1: cmd_push propagates a failing rsync (not swallowed)" 23 "$rc"
case "$out" in
  *"pushed bbb"*) t_fail "H1: cmd_push must not report success after rsync failure" "output: $out" ;;
  *)              t_ok   "H1: cmd_push does not report success after rsync failure" ;;
esac

# H3: the session-file transfer must use -I (--ignore-times) so rsync's own
# size+mtime quick-check can't silently skip an already-adjudicated,
# equal-metadata/different-content transfer.
assert_match "H3: session rsync invocation includes -I" "-aI" "$(cat "$RSYNC_FAIL_LOG")"
unset -f rsync

# H1: a failing remote_sh (the remote `mkdir -p`) inside cmd_push must also
# propagate as nonzero, and rsync must never be reached once it has failed.
RSYNC_UNREACHED_LOG="$TMP/rsync_unreached"; : > "$RSYNC_UNREACHED_LOG"
rsync() { printf '%s\n' "$*" >> "$RSYNC_UNREACHED_LOG"; }
remote_sh() { return 5; }
rc=0; (FORCE=1 cmd_push bbb) >/dev/null 2>&1 || rc=$?
assert_rc "H1: cmd_push propagates a failing remote_sh mkdir" 5 "$rc"
assert_eq "H1: rsync must not run after remote_sh mkdir failure" "" "$(cat "$RSYNC_UNREACHED_LOG")"
unset -f rsync remote_sh compare_mtimes find_local_session require_remote

# H3 (pull side): same -I check for cmd_pull's session-file transfer.
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-p1/bbb.jsonl"; }
compare_mtimes() { printf 'remote-newer'; }
remote_sh() { :; }
RSYNC_PULL_LOG="$TMP/rsync_pull_calls"; : > "$RSYNC_PULL_LOG"
rsync() { printf '%s\n' "$*" >> "$RSYNC_PULL_LOG"; }
rc=0; (FORCE=1 cmd_pull bbb) >/dev/null 2>&1 || rc=$?
assert_rc "H3: forced cmd_pull with cooperative stubs succeeds" 0 "$rc"
assert_match "H3: session pull rsync invocation includes -I" "-aI" "$(cat "$RSYNC_PULL_LOG")"
unset -f rsync remote_sh compare_mtimes find_remote_session require_remote

# H7: dots in a session id are ERE wildcards for `pgrep -f`, and the id is
# attacker/collision-adjacent (any two sessions differing only by a dot vs.
# another char would otherwise cross-match). sid_to_ere must turn '.' into a
# literal-dot bracket expression before it reaches the pgrep pattern that
# find_remote_pane/stop_remote_claude build.
sid="abc.def"
sid_re="$(sid_to_ere "$sid")"
pgrep_pattern="claude --resume[= ]${sid_re}( |\$)"
if printf 'claude --resume abc.def ' | grep -E "$pgrep_pattern" >/dev/null; then
  t_ok "H7: escaped sid pattern still matches the literal dotted sid"
else
  t_fail "H7: escaped sid pattern still matches the literal dotted sid" "no match"
fi
if printf 'claude --resume abcXdef ' | grep -E "$pgrep_pattern" >/dev/null; then
  t_fail "H7: escaped sid pattern must not match a wildcard-substituted sid" "matched abcXdef"
else
  t_ok "H7: escaped sid pattern does not match a wildcard-substituted sid"
fi

# M2: _sync_from must distinguish "ssh/transport failed" (remote_sh itself
# returns nonzero, e.g. ssh exit 255) from "directory genuinely absent"
# (remote_sh succeeds and reports NO) -- the old `remote_sh '[ -d "$1" ]'
# ... || return 0` collapsed both into a silent, successful no-op.
remote_sh() { return 255; }
rc=0; (_sync_from /home/alice/.claude/projects/-home-alice-code-p1/plans "$TMP/m2_transport_fail") >/dev/null 2>&1 || rc=$?
assert_rc "M2: _sync_from propagates an ssh/transport failure" 255 "$rc"
unset -f remote_sh

remote_sh() { printf 'NO'; }
rc=0; (_sync_from /home/alice/.claude/projects/-home-alice-code-p1/plans "$TMP/m2_missing_dir") >/dev/null 2>&1 || rc=$?
assert_rc "M2: _sync_from returns 0 when the remote dir is genuinely absent" 0 "$rc"
unset -f remote_sh

# ---- repo_sync_state / warn_repo_unclean / --require-clean ----
# Prior blocks `unset -f` several of the real functions this section
# relies on (remote_sh, compare_mtimes, find_local_session, require_remote)
# -- re-source first to bring back the genuine implementations before
# layering test-local stubs on top.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"

if ! command -v git >/dev/null 2>&1; then
  t_ok "repo_sync_state/warn_repo_unclean/--require-clean tests skipped (no git on PATH)"
else
  RSDIR="$TMP/reposync"; mkdir -p "$RSDIR"

  # no-dir: path does not exist at all.
  repo_sync_state "$RSDIR/does-not-exist"
  assert_eq "repo_sync_state: missing dir -> no-dir" "no-dir" "$REPO_STATE"

  # not-a-repo: dir exists, no .git.
  mkdir -p "$RSDIR/notrepo"
  repo_sync_state "$RSDIR/notrepo"
  assert_eq "repo_sync_state: plain dir -> not-a-repo" "not-a-repo" "$REPO_STATE"

  # dirty: untracked file, no commits at all yet.
  mkdir -p "$RSDIR/dirtyrepo"
  git -C "$RSDIR/dirtyrepo" init -q >/dev/null 2>&1
  printf 'x' > "$RSDIR/dirtyrepo/f.txt"
  repo_sync_state "$RSDIR/dirtyrepo"
  assert_eq "repo_sync_state: untracked file -> dirty" "dirty" "$REPO_STATE"

  # no-upstream: clean and committed, but the branch has no upstream at all.
  mkdir -p "$RSDIR/noupstream"
  git -C "$RSDIR/noupstream" init -q -b main >/dev/null 2>&1
  printf 'x' > "$RSDIR/noupstream/f.txt"
  git -C "$RSDIR/noupstream" add f.txt >/dev/null 2>&1
  git -C "$RSDIR/noupstream" -c user.name=t -c user.email=t@example.com commit -q -m init >/dev/null 2>&1
  repo_sync_state "$RSDIR/noupstream"
  assert_eq "repo_sync_state: committed, no upstream -> no-upstream" "no-upstream" "$REPO_STATE"

  # clean + unpushed: a bare "remote" plus a clone tracking it.
  BARE="$RSDIR/bare.git"; CLONE="$RSDIR/clone"
  git init -q --bare -b main "$BARE" >/dev/null 2>&1
  git clone -q "$BARE" "$CLONE" >/dev/null 2>&1
  git -C "$CLONE" -c user.name=t -c user.email=t@example.com commit -q -m init --allow-empty >/dev/null 2>&1
  git -C "$CLONE" push -q -u origin main >/dev/null 2>&1
  repo_sync_state "$CLONE"
  assert_eq "repo_sync_state: clean and pushed -> clean" "clean" "$REPO_STATE"

  git -C "$CLONE" -c user.name=t -c user.email=t@example.com commit -q -m second --allow-empty >/dev/null 2>&1
  repo_sync_state "$CLONE"
  assert_eq "repo_sync_state: one local commit not yet pushed -> unpushed" "unpushed" "$REPO_STATE"
  assert_eq "repo_sync_state: REPO_AHEAD_COUNT counts the unpushed commit" "1" "$REPO_AHEAD_COUNT"

  # warn_repo_unclean: dirty repo -> returns 1, warns on stderr naming the label.
  rc=0; (warn_repo_unclean "$RSDIR/dirtyrepo" "dirtylabel") >/dev/null 2>/dev/null || rc=$?
  assert_rc "warn_repo_unclean: dirty repo returns 1" 1 "$rc"
  err="$(warn_repo_unclean "$RSDIR/dirtyrepo" "dirtylabel" 2>&1 1>/dev/null)"
  assert_match "warn_repo_unclean: dirty repo warning names the label" "dirtylabel" "$err"
  assert_match "warn_repo_unclean: dirty repo warning says WARNING" "WARNING" "$err"

  # warn_repo_unclean: non-repo -> returns 0, prints nothing at all.
  rc=0; (warn_repo_unclean "$RSDIR/notrepo" "notrepolabel") >/dev/null 2>/dev/null || rc=$?
  assert_rc "warn_repo_unclean: non-repo returns 0" 0 "$rc"
  out="$(warn_repo_unclean "$RSDIR/notrepo" "notrepolabel" 2>&1)"
  assert_eq "warn_repo_unclean: non-repo prints nothing" "" "$out"

  # push --require-clean: reuse the Task 7 stub pattern (stub every
  # remote-facing call so cmd_push exercises only decision logic), plus
  # stub session_cwd_local directly to point the push at the dirty repo.
  require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
  remote_sh() { :; }
  compare_mtimes() { printf 'local-newer'; }
  find_local_session() { printf '%s' "$SDIR/bbb.jsonl"; }
  session_cwd_local() { printf '%s' "$RSDIR/dirtyrepo"; }
  RSYNC_RC_LOG="$TMP/rsynclog_requireclean"; : > "$RSYNC_RC_LOG"
  rsync() { printf '%s\n' "$*" >> "$RSYNC_RC_LOG"; }
  FORCE=1

  REQUIRE_CLEAN=1
  rc=0; out="$( (cmd_push bbb) 2>&1 )" || rc=$?
  assert_rc "push --require-clean dies when the project repo is dirty" 1 "$rc"
  assert_match "push --require-clean death names what's wrong" "not clean" "$out"
  assert_eq "push --require-clean never reaches rsync" "" "$(cat "$RSYNC_RC_LOG")"

  REQUIRE_CLEAN=0
  : > "$RSYNC_RC_LOG"
  rc=0; out="$( (cmd_push bbb) 2>&1 )" || rc=$?
  assert_rc "push without --require-clean proceeds despite a dirty repo" 0 "$rc"
  assert_match "push without --require-clean still prints the warning" "WARNING" "$out"
  assert_match "push without --require-clean still transfers the jsonl" "bbb.jsonl" "$(cat "$RSYNC_RC_LOG")"

  unset -f require_remote remote_sh compare_mtimes find_local_session session_cwd_local rsync
  REQUIRE_CLEAN=0
fi

# ---- H6 rev2: remote-origin session cwd resolution ----
# Resolve a session's LOCAL project cwd from its JSONL cwd records by matching
# each candidate against the encoded parent dir name (which push/pull already
# translate), instead of blindly trusting the first record. Prior blocks
# `unset -f`'d the real resolver/helpers; re-source to restore them.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
LHP="$(encode_path "$HOME")"

# make a session file: $1 encoded-parent-dir, $2 sid, $3 printf-body (%b)
h6mk() { local d="$PROJECTS/$1"; mkdir -p "$d"; printf '%b' "$3" > "$d/$2.jsonl"; }

# 1. foreign remote-origin cwd -> resolves to the correct LOCAL project dir.
h6mk "$LHP-code-my-app" h6a '{"type":"x","cwd":"/home/alice/code/my-app"}\n'
assert_eq "H6.1 resolves remote-origin cwd to local dir" "$HOME/code/my-app" "$(session_cwd_local h6a)"

# 2. hyphen-ambiguous parent decoded via the candidate's own slashes.
h6mk "$LHP-code-my-app" h6b '{"cwd":"/home/alice/code/my/app"}\n'
assert_eq "H6.2 hyphen-ambiguous parent uses candidate slash placement" "$HOME/code/my/app" "$(session_cwd_local h6b)"

# 3. session_cwd_remote round-trips the resolved cwd back to remote $HOME.
require_remote() { :; }; RHOME="/home/alice"
assert_eq "H6.3 session_cwd_remote round-trips remote-origin" "/home/alice/code/my-app" "$(session_cwd_remote h6a)"
unset -f require_remote

# 4. a single non-colliding mismatched record refuses; a valid later record wins.
h6mk "$LHP-code-my-app" h6d '{"cwd":"/some/other/proj"}\n'
rc=0; (session_cwd_local h6d) >/dev/null 2>&1 || rc=$?
assert_rc "H6.4 lone non-matching cwd record -> refuse" 1 "$rc"
h6mk "$LHP-code-my-app" h6d2 '{"cwd":"/some/other/proj"}\n{"cwd":"/home/alice/code/my-app"}\n'
assert_eq "H6.4 a later matching record is used" "$HOME/code/my-app" "$(session_cwd_local h6d2)"

# 5. two records resolving to DIFFERENT local dirs -> ambiguous refusal.
h6mk "$LHP-code-my-app" h6e '{"cwd":"/home/alice/code/my-app"}\n{"cwd":"/home/alice/code-my/app"}\n'
rc=0; (session_cwd_local h6e) >/dev/null 2>&1 || rc=$?
assert_rc "H6.5 conflicting resolutions -> refuse" 1 "$rc"

# 6. local-origin direct match (candidate already encodes to the parent).
h6mk "$LHP-code-loc" h6f "$(printf '{"cwd":"%s/code/loc"}\n' "$HOME")"
assert_eq "H6.6 local-origin direct match" "$HOME/code/loc" "$(session_cwd_local h6f)"

# 10. single-record local collision: '/' vs literal '-' both encode to '-', so
# code-my/app and code/my-app share a parent. Policy: trust the sole candidate's
# slash placement (documented; NOT a security guarantee).
h6mk "$LHP-code-my-app" h6g "$(printf '{"cwd":"%s/code-my/app"}\n' "$HOME")"
assert_eq "H6.10 sole local colliding candidate is trusted as-is" "$HOME/code-my/app" "$(session_cwd_local h6g)"

# 11. single-record foreign collision: remote-origin path with a literal hyphen
# dir maps preserving its slash placement.
h6mk "$LHP-code-my-app" h6h '{"cwd":"/home/alice/code-my/app"}\n'
assert_eq "H6.11 sole foreign colliding candidate preserves slashes" "$HOME/code-my/app" "$(session_cwd_local h6h)"

# 12. relative cwd is not absolute -> refused (encode_path strips a leading '/'
# so a relative path would otherwise encode like an absolute one).
h6mk "$LHP-code-my-app" h6i '{"cwd":"home/alice/code/my-app"}\n'
rc=0; (session_cwd_local h6i) >/dev/null 2>&1 || rc=$?
assert_rc "H6.12 relative cwd refused" 1 "$rc"

# 13. a cwd whose JSON value embeds a newline escape (valid JSON: "evil\n/...")
# must NOT split into a phantom second candidate. Old `jq -r` emitted two lines
# and the first-record pick returned "evil"; the new extractor drops the whole
# newline-bearing value. The `\\n` below is a literal backslash-n in the file.
h6mk "$LHP-code-my-app" h6j '{"cwd":"evil\\n/home/alice/code/my-app"}\n'
rc=0; out="$( (session_cwd_local h6j) 2>&1 )" || rc=$?
assert_rc "H6.13 newline-in-cwd does not split into a phantom candidate" 1 "$rc"
case "$out" in *evil*) t_fail "H6.13 must not return the pre-newline fragment" "$out" ;; *) t_ok "H6.13 does not return the pre-newline fragment" ;; esac

# 14. non-string cwd is ignored.
h6mk "$LHP-code-my-app" h6k '{"cwd":123}\n'
rc=0; (session_cwd_local h6k) >/dev/null 2>&1 || rc=$?
assert_rc "H6.14 non-string cwd refused" 1 "$rc"

# 15. trailing slash is normalized away.
h6mk "$LHP-code-my-app" h6l "$(printf '{"cwd":"%s/code/my-app/"}\n' "$HOME")"
assert_eq "H6.15 trailing slash normalized" "$HOME/code/my-app" "$(session_cwd_local h6l)"

# 16. dot/dotdot components are refused (they could textually match yet point
# elsewhere).
h6mk "$LHP-code-my-app" h6m "$(printf '{"cwd":"%s/code/../evil"}\n' "$HOME")"
rc=0; (session_cwd_local h6m) >/dev/null 2>&1 || rc=$?
assert_rc "H6.16 dotdot component refused" 1 "$rc"

# 17. a session whose project lives OUTSIDE $HOME resolves via direct match.
h6mk "-tmp-code-app" h6n '{"cwd":"/tmp/code/app"}\n'
assert_eq "H6.17 outside-\$HOME direct match" "/tmp/code/app" "$(session_cwd_local h6n)"

# 18. an outside-$HOME parent must NOT accept a foreign-suffix (home-mapped)
# false match — only direct matches are valid there.
h6mk "-tmp-code-app" h6o '{"cwd":"/foreign/tmp/code/app"}\n'
rc=0; (session_cwd_local h6o) >/dev/null 2>&1 || rc=$?
assert_rc "H6.18 outside-\$HOME foreign false-match refused" 1 "$rc"

# 19 + 20. push calls session_cwd_local for its repo-clean advisory; a
# remote-origin session now resolves to the real local repo (M1 blast radius).
if command -v git >/dev/null 2>&1; then
  WPROJ="$HOME/code/warnproj"; mkdir -p "$WPROJ"
  git -C "$WPROJ" init -q >/dev/null 2>&1
  printf 'x' > "$WPROJ/dirty.txt"            # untracked -> dirty
  h6mk "$LHP-code-warnproj" h6w '{"cwd":"/home/alice/code/warnproj"}\n'
  require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
  remote_sh() { :; }
  compare_mtimes() { printf 'local-newer'; }
  rsync() { printf '%s\n' "$*" >> "$TMP/h6_wrsync"; }
  : > "$TMP/h6_wrsync"; FORCE=1

  REQUIRE_CLEAN=0
  out="$( (cmd_push h6w) 2>&1 )" || true
  assert_match "H6.19 push resolves remote-origin cwd and warns on dirty repo" "WARNING" "$out"

  REQUIRE_CLEAN=1
  rc=0; out="$( (cmd_push h6w) 2>&1 )" || rc=$?
  assert_rc "H6.20 push --require-clean refuses a dirty remote-origin repo" 1 "$rc"
  assert_match "H6.20 refusal names the unclean repo" "not clean" "$out"
  unset -f require_remote remote_sh compare_mtimes rsync
  REQUIRE_CLEAN=0; FORCE=0
else
  t_ok "H6.19/20 push remote-origin cwd tests skipped (no git on PATH)"
fi

# 9. cmd_repo_pull must PROPAGATE a cwd-resolution failure, not no-op to success
# (its rcwd assignment runs inside handoff's errexit-disabling `|| return`).
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
session_cwd_remote() { return 1; }
: > "$TMP/h6_rp"; remote_sh() { echo ran >> "$TMP/h6_rp"; }
rc=0; (cmd_repo_pull h6a) >/dev/null 2>&1 || rc=$?
assert_rc "H6.9 cmd_repo_pull propagates a cwd-resolution failure" 1 "$rc"
assert_eq "H6.9 no remote git runs after resolver failure" "" "$(cat "$TMP/h6_rp")"
unset -f require_remote session_cwd_remote remote_sh

# 21. cmd_sync_extras must likewise propagate a resolver failure.
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
session_cwd_local() { return 1; }
find_local_session() { printf '%s' "$PROJECTS/$LHP-code-my-app/h6a.jsonl"; }
: > "$TMP/h6_se"; _sync_from() { echo "xfer $*" >> "$TMP/h6_se"; }
PROJECT_CLAUDE_EXTRAS=(plans); SESSION_DIR_EXTRAS=(); HOME_RELATIVE_EXTRAS=()
rc=0; (cmd_sync_extras h6a from-remote) >/dev/null 2>&1 || rc=$?
assert_rc "H6.21 cmd_sync_extras propagates a cwd-resolution failure" 1 "$rc"
assert_eq "H6.21 no transfers run after resolver failure" "" "$(cat "$TMP/h6_se")"
unset -f require_remote session_cwd_local find_local_session _sync_from
load_config   # restore extras arrays

# 7. handback must validate the REMOTE source cwd BEFORE stopping the remote:
# an unresolvable remote transcript refuses while claude is still running.
STOPF="$TMP/h6_hb_stop"; : > "$STOPF"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-my-app/h6r.jsonl"; }
find_remote_pane() { printf 'OK main:1.0'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$STOPF"; }
cmd_pull() { echo pull >> "$STOPF"; }
remote_sh() { printf '/home/alice/UNRELATED/place\n'; }   # remote cwd extractor: unresolvable
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; (cmd_handback h6r) >/dev/null 2>&1 || rc=$?
assert_rc "H6.7 handback refuses unresolvable remote cwd" 1 "$rc"
assert_eq "H6.7 handback did NOT stop the remote before the refusal" "" "$(cat "$STOPF")"

# 8. --no-extras skips the cwd preflight and pulls the transcript regardless.
: > "$STOPF"; NO_EXTRAS=1
rc=0; (cmd_handback h6r) >/dev/null 2>&1 || rc=$?
assert_rc "H6.8 handback --no-extras proceeds despite unresolvable cwd" 0 "$rc"
assert_match "H6.8 handback --no-extras still stops and pulls" "stop" "$(cat "$STOPF")"
unset -f require_remote find_remote_session find_remote_pane compare_mtimes stop_remote_claude cmd_pull remote_sh
NO_EXTRAS=0

# 22. handoff: a resolver failure surfacing AFTER the preflight (records mutated
# between reads) must propagate — not degrade into "handoff complete".
CALLS2="$TMP/h6_ho"; : > "$CALLS2"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_local_session() { printf '%s' "$PROJECTS/$LHP-code-my-app/h6a.jsonl"; }
find_remote_pane() { printf 'OK main:1.0'; }
compare_mtimes() { printf 'local-newer'; }
session_cwd_local() { printf '%s' "$HOME/code/my-app"; }   # preflight resolves fine
session_cwd_remote() { return 1; }                          # later read: unresolvable
stop_remote_claude() { echo stop >> "$CALLS2"; }
cmd_push() { echo push >> "$CALLS2"; }
remote_sh() { :; }
restart_remote_claude() { echo restart >> "$CALLS2"; }
NO_EXTRAS=0; NO_STOP=0; FORCE=0
rc=0; (cmd_handoff h6a) >/dev/null 2>&1 || rc=$?
assert_rc "H6.22 handoff propagates a post-preflight resolver failure" 1 "$rc"
assert_match "H6.22 handoff attempted restart after the failure" "restart" "$(cat "$CALLS2")"
unset -f require_remote find_local_session find_remote_pane compare_mtimes \
  session_cwd_local session_cwd_remote stop_remote_claude cmd_push remote_sh restart_remote_claude

t_summary
