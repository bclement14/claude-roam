# claude-roam

Move a Claude Code session — and the working docs that go with it — between
machines. A small bash CLI plus a skill that teaches Claude Code how to use it.

## The problem

Claude Code sessions are recorded as JSONL transcript files under
`~/.claude/projects/`, keyed to the machine they were started on. If you
start a long-running conversation on your laptop and then sit down at a
server (or vice versa), there is no built-in way to keep talking to the same
session — you'd have to start over. `claude-roam` copies the session file
(and its related working docs) to the other machine so `claude --resume
<session-id>` picks up exactly where you left off.

It moves **one session at a time, on purpose** — this is a deliberate
hand-off tool, not a background sync daemon. See
[docs/workflow.md](docs/workflow.md) for why.

## The three-layer mental model

`claude-roam` only ever handles one of three layers that make up a project.
The other two are handled by tools you already use:

| Layer | What it is | Moved by |
|---|---|---|
| Code | The repo itself — source files, commits | `git` (push/pull) |
| Conversations | The Claude Code session transcript (JSONL) | `claude-roam` (`push`/`pull`/`handoff`/`handback`) |
| Working docs | Gitignored per-project artifacts: plans, reviews, notes, memory | `rsync -au` (via `claude-roam sync-extras` / `sync-all`) |

Keeping these separate is deliberate: git already has a merge model for
code, so `claude-roam` doesn't try to reinvent one. The session JSONL and
the gitignored working docs get a much simpler update-only rsync, because
there's no merge model for a conversation transcript — only "which copy is
newer."

## Quickstart

Run these on the machine you'll call the "local" side (the one that can SSH
out to the other machine — see [hub-and-spoke](#honest-limits) below).

```bash
# 1. Get the code and install (the CLI + the Claude Code skill that teaches it)
git clone https://github.com/<you>/claude-roam ~/code/claude-roam
cd ~/code/claude-roam
./install.sh

# 2. Point it at your other machine
#    (install.sh seeds ~/.config/claude-roam/config for you — edit it)
$EDITOR ~/.config/claude-roam/config
#    set: CLAUDE_ROAM_REMOTE="myserver"   (an alias from ~/.ssh/config)
#    the same config also holds PROJECT_ROOTS and the extras arrays that
#    drive sync-extras/sync-all — see docs/configuration.md for the full reference

# 3. Check both sides are ready
claude-roam doctor

# 4. Find a session to move
claude-roam recent

# 5. Push it to the remote
claude-roam push <sid>
```

`claude-roam recent` prints one line per session: a timestamp, the session
id, and the full path to its JSONL file, e.g.:

```text
2026-07-05 06:20  4f2a9c1e-88b3-4a2f-9c11-2b7e6d4f2a9c  /Users/alice/.claude/projects/-Users-alice-code-example-app/4f2a9c1e-88b3-4a2f-9c11-2b7e6d4f2a9c.jsonl
2026-07-04 19:03  9b1d2e77-4a3f-4c9a-8e21-0f6a5b3c7d02  /Users/alice/.claude/projects/-Users-alice-code-other-app/9b1d2e77-4a3f-4c9a-8e21-0f6a5b3c7d02.jsonl
```

`<sid>` is the middle column — printed as its own token, so you can copy it
directly without pulling it out of the path.

Then, on the remote machine:

```bash
cd ~/code/example-app && claude --resume <sid>
```

`~/code/example-app` is whatever project directory that session was recorded
under (see `claude-roam project <sid>` if you're not sure). For anything
beyond a one-off push/pull — committing the repo first, restarting a remote
tmux pane, syncing working docs — see [docs/workflow.md](docs/workflow.md).

## Commands

```text
claude-roam recent [n]               list n local sessions (default 10)
claude-roam list   [n]               list n remote sessions (default 30)
claude-roam push   <sid>             local  -> remote (JSONL only)
claude-roam pull   <sid>             remote -> local (JSONL only)
claude-roam handoff  <sid>           stop remote claude + push JSONL + git pull on remote
                                      + sync extras + restart claude in same tmux pane
claude-roam handback <sid>           stop remote claude + pull JSONL + sync extras
claude-roam project  <sid> [remote]  print the session's local (or remote) cwd
claude-roam repo-status <sid>        git status of the local project (if a repo)
claude-roam repo-pull   <sid>        git pull --ff-only on the remote project dir
claude-roam sync-extras <sid> [to-remote|from-remote]
                                      rsync gitignored working dirs for one project/session
claude-roam sync-all [both|to-remote|from-remote]
                                      blanket sweep: all sessions + per-project .claude
                                      extras (allowlist) + home extras
claude-roam doctor                   check prerequisites (local, and remote if configured)
```

| Flag | Effect |
|---|---|
| `--remote <host>` | Override the configured remote for this run |
| `--force` | Skip the newer-side mtime/size check |
| `--no-extras` | Skip the `sync-extras` step inside `handoff` / `handback` |
| `--no-stop` | `handback`: don't stop a running remote claude first |
| `-h`, `--help` | Show usage |

`--force` always overwrites the **destination** of the command you ran:
`push --force` overwrites the remote copy, `pull --force` overwrites the
local copy.

## Honest limits

- **Advisory locking, not real locking.** `claude-roam` compares mtimes
  before transferring and refuses if the other side looks newer or
  diverged, but nothing stops two `claude` processes from running against
  the same session id on both machines at once. Do that and you'll fork
  the session's history. Stop one side before working the other.
- **Hub-and-spoke, not mesh.** `claude-roam` must be run from the machine
  that can SSH out. There's no reverse tunnel — a remote/server box can't
  push a session back to your laptop on its own; someone has to run
  `claude-roam pull` from the laptop.
- **Paths with spaces (or shell metacharacters) aren't supported.**
  Project paths are validated against a conservative safe character set
  before they're used in any ssh/rsync command; anything outside it is
  refused rather than risked. See [docs/caveats.md](docs/caveats.md).
- **Sessions can contain secrets.** A session transcript can include
  anything that was typed, pasted, or read into it — tokens, credentials,
  private file contents. Moving a session moves that too. Never commit or
  publish a session JSONL (or `~/.claude/projects/` in general).

## Supported platforms

macOS and Linux, using the system `bash` (>= 3.2 — including macOS's stock
`/bin/bash`; no bash 4+ features are used). Requires `ssh`, `rsync`, `git`,
`find`, `stat`, `sort`, `date`. `tmux` is optional (enables the automatic
pane restart in `handoff`/`handback`); `jq` or `python3` is recommended for
robust session-metadata parsing. Run `claude-roam doctor` to check all of
this on both machines at once.

## Documentation

- [docs/setup.md](docs/setup.md) — prerequisites, first-project bootstrap, troubleshooting
- [docs/workflow.md](docs/workflow.md) — the handoff/handback/sync-all workflows in detail
- [docs/internals.md](docs/internals.md) — how it works under the hood
- [docs/configuration.md](docs/configuration.md) — full config reference
- [docs/caveats.md](docs/caveats.md) — everything it doesn't handle, and why
- [examples/dotfiles-integration.md](examples/dotfiles-integration.md) — vendoring `claude-roam` into a personal dotfiles repo
