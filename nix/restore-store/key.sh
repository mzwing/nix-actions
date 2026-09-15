#!/usr/bin/env bash
# Derive the store cache key from whichever of the shared lock files this repository has.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

present=()
# LOCK_FILES is a space-separated list and must word-split.
# shellcheck disable=SC2086
for file in ${LOCK_FILES}; do
  if [[ -f "${file}" ]]; then
    present+=("${file}")
  fi
done

((${#present[@]})) || die "This repository has none of the lock files: ${LOCK_FILES}"

notice "Keying the store cache on: ${present[*]}"

# The names are hashed alongside the contents, so adding an empty lock file still changes the key.
digest="$({
  printf '%s\n' "${present[@]}"
  cat "${present[@]}"
} | shasum -a 256 | cut -d' ' -f1)"

emit_output key "${KEY_PREFIX}-${digest}"
