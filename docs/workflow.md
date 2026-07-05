# Workflow

## Explicit hand-off, not continuous sync

`claude-roam` is a hand-off tool: push when you're leaving a machine, pull
when you're arriving at one. It is **not** a background syncer that keeps
two copies converged while you work on both at once — if you run `claude
--resume <sid>` on both machines against the same session at the same
time, each side appends to its own copy independently and you get two
diverging histories (a fork), not a merge. There's no merge model for a
conversation transcript, so `claude-roam` doesn't pretend to have one:
one side is authoritative at a time, and you tell it which by pushing or
pulling.

## `handoff`: the main workflow (local machine leaving, remote taking over)

Running `claude-roam handoff <sid>` on its own only moves the JSONL and
restarts a tmux pane — it does not touch the project's git repo. If the
project has uncommitted work, that work won't exist on the remote and the
resumed session will be confused about its own state. The full workflow
wraps the CLI command with a repo-commit step:

1. **Consent-gated commit, and pane pre-lookup.** If the local project repo is dirty, get
   explicit confirmation before committing and pushing it — a request to
   "continue this on the server" is not consent to `git push`. Once
   confirmed, a dedicated commit step stages specific files by name (never
   `git add -A`/`.`), writes a message describing the actual diff, and
   pushes. Meanwhile, `claude-roam handoff` performs a read-only lookup of
   the tmux pane running `claude --resume <sid>` on the remote via
   pgrep/tmux — this lookup touches nothing and is done before the
   preflight, ensuring the pane target is known if recovery is needed later.
2. **Preflight, before anything is stopped.** `claude-roam handoff`
   compares the local and remote JSONL by mtime/size *before* touching the
   remote `claude` process. If the remote copy looks newer or the two have
   diverged (same mtime, different size), it refuses right there —
   nothing on the remote has been stopped yet, so refusing is free of
   side effects. Pull or resolve the divergence first, or pass `--force`
   if you're sure which side should win.
3. **Stop.** The tmux pane was already located in step 1 as a read-only
   lookup that touches nothing. Only after the preflight in step 2 passes
   does the command actually stop that pane via `Ctrl-C`, polling for up to
   10 seconds for the process to exit (a second `Ctrl-C` is sent partway
   through if it hasn't). From this point on, any failure triggers automatic
   recovery (see below) — the remote writer is stopped, so leaving it
   stopped on failure would strand the user.
4. **Push, forced.** The JSONL is transferred with the newer-side check
   overridden — the preflight in step 2 already adjudicated which side
   should win, and the remote `claude` may have written a few final
   shutdown records while exiting, which would otherwise look like a
   `remote-newer` race against the copy we're about to send.
5. **Branch-checked repo pull.** `git pull --ff-only` runs in the matching
   project directory on the remote, but only if the remote repo is
   currently on the same branch the local repo was on when the hand-off
   started. A branch mismatch is reported and the pull is skipped rather
   than force-checking out a different branch underneath whatever the
   remote was doing. Note: the branch check only applies when the local
   project directory is a git repo; if it isn't (so no local branch is
   known), the remote pull proceeds on whatever branch the remote has
   checked out.
6. **Extras.** Gitignored working docs (plans, reviews, session memory,
   etc. — see [docs/configuration.md](configuration.md)) are synced
   local-to-remote, unless `--no-extras` was passed.
7. **Restart.** `claude --resume <sid>` is sent to the same tmux pane it
   was stopped in, and the pane target is printed so you can attach to it.

If no remote pane was found running the session in the first place, steps
3 and 7 are skipped — the JSONL is still pushed and the repo still pulled,
but you get a message telling you to start `claude --resume <sid>`
yourself.

### Failure recovery after the stop

Once the remote `claude` has been stopped (step 3), a failure in any later
step (push, repo pull, or extras) triggers an automatic attempt to restart
`claude --resume <sid>` in the same pane it was stopped in — so a failed
hand-off doesn't leave the remote machine with a session stopped and
nobody watching it. If even that restart fails, the exact `ssh` command to
restart it by hand is printed.

## `handback`: the reverse direction (remote returning control to local)

`handback` is asymmetric with `handoff` because there's no local Claude
running on the remote side to dispatch a commit through — the repo-commit
step of `handoff` requires a Claude agent to run *in the project
directory*, and that directory is remote. So before running
`claude-roam handback <sid>`, check the remote repo state first —
`claude-roam repo-status <sid> remote` resolves the remote project path and
runs `git status --short --branch` there over SSH, passing the path as a
quoted argv element rather than interpolating it into a hand-built SSH
command — if it's dirty, stop and get it committed on the remote side
before pulling anything.

