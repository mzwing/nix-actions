#!/usr/bin/env bash
# Prepare the Attic subtree before any cache action touches it.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

# With nix:false the cache action extracts as the runner user rather than managing /nix permissions, so these are its only writable subtree.
sudo install -d -o "$(id -u)" -g "$(id -g)" "${DATA_DIR}" "${TEMP_DIR}" "${CHECKPOINT_DIR}"

# Attic blobs are write-once and the database is rebuilt every run, so btrfs copy-on-write and checksumming only amplify writes on the loop-backed pool.
sudo chattr +C "${DATA_DIR}" "${TEMP_DIR}" "${CHECKPOINT_DIR}"

# The runner resolves its temp directory before the job starts and forces that value onto cache action steps, so a per-step env override cannot move the multi-GiB tar/zstd staging off the tiny root filesystem that nothing-but-nix leaves behind.
# Swapping in a symlink works because the running step script stays readable through its already-open descriptor.
sudo rm -rf "${RUNNER_TEMP}"
sudo ln -s "${TEMP_DIR}" "${RUNNER_TEMP}"
