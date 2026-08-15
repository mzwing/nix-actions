#!/usr/bin/env bash
# Clear the store cache family so the save that follows fits in the repository quota.
# Deleting here is safe: the entry is already restored onto this runner's disk, and a checkpoint is by construction a superset of the generation it was restored from.
# The only exposure is a failed upload leaving the family empty for one run, which is no worse than the eviction this replaces.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

[[ -n "${GH_TOKEN:-}" ]] || die 'GH_TOKEN is required, and the calling job needs actions:write permission.'

gh cache list --repo "${GITHUB_REPOSITORY}" --limit 100 \
  --json id,key,sizeInBytes \
  --jq ".[] | select(.key | startswith(\"${KEY_PREFIX}\")) | \"\(.id)\t\(.key)\t\(.sizeInBytes)\"" |
  while IFS=$'\t' read -r id key size; do
    notice "Freeing ${size} bytes held by \"${key}\"."
    gh cache delete --repo "${GITHUB_REPOSITORY}" "${id}" || warn "Could not delete cache entry \"${key}\"."
  done
