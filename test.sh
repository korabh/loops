#!/usr/bin/env bash
set -uo pipefail
shopt -s nullglob

cd "$(dirname "$0")" || exit 1
failed=""
for t in plugins/*/tests/*.test.sh; do
  printf '== %s\n' "$t"
  bash "$t" || failed="$failed $t"
done
if [ "${1:-}" = --app ]; then
  printf '== app\n'
  (cd app && swift test) || failed="$failed app"
fi
if [ -n "$failed" ]; then
  printf '\nfailed:%s\n' "$failed"
  exit 1
fi
printf '\nevery test passed\n'
