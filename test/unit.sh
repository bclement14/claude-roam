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

# union_projects: a trailing project dir WITHOUT .claude must not flip the
# remote discovery exit status (a for-loop's status is its last command's).
# Execute the real remote script through bash, exactly as remote_sh does.
remote_sh() { local script="$1"; shift; printf '%s' "$script" | bash -s -- "$@"; }
mkdir -p "$TMP/rhome/code/aproj/.claude" "$TMP/rhome/code/zzz-no-claude"
rc=0; out="$( ( PROJECT_ROOTS=(code); RHOME="$TMP/rhome"; union_projects ) )" || rc=$?
assert_rc "union_projects: trailing no-.claude dir keeps rc=0" 0 "$rc"
assert_match "union_projects: still lists the remote project" "code/aproj" "$out"
unset -f remote_sh

# union_session_dirs: a FAILING remote find must surface as rc=1 -- in
# `find | while`, the pipeline's exit status is the while-loop's (always 0
# at EOF) and find's stderr is suppressed, so a genuine find failure
# (missing dir, permission, I/O error) would otherwise be silently
# swallowed and the union would degrade to local-only while still
# reporting success. Execute the REAL remote script through bash with a
# fake `find` on a restricted PATH, exactly as remote_sh does.
USDBIN="$TMP/usdbin"; mkdir -p "$USDBIN"
for t in bash basename; do ln -sf "$(command -v "$t")" "$USDBIN/$t"; done
cat > "$USDBIN/find" <<'FEOF'
#!/bin/bash
[ "${FAKE_FIND_RC:-0}" != 0 ] && exit "$FAKE_FIND_RC"
[ -n "${FAKE_FIND_OUT:-}" ] && printf '%s\n' "$FAKE_FIND_OUT"
exit 0
FEOF
chmod +x "$USDBIN/find"
remote_sh() { local s="$1"; shift; printf '%s' "$s" | PATH="$USDBIN" bash -s -- "$@"; }

# find fails (rc 42) -> union_session_dirs returns 1, not a silently
# "successful" local-only union.
export FAKE_FIND_RC=42 FAKE_FIND_OUT=""
rc=0; out="$(union_session_dirs)" || rc=$?
assert_rc "union_session_dirs: remote find failure -> rc=1" 1 "$rc"

# find succeeds with results -> rc=0 and remote-only dirs are translated in.
export FAKE_FIND_RC=0
FAKE_FIND_OUT="/home/alice/.claude/projects/-home-alice-code-p1
/home/alice/.claude/projects/-home-alice-code-usd-remoteonly"
export FAKE_FIND_OUT
rc=0; out="$(union_session_dirs)" || rc=$?
assert_rc "union_session_dirs: find ok -> rc=0" 0 "$rc"
assert_match "union_session_dirs: remote-only dir translated in" "$(encode_path "$HOME")-code-usd-remoteonly" "$out"
assert_match "union_session_dirs: local dir still present" "$(encode_path "$HOME")-code-p1" "$out"

# find succeeds with ZERO results -> still rc=0 (empty remote is normal).
export FAKE_FIND_OUT=""
rc=0; out="$(union_session_dirs)" || rc=$?
assert_rc "union_session_dirs: find ok, zero results -> rc=0" 0 "$rc"
unset FAKE_FIND_RC FAKE_FIND_OUT
unset -f remote_sh

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
find_remote_pane() { printf '%s' 'OK %1'; }
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

# trap recovery: failure after stop must still attempt restart. Recovery now
# goes through the safe re-check+restart op (_recover_remote_op); stub it to
# report "no matching process -> restarted" so the trap's restart is observable.
: > "$CALLS"; cmd_repo_pull() { echo repopull >> "$CALLS"; return 1; }
_recover_remote_op() { echo restart >> "$CALLS"; printf RESTARTED; }
rc=0; (cmd_handoff bbb) >/dev/null 2>&1 || rc=$?
assert_rc "handoff propagates failure" 1 "$rc"
assert_match "trap attempted restart after failure" "restart" "$(cat "$CALLS")"
unset -f require_remote find_local_session find_remote_pane compare_mtimes \
  stop_remote_claude cmd_push cmd_repo_pull cmd_sync_extras restart_remote_claude \
  session_cwd_local _recover_remote_op

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
find_remote_pane() { printf '%s' 'OK %1'; }
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
find_remote_pane() { printf '%s' 'OK %1'; }
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
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'local-newer'; }
session_cwd_local() { printf '%s' "$HOME/code/my-app"; }   # preflight resolves fine
session_cwd_remote() { return 1; }                          # later read: unresolvable
stop_remote_claude() { echo stop >> "$CALLS2"; }
cmd_push() { echo push >> "$CALLS2"; }
remote_sh() { :; }
# Recovery now flows through the safe re-check+restart op; stub it to report a
# clean restart so the trap's recovery action stays observable.
_recover_remote_op() { echo restart >> "$CALLS2"; printf RESTARTED; }
NO_EXTRAS=0; NO_STOP=0; FORCE=0
rc=0; (cmd_handoff h6a) >/dev/null 2>&1 || rc=$?
assert_rc "H6.22 handoff propagates a post-preflight resolver failure" 1 "$rc"
assert_match "H6.22 handoff attempted restart after the failure" "restart" "$(cat "$CALLS2")"
unset -f require_remote find_local_session find_remote_pane compare_mtimes \
  session_cwd_local session_cwd_remote stop_remote_claude cmd_push remote_sh _recover_remote_op

# ---- H6 audit fixes: D1 (jq/python3 required for cwd extraction), ----
# ---- D2 (validate transfer paths BEFORE the remote stop),          ----
# ---- D3 (reject outside-$HOME handback cwd before the stop)        ----
# Prior blocks unset -f'd real functions; re-source to restore the genuine
# implementations before layering test-local stubs on top.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
LHP="$(encode_path "$HOME")"

# -- D1: the cwd extractor must be a real JSON parser. A torn record (raw
# -- physical newline inside a JSON string) must refuse under jq and python3,
# -- and with NEITHER parser on PATH resolution must die with an install hint
# -- instead of grep-scanning line fragments into a phantom (wrong-directory)
# -- cwd. The torn fixture's second physical line looks like a cwd for
# -- code-my/app, which direct-encodes to this parent via the '/'<->'-'
# -- collision -- the legitimate project for the parent is code/my-app.
D1DIR="$PROJECTS/$LHP-code-my-app"; mkdir -p "$D1DIR"
printf '{"cwd":"evil\n"cwd":"%s/code-my/app"}\n' "$HOME" > "$D1DIR/d1torn.jsonl"
printf '{"cwd":"%s/code/my-app"}\n' "$HOME" > "$D1DIR/d1ctl.jsonl"

# Restricted-PATH mode dirs: symlink ONLY the binaries the resolution path
# needs (sed is included so the OLD grep|sed fallback is genuinely runnable
# in no-parser mode -- proving the fix removed it, not that sed was missing).
D1BIN="$TMP/d1bins"
d1_mode_dir() { # $1 = mode name, $2.. = parser binaries to include
  local d="$D1BIN/$1" t; shift
  mkdir -p "$d"
  for t in bash cat find grep sed tr dirname basename "$@"; do
    ln -sf "$(command -v "$t")" "$d/$t"
  done
  printf '%s' "$d"
}
d1_run() { # $1 = mode dir, $2 = sid: session_cwd_local under a clean env
  env -i HOME="$HOME" PATH="$1" bash -c \
    ". '$REPO_DIR/bin/claude-roam'; PROJECTS='$PROJECTS'; session_cwd_local '$2'" 2>&1
}

if command -v jq >/dev/null 2>&1; then
  D1JQ="$(d1_mode_dir jq jq)"
  rc=0; out="$(d1_run "$D1JQ" d1ctl)" || rc=$?
  assert_rc "D1 jq mode resolves the well-formed control" 0 "$rc"
  assert_eq "D1 jq mode control resolves to the real project" "$HOME/code/my-app" "$out"
  rc=0; out="$(d1_run "$D1JQ" d1torn)" || rc=$?
  assert_rc "D1 jq mode refuses the torn record" 1 "$rc"
  case "$out" in *code-my/app*) t_fail "D1 jq mode must not emit the phantom cwd" "$out" ;; *) t_ok "D1 jq mode does not emit the phantom cwd" ;; esac
else
  t_ok "D1 jq-mode tests skipped (no jq on PATH)"
fi

if command -v python3 >/dev/null 2>&1; then
  D1PY="$(d1_mode_dir py python3)"
  rc=0; out="$(d1_run "$D1PY" d1ctl)" || rc=$?
  assert_rc "D1 python3 mode resolves the well-formed control" 0 "$rc"
  assert_eq "D1 python3 mode control resolves to the real project" "$HOME/code/my-app" "$out"
  rc=0; out="$(d1_run "$D1PY" d1torn)" || rc=$?
  assert_rc "D1 python3 mode refuses the torn record" 1 "$rc"
  case "$out" in *code-my/app*) t_fail "D1 python3 mode must not emit the phantom cwd" "$out" ;; *) t_ok "D1 python3 mode does not emit the phantom cwd" ;; esac
else
  t_ok "D1 python3-mode tests skipped (no python3 on PATH)"
fi

D1NONE="$(d1_mode_dir none)"
rc=0; out="$(d1_run "$D1NONE" d1ctl)" || rc=$?
assert_rc "D1 no-parser mode dies instead of resolving (control)" 1 "$rc"
assert_match "D1 no-parser death carries the install hint" "requires jq or python3" "$out"
rc=0; out="$(d1_run "$D1NONE" d1torn)" || rc=$?
assert_rc "D1 no-parser mode dies instead of resolving (torn)" 1 "$rc"
case "$out" in *code-my/app*) t_fail "D1 no-parser mode must not emit the phantom cwd" "$out" ;; *) t_ok "D1 no-parser mode does not emit the phantom cwd" ;; esac

# D1 remote side: a remote extractor exiting 3 (no jq/python3 THERE) must
# surface handback's own actionable hint, still before the stop.
HB3STOP="$TMP/hb3_stop"; : > "$HB3STOP"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-my-app/hb3.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$HB3STOP"; }
cmd_pull() { echo pull >> "$HB3STOP"; }
remote_sh() { return 3; }
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; out="$( (cmd_handback hb3) 2>&1 )" || rc=$?
assert_rc "D1 handback dies when the remote lacks jq/python3" 1 "$rc"
assert_match "D1 remote-parser death carries the install hint" "jq or python3 on the remote" "$out"
assert_eq "D1 remote-parser death happens before the stop" "" "$(cat "$HB3STOP")"
unset -f require_remote find_remote_session find_remote_pane compare_mtimes stop_remote_claude cmd_pull remote_sh

# -- D2: a space-containing transfer path must refuse BEFORE the remote stop,
# -- in BOTH handback and handoff (the encoded project dir keeps every char
# -- of the cwd except '/', so a space in the cwd puts a space in the path
# -- rsync would receive -- previously only caught inside cmd_pull/cmd_push,
# -- AFTER stop_remote_claude).
D2STOP="$TMP/d2hb_stop"; : > "$D2STOP"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-my app/d2s.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$D2STOP"; }
cmd_pull() { echo pull >> "$D2STOP"; }
NO_STOP=0; NO_EXTRAS=1; FORCE=0
rc=0; out="$( (cmd_handback d2s) 2>&1 )" || rc=$?
assert_rc "D2 handback refuses a space-containing remote path" 1 "$rc"
assert_match "D2 handback refusal says the remote was not stopped" "NOT stopped" "$out"
assert_eq "D2 handback neither stopped nor pulled after the refusal" "" "$(cat "$D2STOP")"
unset -f require_remote find_remote_session find_remote_pane compare_mtimes stop_remote_claude cmd_pull
NO_EXTRAS=0

