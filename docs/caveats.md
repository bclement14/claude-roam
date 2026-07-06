# Caveats

Honest limits, in prose. If you're deciding whether `claude-roam` fits
your setup, read this before you rely on it.

## Advisory locking, not real locking

Every transfer checks mtime/size before it runs and refuses if the
destination looks newer or has diverged (see
[docs/internals.md](internals.md)). That check is **advisory**: it only
looks at the file, not at whether a process is currently writing it.
Nothing stops you from running `claude --resume <sid>` on both machines
against the same session at the same time.

If you do that, each side appends to its own copy of the JSONL
independently. There is no merge — you get two diverging conversation
histories (a fork). The mtime check would let whichever copy you transfer
later win; the **size-shrink guard** (see
[docs/internals.md](internals.md)) is the backstop that catches the common
case, because it refuses to overwrite a larger transcript with a smaller
one without `--force`. But it is only a heuristic — the real fix is
procedural: stop the session on one side (`handoff`/`handback` already do
this for you) before resuming it on the other.

## `--force` stashes the clobbered copy first

A `--force` overwrite is the one destructive operation in the tool. Before
it replaces an existing destination file, that file is copied to
`~/.claude/roam-backups/<sid>.<timestamp>.jsonl` on the side being
overwritten — locally for `pull --force`, on the remote for `push --force`
— so the losing copy is always recoverable. Backups older than 30 days are
pruned automatically. The stash is best-effort: if it fails you get a
warning, but the forced transfer still proceeds.

## Clock skew between machines

The `local-newer`/`remote-newer` verdict compares the two machines' clocks
with no tolerance. If one clock runs ahead (a misconfigured timezone,
drifting NTP, a sleeping laptop), a copy can look "newer" when it isn't.
The size-shrink guard limits the damage — a wrong-direction overwrite that
would shrink the destination is refused — but if you care about ordering,
keep both machines on NTP. `claude-roam doctor` does not check clock sync;
`date +%s` on both sides will show any offset.

## When the remote can't be read

If the ssh/stat that inspects the remote copy fails (network drop, host
down), `claude-roam` reports `remote-unknown` and **refuses** the transfer
rather than assuming the remote file is absent. This is deliberate:
treating an unreachable remote as "missing" is the one reading that leads
to a silent overwrite. Check connectivity and retry.

## Hub-and-spoke topology

`claude-roam` must run on the machine that can SSH out — the "local" side
of every command. There's no reverse channel: a remote/server box can't
push a session back to your laptop on its own initiative, because
`claude-roam` doesn't assume (and doesn't set up) a reverse tunnel. If
you're sitting at the remote machine and want to send a session back, the
command still has to be run from the machine that can reach out via SSH —
switch to it, or ask whoever's there to do it. This also means
`claude-roam` isn't a mesh sync between three or more machines by default;
each pair needs its own reachable-from direction.

## Secrets travel with sessions

A session's JSONL is a transcript of the whole conversation, including
whatever was typed, pasted, read from files, or returned by tool calls
during it. That can include credentials, tokens, private file contents —
anything that ended up in the conversation. Moving a session moves all of
that too, onto whatever machine you pushed or pulled it to.

**Never commit or publish a session JSONL, or `~/.claude/projects/` in
general.** Treat it the way you'd treat a shell history file or a
credentials cache — useful locally, not something to check into a
repository or share outside the machines it's meant to live on.

## Retention alignment

Claude Code's own session-cleanup setting (`cleanupPeriodDays`) deletes
old session JSONLs locally after a configured number of days. If your two
machines have different retention windows, `sync-all` can *resurrect* a
session that was already cleaned up on one machine: because `rsync -au`
only adds or updates files and never deletes them, the machine that
hasn't reached its own cleanup window yet will simply copy the "deleted"
file back the next time you run `sync-all`. If you rely on cleanup
actually sticking, keep the retention window the same on both machines —
or manage cleanup of old sessions manually instead.

## `rsync` variants

