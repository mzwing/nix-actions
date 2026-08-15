#!/usr/bin/env bash
# Bounded uploader for the post-build hook's spool: one Attic process per builder, pushing in batches.
# Runs until store-cache/reconcile asks for a final flush, so late hook uploads never overlap its own batched pushes.
set -uo pipefail

export XDG_CONFIG_HOME=/etc
attic_bin="$(cat /etc/attic/attic-bin)"
cache="$(cat /etc/attic/cache)"
spool=/tmp/attic-spool
lock=/tmp/attic-spool.lock
batch_size=128

touch "${spool}"
while true; do
  drain=0
  [[ -e /tmp/attic-drain-request ]] && drain=1

  batch="$(mktemp /tmp/attic-batch.XXXXXX)"
  for _ in $(seq 50); do
    mkdir "${lock}" 2>/dev/null && break
    sleep 0.2
  done
  cat "${spool}" >>"${batch}"
  : >"${spool}"
  rmdir "${lock}" 2>/dev/null || true

  if [[ ! -s "${batch}" ]]; then
    rm -f "${batch}"
    if ((drain)); then
      touch /tmp/attic-drain-done
      exit 0
    fi
    sleep 2
    continue
  fi

  sort -u -o "${batch}" "${batch}"
  split -l "${batch_size}" "${batch}" "${batch}.part."
  for part in "${batch}".part.*; do
    for _ in 1 2 3; do
      "${attic_bin}" push --stdin --no-closure --jobs 4 "${cache}" <"${part}" && break
      sleep 2
    done
    rm -f "${part}"
  done
  rm -f "${batch}"
done
