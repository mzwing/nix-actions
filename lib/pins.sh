# shellcheck shell=bash
# The nixpkgs revision attic and rclone are fetched from, previously duplicated as `inputs.*.default` across four actions (which is how the caches in lib/caches.sh drifted).
# Pinned because these jobs run with max-jobs=0: a revision nobody has prebuilt turns a substitute into a failure instead of a local Rust or Go build.

# shellcheck disable=SC2034  # read by the scripts that source this.
CI_NIXPKGS_REV=2fcb964de67fcf60b43471c55d5d99e61a9ccb5a