D2HOSTOP="$TMP/d2ho_stop"; : > "$D2HOSTOP"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_local_session() { printf '%s' "$PROJECTS/$LHP-code-my app/d2h.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'local-newer'; }
session_cwd_local() { printf '%s/code/my app' "$HOME"; }
stop_remote_claude() { echo stop >> "$D2HOSTOP"; }
cmd_push() { echo push >> "$D2HOSTOP"; }
cmd_repo_pull() { :; }
cmd_sync_extras() { :; }
restart_remote_claude() { :; }
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; out="$( (cmd_handoff d2h) 2>&1 )" || rc=$?
assert_rc "D2 handoff refuses a space-containing remote path" 1 "$rc"
assert_match "D2 handoff refusal says the remote was not stopped" "NOT stopped" "$out"
assert_eq "D2 handoff neither stopped nor pushed after the refusal" "" "$(cat "$D2HOSTOP")"
unset -f require_remote find_local_session find_remote_pane compare_mtimes \
  session_cwd_local stop_remote_claude cmd_push cmd_repo_pull cmd_sync_extras restart_remote_claude

# D2 belt-and-suspenders: a die INSIDE the post-pull extras step must not
# skip the local resume hint -- the transcript is already safely local.
HINTLOG="$TMP/d2hint_calls"; : > "$HINTLOG"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-my-app/hbe.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$HINTLOG"; }
cmd_pull() { echo pull >> "$HINTLOG"; }
remote_sh() { printf '/home/alice/code/my-app\n'; }
cmd_sync_extras() { die "extras exploded"; }
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; out="$( (cmd_handback hbe) 2>&1 )" || rc=$?
assert_rc "D2 handback propagates an extras die as nonzero" 1 "$rc"
assert_match "D2 resume hint still prints when extras die" "to resume locally" "$out"
assert_match "D2 extras-failure warning still prints" "WARNING" "$out"
assert_match "D2 pull completed before the extras failure" "pull" "$(cat "$HINTLOG")"
unset -f require_remote find_remote_session find_remote_pane compare_mtimes \
  stop_remote_claude cmd_pull remote_sh cmd_sync_extras

# -- D3: the '/'<->'-' collision lets an outside-$HOME candidate direct-encode
# -- to an under-home parent; the resolver accepts it (documented mechanism)...
rc=0; out="$(_resolve_cwd_candidate "/Users-alice/code/app" "-Users-alice-code-app" "-Users-alice")" || rc=$?
assert_rc "D3 resolver accepts the collision candidate (mechanism)" 0 "$rc"
assert_eq "D3 resolver returns the collision candidate as-is" "/Users-alice/code/app" "$out"

# ...so handback's preflight must refuse the resolved outside-$HOME cwd
# BEFORE the stop (previously: empty hb_rcwd, stop, pull, extras failure).
# The stub emits "$HOME-code/app", which direct-encodes to the translated
# parent "$LHP-code-app" yet is a sibling of $HOME, not under it.
D3STOP="$TMP/d3_stop"; : > "$D3STOP"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-app/d3s.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$D3STOP"; }
cmd_pull() { echo pull >> "$D3STOP"; }
remote_sh() { printf '%s-code/app\n' "$HOME"; }
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; out="$( (cmd_handback d3s) 2>&1 )" || rc=$?
assert_rc "D3 handback refuses an outside-\$HOME resolved cwd" 1 "$rc"
assert_match "D3 refusal names the outside-home problem" "outside" "$out"
assert_match "D3 refusal says the remote was not stopped" "NOT stopped" "$out"
assert_eq "D3 handback neither stopped nor pulled after the refusal" "" "$(cat "$D3STOP")"
unset -f require_remote find_remote_session find_remote_pane compare_mtimes \
  stop_remote_claude cmd_pull remote_sh

# ---- backup before --force overwrite ----
# A --force overwrite is the tool's only destructive operation. Before it
# replaces an EXISTING destination file, the losing copy must be stashed to
# ~/.claude/roam-backups/<sid>.<UTC-timestamp>.jsonl on the machine that
# holds it (local for pull, remote for push), and stashes older than 30
# days pruned. No stash on a normal transfer or when the destination is
# missing (nothing to lose). Prior blocks unset -f'd real functions;
# re-source first. HOME is the harness's temp dir, so the real
# ~/.claude/roam-backups is never touched.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
LHP="$(encode_path "$HOME")"
BKD="$HOME/.claude/roam-backups"
BKP1="$PROJECTS/$LHP-code-p1"; mkdir -p "$BKP1"

require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
BKRSYNC="$TMP/bk_rsync"; : > "$BKRSYNC"
rsync() { printf '%s\n' "$*" >> "$BKRSYNC"; }
# cmd_pull's liveness check (M5) stats the remote source around the transfer;
# stub remote_stat so these pulls stay hermetic (no real ssh to host "stub").
# MISSING means "nothing to compare", so the liveness warning is skipped.
remote_stat() { printf 'MISSING'; }

# -- 1. pull --force over an existing local dest: stash the OLD bytes into a
# -- timestamped file under roam-backups, prune stale stashes, still rsync.
printf 'OLD-LOCAL-BYTES' > "$BKP1/bk1.jsonl"
rm -rf "$BKD"; mkdir -p "$BKD"
printf 'stale' > "$BKD/stale.jsonl"
bk_stale_ts="$(date -v-40d +%Y%m%d%H%M 2>/dev/null || date -d '40 days ago' +%Y%m%d%H%M)"
touch -t "$bk_stale_ts" "$BKD/stale.jsonl"
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-p1/bk1.jsonl"; }
compare_mtimes() { printf 'remote-newer'; }
FORCE=1
rc=0; out="$( (cmd_pull bk1) 2>&1 )" || rc=$?
assert_rc "backup: forced pull over existing local dest succeeds" 0 "$rc"
assert_match "backup: forced pull reports the local stash" "backed up prior local copy" "$out"
bk_file=""
for f in "$BKD"/bk1.*.jsonl; do if [ -f "$f" ]; then bk_file="$f"; fi; done
if [ -n "$bk_file" ]; then
  t_ok "backup: stash file created under roam-backups"
else
  t_fail "backup: stash file created under roam-backups" "no bk1.*.jsonl in $BKD"
fi
case "${bk_file##*/}" in
  bk1.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z.jsonl)
    t_ok "backup: stash name is sid + UTC timestamp" ;;
  *) t_fail "backup: stash name is sid + UTC timestamp" "got: [${bk_file##*/}]" ;;
esac
assert_eq "backup: stash preserves the OLD bytes" "OLD-LOCAL-BYTES" "$(cat "$bk_file" 2>/dev/null)"
assert_match "backup: the pull rsync still ran" "bk1.jsonl" "$(cat "$BKRSYNC")"
if [ -f "$BKD/stale.jsonl" ]; then
  t_fail "backup: stash older than 30 days is pruned" "stale.jsonl survived"
else
  t_ok "backup: stash older than 30 days is pruned"
fi

# -- 2. pull WITHOUT --force: no stash is created (guard on FORCE).
FORCE=0
rm -rf "$BKD"; : > "$BKRSYNC"
_remote_size_or_empty() { printf ''; }   # shrink guard runs when FORCE=0
rc=0; (cmd_pull bk1) >/dev/null 2>&1 || rc=$?
assert_rc "backup: non-force pull still succeeds" 0 "$rc"
if [ -d "$BKD" ]; then
  t_fail "backup: non-force pull creates no stash" "roam-backups appeared: $(ls "$BKD" 2>/dev/null)"
else
  t_ok "backup: non-force pull creates no stash"
fi
unset -f _remote_size_or_empty

# -- 3. pull --force with NO existing local dest: nothing to lose, no stash
# -- attempted, no error, transfer still runs.
FORCE=1
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-p1/bk3.jsonl"; }
compare_mtimes() { printf 'local-missing'; }
rm -rf "$BKD"; : > "$BKRSYNC"
rc=0; out="$( (cmd_pull bk3) 2>&1 )" || rc=$?
assert_rc "backup: forced pull with no local dest succeeds" 0 "$rc"
case "$out" in
  *"backed up"*) t_fail "backup: local-missing pull attempts no stash" "output: $out" ;;
  *)             t_ok   "backup: local-missing pull attempts no stash" ;;
esac
if [ -d "$BKD" ]; then
  t_fail "backup: local-missing pull creates no stash dir" "roam-backups appeared"
else
  t_ok "backup: local-missing pull creates no stash dir"
fi
assert_match "backup: local-missing pull still rsyncs" "bk3.jsonl" "$(cat "$BKRSYNC")"

# -- 4. push --force over an existing remote dest: the backup command goes to
# -- the remote (mkdir + cp with a timestamped path, as quoted argv), push
# -- proceeds.
printf '{"type":"x"}\n' > "$BKP1/bk4.jsonl"
compare_mtimes() { printf 'remote-newer'; }
BKPLOG="$TMP/bk_push_remote"; : > "$BKPLOG"
remote_sh() { { printf 'CALL:'; printf ' [%s]' "$@"; printf '\n'; } >> "$BKPLOG"; }
: > "$BKRSYNC"
FORCE=1
rc=0; out="$( (cmd_push bk4) 2>&1 )" || rc=$?
assert_rc "backup: forced push over existing remote dest succeeds" 0 "$rc"
assert_match "backup: forced push reports the remote stash" "backed up prior remote copy" "$out"
assert_match "backup: remote backup targets the remote roam-backups dir" "/home/alice/.claude/roam-backups" "$(cat "$BKPLOG")"
assert_match "backup: remote backup script copies the old file" "cp " "$(cat "$BKPLOG")"
if grep -E 'bk4\.[0-9]{8}T[0-9]{6}Z\.jsonl' "$BKPLOG" >/dev/null; then
  t_ok "backup: remote stash path is sid + UTC timestamp"
else
  t_fail "backup: remote stash path is sid + UTC timestamp" "no timestamped bk4 arg in remote_sh log"
fi
assert_match "backup: the push rsync still ran" "bk4.jsonl" "$(cat "$BKRSYNC")"

# -- 5. push --force with the remote dest missing: no backup command issued
# -- (the mkdir-for-transfer call still runs; it must not mention backups).
compare_mtimes() { printf 'remote-missing'; }
: > "$BKPLOG"; : > "$BKRSYNC"
rc=0; out="$( (cmd_push bk4) 2>&1 )" || rc=$?
assert_rc "backup: forced push with remote dest missing succeeds" 0 "$rc"
case "$(cat "$BKPLOG")" in
  *roam-backups*) t_fail "backup: remote-missing push issues no backup command" "remote_sh log: $(cat "$BKPLOG")" ;;
  *)              t_ok   "backup: remote-missing push issues no backup command" ;;
esac
assert_match "backup: remote-missing push still rsyncs" "bk4.jsonl" "$(cat "$BKRSYNC")"
unset -f require_remote find_remote_session compare_mtimes rsync remote_sh remote_stat
FORCE=0

# ---- M5 + M6a: pull-side liveness warning + doctor handoff-tool checks ----
# The prior block unset -f'd the real find_remote_session/compare_mtimes/
# remote_sh/rsync/require_remote -- re-source to restore the genuine
# cmd_pull/cmd_doctor/remote_stat before layering test-local stubs on top.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"

# -- M5: cmd_pull snapshots the REMOTE source's mtime+size around the rsync
# -- (mirroring cmd_push's local pre/post snapshot) and WARNS -- without
# -- failing -- when the remote file changed mid-transfer: a Claude is likely
# -- still writing it there, so the pulled copy may be a torn snapshot.
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-p1/m5a.jsonl"; }
compare_mtimes() { printf 'remote-newer'; }
remote_sh() { :; }
rsync() { :; }
# Keep the shrink guard from consuming a remote_stat call of its own, so the
# stubs below see exactly the two liveness snapshots (pre + post).
_remote_size_or_empty() { printf ''; }
FORCE=0
M5_STAT_CALLS="$TMP/m5_stat_calls"

# 1. source mutated mid-transfer: 2nd stat differs -> WARN, still exit 0.
: > "$M5_STAT_CALLS"
remote_stat() {
  echo x >> "$M5_STAT_CALLS"
  if [ "$(grep -c x "$M5_STAT_CALLS")" -ge 2 ]; then printf '200 9999'; else printf '100 5555'; fi
}
rc=0; out="$( (cmd_pull m5a) 2>&1 )" || rc=$?
assert_rc "M5: pull with a mutating remote source still succeeds" 0 "$rc"
assert_match "M5: pull warns when the remote source changed during transfer" "changed during transfer" "$out"
assert_match "M5: the liveness warning is advisory (WARNING, not error)" "WARNING" "$out"

# 2. stable source: identical stats -> no warning, exactly pre+post calls.
: > "$M5_STAT_CALLS"
remote_stat() { echo x >> "$M5_STAT_CALLS"; printf '100 5555'; }
rc=0; out="$( (cmd_pull m5a) 2>&1 )" || rc=$?
assert_rc "M5: pull with a stable remote source succeeds" 0 "$rc"
case "$out" in
  *"changed during transfer"*) t_fail "M5: no warning when the remote source is stable" "output: $out" ;;
  *)                           t_ok   "M5: no warning when the remote source is stable" ;;
esac
assert_eq "M5: pull stats the remote source before and after (2 calls)" "2" "$(grep -c x "$M5_STAT_CALLS")"

# 3. transport-degraded stats must not false-alarm: remote_stat erroring out
# (nonzero, per its contract) skips the check and never fails the pull.
remote_stat() { return 7; }
rc=0; out="$( (cmd_pull m5a) 2>&1 )" || rc=$?
assert_rc "M5: pull succeeds when the liveness stats error out" 0 "$rc"
case "$out" in
  *"changed during transfer"*) t_fail "M5: no warning when the liveness stats error out" "output: $out" ;;
  *)                           t_ok   "M5: no warning when the liveness stats error out" ;;
esac

# 4. a MISSING sentinel on either side is "nothing to compare", not a change
# (even though the two snapshots differ textually).
: > "$M5_STAT_CALLS"
remote_stat() {
  echo x >> "$M5_STAT_CALLS"
  if [ "$(grep -c x "$M5_STAT_CALLS")" -ge 2 ]; then printf '100 5555'; else printf 'MISSING'; fi
}
rc=0; out="$( (cmd_pull m5a) 2>&1 )" || rc=$?
assert_rc "M5: pull succeeds when a liveness stat reports MISSING" 0 "$rc"
case "$out" in
  *"changed during transfer"*) t_fail "M5: MISSING snapshot does not trigger the warning" "output: $out" ;;
  *)                           t_ok   "M5: MISSING snapshot does not trigger the warning" ;;
esac
unset -f remote_stat _remote_size_or_empty rsync remote_sh compare_mtimes find_remote_session require_remote

# -- M6a: doctor's remote section checks the tools handoff needs -- pgrep/ps/
# -- awk for pane discovery and the claude binary for restart -- as WARNs
# -- (advisory: they only affect handoff/handback, never push/pull/sync).
# Same stubbing approach as the Task 12 doctor tests: stub remote_sh output.
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE="stubhost"

# 1. the remote script doctor ships must actually probe the handoff tools.
M6_SCRIPT="$TMP/m6_script"; : > "$M6_SCRIPT"
remote_sh() { printf '%s' "$1" > "$M6_SCRIPT"; }
rc=0; (cmd_doctor) >/dev/null 2>&1 || rc=$?
assert_rc "M6a: doctor exits 0 with an empty remote report" 0 "$rc"
assert_match "M6a: doctor's remote script probes pgrep/ps/awk" "pgrep ps awk" "$(cat "$M6_SCRIPT")"
assert_match "M6a: doctor's remote script probes the claude binary" "command -v claude" "$(cat "$M6_SCRIPT")"

