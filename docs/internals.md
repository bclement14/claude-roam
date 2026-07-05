# Internals

This doc explains the mechanics behind the commands in
[docs/workflow.md](workflow.md) — useful if something behaves unexpectedly
and you want to know why, or if you're reading the source.

## Encoded project directory names

Claude Code stores each project's sessions under an *encoded* form of the
project's absolute path, with `/` replaced by `-`:

```
/Users/alice/code/example-app  ->  -Users-alice-code-example-app
```

`claude-roam` reproduces this encoding itself (it has to, in order to find
the matching directory on the other machine) — see `encode_path()` in
`bin/claude-roam`.

### The `$HOME`-prefix translation rule

Because the encoded name embeds the full absolute path, the same project
checked out under different home directories on two machines produces two
different encoded names:

```
/Users/alice/code/example-app  ->  -Users-alice-code-example-app   (Mac)
/home/alice/code/example-app   ->  -home-alice-code-example-app    (Linux)
```

`claude-roam` translates between these by finding each machine's own
`$HOME`, encoding *that*, and swapping the prefix — so it only needs to
know each side's home directory, not have any project-specific
configuration. This is also why the part of the path **under** `$HOME` has
to match on both machines (see [docs/setup.md](setup.md)): translation
only rewrites the home-directory prefix, nothing after it.

**Prefix-collision guard:** the match isn't a plain substring check.
`-Users-alice` must match exactly, or be followed immediately by another
`-`, before it's treated as a prefix. Without this, encoding
`/Users/alice2/...` (`-Users-alice2-...`) would wrongly be recognized as
starting with the `-Users-alice` prefix and get mistranslated. This
matters most on shared or multi-account machines where home directory
names can be prefixes of each other.

If a project lives outside `$HOME` entirely on either side, translation
refuses outright ("outside local/remote `$HOME` prefix") rather than
guessing.

## Session names live inside the JSONL, not alongside it

A session's display name/title isn't a separate metadata file —
Claude Code records it as entries inside the session's own JSONL stream
(records such as `custom-title` and `agent-name`). Because `claude-roam`
copies the whole JSONL file, the name travels with it automatically. There
is no second sync step needed to keep a session's name consistent between
machines, and no separate index file for `claude-roam` to keep in sync.

## Newer-side comparison

Before `push`/`pull`/`handoff` transfers a JSONL, both copies are compared
by mtime and size (`compare_mtimes()` in `bin/claude-roam`):

| Result | Meaning |
|---|---|
| `local-missing` / `remote-missing` | one side genuinely doesn't have the file yet (the stat succeeded and reported absence) |
| `remote-unknown` | the remote stat itself failed (ssh/network) — the remote state is unknown, so `push`/`pull`/`handoff` **refuse** rather than treat it as "missing" and overwrite |
| `local-newer` / `remote-newer` | mtimes differ; the newer side is presumed authoritative |
| `equal` | same mtime and same size — nothing to resolve |
| `diverged` | same mtime, **different** size — both sides written independently; refuses without `--force` |

mtime and size are read locally with `stat` (GNU `stat -c` first, BSD
`stat -f` as a fallback) and on the remote in a single SSH round trip that
returns both numbers together, so the comparison never straddles a race
between two separate remote calls.

### The size-shrink guard (clock skew and forks)

The `local-newer`/`remote-newer` verdict trusts the two machines' clocks.
Two independent clocks can disagree, and `diverged` only catches the narrow
case of an exact same-second mtime tie — so a genuine fork with differing
mtimes, or a copy that *looks* newer only because one clock runs ahead,
would otherwise win and silently overwrite real work.

Session JSONLs are append-mostly and only grow. So on top of the mtime
verdict, `push`/`pull` apply a direction-aware guard: **they refuse to
overwrite a larger destination file with a smaller source file** (pass
`--force` to override). A shrink is a strong signal that the mtime verdict
was inverted by clock skew, or that the two copies forked. This does not
require the clocks to agree — it only assumes transcripts don't shrink.

## Why `rsync -au` never deletes or overwrites a newer file

Every extras/`sync-all` transfer uses `rsync -a -u`:

- `-a` ("archive") copies recursively and preserves permissions, times,
  symlinks, etc. — the standard "faithful copy" flag.
- `-u` ("update") skips any file that is newer on the receiving side, so a
  sync never clobbers a change made there since the last sync.

Neither flag implies `--delete`, and `claude-roam` never passes it: a file
removed from the source directory is simply left alone on the destination.
This is a deliberate one-directional add/update semantics, not a full
two-way merge — it's what makes repeated `sync-all` runs safe to run
opportunistically without a lock, at the cost of never being able to
propagate a deletion (see the retention-alignment caveat in
[docs/workflow.md](workflow.md) and [docs/caveats.md](caveats.md)).

## Remote command transport: `bash -s --` with quoted argv

Commands that need to run something on the remote (`remote_sh()` in
`bin/claude-roam`) send the script body over `stdin`, not as part of the
command line:

```bash
printf '%s' "$script" | ssh "$REMOTE" "bash -s --$quoted_args"
```

`bash -s` tells the remote bash to read its script from stdin; `--` marks
the end of options so everything after it becomes the script's positional
parameters (`$1`, `$2`, …) rather than being reinterpreted as more shell
syntax. Each argument is individually escaped with POSIX single-quote
escaping (`shq()`: replace `'` with `'\''`, then wrap the whole thing in
single quotes) before being appended to the one string that *is* passed on
the command line — so a value containing spaces, quotes, or shell
metacharacters still arrives on the remote as one exact, unmangled
argument, rather than being re-parsed as shell syntax by the remote shell.
The script text itself, by contrast, is never built by interpolating
untrusted values into it — only fixed script bodies are piped over stdin,
with all variable data passed as quoted positional arguments.

## One-SSH remote resolution

`require_remote()` runs at most once per invocation: it resolves which
remote alias to use (flag, then env, then config — see
[docs/configuration.md](configuration.md)), then makes exactly one SSH
round trip (`ssh "$REMOTE" 'printf %s "$HOME"'`) to learn the remote's home
directory. That value is cached for the rest of the run, so a command like
`sync-all` — which needs the remote home directory repeatedly — never
re-resolves it or opens a second connection just to ask again.