`rsync` itself isn't one consistent implementation across the platforms
`claude-roam` targets:

- Older macOS still ships `rsync` 2.6.9 (ancient, GPLv2-licensed, missing
  many modern flags).
- Newer macOS ships Apple's `openrsync` — a from-scratch rewrite with its
  own, different, flag support.
- Linux distributions typically ship `rsync` 3.x, the feature-rich
  upstream version.

`claude-roam` deliberately sticks to a small, conservative flag set (`-a`,
`-u`, `--progress`) that behaves the same way across all three, rather
than depending on anything (checksums, filters, `--info=progress2`, etc.)
that doesn't exist — or behaves differently — on one of them. `doctor`
prints the detected `rsync --version` line on both sides so you can see
what you're actually running.

## `tmux` pane discovery is process-tree-based, and can miss

`handoff`/`handback`'s automatic pane restart works by finding the process
running `claude --resume <sid>` on the remote (`pgrep`), then walking up
its parent-process chain until it finds one owned by a `tmux` pane
(`tmux list-panes -a`). This works reliably for the common case — a
session started directly in a tmux pane — but it can fail to find a pane
if the session was started outside `tmux` entirely, if the tmux server
that owned it has since been killed, or in other process-tree edge cases.
When no pane is found, `handoff`/`handback` still do everything else (push
the JSONL, pull the repo, sync extras) — they just leave you to run
`claude --resume <sid>` yourself instead of restarting it for you.

## macOS remotes: stale tmux argv can make handoff refuse

Pane discovery matches processes with `pgrep -f 'claude --resume <sid>'`.
On a **macOS remote**, when a tmux session was created with an inline
command (e.g. `tmux new-session -d 'claude --resume <sid>'`), the tmux
server process itself can carry that command line in its argv — and on
macOS it keeps matching the `pgrep -f` pattern even after the claude
inside has exited. Discovery then sees a "match" that maps to no pane
and reports `NOTMUX` (or the stop wait times out), so
`handoff`/`handback` **refuse**. The refusal is fail-closed — nothing
is stopped or restarted, so it is never unsafe — but it can decline a
handoff that would actually have been fine. Linux remotes are
unaffected. If you hit this on a macOS remote, clear the stale match
first (kill the leftover tmux session or window that was created with
the inline command), or stop the remote session yourself and re-run
with `--no-stop`.

## Tool-call paths inside the JSONL are not rewritten

The `$HOME`-prefix translation in [docs/internals.md](internals.md) only
applies to the *directory naming* `claude-roam` uses to find and place
session files — it does not rewrite anything inside the JSONL's content.
Tool call outputs recorded in old messages keep their original absolute
paths (e.g. `/Users/alice/code/example-app/notes.md`). Resuming still
works — those paths are just inert text in the history — but the model
can't use them to re-open or re-read a file at that exact path if it
doesn't exist under that name on the new machine.

## Paths outside a conservative safe character set are rejected by design

Any path that gets embedded in an `ssh`/`rsync` command line is checked
against a deliberately narrow set of allowed characters before use. A
path is refused if it:

- is empty, or is not absolute
- contains a quote or backslash character (`'`, `` ` ``, `$`, `"`, `\`)
- contains a shell metacharacter (`;`, `&`, `|`, `(`, `)`, `<`, `>`)
- contains a glob character (`[`, `]`, `{`, `}`, `*`, `?`)
- contains whitespace

This isn't an oversight to be relaxed later — `rsync`'s remote operands
pass through the remote shell on the way in, and quoting them reliably
across the `rsync`/`openrsync`/`ssh`/shell combinations `claude-roam`
targets isn't something that can be done portably. Refusing outright is
safer than attempting a quoting scheme that might work on one platform and
silently misbehave on another. In practice, this means: **project paths
containing spaces or shell-special characters aren't supported.** If one
of your projects lives at a path like that, you'll need to rename it, move
it, or sync that project's files manually rather than through
`claude-roam`.