# 2. a remote missing the handoff tools warns but must NOT fail doctor
# (warn lines must not increment the FAIL counter the local side parses).
remote_sh() { printf '%s\n' \
  'ok   remote rsync present' \
  'warn remote pgrep missing — handoff cannot locate/stop the remote session without it' \
  'warn remote claude missing — handoff cannot restart the session on the remote without it'; }
rc=0; out="$(cmd_doctor 2>&1)" || rc=$?
assert_rc "M6a: doctor exits 0 when remote handoff tools are only warned" 0 "$rc"
assert_match "M6a: doctor surfaces the pgrep warn line" "warn remote pgrep missing" "$out"
assert_match "M6a: doctor surfaces the claude warn line" "warn remote claude missing" "$out"
assert_match "M6a: doctor still reports overall success despite the warns" "all checks passed" "$out"

# 3. all remote handoff tools present -> no handoff warns in the report.
remote_sh() { printf '%s\n' \
  'ok   remote pgrep present' \
  'ok   remote ps present' \
  'ok   remote awk present' \
  'ok   remote claude present'; }
rc=0; out="$(cmd_doctor 2>&1)" || rc=$?
assert_rc "M6a: doctor exits 0 when remote handoff tools are present" 0 "$rc"
case "$out" in
  *"warn remote pgrep missing"*|*"warn remote claude missing"*)
    t_fail "M6a: no handoff warns when the remote tools are present" "output: $out" ;;
  *) t_ok "M6a: no handoff warns when the remote tools are present" ;;
esac
unset -f remote_sh require_remote
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE=""

# ---- doctor: remote claude probed on the LOGIN-shell PATH ----
# The tmux-pane restart ("claude --resume" typed into the pane) resolves
# claude via the user's LOGIN/INTERACTIVE shell, whose PATH includes user
# toolchains (mise, ~/.local/bin). The bare non-interactive ssh PATH does
# NOT -- probing it false-alarmed "remote claude missing" on working setups.
# Re-source to restore the genuine cmd_doctor/remote_sh after the unset -f
# above, then stub remote_sh (same approach as the Task 12/M6a doctor tests).
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE="stubhost"

# 1. script-content: the claude probe must run through a login+interactive
# shell (bash -lic) with stdin closed so the interactive shell cannot hang.
DRC_SCRIPT="$TMP/drc_script"; : > "$DRC_SCRIPT"
remote_sh() { printf '%s' "$1" > "$DRC_SCRIPT"; }
rc=0; (cmd_doctor) >/dev/null 2>&1 || rc=$?
assert_rc "doctor claude probe: doctor exits 0 with an empty remote report" 0 "$rc"
assert_match "doctor claude probe: runs via a login+interactive shell" 'bash -lic "command -v claude' "$(cat "$DRC_SCRIPT")"
assert_match "doctor claude probe: closes stdin so bash -i cannot hang" '</dev/null' "$(cat "$DRC_SCRIPT")"

# 2. claude absent from the login-shell PATH -> WARN only: doctor must
# still exit 0 (warn lines never increment DOCTOR_FAILS) and surface it.
remote_sh() { printf '%s\n' \
  'ok   remote rsync present' \
  'warn remote claude not found on the login-shell PATH — handoff restarts the session by typing claude --resume into the tmux pane, so claude must be on your interactive shell PATH (e.g. mise or ~/.local/bin)'; }
rc=0; out="$(cmd_doctor 2>&1)" || rc=$?
assert_rc "doctor claude probe: login-PATH warn does not fail doctor" 0 "$rc"
assert_match "doctor claude probe: surfaces the login-PATH warn" "warn remote claude not found on the login-shell PATH" "$out"
assert_match "doctor claude probe: warn points at the interactive-shell PATH fix" "interactive shell PATH" "$out"
assert_match "doctor claude probe: doctor still reports overall success" "all checks passed" "$out"

# 3. claude present on the login-shell PATH -> ok line, no warn.
remote_sh() { printf '%s\n' \
  'ok   remote claude present (on the login-shell PATH)'; }
rc=0; out="$(cmd_doctor 2>&1)" || rc=$?
assert_rc "doctor claude probe: exits 0 when claude is on the login-shell PATH" 0 "$rc"
assert_match "doctor claude probe: surfaces the login-shell ok line" "ok   remote claude present (on the login-shell PATH)" "$out"
case "$out" in
  *"not found on the login-shell PATH"*)
    t_fail "doctor claude probe: no warn when claude is on the login-shell PATH" "output: $out" ;;
  *) t_ok "doctor claude probe: no warn when claude is on the login-shell PATH" ;;
esac
unset -f remote_sh require_remote
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE=""
# ============================================================================
# H5/M6b commit 1: fail-closed find_remote_pane protocol + caller refusals
# ============================================================================
# Prior blocks unset -f'd real functions; re-source to restore the genuine
# implementations before layering the protocol harness on top.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
SDIR="$PROJECTS/$(encode_path "$HOME")-code-p1"

# -- Fake remote tools, driven by env vars. The REAL find_remote_pane script is
# -- run locally by pointing a remote_sh stub at `bash -s` under a restricted
# -- PATH containing ONLY these fakes plus the coreutils the script needs. This
# -- exercises the ACTUAL protocol logic (tool detection, pgrep rc distinction,
# -- ancestry walk, stable pane-id dedup), not a re-implementation of it.
PANEBIN_BASE="$TMP/panebins"; mkdir -p "$PANEBIN_BASE"
cat > "$TMP/fake_pgrep" <<'FEOF'
#!/bin/bash
[ -n "${FAKE_PGREP_OUT:-}" ] && printf '%s\n' $FAKE_PGREP_OUT
exit "${FAKE_PGREP_RC:-0}"
FEOF
cat > "$TMP/fake_ps" <<'FEOF'
#!/bin/bash
[ "${FAKE_PS_RC:-0}" != 0 ] && exit "$FAKE_PS_RC"
pid=""
while [ $# -gt 0 ]; do case "$1" in -p) pid="$2"; shift 2 ;; *) shift ;; esac; done
eval "v=\${FAKE_PPID_$pid:-}"
[ -n "$v" ] && printf '   %s\n' "$v"
exit 0
FEOF
cat > "$TMP/fake_tmux" <<'FEOF'
#!/bin/bash
case "${1:-}" in
  list-panes) [ "${FAKE_TMUX_RC:-0}" != 0 ] && exit "$FAKE_TMUX_RC"
              printf '%s\n' "${FAKE_PANES:-}"; exit 0 ;;
  send-keys)  exit "${FAKE_SEND_RC:-0}" ;;
  display-message) printf '%s\n' "${FAKE_SESSION:-}"; exit 0 ;;
  *) exit 0 ;;
esac
FEOF
mk_panebin() {  # $1 = mode name ; remaining = fake tool basenames to install
  local d="$PANEBIN_BASE/$1" t; shift
  rm -rf "$d"; mkdir -p "$d"
  for t in bash tr grep; do ln -sf "$(command -v "$t")" "$d/$t"; done
  for t in "$@"; do cp "$TMP/fake_$t" "$d/$t"; chmod +x "$d/$t"; done
  printf '%s' "$d"
}
export REMOTE=stub
# remote_sh stub: pipe the payload into bash -s under the restricted PATH.
remote_sh() { local s="$1"; shift; printf '%s' "$s" | PATH="$PANEBIN" bash -s -- "$@"; }

# missing pgrep (the gateway tool) -> NOTOOLS, never NOPANE (M6b core fix)
PANEBIN="$(mk_panebin notools_pgrep ps tmux)"
assert_eq "protocol: missing pgrep -> NOTOOLS pgrep" "NOTOOLS pgrep" "$(find_remote_pane s1)"

# pgrep present but the process is gone (rc 1) -> NOPANE
PANEBIN="$(mk_panebin present pgrep ps tmux)"
export FAKE_PGREP_RC=1 FAKE_PGREP_OUT=""
assert_eq "protocol: pgrep rc1 -> NOPANE" "NOPANE" "$(find_remote_pane s1)"

# pgrep present but ERRORS (rc>1) -> ERROR, never NOPANE (H3)
export FAKE_PGREP_RC=2
assert_eq "protocol: pgrep rc2 -> ERROR pgrep 2" "ERROR pgrep 2" "$(find_remote_pane s1)"
unset FAKE_PGREP_RC

# wrapper + child PIDs resolving to the SAME pane id dedup to one OK (H2)
export FAKE_PGREP_RC=0 FAKE_PGREP_OUT="1000 1001"
export FAKE_PPID_1000=900 FAKE_PPID_1001=900 FAKE_PPID_900=1
export FAKE_PANES="900 %3"
assert_eq "protocol: wrapper+child on one pane -> OK %3 (dedup)" "OK %3" "$(find_remote_pane s1)"

# identity is the pane id, so an arbitrary/space-containing session name is
# irrelevant: the same pid on a differently-named session still maps to its %id
export FAKE_PANES="900 %7"
assert_eq "protocol: pane id parsed regardless of session naming" "OK %7" "$(find_remote_pane s1)"

# two DISTINCT panes -> AMBIGUOUS (never a false OK) (H2/FM3)
export FAKE_PGREP_OUT="1000 2000"
export FAKE_PPID_1000=900 FAKE_PPID_2000=800 FAKE_PPID_800=1
export FAKE_PANES=$'900 %3\n800 %4'
assert_eq "protocol: two panes -> AMBIGUOUS %3 %4" "AMBIGUOUS %3 %4" "$(find_remote_pane s1)"

# a match whose ancestry never reaches a tmux pane -> NOTMUX
export FAKE_PGREP_OUT="1000"
export FAKE_PPID_1000=900 FAKE_PPID_900=1
export FAKE_PANES="700 %9"
assert_eq "protocol: match outside tmux -> NOTMUX" "NOTMUX" "$(find_remote_pane s1)"

# tmux missing once a match exists -> NOTOOLS tmux (H3/M6b)
PANEBIN="$(mk_panebin notools_tmux pgrep ps)"
assert_eq "protocol: match but no tmux -> NOTOOLS tmux" "NOTOOLS tmux" "$(find_remote_pane s1)"

# tmux present but list-panes fails at runtime -> ERROR tmux (H3)
PANEBIN="$(mk_panebin err_tmux pgrep ps tmux)"
export FAKE_TMUX_RC=3
assert_eq "protocol: tmux list-panes error -> ERROR tmux 3" "ERROR tmux 3" "$(find_remote_pane s1)"
unset FAKE_TMUX_RC FAKE_PGREP_OUT FAKE_PGREP_RC FAKE_PANES
unset -f remote_sh
unset REMOTE

# -- Caller reactions: handoff AND handback must REFUSE before ANY stop on
# -- every ambiguous / unverifiable state (the writer may still be running).
NO_STOP=0; NO_EXTRAS=0; FORCE=0
RSTOP="$TMP/refuse_stop"
STATE=""
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-my-app/refuse.jsonl"; }
find_remote_pane() { printf '%s' "$STATE"; }
stop_remote_claude() { echo stop >> "$RSTOP"; }
for STATE in "AMBIGUOUS %3 %4" "NOTMUX" "NOTOOLS pgrep" "ERROR pgrep 2"; do
  word="${STATE%% *}"
  : > "$RSTOP"
  rc=0; out="$( (cmd_handoff refuse) 2>&1 )" || rc=$?
  assert_rc "handoff refuses $word before stop" 1 "$rc"
  assert_eq "handoff did not stop on $word" "" "$(cat "$RSTOP")"
  assert_match "handoff $word refusal says NOT stopped" "NOT stopped" "$out"
  : > "$RSTOP"
  rc=0; out="$( (cmd_handback refuse) 2>&1 )" || rc=$?
  assert_rc "handback refuses $word before stop" 1 "$rc"
  assert_eq "handback did not stop on $word" "" "$(cat "$RSTOP")"
  assert_match "handback $word refusal says NOT stopped" "NOT stopped" "$out"
done
unset -f require_remote find_remote_session find_remote_pane stop_remote_claude

# -- handoff --no-stop: skips discovery, stop, AND restart; still pushes.
NSCALLS="$TMP/nostop_calls"; : > "$NSCALLS"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_local_session() { printf '%s' "$SDIR/bbb.jsonl"; }
find_remote_pane() { echo pane-lookup >> "$NSCALLS"; printf '%s' 'OK %1'; }
compare_mtimes() { printf 'local-newer'; }
stop_remote_claude() { echo stop >> "$NSCALLS"; }
cmd_push() { echo push >> "$NSCALLS"; }
cmd_repo_pull() { :; }
cmd_sync_extras() { :; }
restart_remote_claude() { echo restart >> "$NSCALLS"; }
session_cwd_local() { printf '%s' "$HOME/code/p1"; }
NO_STOP=1; NO_EXTRAS=0; FORCE=0
rc=0; out="$( (cmd_handoff bbb) 2>&1 )" || rc=$?
assert_rc "handoff --no-stop succeeds" 0 "$rc"
assert_eq "handoff --no-stop skips discovery+stop+restart (push only)" \
  "push" "$(tr '\n' ' ' < "$NSCALLS" | sed 's/ *$//')"
assert_match "handoff --no-stop prints a manual start hint" "claude --resume" "$out"
unset -f require_remote find_local_session find_remote_pane compare_mtimes \
  stop_remote_claude cmd_push cmd_repo_pull cmd_sync_extras restart_remote_claude session_cwd_local
NO_STOP=0