Once the remote repo is clean (or isn't a git repo at all):

```bash
claude-roam handback <sid>
```

**`handback` stops the remote `claude` first** (unless `--no-stop` is
passed) — pulling a JSONL while it's still being written would tear the
copy. It then pulls the JSONL and syncs extras `from-remote`. It does
**not** pull the repo locally for you — do that yourself once handback
finishes:

```bash
cd "$(claude-roam project "<sid>")" && git pull --ff-only
```

Pass `--no-stop` only when you know the remote isn't actively running the
session (e.g. it already exited on its own) and want to skip the stop
attempt.

## `sync-all`: the blanket sweep

`sync-all` is a different tool for a different job: not a targeted
hand-off of one session, but a sweep across everything.

- **Union discovery.** It builds the set of session directories to sync as
  the *union* of what exists locally and what exists on the remote (one
  SSH round trip lists the remote side, translated back to local naming) —
  so a session that only exists on one machine still gets picked up and
  seeded on the other, not just sessions present on both.
- **Allowlisted project extras.** Per-project working docs are only synced
  for the subdirectories listed in `PROJECT_CLAUDE_EXTRAS` (see
  [docs/configuration.md](configuration.md)) — `sync-all` doesn't sync a
  project's entire `.claude/` directory, only the allowlisted subdirs.
- **The session store rides along whole.** `sync-all`'s session phase
  `rsync`s each encoded session directory as a whole (not just the
  `*.jsonl` files), so `SESSION_DIR_EXTRAS` (like the `memory/`
  auto-memory directory) travels along automatically as a side effect —
  there's no separate step for it.
- **`-au` never deletes.** Every transfer uses `rsync -au`: `-a` for a
  faithful copy, `-u` so a file is only overwritten if the source is
  newer. There's no `--delete`. A file removed on one side is never
  removed on the other by `sync-all` — it can only add or update.
- **Failure summary, not fail-fast.** Each step (each session, each
  project's extras) is attempted independently; a failure is counted and
  logged but doesn't stop the sweep. At the end, if any step failed,
  `sync-all` exits non-zero and prints how many steps failed — check the
  `WARN` lines above that summary for which ones.
- **Not conflict-free for a live session.** `sync-all` has no equivalent
  of `handoff`'s stop-first step. If a session is actively being written
  to on either machine while `sync-all` runs, it just copies whatever
  bytes happen to be on disk at that instant — like `push`/`pull`, but
  without even the mtime-newer refusal (in `sync-all`, `-au` silently
  skips a file that's not newer rather than refusing and reporting it).
  Treat `sync-all` as a periodic broad backfill for sessions and docs that
  aren't actively in use right now, and use explicit `handoff`/`handback`
  for the one you're actively working.
- **Retention alignment.** Claude Code's own session-cleanup setting
  (`cleanupPeriodDays`) deletes old JSONLs locally after a period. If the
  two machines have different retention windows, `sync-all` can
  *resurrect* a session that was already cleaned up on one side — because
  `-au` only adds/updates and never deletes, the side that hasn't reached
  its cleanup window yet will simply copy the old file back. Keep
  retention settings aligned across machines if you rely on cleanup
  actually sticking, or manage retention manually.

### Verifying a sync

`claude-roam sync-extras <sid>` defaults to `to-remote` if you omit the
direction argument — pass `from-remote` explicitly to pull extras back the
other way.

`sync-extras` and `sync-all` both run rsync with `-v`, so every file that
actually gets transferred is listed in-band as it moves. An empty listing
(just the summary lines, no filenames) means nothing needed moving — the
two sides were already in sync — not that the command silently skipped
something. To double-check the remote side afterwards, get the remote
project path with `claude-roam project <sid> remote` and list it directly:

```bash
claude-roam project <sid> remote        # prints the remote project dir
ssh <remote> ls <that-path>/.claude/plans/
```

## Handing off the session you're currently running in

If the session you want to hand off is the one you're using *right now* to
talk to Claude, don't orchestrate the transfer from inside it: every
message written after the JSONL is read for the transfer — including a
final "handoff complete" report — appends to the file and effectively
forks it, because that content never makes it to the copy that gets
pushed. Instead, do the preparation (commit/push if consented, sync
extras) from within the session, then print the exact command for the
user to run **after exiting**:

```bash
claude-roam handoff <sid>
```

There is no way around this from inside the session itself — it's a
consequence of the JSONL being both what you're writing to and what's
being copied.
