#!/usr/bin/env bash
# Stage a consistent mid-run snapshot of the live Attic generation.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../attic-state.sh
. "${here}/../attic-state.sh"

require_positive_int timeout-minutes "${TIMEOUT_MINUTES}"

signalled() { [[ -e /tmp/cache_checkpoint || -e /tmp/cache_done ]] || ! attic_running; }
ci_wait_until "$((TIMEOUT_MINUTES * 60))" 20 'a checkpoint signal' signalled || true

if [[ -e /tmp/cache_done ]] || ! attic_running; then
  notice 'The run is already finishing; leaving the final save to store-cache/finalize.'
  emit_output checkpoint-ready false
  exit 0
fi

if [[ "${STAGE}" != 'true' ]]; then
  notice 'Signalled; the caller persists the live directory itself.'
  emit_output checkpoint-ready true
  exit 0
fi

count="$(attic_object_count "${DATA_DIR}/server.db")"
previous="$(cat "${ATTIC_CHECKPOINT_COUNT_FILE}" 2>/dev/null || echo -1)"
if [[ "${count}" == "${previous}" ]]; then
  notice "Attic object count unchanged (${count}); skipping this checkpoint round."
  emit_output checkpoint-ready false
  exit 0
fi

notice "Staging mid-run Attic snapshot (${count} objects, previously ${previous})..."
find "${CHECKPOINT_DIR}" -mindepth 1 -delete
# Online backup plus hardlinks: the storage tree is write-once, so the snapshot costs no extra space and cannot tear.
sqlite3 "${DATA_DIR}/server.db" ".backup '${CHECKPOINT_DIR}/server.db'"
cp -al "${DATA_DIR}/storage" "${CHECKPOINT_DIR}/storage"
printf '%s\n' "${count}" >"${ATTIC_CHECKPOINT_COUNT_FILE}"
emit_output checkpoint-ready true
notice "Checkpoint staged: $(du -sh "${CHECKPOINT_DIR}" | cut -f1)."