# ============================================================================
# H5 commit 2: arm-before-stop, state-aware recovery, handback pull-window trap
# ============================================================================
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
SDIR="$PROJECTS/$(encode_path "$HOME")-code-p1"
ho_stubs() {  # the shared handoff happy-path stub set
  require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
  find_local_session() { printf '%s' "$SDIR/bbb.jsonl"; }
  find_remote_pane() { printf '%s' 'OK %1'; }
  compare_mtimes() { printf 'local-newer'; }
  cmd_push() { echo push >> "$C2"; }
  cmd_repo_pull() { echo repopull >> "$C2"; }
  cmd_sync_extras() { echo extras >> "$C2"; }
  session_cwd_local() { printf '%s' "$HOME/code/p1"; }
}
ho_unstub() { unset -f require_remote find_local_session find_remote_pane compare_mtimes \
  cmd_push cmd_repo_pull cmd_sync_extras session_cwd_local stop_remote_claude \
  restart_remote_claude _recover_remote_op; }

# -- (A) H1 recovery matrix at the decision layer: _recover_restart must type
# -- into the pane ONLY when the op positively reports RESTARTED (i.e. the
# -- remote confirmed nothing was running and already restarted it). Every
# -- other outcome -> a manual hint, never a blind restart.
export REMOTE=stub
OP_OUT=""; OP_RC=0
_recover_remote_op() { printf '%s' "$OP_OUT"; return "$OP_RC"; }
# spec: <op-output>|<needle in log>|<restarted? yes/no>   (OP_RC=0 for all)
for spec in \
  "RESTARTED|restarted it|yes" \
  "RUNNING|still running|no" \
  "ERROR 2|NOT restarting|no" \
  "NOTOOLS|NOT restarting|no" \
  "NOPANEID|no longer exists|no" \
  "SENDFAIL|send-keys failed|no" \
  "|unexpected|no" \
  "WEIRD|unexpected|no"; do
  OP_OUT="${spec%%|*}"; rest="${spec#*|}"; needle="${rest%%|*}"; want="${rest#*|}"
  OP_RC=0
  out="$(_recover_restart sess %1 2>&1)"
  label="${OP_OUT:-<empty>}"
  assert_match "recover($label): logs '$needle'" "$needle" "$out"
  case "$out" in *"restarted it"*) got=yes ;; *) got=no ;; esac
  assert_eq "recover($label): restart=$want" "$want" "$got"
done
# ssh/transport failure (op returns nonzero) -> no restart, manual hint
OP_OUT="RESTARTED"; OP_RC=255
out="$(_recover_restart sess %1 2>&1)"
assert_match "recover(ssh-fail): manual hint" "manual recovery" "$out"
case "$out" in *"restarted it"*) t_fail "recover(ssh-fail): must NOT restart" "$out" ;; *) t_ok "recover(ssh-fail): no restart" ;; esac
unset -f _recover_remote_op
unset OP_OUT OP_RC REMOTE

# -- (B) _recover_remote_op at the SCRIPT level: restart happens exactly once
# -- and ONLY when pgrep confirms no match, rechecked immediately before the
# -- send-keys (the probe/restart race narrowed to one op). A send-keys log
# -- records any type into the pane. (Block A unset -f'd the real op; re-source
# -- to restore the genuine implementation before running it for real.)
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
cat > "$TMP/fake_tmux" <<'FEOF'
#!/bin/bash
case "${1:-}" in
  list-panes) [ "${FAKE_TMUX_RC:-0}" != 0 ] && exit "$FAKE_TMUX_RC"
              printf '%s\n' "${FAKE_PANES:-}"; exit 0 ;;
  send-keys)  [ -n "${FAKE_SEND_LOG:-}" ] && echo "send $*" >> "$FAKE_SEND_LOG"
              exit "${FAKE_SEND_RC:-0}" ;;
  display-message) printf '%s\n' "${FAKE_SESSION:-}"; exit 0 ;;
  *) exit 0 ;;
esac
FEOF
# RESTARTED is now VERIFIED (H5 commit 3): the op polls for the matching
# process AFTER the send. The fake pgrep models a claude that starts once the
# keys land: when FAKE_PGREP_AFTER_SEND_RC is set AND the send log is
# non-empty, it reports that rc instead of FAKE_PGREP_RC. With it unset the
# fake behaves exactly as before. The instant fake sleep keeps the poll fast.
cat > "$TMP/fake_pgrep" <<'FEOF'
#!/bin/bash
if [ -n "${FAKE_PGREP_AFTER_SEND_RC:-}" ] && [ -s "${FAKE_SEND_LOG:-/dev/null}" ]; then
  exit "$FAKE_PGREP_AFTER_SEND_RC"
fi
[ -n "${FAKE_PGREP_OUT:-}" ] && printf '%s\n' $FAKE_PGREP_OUT
exit "${FAKE_PGREP_RC:-0}"
FEOF
cat > "$TMP/fake_sleep" <<'FEOF'
#!/bin/bash
exit 0
FEOF
export REMOTE=stub
export FAKE_SEND_LOG="$TMP/sendlog"
remote_sh() { local s="$1"; shift; printf '%s' "$s" | PATH="$PANEBIN" bash -s -- "$@"; }
PANEBIN="$(mk_panebin recov pgrep ps tmux sleep)"

# no match + pane present -> send, process appears -> RESTARTED, one send-keys
: > "$FAKE_SEND_LOG"; export FAKE_PGREP_RC=1 FAKE_PGREP_OUT="" FAKE_PANES="%1"
export FAKE_PGREP_AFTER_SEND_RC=0
assert_eq "op: no match + pane -> RESTARTED" "RESTARTED" "$(_recover_remote_op sess %1)"
assert_eq "op: RESTARTED typed exactly once" "1" "$(grep -c '^send' "$FAKE_SEND_LOG")"

# a matching process is present -> RUNNING, NO send-keys (idempotent / FM5;
# the recheck-before-type that narrows the probe->restart race, H4)
: > "$FAKE_SEND_LOG"; export FAKE_PGREP_RC=0 FAKE_PGREP_OUT="1234"
assert_eq "op: match present -> RUNNING" "RUNNING" "$(_recover_remote_op sess %1)"
assert_eq "op: RUNNING never types into the pane" "0" "$(grep -c '^send' "$FAKE_SEND_LOG")"

# pgrep errors -> ERROR, never restart (H3)
export FAKE_PGREP_RC=2
: > "$FAKE_SEND_LOG"
assert_eq "op: pgrep error -> ERROR 2" "ERROR 2" "$(_recover_remote_op sess %1)"
assert_eq "op: ERROR never types" "0" "$(grep -c '^send' "$FAKE_SEND_LOG")"

# no match but the stored pane id is gone/reused -> NOPANEID, no send-keys
export FAKE_PGREP_RC=1 FAKE_PGREP_OUT="" FAKE_PANES="%2"
: > "$FAKE_SEND_LOG"
assert_eq "op: missing pane id -> NOPANEID" "NOPANEID" "$(_recover_remote_op sess %1)"
assert_eq "op: NOPANEID never types" "0" "$(grep -c '^send' "$FAKE_SEND_LOG")"
unset FAKE_PGREP_RC FAKE_PGREP_OUT FAKE_PANES FAKE_SEND_LOG FAKE_PGREP_AFTER_SEND_RC
unset -f remote_sh; unset REMOTE

# -- (C) arm-before-stop (FM1): a failure DURING the stop (before any transfer)
# -- must still reach recovery, and the original exit code is preserved.
C2="$TMP/c2_abs"; : > "$C2"
ho_stubs
stop_remote_claude() { echo stop >> "$C2"; exit 7; }   # dies mid-stop
_recover_remote_op() { echo op-restart >> "$C2"; printf RESTARTED; }
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; (cmd_handoff bbb) >/dev/null 2>&1 || rc=$?
assert_rc "arm-before-stop: exit code from a failed stop is preserved" 7 "$rc"
assert_match "arm-before-stop: recovery ran despite failure during stop" "op-restart" "$(cat "$C2")"
assert_eq "arm-before-stop: nothing was transferred" "" "$(grep push "$C2" || true)"
ho_unstub

# -- (D) exit-code preservation + single-fire: a failure AFTER the stop fires
# -- recovery exactly once and preserves the code.
C2="$TMP/c2_sf"; : > "$C2"
ho_stubs
stop_remote_claude() { echo stop >> "$C2"; }
cmd_repo_pull() { return 7; }
_recover_remote_op() { echo op >> "$C2"; printf RESTARTED; }
rc=0; (cmd_handoff bbb) >/dev/null 2>&1 || rc=$?
assert_rc "recovery preserves the original exit code (7)" 7 "$rc"
assert_eq "recovery fired exactly once (single-fire)" "1" "$(grep -c '^op$' "$C2")"
ho_unstub

# -- (E) restart half-success then probe OK does NOT type twice: the happy-path
# -- send-keys returns nonzero but claude actually started; the trap re-checks,
# -- sees RUNNING, and does not restart again.
C2="$TMP/c2_half"; : > "$C2"
ho_stubs
stop_remote_claude() { echo stop >> "$C2"; }
restart_remote_claude() { echo happy-restart >> "$C2"; return 1; }   # half-success
_recover_remote_op() { echo probe >> "$C2"; printf RUNNING; }
rc=0; out="$( (cmd_handoff bbb) 2>&1 )" || rc=$?
assert_rc "half-success restart exits nonzero" 1 "$rc"
assert_eq "happy-path restart attempted once" "1" "$(grep -c '^happy-restart$' "$C2")"
assert_eq "recovery probed once" "1" "$(grep -c '^probe$' "$C2")"
assert_match "recovery saw it already running (no second type)" "still running" "$out"
ho_unstub

# -- (F) handback pre-pull failure recovers the remote; no local-resume hint.
HBF="$TMP/c2_hbf"; : > "$HBF"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-my-app/hbf.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$HBF"; }
cmd_pull() { echo pull >> "$HBF"; return 9; }
_recover_remote_op() { echo op-restart >> "$HBF"; printf RESTARTED; }
NO_STOP=0; NO_EXTRAS=1; FORCE=0
rc=0; out="$( (cmd_handback hbf) 2>&1 )" || rc=$?
assert_rc "handback pull failure propagates (9)" 9 "$rc"
assert_match "handback pull failure triggers recovery restart" "op-restart" "$(cat "$HBF")"
case "$out" in *"resume locally"*) t_fail "no resume hint after a failed pull" "$out" ;; *) t_ok "no resume hint after a failed pull" ;; esac
unset -f require_remote find_remote_session find_remote_pane compare_mtimes stop_remote_claude cmd_pull _recover_remote_op

# -- (G) --no-extras does NOT disable pull-window recovery (F ran with
# -- NO_EXTRAS=1). And handback --no-stop performs NO recovery on pull failure.
NSB="$TMP/c2_nsb"; : > "$NSB"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-my-app/nsb.jsonl"; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$NSB"; }
cmd_pull() { echo pull >> "$NSB"; return 4; }
_recover_remote_op() { echo op >> "$NSB"; printf RESTARTED; }
NO_STOP=1; NO_EXTRAS=1; FORCE=0
rc=0; (cmd_handback nsb) >/dev/null 2>&1 || rc=$?
assert_rc "handback --no-stop pull failure propagates (4)" 4 "$rc"
assert_eq "handback --no-stop never stops" "" "$(grep stop "$NSB" || true)"
assert_eq "handback --no-stop performs NO recovery" "" "$(grep '^op$' "$NSB" || true)"
unset -f require_remote find_remote_session compare_mtimes stop_remote_claude cmd_pull _recover_remote_op
NO_STOP=0

# -- (H) no restart after a SUCCESSFUL pull, even when extras hard-exits: the
# -- trap is disarmed once the pull confirms local, so a later failure never
# -- recreates a dual writer. (Mirrors the D2-belt cwd setup.)
NRF="$TMP/c2_nrf"; : > "$NRF"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-code-my-app/nrf.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$NRF"; }
cmd_pull() { echo pull >> "$NRF"; }
remote_sh() { printf '/home/alice/code/my-app\n'; }   # cwd extractor for step 2b
cmd_sync_extras() { echo extras >> "$NRF"; exit 5; }   # hard exit in the extras subshell
_recover_remote_op() { echo op-restart >> "$NRF"; printf RESTARTED; }
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; out="$( (cmd_handback nrf) 2>&1 )" || rc=$?
assert_rc "handback extras failure after a good pull returns extras rc (5)" 5 "$rc"
assert_match "handback still prints the local-resume hint" "resume locally" "$out"
assert_eq "NO recovery restart after a successful pull" "" "$(grep op-restart "$NRF" || true)"
unset -f require_remote find_remote_session find_remote_pane compare_mtimes \
  stop_remote_claude cmd_pull remote_sh cmd_sync_extras _recover_remote_op

# -- (I) stop_remote_claude classifies its exit: 255 (disconnect) vs 1
# -- (timeout) vs 2 (pgrep error) get distinct, accurate messages. Prior
# -- blocks unset -f'd the real stop_remote_claude; re-source to restore it.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
export REMOTE=myhost
remote_sh() { return 255; }
rc=0; out="$( (stop_remote_claude sess %1) 2>&1 )" || rc=$?
assert_rc "stop dies on ssh disconnect" 1 "$rc"
assert_match "stop 255 -> disconnect/unknown message" "disconnected" "$out"
remote_sh() { return 1; }
out="$( (stop_remote_claude sess %1) 2>&1 )" || true
assert_match "stop 1 -> timeout message" "did not exit after 10s" "$out"
remote_sh() { return 2; }
out="$( (stop_remote_claude sess %1) 2>&1 )" || true
assert_match "stop 2 -> pgrep-error/unknown message" "pgrep errored" "$out"
unset -f remote_sh; unset REMOTE

