#!/usr/bin/env bash
# Minimal assertion harness. Source me from a test script.
T_PASS=0; T_FAIL=0

t_ok()   { T_PASS=$((T_PASS+1)); printf '  ok   %s\n' "$1"; }
t_fail() { T_FAIL=$((T_FAIL+1)); printf '  FAIL %s: %s\n' "$1" "$2"; }

# assert_eq <desc> <expected> <actual>
assert_eq() { if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1" "expected [$2] got [$3]"; fi; }
# assert_match <desc> <needle> <haystack>
assert_match() { case "$3" in *"$2"*) t_ok "$1" ;; *) t_fail "$1" "output [$3] lacks [$2]" ;; esac; }
# assert_rc <desc> <expected-rc> <actual-rc>
assert_rc() { if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1" "expected rc=$2 got rc=$3"; fi; }

t_summary() { printf '%d passed, %d failed\n' "$T_PASS" "$T_FAIL"; [ "$T_FAIL" -eq 0 ]; }
