#!/usr/bin/env bash
# Delete the stale build lock files restored with the store.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

# Store paths can be named *.lock too, like a Cargo.lock that importCargoLock copied in; deleting a registered one leaves the database vouching for a file the next build cannot find.
find /nix/store -maxdepth 1 -name '*.lock' -print0 |
  xargs -0 -r nix-store --check-validity --print-invalid |
  xargs -r sudo rm --