# ============================================================================
# H5 nit: _recover_remote_op's tool check must include grep
# ============================================================================
# The op's pane-existence check pipes `tmux list-panes` through grep; without
# a grep presence check a grep-less remote would misreport NOPANEID. It must
# answer NOTOOLS ("cannot verify") instead — and never type into the pane.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
export REMOTE=stub
export FAKE_SEND_LOG="$TMP/sendlog_nogrep"
remote_sh() { local s="$1"; shift; printf '%s' "$s" | PATH="$PANEBIN" bash -s -- "$@"; }
PANEBIN="$(mk_panebin recov_nogrep pgrep ps tmux)"
rm -f "$PANEBIN/grep"
: > "$FAKE_SEND_LOG"; export FAKE_PGREP_RC=1 FAKE_PGREP_OUT="" FAKE_PANES="%1"
assert_eq "op: no match + grep missing -> NOTOOLS (not NOPANEID)" "NOTOOLS" "$(_recover_remote_op sess %1)"
assert_eq "op: grep-missing NOTOOLS never types" "0" "$(grep -c '^send' "$FAKE_SEND_LOG")"
# decision layer on top of the same grep-less remote: "cannot verify" + manual
# hint, no restart.
out="$(_recover_restart sess %1 2>&1)"
assert_match "recover(no-grep): cannot-verify message" "cannot verify" "$out"
assert_match "recover(no-grep): manual hint" "manual recovery" "$out"
assert_eq "recover(no-grep): never types into the pane" "0" "$(grep -c '^send' "$FAKE_SEND_LOG")"
unset FAKE_PGREP_RC FAKE_PGREP_OUT FAKE_PANES FAKE_SEND_LOG
unset -f remote_sh; unset REMOTE

# ============================================================================
# H5 commit 3: mixed pane topology fails closed; restarts are VERIFIED
# ============================================================================
# Prior blocks unset -f'd real functions; re-source to restore the genuine
# implementations before layering the protocol harness on top.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
SDIR="$PROJECTS/$(encode_path "$HOME")-code-p1"
export REMOTE=stub
remote_sh() { local s="$1"; shift; printf '%s' "$s" | PATH="$PANEBIN" bash -s -- "$@"; }

# -- (J) FIX 1 at the protocol level: a matching PID that maps to a pane
# -- alongside a matching PID that walks to PID 1 WITHOUT mapping (a stale
# -- tmux-argv match, or a matching process outside tmux) must fail closed as
# -- AMBIGUOUS, never OK: stopping the mapped pane would leave the unmapped
# -- matching writer running. Upgraded fake ps: per-pid rc via FAKE_PS_RC_<pid>
# -- so one pid can vanish (rc 1) while the others keep resolving.
cat > "$TMP/fake_ps" <<'FEOF'
#!/bin/bash
[ "${FAKE_PS_RC:-0}" != 0 ] && exit "$FAKE_PS_RC"
pid=""
while [ $# -gt 0 ]; do case "$1" in -p) pid="$2"; shift 2 ;; *) shift ;; esac; done
eval "prc=\${FAKE_PS_RC_$pid:-0}"
[ "$prc" != 0 ] && exit "$prc"
eval "v=\${FAKE_PPID_$pid:-}"
[ -n "$v" ] && printf '   %s\n' "$v"
exit 0
FEOF
PANEBIN="$(mk_panebin mixed pgrep ps tmux)"
# pid 1000 maps to pane %3 (via wrapper 900); pid 5000 walks to PID 1 unmapped.
export FAKE_PGREP_RC=0 FAKE_PGREP_OUT="1000 5000"
export FAKE_PPID_1000=900 FAKE_PPID_900=1 FAKE_PPID_5000=1
export FAKE_PANES="900 %3"
assert_eq "protocol: mapped + unmapped match -> AMBIGUOUS (fail closed)" \
  "AMBIGUOUS %3" "$(find_remote_pane s1)"
# the single-session wrapper+child shape must still dedup to one clean OK
export FAKE_PGREP_OUT="1000 1001" FAKE_PPID_1001=900
assert_eq "protocol: wrapper+child both map -> still OK %3" "OK %3" "$(find_remote_pane s1)"

# -- (K) FIX 1b: a matched pid VANISHING mid-walk (ps -p rc 1: it exited
# -- between pgrep and the walk) is not a tool failure — it is an unmapped
# -- match, so alongside a mapped one the answer is AMBIGUOUS, never ERROR ps.
export FAKE_PGREP_OUT="1000 6000" FAKE_PS_RC_6000=1
assert_eq "protocol: vanished pid + mapped pid -> AMBIGUOUS (not ERROR ps)" \
  "AMBIGUOUS %3" "$(find_remote_pane s1)"
# a REAL ps failure (rc > 1) still fails closed as ERROR ps
export FAKE_PS_RC_6000=2
assert_eq "protocol: ps rc 2 stays ERROR ps 2" "ERROR ps 2" "$(find_remote_pane s1)"
unset FAKE_PS_RC_6000 FAKE_PGREP_RC FAKE_PGREP_OUT FAKE_PANES
unset FAKE_PPID_1000 FAKE_PPID_1001 FAKE_PPID_900 FAKE_PPID_5000

# -- (L) FIX 2 at the op level: RESTARTED must be VERIFIED. Keys delivered
# -- (send-keys rc 0) but no matching process appearing within the poll budget
# -- -> NOTSTARTED, never RESTARTED. Uses the send-log-aware fake pgrep and the
# -- instant fake sleep from the block above.
export FAKE_SEND_LOG="$TMP/sendlog3"
PANEBIN="$(mk_panebin verify pgrep ps tmux sleep)"
unset FAKE_PGREP_AFTER_SEND_RC
: > "$FAKE_SEND_LOG"; export FAKE_PGREP_RC=1 FAKE_PGREP_OUT="" FAKE_PANES="%1"
assert_eq "op: send ok but claude never appears -> NOTSTARTED" \
  "NOTSTARTED" "$(_recover_remote_op sess %1)"
assert_eq "op: unconfirmed restart still typed exactly once" "1" "$(grep -c '^send' "$FAKE_SEND_LOG")"
# decision layer on the REAL op: NOTSTARTED prints could-not-confirm + the
# manual hint and never logs a successful restart.
: > "$FAKE_SEND_LOG"
out="$(_recover_restart sess %1 2>&1)"
assert_match "recover(NOTSTARTED): could-not-confirm message" "could not confirm" "$out"
assert_match "recover(NOTSTARTED): manual hint" "manual recovery" "$out"
case "$out" in
  *"restarted it"*) t_fail "recover(NOTSTARTED): must not log a successful restart" "$out" ;;
  *) t_ok "recover(NOTSTARTED): no success log" ;;
esac
# gone before the send, present after it -> a CONFIRMED RESTARTED
: > "$FAKE_SEND_LOG"; export FAKE_PGREP_AFTER_SEND_RC=0
assert_eq "op: claude appears after send -> RESTARTED" "RESTARTED" "$(_recover_remote_op sess %1)"

# -- (M) FIX 2 happy path: restart_remote_claude returns 0 ONLY when the
# -- post-send poll finds the process, nonzero when it never appears.
: > "$FAKE_SEND_LOG"; unset FAKE_PGREP_AFTER_SEND_RC
rc=0; restart_remote_claude sess %1 || rc=$?
assert_rc "restart_remote_claude: unconfirmed -> nonzero" 1 "$rc"
: > "$FAKE_SEND_LOG"; export FAKE_PGREP_AFTER_SEND_RC=0
rc=0; restart_remote_claude sess %1 || rc=$?
assert_rc "restart_remote_claude: confirmed -> 0" 0 "$rc"

# -- (N) FIX 2 end-to-end: an unconfirmed restart must NOT produce "handoff
# -- complete" -- it exits nonzero with the armed trap / manual hint engaged.
C3="$TMP/c3_ho"; : > "$C3"
require_remote() { REMOTE=stub; RHOME=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_local_session() { printf '%s' "$SDIR/bbb.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'local-newer'; }
stop_remote_claude() { echo stop >> "$C3"; }
cmd_push() { echo push >> "$C3"; }
cmd_repo_pull() { echo repopull >> "$C3"; }
cmd_sync_extras() { echo extras >> "$C3"; }
session_cwd_local() { printf '%s' "$HOME/code/p1"; }
: > "$FAKE_SEND_LOG"; unset FAKE_PGREP_AFTER_SEND_RC
export FAKE_PGREP_RC=1 FAKE_PGREP_OUT="" FAKE_PANES="%1"
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; out="$( (cmd_handoff bbb) 2>&1 )" || rc=$?
assert_rc "handoff: unconfirmed restart exits nonzero" 1 "$rc"
case "$out" in
  *"handoff complete"*) t_fail "handoff: unconfirmed restart must not claim completion" "$out" ;;
  *) t_ok "handoff: unconfirmed restart never claims completion" ;;
esac
assert_match "handoff: unconfirmed restart says could-not-confirm" "could not confirm" "$out"
assert_match "handoff: unconfirmed restart prints the manual hint" "manual recovery" "$out"
unset -f require_remote find_local_session find_remote_pane compare_mtimes \
  stop_remote_claude cmd_push cmd_repo_pull cmd_sync_extras session_cwd_local

# -- (O) FIX 3: the recovery banner is phase-sensitive. A failure while
# -- STOPPING never claims the remote is stopped (the stop was unconfirmed);
# -- only stopped-confirmed may say so.
_recover_remote_op() { printf RUNNING; }
rc=0; out="$( ( ROAM_RECOVER_PANE=%1; ROAM_RECOVER_SID=sess; ROAM_RECOVER_PHASE=stopping
  false; _remote_recover ) 2>&1 )" || rc=$?
assert_rc "recover banner (stopping): preserves the exit code" 1 "$rc"
assert_match "recover banner (stopping): remote state unknown" "remote state unknown" "$out"
assert_match "recover banner (stopping): names the stopping failure" "while stopping" "$out"
out2="$( ( ROAM_RECOVER_PANE=%1; ROAM_RECOVER_SID=sess; ROAM_RECOVER_PHASE=stopped-confirmed
  false; _remote_recover ) 2>&1 )" || true
assert_match "recover banner (stopped-confirmed): says it was stopped" "the remote claude was stopped" "$out2"
case "$out2" in
  *"remote state unknown"*) t_fail "recover banner: phases must differ" "$out2" ;;
  *) t_ok "recover banner: phases differ" ;;
esac
unset -f _recover_remote_op
unset FAKE_PGREP_RC FAKE_PGREP_OUT FAKE_PANES FAKE_SEND_LOG FAKE_PGREP_AFTER_SEND_RC
unset -f remote_sh; unset REMOTE

# ============================================================================
# stop_remote_claude sends a RAPID double Ctrl-C (Claude Code quit sequence)
# ============================================================================
# Claude Code's TUI quits only on two Ctrl-C presses in quick succession;
# presses seconds apart each just re-arm "press again to exit" and never quit.
# Drive the REAL stop payload through `bash -s` on a restricted PATH whose
# fakes append every tmux/sleep/pgrep event to ONE ordered sequence log, then
# assert on the ORDER: the first pair must be back-to-back with no poll
# between (the old code slept 5s before the second press and never stopped a
# real Claude Code), re-sent in adjacent pairs during the poll, and the pgrep
# rc-distinction (rc1 gone / rc>1 error / timeout) must survive unchanged.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
SEQ="$TMP/stopseq"
export FAKE_SEQ_LOG="$SEQ"
cat > "$TMP/fake_tmux" <<'FEOF'
#!/bin/bash
echo "tmux $*" >> "${FAKE_SEQ_LOG:-/dev/null}"
exit 0
FEOF
cat > "$TMP/fake_sleep" <<'FEOF'
#!/bin/bash
echo "sleep $*" >> "${FAKE_SEQ_LOG:-/dev/null}"
exit 0
FEOF
cat > "$TMP/fake_pgrep" <<'FEOF'
#!/bin/bash
echo "pgrep" >> "${FAKE_SEQ_LOG:-/dev/null}"
exit "${FAKE_PGREP_RC:-0}"
FEOF
export REMOTE=stub
remote_sh() { local s="$1"; shift; printf '%s' "$s" | PATH="$PANEBIN" bash -s -- "$@"; }
PANEBIN="$(mk_panebin stopseq pgrep tmux sleep)"

# pgrep rc 1 (process gone on the first poll) -> confirmed stopped, rc 0
: > "$SEQ"; export FAKE_PGREP_RC=1
rc=0; out="$( (stop_remote_claude sess %1) 2>&1 )" || rc=$?
assert_rc "stop: pgrep rc1 -> confirmed stopped (rc 0)" 0 "$rc"
assert_match "stop: rc1 logs stopped" "stopped" "$out"
# the quit sequence: BOTH Ctrl-C's land before any sleep/poll (rapid pair) --
# the old code slept between them, so event 2 was `sleep`, not a send
assert_eq "stop: first two events are a back-to-back C-c pair (no sleep between)" \
  "tmux send-keys -t %1 C-c
tmux send-keys -t %1 C-c" "$(sed -n '1,2p' "$SEQ")"
assert_eq "stop: confirmed-on-first-poll sends exactly one pair" \
  "2" "$(grep -c '^tmux send-keys' "$SEQ")"

# pgrep rc >1 (errored) -> exit 2 path: state UNKNOWN, never treated as gone
export FAKE_PGREP_RC=2
rc=0; out="$( (stop_remote_claude sess %1) 2>&1 )" || rc=$?
assert_rc "stop: pgrep rc2 -> dies (state UNKNOWN)" 1 "$rc"
assert_match "stop: pgrep rc2 -> pgrep-errored message" "pgrep errored" "$out"

