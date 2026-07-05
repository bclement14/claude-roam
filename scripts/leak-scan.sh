#!/usr/bin/env bash
# Fail if any personal identifier appears in the repo. CI gate + pre-publish check.
#
# GENERIC (tracked, always runs): IPv4-looking addresses, email addresses, and
# real (non-example) home-dir paths under /Users or /home. `alice` is the
# documented example user throughout README/SKILL.md/docs, so it's excluded
# via a negative lookahead rather than treated as a leak.
#
# PERSONAL (untracked, optional): usernames, hostnames, private project
# names, and other author-specific strings do NOT belong in a published
# script — the pattern text itself would leak them. They live in
# scripts/leak-scan.local instead (gitignored — see .gitignore — and must
# never be committed). If present, it's read (not sourced: plain data, not
# executed) and OR-merged into the scan. Format: one extended-regex pattern
# per line; blank lines and lines starting with '#' are ignored.
set -euo pipefail
cd "$(dirname "$0")/.."

GENERIC='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|/Users/(?!alice\b)[a-z][a-z0-9_.-]+|/home/(?!alice\b)[a-z][a-z0-9_.-]+'

PATTERNS="$GENERIC"
LOCAL_FILE="scripts/leak-scan.local"
if [ -f "$LOCAL_FILE" ]; then
  LOCAL_PATTERNS=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ""|"#"*) continue ;; esac
    if [ -z "$LOCAL_PATTERNS" ]; then LOCAL_PATTERNS="$line"; else LOCAL_PATTERNS="$LOCAL_PATTERNS|$line"; fi
  done < "$LOCAL_FILE"
  if [ -n "$LOCAL_PATTERNS" ]; then
    PATTERNS="$PATTERNS|$LOCAL_PATTERNS"
  fi
fi

# Hits that are known-safe documentation examples are filtered out AFTER a
# successful match (not excluded from PATTERNS), so a real leak sharing a
# line with an example is still caught. Covers: RFC5737 example ranges,
# example.com/org, the documented example user/host, GitHub's noreply email
# domain, and the doc's own prefix-collision example (alice2).
ALLOW='203\.0\.113\.|192\.0\.2\.|198\.51\.100\.|example\.(com|org)|alice@|@myserver|users\.noreply\.github\.com|Users[/-]alice2'

# Exclude this file and the local pattern file: this file necessarily spells
# out the generic denylist as plain text to define it, and the local file
# necessarily contains the personal denylist as plain text — both would
# otherwise make the gate self-fail forever once committed. Neither file's
# CONTENT gets weaker as a result: the regexes above are untouched.
# -P (PCRE): \b is silently dead under git grep -E on Apple Git; lookaheads
# also require -P.
# git grep exit codes: 0 = match (leak!), 1 = no match (clean), >1 = error
# (e.g. PCRE not compiled in) — an error must NOT read as clean.
set +e
hits="$(git grep -nPI "$PATTERNS" -- . ':(exclude)scripts/leak-scan.sh' ':(exclude)scripts/leak-scan.local' 2>&1)"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  filtered="$(printf '%s\n' "$hits" | grep -vE "$ALLOW" || true)"
  if [ -n "$filtered" ]; then
    printf 'LEAK-SCAN FAILED — personal strings found:\n%s\n' "$filtered"
    exit 1
  fi
  echo "leak-scan clean (allowlisted example hits only)"
  exit 0
elif [ "$rc" -ne 1 ]; then
  printf 'LEAK-SCAN ERROR — git grep failed (rc=%s):\n%s\n' "$rc" "$hits"
  exit 2
fi
echo "leak-scan clean"
