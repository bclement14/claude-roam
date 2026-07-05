# Vendoring claude-roam from a personal dotfiles repo

If you already keep a personal dotfiles repo that bootstraps a new
machine, you can vendor `claude-roam` into it as a git submodule instead
of installing it separately on each machine — your dotfiles installer
sets it up alongside everything else.

## Add the submodule

```bash
git submodule add https://github.com/<you>/claude-roam vendor/claude-roam
```

Replace `<you>` with wherever you host your copy of this repo — your own
fork, an internal mirror, or the upstream project. Commit the resulting
`.gitmodules` change and the new `vendor/claude-roam` gitlink along with
your other dotfiles changes.

## Hard-fail if the submodule isn't initialized

A dotfiles repo can be cloned by someone (including future you, on a new
machine) without `--recurse-submodules`, leaving `vendor/claude-roam`
present but empty. Guard against silently skipping the whole integration
by failing loudly instead:

```bash
DOTFILES="$HOME/.dotfiles"   # wherever your dotfiles repo lives

git -C "$DOTFILES" submodule update --init vendor/claude-roam || exit 1
```

This both initializes the submodule on a fresh clone and verifies an
already-initialized one is actually populated — either way, a non-zero
exit here means don't proceed with the rest of the installer.

## Link the vendored CLI and skill

Once the submodule is populated, point the same locations `claude-roam`'s
own `install.sh` uses at the vendored copy instead of copying it:

```bash
mkdir -p "$HOME/.local/bin" "$HOME/.claude/skills"
ln -sfn "$DOTFILES/vendor/claude-roam/bin/claude-roam"   "$HOME/.local/bin/claude-roam"
ln -sfn "$DOTFILES/vendor/claude-roam/skill/claude-roam" "$HOME/.claude/skills/claude-roam"
```

This is exactly what `vendor/claude-roam/install.sh` does on its own, so
if your dotfiles installer doesn't need to own these symlinks itself, you
can just call it directly instead of duplicating the two `ln` lines above:

```bash
"$DOTFILES/vendor/claude-roam/install.sh"
```

## Write the personal config once, never overwrite it

`CLAUDE_ROAM_REMOTE` and any extras lists you configure are personal to
each machine (a laptop's remote alias for its server isn't the same as the
server's, if it even needs one). Seed the config file only if it doesn't
already exist — the same idempotent check `install.sh` uses:

```bash
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-roam"
CFG="$CFG_DIR/config"
if [ ! -f "$CFG" ]; then
  mkdir -p "$CFG_DIR"
  cp "$DOTFILES/vendor/claude-roam/examples/config.example" "$CFG"
  echo "seeded $CFG — edit CLAUDE_ROAM_REMOTE"
fi
```

Re-running your dotfiles installer (to pick up an unrelated update, say)
must never overwrite a config you've since edited by hand — that's why
this checks for the file's existence rather than always copying. Calling
`vendor/claude-roam/install.sh` directly gets you this same guarantee for
free, since it performs the identical check internally.

## Cloning your dotfiles onto a new machine (submodule already committed)

On a brand new machine, clone your dotfiles with submodules in one step:

```bash
git clone --recurse-submodules <your-dotfiles-url> ~/.dotfiles
```

If you (or your installer) forgot the flag on an existing clone:

```bash
git -C ~/.dotfiles submodule update --init --recursive
```

Either way, run your dotfiles installer afterward so the hard-fail check
above catches an empty submodule directory rather than silently
continuing without `claude-roam` installed.

## See also

- [../README.md](../README.md) — what `claude-roam` does and the full
  command list
- [../docs/setup.md](../docs/setup.md) — prerequisites and first-project
  bootstrap, independent of how it got installed
- [../docs/configuration.md](../docs/configuration.md) — everything in
  the config file
- [../install.sh](../install.sh) — the standalone installer this doc
  mirrors