# pgrep rc 0 throughout (never exits) -> timeout path, with the rapid pair
# RE-SENT during the poll (a mid-response claude eats the first pair)
: > "$SEQ"; export FAKE_PGREP_RC=0
rc=0; out="$( (stop_remote_claude sess %1) 2>&1 )" || rc=$?
assert_rc "stop: still running after 10s -> dies" 1 "$rc"
assert_match "stop: timeout message" "did not exit after 10s" "$out"
assert_eq "stop: timeout run re-sends the pair during the poll (3 pairs total)" \
  "6" "$(grep -c '^tmux send-keys' "$SEQ")"
# every C-c must be half of an ADJACENT pair: consecutive log lines, no
# sleep/pgrep between the two presses (else Claude Code never sees a double)
pairs_ok=yes; prev=""
while read -r n; do
  if [ -z "$prev" ]; then prev="$n"
  else
    [ "$n" -eq $((prev+1)) ] || pairs_ok=no
    prev=""
  fi
done <<EOF
$(grep -n '^tmux send-keys' "$SEQ" | cut -d: -f1)
EOF
if [ -n "$prev" ]; then pairs_ok=no; fi
assert_eq "stop: every re-sent C-c is back-to-back with its pair" "yes" "$pairs_ok"
unset FAKE_PGREP_RC FAKE_SEQ_LOG
unset -f remote_sh; unset REMOTE

# ============================================================================
# Home-prefix aliases v1: physical-home detection, dual-root accept sets,
# canonical (physical) emission, fail-closed duplicates and lossy-encoding
# corroboration. Reduced scope: auto-detected roots only (no config arrays).
# ============================================================================
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
LHP="$(encode_path "$HOME")"

# ---- HP1: the remote probe payload (Blocker 6 protocol) ----
HPPROBE_OUT="$TMP/hp_probe_out"

# cd/pwd failure inside the payload must NOT fail the payload (exit 0), and
# the second line must be empty (the local parser turns that into fallback).
rc=0; env HOME="$TMP/hp-does-not-exist" bash -c "$(remote_home_probe_script)" > "$HPPROBE_OUT" || rc=$?
assert_rc "probe: cd failure is nonfatal (payload exits 0)" 0 "$rc"
assert_eq "probe: line 1 is the logical HOME" "$TMP/hp-does-not-exist" "$(sed -n 1p "$HPPROBE_OUT")"
assert_eq "probe: line 2 empty when the probe fails" "" "$(sed -n 2p "$HPPROBE_OUT")"

# multi-hop symlink: HOME -> l1 -> real resolves to the final physical dir.
mkdir -p "$TMP/hp_real"
ln -s "$TMP/hp_real" "$TMP/hp_l1"
ln -s "$TMP/hp_l1" "$TMP/hp_l2"
HP_PHYS_EXPECT="$(cd "$TMP/hp_real" && pwd -P)"
rc=0; env HOME="$TMP/hp_l2" bash -c "$(remote_home_probe_script)" > "$HPPROBE_OUT" || rc=$?
assert_rc "probe: symlinked home probe succeeds" 0 "$rc"
assert_eq "probe: multi-hop symlink resolves to the physical home" "$HP_PHYS_EXPECT" "$(sed -n 2p "$HPPROBE_OUT")"

# ---- HP1b: require_remote parses the two-line reply (ssh stubbed) ----
FAKE_SSH_RC=0; FAKE_SSH_REPLY=""
ssh() { printf '%s' "$FAKE_SSH_REPLY"; return "$FAKE_SSH_RC"; }
hp_rr() {  # reset remote state, then run the REAL require_remote
  RHOME=""; RHOME_PHYS=""; RHOME_PHYS_FALLBACK=0; REMOTE=""
  REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE=stubhost
  require_remote
}

FAKE_SSH_REPLY='/home/alice
/home/alice'
rc=0; hp_rr || rc=$?
assert_rc "require_remote: equal two-line reply accepted" 0 "$rc"
assert_eq "require_remote: physical == logical" "/home/alice" "$(remote_home_phys)"
assert_eq "require_remote: equal homes set no fallback flag" 0 "$RHOME_PHYS_FALLBACK"

FAKE_SSH_REPLY='/home/alice
/lustre/home/alice'
rc=0; hp_rr || rc=$?
assert_rc "require_remote: differing physical home accepted" 0 "$rc"
assert_eq "require_remote: RHOME stays the logical home" "/home/alice" "$RHOME"
assert_eq "require_remote: physical home detected" "/lustre/home/alice" "$(remote_home_phys)"
assert_eq "require_remote: canonical encoding is the physical one" "-lustre-home-alice" "$(remote_home_encoded)"
assert_eq "require_remote: RPROJECTS composed from the LOGICAL home" "/home/alice/.claude/projects" "$RPROJECTS"

FAKE_SSH_REPLY='/home/alice'
rc=0; hp_rr || rc=$?
assert_rc "require_remote: missing second line falls back" 0 "$rc"
assert_eq "require_remote: fallback physical == logical" "/home/alice" "$(remote_home_phys)"
assert_eq "require_remote: fallback flag set (missing line)" 1 "$RHOME_PHYS_FALLBACK"

FAKE_SSH_REPLY='/home/alice
'
rc=0; hp_rr || rc=$?
assert_eq "require_remote: empty second line falls back" "/home/alice" "$(remote_home_phys)"
assert_eq "require_remote: fallback flag set (empty line)" 1 "$RHOME_PHYS_FALLBACK"

FAKE_SSH_REPLY='/home/alice
lustre/home/alice'
rc=0; hp_rr || rc=$?
assert_eq "require_remote: relative physical line falls back" "/home/alice" "$(remote_home_phys)"
assert_eq "require_remote: fallback flag set (invalid line)" 1 "$RHOME_PHYS_FALLBACK"

FAKE_SSH_REPLY='/home/alice
/'
rc=0; hp_rr || rc=$?
assert_eq "require_remote: root '/' physical home is rejected (fallback)" "/home/alice" "$(remote_home_phys)"
assert_eq "require_remote: fallback flag set (root alias)" 1 "$RHOME_PHYS_FALLBACK"

# ssh transport failure stays FATAL (never a silent fallback).
FAKE_SSH_RC=255; FAKE_SSH_REPLY=''
rc=0; out="$( (hp_rr) 2>&1 )" || rc=$?
assert_rc "require_remote: ssh transport failure is still fatal" 1 "$rc"
assert_match "require_remote: transport failure names ssh" "ssh to stubhost failed" "$out"
FAKE_SSH_RC=0

# accept-set construction refuses colliding roots (Blocker 1 rule).
FAKE_SSH_REPLY='/a/b
/a-b'
rc=0; out="$( (hp_rr) 2>&1 )" || rc=$?
assert_rc "require_remote: equal-encoding roots (/a/b vs /a-b) refuse" 1 "$rc"
assert_match "collision refusal names the colliding encoding" "colliding encodings" "$out"
assert_match "collision refusal names both raw roots" "/a-b" "$out"

FAKE_SSH_REPLY='/home/b
/home/b/x/home'
rc=0; out="$( (hp_rr) 2>&1 )" || rc=$?
assert_rc "require_remote: '-'-boundary-overlapping roots refuse (no longest-match)" 1 "$rc"
assert_match "overlap refusal names the colliding encoding" "colliding encodings" "$out"

# RPROJECTS override + dual roots: override wins, names stay canonical.
REMOTE_PROJECTS_OVERRIDE="/custom/proj"
FAKE_SSH_REPLY='/home/alice
/lustre/home/alice'
rc=0; hp_rr || rc=$?
assert_eq "require_remote: RPROJECTS override respected under dual roots" "/custom/proj" "$RPROJECTS"
assert_eq "translate under RPROJECTS override still emits canonical names" \
  "-lustre-home-alice-code-app" "$(translate_dir "$LHP-code-app" to-remote)"
REMOTE_PROJECTS_OVERRIDE=""
unset -f ssh
RHOME=""; RHOME_PHYS=""; RHOME_PHYS_FALLBACK=0; REMOTE=""; REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE=""

# ---- HP2: translation accept/emit matrix (dual remote root) ----
REMOTE=stub; RHOME="/home/alice"; RHOME_PHYS="/lustre/home/alice"; RHOME_PHYS_FALLBACK=0
assert_eq "translate to-local accepts the logical encoding" "$LHP-code-app" "$(translate_dir "-home-alice-code-app" to-local)"
assert_eq "translate to-local accepts the physical encoding" "$LHP-code-app" "$(translate_dir "-lustre-home-alice-code-app" to-local)"
assert_eq "translate to-remote emits the canonical physical encoding" "-lustre-home-alice-code-app" "$(translate_dir "$LHP-code-app" to-remote)"
assert_eq "translate exact logical root (empty suffix)" "$LHP" "$(translate_dir "-home-alice" to-local)"
assert_eq "translate exact physical root (empty suffix)" "$LHP" "$(translate_dir "-lustre-home-alice" to-local)"
assert_eq "translate preserves a home-bearing project suffix intact" \
  "-lustre-home-alice-code-my-home-app" "$(translate_dir "$LHP-code-my-home-app" to-remote)"
assert_eq "round trip logical -> local -> remote canonicalizes" \
  "-lustre-home-alice-code-app" "$(translate_dir "$(translate_dir "-home-alice-code-app" to-local)" to-remote)"
rc=0; (translate_dir "-home-alice2-code-app" to-local) >/dev/null 2>&1 || rc=$?
assert_rc "translate rejects '-'-boundary collision on the logical root" 1 "$rc"
rc=0; (translate_dir "-lustre-home-alice2-code-app" to-local) >/dev/null 2>&1 || rc=$?
assert_rc "translate rejects '-'-boundary collision on the physical root" 1 "$rc"
rc=0; (translate_dir "-elsewhere-code-app" to-local) >/dev/null 2>&1 || rc=$?
assert_rc "translate still rejects a dir outside both roots" 1 "$rc"

# single-root behavior is unchanged (explicit physical == logical, AND the
# unset-globals test seam).
RHOME_PHYS="/home/alice"
assert_eq "single-root translate to-remote unchanged" "-home-alice-code-app" "$(translate_dir "$LHP-code-app" to-remote)"
RHOME_PHYS=""
assert_eq "unset RHOME_PHYS behaves as a single root (seam)" "-home-alice-code-app" "$(translate_dir "$LHP-code-app" to-remote)"

# union discovery merges the two remote encodings into ONE canonical entry.
RHOME_PHYS="/lustre/home/alice"
remote_sh() { case "$1" in *find*-maxdepth\ 1*) printf '%s\n' "-home-alice-code-ua" "-lustre-home-alice-code-ua" ;; *) : ;; esac; }
out="$(union_session_dirs)"
assert_eq "union: both remote encodings collapse to one canonical local entry" \
  "1" "$(printf '%s\n' "$out" | grep -cxF -e "$LHP-code-ua")"
unset -f remote_sh

