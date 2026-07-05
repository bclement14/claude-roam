# Setup

Everything in this doc happens once, before your first hand-off. See the
[README quickstart](../README.md#quickstart) for the shortest path; this
doc fills in the details.

## Prerequisites

### A key-based SSH alias

`claude-roam` never prompts for a password — it assumes an SSH alias with
key-based auth already works non-interactively. Add one to `~/.ssh/config`
on the machine you'll run `claude-roam` from:

```
Host myserver
    HostName 203.0.113.10
    User alice
    IdentityFile ~/.ssh/id_ed25519
```

Verify it works with no prompts before going any further:

```bash
ssh myserver true
```

If that asks for a password or a passphrase every time, fix that first
(`ssh-copy-id`, an `ssh-agent`, etc.) — `claude-roam` will otherwise hang or
fail in confusing ways.

### Claude Code on both sides

Install and run Claude Code at least once on **both** machines. Its first
run creates `~/.claude/projects/`, which is where `claude-roam` looks for
session files. There's nothing for `claude-roam` to find until that
directory exists.

### Mirrored `$HOME`-relative project paths

`claude-roam` translates the `$HOME` prefix of a project path automatically
(`/Users/alice/code/example-app` on a Mac becomes `/home/alice/code/example-app`
on Linux), but the part of the path **under** `$HOME` has to match on both
machines. If a project lives at `~/code/example-app` locally, it needs to
live at `~/code/example-app` on the remote too — not `~/projects/example-app`
or `~/work/example-app`. See [docs/internals.md](internals.md) for exactly
how the translation works.

### `~/.local/bin` on `PATH`

`./install.sh` symlinks the CLI to `~/.local/bin/claude-roam`. Make sure
that directory is on your `PATH` on both machines:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

(add this to your shell rc file so it persists).

### Dependencies

| Tool | Required? | Why |
|---|---|---|
| `ssh` | required | remote command execution |
| `rsync` | required | file transfer |
| `git` | required | `repo-status` / `repo-pull` |
| `find` | required | session lookup |
| `stat` | required | mtime/size comparison |
| `sort` | required | ordering `list`/`recent` output |
| `date` | required | formatting timestamps |
| `tmux` | optional | lets `handoff`/`handback` find and restart the remote `claude` pane automatically |
| `jq` or `python3` | recommended | robust parsing of the session's `cwd` out of the JSONL; without either, `claude-roam` falls back to a `grep`-based parser that can misread paths containing escape sequences |

`claude-roam doctor` checks all of these for you — see below.

## First-project bootstrap

Before the *first* hand-off for a given project, get the project itself
onto both machines at the same relative path — `claude-roam` moves
conversations and working docs, not code:

1. Clone (or create) the project at the same `$HOME`-relative path on both
   machines, e.g. `~/code/example-app` on both.
2. Launch Claude Code once in that directory on **each** machine. A brief
   session is enough — this is just to seed the
   `~/.claude/projects/<encoded-name>/` directory so `claude-roam` has
   somewhere to look.

Do this once per project, not once per session. Note that this bootstrap is
for *resuming* on the destination machine, not for the transfer itself:
`push`/`pull` create the remote encoded session directory automatically
(via `mkdir -p`) if it doesn't already exist, so the first transfer to a
never-before-seen project on the remote still works. What the bootstrap
buys you is a project directory that already exists at the matching path,
so `claude --resume <sid>` has somewhere to `cd` into once the session
lands there.

## Run `doctor` on both sides

```bash
claude-roam doctor
```

This checks the local machine — `bash` version, every required tool
listed above, the `rsync` version in use, whether `~/.claude/projects`
exists, whether `~/.local/bin` is on `PATH`, and whether a config file
exists — and prints one `ok` / `warn` / `FAIL` line per check. Only `FAIL`
lines make the command exit non-zero; `warn` lines are advisory (e.g. no
`tmux` just means `handoff` won't be able to restart a pane for you).

Once a remote is configured (via config, env, or flag), the same command
also checks the remote side over one SSH connection — remote tool
presence, remote `tmux`, remote `~/.claude/projects` — so you can confirm
both machines are ready without leaving your terminal:

```bash
claude-roam --remote myserver doctor
```

(If you've already set `CLAUDE_ROAM_REMOTE` in your config, plain
`claude-roam doctor` covers both sides at once — the `--remote` flag above
is only needed to check a different or not-yet-configured host.)

## First hand-off walkthrough

Once `doctor` passes on both sides:

```bash
claude-roam recent              # find a session id
claude-roam push <sid>          # copy it to the remote
```

Then, on the remote machine, in the matching project directory:

```bash
cd ~/code/example-app && claude --resume <sid>
```

That's the minimal JSONL-only path. For the full orchestrated flow —
committing the project repo first, restarting a tmux pane, syncing
gitignored working docs — see [docs/workflow.md](workflow.md).

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `session <sid> not found locally` | Typo, or wrong machine | `claude-roam recent` to verify |
| `session <sid> not found on remote` | Never pushed, or wrong remote | Push from the other side first |
| `remote is newer; pull first or pass --force` | Stale local copy | `pull`, or `--force` if you're sure |
| `local is newer; push first or pass --force to overwrite` | remote copy is stale (local has newer work) | `push`, or `--force` to overwrite local |
| `outside local/remote $HOME prefix` | Project isn't under `$HOME` | Needs manual handling — see [docs/caveats.md](caveats.md) |
| `Host key verification failed` | First-time SSH to that host | Run `ssh <remote>` interactively once to accept the host key |
| `command not found: claude-roam` | `~/.local/bin` not on `PATH` | `export PATH="$HOME/.local/bin:$PATH"` |
| an older/other `claude-roam` runs (stale help text, missing commands) | another copy earlier on `PATH` (e.g. a dotfiles-vendored one) | `which -a claude-roam`; `claude-roam doctor` prints which binary it is |
| `no remote configured` | No default remote set anywhere | Edit the config, set `CLAUDE_ROAM_REMOTE`, or pass `--remote` |
| `ambiguous session id` | Two projects contain the same session id | Resolve manually — see the file paths in the error |
