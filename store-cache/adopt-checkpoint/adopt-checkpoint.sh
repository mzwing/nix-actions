#!/usr/bin/env bash
# Promote a restored checkpoint over the restored finalized generation.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

if [[ -s "${CHECKPOINT_DIR}/server.db" ]]; then
  rsync -a "${CHECKPOINT_DIR}/" "${DATA_DIR}/"
  notice 'Adopted a mid-run checkpoint Attic generation.'
fi

# /nix is root-owned, so only the runner-owned contents go; the directory itself stays for the later save.
find "${CHECKPOINT_DIR}" -mindepth 1 -delete
