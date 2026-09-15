#!/usr/bin/env bash
# Stage PATHS, commit as github-actions[bot], push, and optionally trigger another workflow.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

# PATHS is a space-separated list and must word-split.
# shellcheck disable=SC2086
git add -- ${PATHS}

if git diff --cached --quiet; then
  notice 'Nothing to commit.'
  exit 0
fi

git commit -m "${MESSAGE}"

# actions/checkout leaves the token in the remote's extraheader, so a plain push authenticates. It also checks out a detached HEAD, hence the explicit refspec.
git push origin "HEAD:${GITHUB_REF}"

[[ -n "${TRIGGER_WORKFLOW}" ]] || exit 0
gh workflow run "${TRIGGER_WORKFLOW}" --ref "${GITHUB_REF}"
