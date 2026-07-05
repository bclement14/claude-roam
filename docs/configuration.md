# Configuration

## Location

```
${XDG_CONFIG_HOME:-$HOME/.config}/claude-roam/config
```

`./install.sh` seeds this file from `examples/config.example` the first
time it runs, and never overwrites it on subsequent runs.

> **Trust boundary: this file is executable shell, not data.**
>
> `claude-roam` loads it with `. "$cfg"` — a plain shell `source`, not a
> parser. Anything written in it runs with your full user privileges the
> moment any `claude-roam` subcommand starts. Treat it exactly like a
> shell rc file: don't source a config you didn't write yourself, keep its
> permissions tight (`chmod 600`), and never let another user on a shared
> machine have write access to it. This isn't a theoretical concern to be
> "safe later" about — it's how the file is actually loaded.

## Reference

Every variable `claude-roam` reads from the config, with its default if
the config doesn't set it:

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `CLAUDE_ROAM_REMOTE` | string | *(unset)* | Default SSH host alias (from `~/.ssh/config`) used when no `--remote` flag or `CLAUDE_ROAM_REMOTE` env var is given. |
| `PROJECT_ROOTS` | array | `(code)` | `$HOME`-relative directories whose *immediate child directories* are project checkouts. `sync-all` scans these to find every project with a `.claude/` directory, on both sides. |
| `PROJECT_CLAUDE_EXTRAS` | array | `(plans reviews codebase-knowledge agent-memory agents skills)` | Subdirectories under each project's `.claude/` directory that `sync-extras`/`sync-all` carry between machines — gitignored working artifacts (specs, reviews, codebase notes, user-authored agents/skills). |
| `SESSION_DIR_EXTRAS` | array | `(memory)` | Subdirectories that live as siblings of a session's JSONL file (under its encoded project directory) that `sync-extras` carries along — e.g. the file-based auto-memory directory. (`sync-all`'s session phase already `rsync`s the whole encoded directory, so these travel implicitly there too — see [docs/internals.md](internals.md).) |
| `HOME_RELATIVE_EXTRAS` | array | `()` | `$HOME`-relative paths that sync unconditionally, independent of any particular session or project — e.g. `HOME_RELATIVE_EXTRAS=(code/dev-docs)`. Empty by default. |

Every path entry in the four array variables above is validated before
use:

- Must be relative (not starting with `/`) and not start with `-`.
- Must not contain `..`.
- Must not contain quote or shell-metacharacter characters (`'`, `` ` ``,
  `$`, `"`, `\`).
- Must not contain whitespace.

`CLAUDE_ROAM_REMOTE` (and the value passed to `--remote`) is validated
separately: it must be non-empty, must not start with `-`, and must not
contain whitespace or shell-metacharacter characters (including `;`). Any
violation causes `claude-roam` to exit immediately with a descriptive
error — invalid config values fail closed rather than being silently
ignored or half-applied.

## Precedence

When a command needs a remote host, `claude-roam` resolves it in this
order:

1. `--remote <host>` flag (highest priority — overrides everything for
   this one invocation)
2. `CLAUDE_ROAM_REMOTE` environment variable
3. `CLAUDE_ROAM_REMOTE` set in the config file
4. none of the above → error: `no remote configured: pass --remote <host>,
   set CLAUDE_ROAM_REMOTE, or edit <config path>`

**An empty environment variable counts as unset.** `CLAUDE_ROAM_REMOTE=`
(empty) does not override a value set in the config file — only a
non-empty env var does. This lets you leave `CLAUDE_ROAM_REMOTE` exported-
but-empty in a shell profile without it silently masking your config.

### Commands that need no remote at all

Not every command touches a remote, and these work with zero
configuration:

- `claude-roam recent`
- `claude-roam project <sid>` (local mode — the default; `project <sid>
  remote` does need a remote)
- `claude-roam repo-status <sid>`
- `claude-roam -h` / `--help`
- the local half of `claude-roam doctor` (it prints "no remote configured"
  for the remote half and simply skips it)

## `CLAUDE_ROAM_PROJECTS` / `CLAUDE_ROAM_REMOTE_PROJECTS`

Two more environment variables, set outside the config file (not inside
it — these override where `claude-roam` looks for the session-index
directory, not what remote it talks to):

| Variable | Overrides | Default |
|---|---|---|
| `CLAUDE_ROAM_PROJECTS` | local session-index root | `$HOME/.claude/projects` |
| `CLAUDE_ROAM_REMOTE_PROJECTS` | remote session-index root | `$RHOME/.claude/projects` |

These exist for testing (pointing `claude-roam` at a scratch directory
instead of your real session history) and for nonstandard installs where
Claude Code's project index lives somewhere other than the default. Most
users never need to set either.

`CLAUDE_ROAM_REMOTE_PROJECTS` composes with the `$HOME`-prefix translation
in [docs/internals.md](internals.md) rather than replacing it: the encoded
directory name (`translate_dir`'s output, e.g. `-home-alice-code-proj`) is
still computed the same way, the override just relocates the *root* it
lives under (e.g. `/mnt/scratch/claude-projects/-home-alice-code-proj`
instead of `$RHOME/.claude/projects/-home-alice-code-proj`). That makes it
safe to use for any nonstandard remote layout where the session index
lives outside `~/.claude/projects`, not just for tests.

## Multi-remote usage

The config file holds exactly one default remote. If you regularly work
with more than two machines:

- Use `--remote <host>` per invocation to target a machine other than the
  default for one command.
- `export CLAUDE_ROAM_REMOTE=<host>` for the duration of a shell session
  or script to change the default temporarily.
- If you juggle several machine pairs often enough that this gets
  tedious, consider always passing `--remote` explicitly in whatever
  wraps `claude-roam` for you (an alias, a script) rather than relying on
  the config default at all — the config's `CLAUDE_ROAM_REMOTE` is a
  convenience for the common single-remote case, not a multi-remote
  registry.

Because environment variables override the config file, tools like
[direnv](https://direnv.net) can set `CLAUDE_ROAM_REMOTE` per project
directory (e.g. in a project's `.envrc`), giving per-project default
remotes with no `claude-roam` support needed. For example, add `export
CLAUDE_ROAM_REMOTE=staging-server` to a project's `.envrc` and `direnv`
will automatically set it whenever you `cd` into that directory.
