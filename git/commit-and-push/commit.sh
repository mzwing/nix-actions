#!/usr/bin/env bash
# Stage PATHS and commit as github-actions[bot], reporting whether anything changed.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

# PATHS is a space-separated list and must word-split.
# shellcheck disable=SC2086
git add -- ${PATHS}

if git diff --cached --quiet; then
  emit_output changed false
  exit 0
fi

git commit -m "${MESSAGE}"
emit_output changed true
