#!/bin/sh
# Nix waits for this hook, so it only enqueues; after 10 s of contention it drops the paths, and the flush re-offers every built target
lock=/tmp/firn-spool.lock
attempt=0
while [ "${attempt}" -lt 50 ]; do
  if mkdir "${lock}" 2>/dev/null; then
    # shellcheck disable=SC2086
    printf '%s\n' ${OUT_PATHS} >>/tmp/firn-spool
    rmdir "${lock}"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 0.2
done