# ---- HP3: lossy-encoding corroboration (Blocker 1.2) ----
REMOTE=stub; RHOME="/home/alice"; RHOME_PHYS="/lustre/home/alice"; LHOME_PHYS=""
rc=0; (_corroborate_parent_tail "-project" "/home/alice/project" t) >/dev/null 2>&1 || rc=$?
assert_rc "corroborate: logical raw cwd agrees with the tail" 0 "$rc"
rc=0; (_corroborate_parent_tail "-project" "/lustre/home/alice/project" t) >/dev/null 2>&1 || rc=$?
assert_rc "corroborate: physical raw cwd agrees with the tail" 0 "$rc"
rc=0; (_corroborate_parent_tail "-code-app" "$HOME/code/app" t) >/dev/null 2>&1 || rc=$?
assert_rc "corroborate: the LOCAL raw home is accepted too (transferred transcript)" 0 "$rc"
rc=0; (_corroborate_parent_tail "" "/home/alice" t) >/dev/null 2>&1 || rc=$?
assert_rc "corroborate: exact root with empty tail agrees" 0 "$rc"
rc=0; out="$( (_corroborate_parent_tail "-project" "/home/alice-project" t) 2>&1 )" || rc=$?
assert_rc "corroborate: literal-hyphen sibling (/home/alice-project) refuses" 1 "$rc"
assert_match "corroborate: sibling refusal explains the lossy encoding" "does not corroborate" "$out"
rc=0; (_corroborate_parent_tail "-code-app" "/evil/code/app" t) >/dev/null 2>&1 || rc=$?
assert_rc "corroborate: cwd outside every raw root refuses" 1 "$rc"
rc=0; (_corroborate_parent_tail "-code-app" "${HOME}zz/code/app" t) >/dev/null 2>&1 || rc=$?
assert_rc "corroborate: raw-boundary sibling of \$HOME refuses despite matching suffix" 1 "$rc"
rc=0; out="$( (_corroborate_parent_tail "-code-app" "" t) 2>&1 )" || rc=$?
assert_rc "corroborate: no usable cwd record refuses" 1 "$rc"
assert_match "corroborate: no-cwd refusal says so" "no usable cwd" "$out"
rc=0; (_corroborate_parent_tail "-project" '/home/alice-project
/home/alice/project' t) >/dev/null 2>&1 || rc=$?
assert_rc "corroborate: the FIRST usable cwd decides (later record cannot rescue)" 1 "$rc"

# cmd_pull integration: a non-canonical remote parent is pulled only when
# the remote transcript corroborates it; the sibling case refuses.
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/lustre/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-home-alice-project/sib1.jsonl"; }
remote_sh() { printf '%s\n' "$FAKE_RCWD"; }
remote_stat() { printf 'MISSING'; }
compare_mtimes() { printf 'remote-missing'; }
SIBRSYNC="$TMP/hp_sib_rsync"; : > "$SIBRSYNC"
rsync() { printf '%s\n' "$*" >> "$SIBRSYNC"; }
FORCE=0

FAKE_RCWD="/home/alice-project"
rc=0; out="$( (cmd_pull sib1) 2>&1 )" || rc=$?
assert_rc "pull: uncorroborated non-canonical parent refuses" 1 "$rc"
assert_match "pull: refusal explains the corroboration failure" "does not corroborate" "$out"
assert_eq "pull: nothing was transferred on refusal" "" "$(cat "$SIBRSYNC")"

FAKE_RCWD="/home/alice/project"
rc=0; out="$( (cmd_pull sib1) 2>&1 )" || rc=$?
assert_rc "pull: corroborated non-canonical parent proceeds" 0 "$rc"
assert_match "pull: transfer targets the canonical local dir" "$LHP-project/sib1.jsonl" "$(cat "$SIBRSYNC")"

# canonical (physical) remote parent needs NO corroboration round trip.
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-lustre-home-alice-code-app/can1.jsonl"; }
HPCANLOG="$TMP/hp_can_rsh"; : > "$HPCANLOG"
remote_sh() { echo called >> "$HPCANLOG"; printf '%s\n' "/should/never/be/read"; }
: > "$SIBRSYNC"
rc=0; (cmd_pull can1) >/dev/null 2>&1 || rc=$?
assert_rc "pull: canonical parent pulls without corroboration" 0 "$rc"
assert_eq "pull: canonical parent triggers no extra remote round trip" "" "$(cat "$HPCANLOG")"
assert_match "pull: canonical parent lands in the translated local dir" "$LHP-code-app/can1.jsonl" "$(cat "$SIBRSYNC")"
unset -f require_remote find_remote_session remote_sh remote_stat compare_mtimes rsync
unset FAKE_RCWD

# push side: a session under the non-canonical LOCAL encoding must be
# corroborated by its own (local) transcript before translation.
if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  LHOME_PHYS="$TMP/physhome"; LHOME_PHYS_FALLBACK=0
  mkdir -p "$PROJECTS/$LHP-code-hp"
  printf '{"cwd":"%s/code/hp"}\n' "$HOME" > "$PROJECTS/$LHP-code-hp/hpl1.jsonl"
  printf '{"cwd":"%s/code/other"}\n' "$HOME" > "$PROJECTS/$LHP-code-hp/hpl2.jsonl"
  require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
  remote_sh() { :; }
  compare_mtimes() { printf 'remote-missing'; }
  HPPRSYNC="$TMP/hp_push_rsync"; : > "$HPPRSYNC"
  rsync() { printf '%s\n' "$*" >> "$HPPRSYNC"; }
  FORCE=1

  rc=0; (cmd_push hpl1) >/dev/null 2>&1 || rc=$?
  assert_rc "push: corroborated non-canonical local parent proceeds" 0 "$rc"
  assert_match "push: transfer ran for the corroborated session" "hpl1.jsonl" "$(cat "$HPPRSYNC")"

  : > "$HPPRSYNC"
  rc=0; out="$( (cmd_push hpl2) 2>&1 )" || rc=$?
  assert_rc "push: uncorroborated non-canonical local parent refuses" 1 "$rc"
  assert_match "push: local refusal explains the corroboration failure" "does not corroborate" "$out"
  assert_eq "push: nothing was transferred on local refusal" "" "$(cat "$HPPRSYNC")"

  # canonical local parent: no corroboration (a cwd-less transcript pushes).
  LPPENC="$(encode_path "$TMP/physhome")"
  mkdir -p "$PROJECTS/$LPPENC-code-hp"
  printf '{"nocwd":true}\n' > "$PROJECTS/$LPPENC-code-hp/hpl3.jsonl"
  : > "$HPPRSYNC"
  rc=0; (cmd_push hpl3) >/dev/null 2>&1 || rc=$?
  assert_rc "push: canonical local parent needs no corroboration" 0 "$rc"
  assert_match "push: canonical-parent transfer ran" "hpl3.jsonl" "$(cat "$HPPRSYNC")"
  unset -f require_remote remote_sh compare_mtimes rsync
  FORCE=0; LHOME_PHYS=""; LHOME_PHYS_FALLBACK=0
else
  t_ok "push-side corroboration tests skipped (no jq/python3 on PATH)"
fi

# ---- HP4: duplicates fail closed (Blockers 2/3) ----
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
LHP="$(encode_path "$HOME")"
SDIR="$PROJECTS/$LHP-code-p1"

# find_local_session: physical/logical twins refuse with a migration hint.
LHOME_PHYS="$TMP/physhome"; LHOME_PHYS_FALLBACK=0
LPPENC="$(encode_path "$TMP/physhome")"
mkdir -p "$PROJECTS/$LHP-code-twin" "$PROJECTS/$LPPENC-code-twin"
printf '{}\n' > "$PROJECTS/$LHP-code-twin/tw1.jsonl"
printf '{}\n' > "$PROJECTS/$LPPENC-code-twin/tw1.jsonl"
rc=0; out="$( (find_local_session tw1) 2>&1 )" || rc=$?
assert_rc "find_local_session: encoding twins refuse" 1 "$rc"
assert_match "local twin refusal says home encoding" "local home encoding" "$out"
assert_match "local twin refusal lists the physical twin path" "$LPPENC-code-twin" "$out"
assert_match "local twin refusal carries a migration hint" "merge them manually" "$out"

# same sid in two DIFFERENT projects keeps the generic ambiguity refusal.
mkdir -p "$PROJECTS/$LHP-code-twa" "$PROJECTS/$LHP-code-twb"
printf '{}\n' > "$PROJECTS/$LHP-code-twa/tw3.jsonl"
printf '{}\n' > "$PROJECTS/$LHP-code-twb/tw3.jsonl"
rc=0; out="$( (find_local_session tw3) 2>&1 )" || rc=$?
assert_rc "find_local_session: distinct projects still refuse" 1 "$rc"
assert_match "distinct-project refusal keeps the generic message" "ambiguous session id" "$out"

# single-root seam: the same twin-shaped dirs get the GENERIC message when
# no physical home is set (blast radius: message unchanged).
LHOME_PHYS=""
rc=0; out="$( (find_local_session tw1) 2>&1 )" || rc=$?
assert_rc "find_local_session: single-root twin-shape still refuses" 1 "$rc"
assert_match "single-root refusal keeps the generic message" "ambiguous session id" "$out"
rm -rf "$PROJECTS/$LHP-code-twin" "$PROJECTS/$LPPENC-code-twin" "$PROJECTS/$LHP-code-twa" "$PROJECTS/$LHP-code-twb"

# find_remote_session: remote twins refuse with the migration hint.
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/lustre/home/alice; RPROJECTS=/home/alice/.claude/projects; }
REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/lustre/home/alice; RPROJECTS=/home/alice/.claude/projects
remote_sh() { printf '%s\n%s\n' \
  "/home/alice/.claude/projects/-home-alice-code-app/dup2.jsonl" \
  "/home/alice/.claude/projects/-lustre-home-alice-code-app/dup2.jsonl"; }
rc=0; out="$( (find_remote_session dup2) 2>&1 )" || rc=$?
assert_rc "find_remote_session: encoding twins refuse" 1 "$rc"
assert_match "remote twin refusal says home encoding" "home encoding" "$out"
assert_match "remote twin refusal carries a migration hint" "merge them manually" "$out"
remote_sh() { printf '%s\n%s\n' \
  "/home/alice/.claude/projects/-home-alice-code-p1/dup3.jsonl" \
  "/home/alice/.claude/projects/-home-alice-code-p2/dup3.jsonl"; }
rc=0; out="$( (find_remote_session dup3) 2>&1 )" || rc=$?
assert_rc "find_remote_session: distinct remote projects still refuse" 1 "$rc"
assert_match "distinct remote projects keep the generic message" "ambiguous session id" "$out"
unset -f remote_sh

