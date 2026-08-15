#!/bin/sh
# Nix post-build hook: enqueue built outputs for the drainer, never upload inline.
# Nix waits for this hook, so an inline upload would stall the build, and unbounded background pushes would flatten the single Attic server during a full rebuild.
# The spinlock is shared with the drainer so concurrent completions cannot interleave lines; a dropped enqueue is filled in later by store-cache/reconcile.
lock=/tmp/attic-spool.lock
attempt=0
while [ "${attempt}" -lt 20 ]; do
  if mkdir "${lock}" 2>/dev/null; then
    # OUT_PATHS is intentionally a shell word list supplied by Nix.
    # shellcheck disable=SC2086
    printf '%s\n' ${OUT_PATHS} >>/tmp/attic-spool
    rmdir "${lock}"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 0.2 2>/dev/null || sleep 1
done
exit 0