# push twin guard: a sid under the OTHER remote encoding refuses BEFORE any
# backup/mkdir/rsync — and --force must NOT override.
find_local_session() { printf '%s' "$SDIR/bbb.jsonl"; }
session_cwd_local() { printf '%s' "$HOME/code/p1"; }
TWSTATLOG="$TMP/hp_tw_stat"; : > "$TWSTATLOG"
remote_stat() { printf '%s\n' "$1" >> "$TWSTATLOG"; case "$1" in */-home-alice-code-p1/*) printf '100 5' ;; *) printf 'MISSING' ;; esac; }
TWRSH="$TMP/hp_tw_rsh"; : > "$TWRSH"
remote_sh() { echo "rsh $*" >> "$TWRSH"; }
TWRSYNC="$TMP/hp_tw_rsync"; : > "$TWRSYNC"
rsync() { printf '%s\n' "$*" >> "$TWRSYNC"; }
compare_mtimes() { printf 'remote-missing'; }

FORCE=0
rc=0; out="$( (cmd_push bbb) 2>&1 )" || rc=$?
assert_rc "push: remote twin refuses" 1 "$rc"
assert_match "push twin refusal lists the twin path" "-home-alice-code-p1/bbb.jsonl" "$out"
assert_match "push twin refusal says --force does not override" "--force does not override" "$out"
assert_eq "push twin refusal: no rsync ran" "" "$(cat "$TWRSYNC")"
assert_eq "push twin refusal: no remote mkdir/backup ran" "" "$(cat "$TWRSH")"

FORCE=1
rc=0; (cmd_push bbb) >/dev/null 2>&1 || rc=$?
assert_rc "push: --force does not override the twin refusal" 1 "$rc"
assert_eq "forced push twin refusal: still no rsync" "" "$(cat "$TWRSYNC")"
assert_eq "forced push twin refusal: still no remote mkdir/backup" "" "$(cat "$TWRSH")"
FORCE=0

# twin absent -> push proceeds and lands in the CANONICAL (physical) name.
remote_stat() { printf 'MISSING'; }
: > "$TWRSYNC"
rc=0; (cmd_push bbb) >/dev/null 2>&1 || rc=$?
assert_rc "push: proceeds when no twin exists" 0 "$rc"
assert_match "push lands in the canonical physical encoding" "-lustre-home-alice-code-p1/bbb.jsonl" "$(cat "$TWRSYNC")"

# twin state UNKNOWN (ssh/stat failed) -> fail closed.
remote_stat() { return 3; }
: > "$TWRSYNC"
rc=0; out="$( (cmd_push bbb) 2>&1 )" || rc=$?
assert_rc "push: unknown twin state refuses" 1 "$rc"
assert_match "push unknown-twin refusal explains itself" "duplicate state is unknown" "$out"
assert_eq "push unknown-twin refusal: no rsync ran" "" "$(cat "$TWRSYNC")"

# single-root seam: the twin guard adds ZERO remote round trips — the only
# remote_stat is the pre-existing shrink-guard stat of the destination
# (dual-root runs above show twin-check + shrink-guard = 2 stats).
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
RHOME_PHYS=/home/alice
: > "$TWSTATLOG"
remote_stat() { printf '%s\n' "$1" >> "$TWSTATLOG"; printf 'MISSING'; }
rc=0; (cmd_push bbb) >/dev/null 2>&1 || rc=$?
assert_rc "push: single root still succeeds" 0 "$rc"
assert_eq "push: single root adds no twin stat (shrink-guard stat only)" "1" "$(grep -c . "$TWSTATLOG")"
unset -f require_remote find_local_session session_cwd_local remote_stat remote_sh rsync compare_mtimes

# handoff: twin refusal happens BEFORE the stop; a twin appearing AFTER the
# preflight is caught by cmd_push's re-check and takes the recovery path.
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
LHP="$(encode_path "$HOME")"
SDIR="$PROJECTS/$LHP-code-p1"
HOSTOP="$TMP/hp_ho_stop"; : > "$HOSTOP"
HOSTAT="$TMP/hp_ho_stat"; : > "$HOSTAT"
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/lustre/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_local_session() { printf '%s' "$SDIR/bbb.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'local-newer'; }
session_cwd_local() { printf '%s' "$HOME/code/p1"; }
stop_remote_claude() { echo stop >> "$HOSTOP"; }
remote_sh() { :; }
HORSYNC="$TMP/hp_ho_rsync"; : > "$HORSYNC"
rsync() { printf '%s\n' "$*" >> "$HORSYNC"; }
_recover_remote_op() { echo op-restart >> "$HOSTOP"; printf RESTARTED; }
NO_STOP=0; NO_EXTRAS=0; FORCE=0

# twin present at preflight -> refuse BEFORE stop, remote NOT stopped.
remote_stat() { printf '100 5'; }
rc=0; out="$( (cmd_handoff bbb) 2>&1 )" || rc=$?
assert_rc "handoff: twin at preflight refuses" 1 "$rc"
assert_match "handoff twin refusal says the remote was NOT stopped" "NOT stopped" "$out"
assert_eq "handoff twin refusal: nothing stopped or transferred" "" "$(cat "$HOSTOP")"

# twin appears between preflight and transfer -> post-stop re-check dies,
# the armed trap runs recovery (normal recovery path).
remote_stat() { echo x >> "$HOSTAT"; if [ "$(grep -c x "$HOSTAT")" -ge 2 ]; then printf '100 5'; else printf 'MISSING'; fi; }
: > "$HOSTOP"; : > "$HORSYNC"
rc=0; out="$( (cmd_handoff bbb) 2>&1 )" || rc=$?
assert_rc "handoff: twin appearing post-stop fails the transfer" 1 "$rc"
assert_match "handoff post-stop twin: the stop happened first" "stop" "$(cat "$HOSTOP")"
assert_match "handoff post-stop twin: recovery restart attempted" "op-restart" "$(cat "$HOSTOP")"
assert_eq "handoff post-stop twin: no rsync ran" "" "$(cat "$HORSYNC")"
unset -f require_remote find_local_session find_remote_pane compare_mtimes session_cwd_local \
  stop_remote_claude remote_sh rsync _recover_remote_op remote_stat

# handback: twins refuse before the stop; post-stop rediscovery must never
# silently switch source paths.
HBSTOP="$TMP/hp_hb_stop"; : > "$HBSTOP"
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/lustre/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$HBSTOP"; }
remote_sh() { printf '%s\n%s\n' \
  "/home/alice/.claude/projects/-home-alice-code-app/hbt.jsonl" \
  "/home/alice/.claude/projects/-lustre-home-alice-code-app/hbt.jsonl"; }
NO_STOP=0; NO_EXTRAS=1; FORCE=0
rc=0; out="$( (cmd_handback hbt) 2>&1 )" || rc=$?
assert_rc "handback: remote twins refuse (via find_remote_session)" 1 "$rc"
assert_match "handback twin refusal carries the migration hint" "merge them manually" "$out"
assert_eq "handback twin refusal: remote never stopped" "" "$(cat "$HBSTOP")"
unset -f remote_sh

# source-switch: rediscovery inside the pull returns a DIFFERENT path.
HBSW="$TMP/hp_hb_switch"; : > "$HBSW"
HBSWCNT="$TMP/hp_hb_swcnt"; : > "$HBSWCNT"
find_remote_session() {
  echo x >> "$HBSWCNT"
  if [ "$(grep -c x "$HBSWCNT")" -ge 2 ]; then
    printf '%s' "/home/alice/.claude/projects/-home-alice-code-app/hbs.jsonl"
  else
    printf '%s' "/home/alice/.claude/projects/-lustre-home-alice-code-app/hbs.jsonl"
  fi
}
stop_remote_claude() { echo stop >> "$HBSW"; }
remote_stat() { printf 'MISSING'; }
rsync() { echo "rsync $*" >> "$HBSW"; }
remote_sh() { :; }
_recover_remote_op() { echo op-restart >> "$HBSW"; printf RESTARTED; }
rc=0; out="$( (cmd_handback hbs) 2>&1 )" || rc=$?
assert_rc "handback: post-stop source switch refuses" 1 "$rc"
assert_match "handback source-switch refusal names the move" "moved between preflight and pull" "$out"
assert_match "handback source-switch: recovery restart attempted" "op-restart" "$(cat "$HBSW")"
assert_eq "handback source-switch: nothing was transferred" "" "$(grep rsync "$HBSW" || true)"
unset -f require_remote find_remote_pane compare_mtimes stop_remote_claude \
  find_remote_session remote_stat rsync remote_sh _recover_remote_op
NO_EXTRAS=0

# ---- HP4b: sync-all with dual remote encodings (Blocker 4, minimal-safe) ----
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/sa_projects"; mkdir -p "$PROJECTS"
LHP="$(encode_path "$HOME")"
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/lustre/home/alice; RPROJECTS=/home/alice/.claude/projects; }
PROJECT_ROOTS=(); PROJECT_CLAUDE_EXTRAS=(); SESSION_DIR_EXTRAS=(); HOME_RELATIVE_EXTRAS=()
REQUIRE_CLEAN=0
SARSH="$TMP/hp_sa_rsh"; SARSYNC="$TMP/hp_sa_rsync"
sa_remote_sh() {  # $FAKE_SA_DIRS (newline-separated) drives both discovery rounds
  case "$1" in
    *find*-maxdepth\ 1*) echo find-call >> "$SARSH"; printf '%s\n' "$FAKE_SA_DIRS" ;;
    *mkdir*)             echo "mkdir $2" >> "$SARSH" ;;
    *) : ;;
  esac
}
remote_sh() { sa_remote_sh "$@"; }
rsync() { printf 'rsync %s\n' "$*" >> "$SARSYNC"; }

# (a) data ONLY under the non-canonical encoding: READ from the actual dir,
# WRITE to the canonical destination.
FAKE_SA_DIRS="-home-alice-code-sa1"
: > "$SARSH"; : > "$SARSYNC"
rc=0; out="$( (cmd_sync_all both) 2>&1 )" || rc=$?
assert_rc "sync-all: non-canonical-only project syncs" 0 "$rc"
assert_match "sync-all: remote mkdir targets the CANONICAL dir" "mkdir /home/alice/.claude/projects/-lustre-home-alice-code-sa1" "$(cat "$SARSH")"
assert_match "sync-all: to-remote write goes to the CANONICAL dir" "stub:/home/alice/.claude/projects/-lustre-home-alice-code-sa1/" "$(cat "$SARSYNC")"
assert_match "sync-all: from-remote read comes from the ACTUAL (non-canonical) dir" "stub:/home/alice/.claude/projects/-home-alice-code-sa1/ " "$(cat "$SARSYNC")"

# (b) BOTH encodings hold data: failed step + migration hint, nothing synced.
FAKE_SA_DIRS="-home-alice-code-sa1
-lustre-home-alice-code-sa1"
: > "$SARSH"; : > "$SARSYNC"
rc=0; out="$( (cmd_sync_all both) 2>&1 )" || rc=$?
assert_rc "sync-all: both-encodings project is a FAILED step" 1 "$rc"
assert_match "sync-all: both-encodings warning names both dirs" "BOTH home encodings" "$out"
assert_match "sync-all: the sweep reports the failed step count" "failed step" "$out"
assert_eq "sync-all: both-encodings project transferred nothing" "" "$(cat "$SARSYNC")"

# (c) single root: byte-identical behavior, and NO extra discovery round.
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/home/alice; RPROJECTS=/home/alice/.claude/projects; }
FAKE_SA_DIRS="-home-alice-code-sa1"
: > "$SARSH"; : > "$SARSYNC"
rc=0; out="$( (cmd_sync_all both) 2>&1 )" || rc=$?
assert_rc "sync-all: single root still succeeds" 0 "$rc"
assert_match "sync-all: single root reads and writes the same dir" "stub:/home/alice/.claude/projects/-home-alice-code-sa1/" "$(cat "$SARSYNC")"
assert_eq "sync-all: single root runs exactly ONE remote discovery" "1" "$(grep -c find-call "$SARSH")"
unset -f require_remote remote_sh rsync sa_remote_sh
unset FAKE_SA_DIRS
load_config
PROJECTS="$TMP/projects"

# ---- HP5: raw-path mapping (Blocker 5, scoped) ----
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
LHP="$(encode_path "$HOME")"

# a remote transcript recorded under the PHYSICAL remote home resolves to
# the local project, and the remote emission stays under the LOGICAL $RHOME.
mkdir -p "$PROJECTS/$LHP-code-rp"
printf '{"cwd":"/lustre/home/alice/code/rp"}\n' > "$PROJECTS/$LHP-code-rp/rp1.jsonl"
printf '{"cwd":"/home/alice/code/rp"}\n' > "$PROJECTS/$LHP-code-rp/rp2.jsonl"
assert_eq "raw: physical remote cwd resolves to the local project" "$HOME/code/rp" "$(session_cwd_local rp1)"
assert_eq "raw: logical remote cwd resolves identically" "$HOME/code/rp" "$(session_cwd_local rp2)"
require_remote() { :; }
REMOTE=stub; RHOME="/home/alice"; RHOME_PHYS="/lustre/home/alice"
assert_eq "raw: emission stays under the LOGICAL remote home (physical transcript)" "/home/alice/code/rp" "$(session_cwd_remote rp1)"
assert_eq "raw: emission stays under the LOGICAL remote home (logical transcript)" "/home/alice/code/rp" "$(session_cwd_remote rp2)"

# a LOCAL cwd under the local PHYSICAL home maps to logical $RHOME with the
# same relative suffix; a raw-boundary sibling still refuses.
LHOME_PHYS="$TMP/physhome"; LHOME_PHYS_FALLBACK=0
LPPENC="$(encode_path "$TMP/physhome")"
mkdir -p "$PROJECTS/$LPPENC-code-rp"
printf '{"cwd":"%s/code/rp"}\n' "$TMP/physhome" > "$PROJECTS/$LPPENC-code-rp/rp3.jsonl"
assert_eq "raw: local physical cwd emits under logical \$RHOME" "/home/alice/code/rp" "$(session_cwd_remote rp3)"
mkdir -p "$PROJECTS/$(encode_path "${HOME}zz")-code-rp"
printf '{"cwd":"%szz/code/rp"}\n' "$HOME" > "$PROJECTS/$(encode_path "${HOME}zz")-code-rp/rp4.jsonl"
rc=0; (session_cwd_remote rp4) >/dev/null 2>&1 || rc=$?
assert_rc "raw: a raw-boundary sibling of \$HOME still refuses emission" 1 "$rc"
LHOME_PHYS=""; LHOME_PHYS_FALLBACK=0
unset -f require_remote

# handback end-to-end: physical-home remote transcript cwd -> local project
# dir for extras, remote extras path emitted under the LOGICAL $RHOME.
HBRAW="$TMP/hp_hb_raw"; : > "$HBRAW"
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/lustre/home/alice; RPROJECTS=/home/alice/.claude/projects; }
find_remote_session() { printf '%s' "/home/alice/.claude/projects/-lustre-home-alice-code-rp/hbrp.jsonl"; }
find_remote_pane() { printf '%s' 'OK %1'; }
compare_mtimes() { printf 'remote-newer'; }
stop_remote_claude() { echo stop >> "$HBRAW"; }
cmd_pull() { echo pull >> "$HBRAW"; }
remote_sh() { printf '/lustre/home/alice/code/rp\n'; }
cmd_sync_extras() { echo "extras $*" >> "$HBRAW"; }
NO_STOP=0; NO_EXTRAS=0; FORCE=0
rc=0; (cmd_handback hbrp) >/dev/null 2>&1 || rc=$?
assert_rc "handback: physical-cwd remote transcript hands back" 0 "$rc"
assert_match "handback: extras got the mapped LOCAL project dir" "extras hbrp from-remote $HOME/code/rp" "$(cat "$HBRAW")"
assert_match "handback: extras remote path emitted under LOGICAL \$RHOME" "$HOME/code/rp /home/alice/code/rp" "$(cat "$HBRAW")"
unset -f require_remote find_remote_session find_remote_pane compare_mtimes \
  stop_remote_claude cmd_pull remote_sh cmd_sync_extras

# ---- HP6: doctor reporting ----
# shellcheck disable=SC1090
. "$REPO_DIR/bin/claude-roam"
PROJECTS="$TMP/projects"
DOCSCAN="$TMP/hp_doc_scan"; : > "$DOCSCAN"
FAKE_TWIN_SCAN=""
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/lustre/home/alice; RHOME_PHYS_FALLBACK=0; RPROJECTS=/home/alice/.claude/projects; }
remote_sh() {
  case "$1" in
    *NONCANON*) echo twinscan >> "$DOCSCAN"; printf '%s\n' "$FAKE_TWIN_SCAN" ;;
    *) printf 'ok   remote rsync present\n' ;;
  esac
}
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE="stubhost"

# differing homes: report the pair, non-canonical dirs, and duplicate sids
# on SEPARATE lines; warns only (doctor still passes).
FAKE_TWIN_SCAN='NONCANON -home-alice-code-app
DUP dup1 -home-alice-code-app <-> -lustre-home-alice-code-app'
rc=0; out="$(cmd_doctor 2>&1)" || rc=$?
assert_rc "doctor: dual-root report is warn-only (exit 0)" 0 "$rc"
assert_match "doctor reports the logical+physical home pair" "remote home: /home/alice (physical: /lustre/home/alice" "$out"
assert_match "doctor reports the non-canonical dir on its own line" "non-canonical home encoding: -home-alice-code-app" "$out"
assert_match "doctor reports the duplicate sid on its own line" "duplicate session under both home encodings: dup1" "$out"

# scan failure = UNKNOWN, never "no twins".
FAKE_TWIN_SCAN='SCANFAIL find'
out="$(cmd_doctor 2>&1)" || true
assert_match "doctor: twin scan failure reports UNKNOWN" "twin state UNKNOWN" "$out"
remote_sh() { case "$1" in *NONCANON*) return 255 ;; *) printf 'ok   remote rsync present\n' ;; esac; }
out="$(cmd_doctor 2>&1)" || true
assert_match "doctor: twin scan ssh failure reports UNKNOWN" "twin state UNKNOWN" "$out"

# probe fallback is reported distinctly, and skips the twin scan.
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/home/alice; RHOME_PHYS_FALLBACK=1; RPROJECTS=/home/alice/.claude/projects; }
remote_sh() { case "$1" in *NONCANON*) echo twinscan >> "$DOCSCAN"; printf '\n' ;; *) printf 'ok   remote rsync present\n' ;; esac; }
: > "$DOCSCAN"
out="$(cmd_doctor 2>&1)" || true
assert_match "doctor: probe fallback reported distinctly" "physical-home probe failed" "$out"
assert_eq "doctor: probe fallback skips the twin scan" "" "$(cat "$DOCSCAN")"

# equal homes: no physical-home line at all (byte-level blast radius).
require_remote() { REMOTE=stub; RHOME=/home/alice; RHOME_PHYS=/home/alice; RHOME_PHYS_FALLBACK=0; RPROJECTS=/home/alice/.claude/projects; }
: > "$DOCSCAN"
out="$(cmd_doctor 2>&1)" || true
case "$out" in
  *"physical:"*) t_fail "doctor: equal homes print no physical line" "output: $out" ;;
  *) t_ok "doctor: equal homes print no physical line" ;;
esac
assert_eq "doctor: equal homes run no twin scan" "" "$(cat "$DOCSCAN")"
unset -f require_remote remote_sh
REMOTE_FLAG=""; CLAUDE_ROAM_REMOTE=""
unset FAKE_TWIN_SCAN

t_summary
