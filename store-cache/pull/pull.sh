#!/usr/bin/env bash
# Restore the persisted Attic generation from the rclone remote.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../rclone.sh
. "${here}/../rclone.sh"

require_positive_int transfers "${RCLONE_TRANSFERS}"
require_positive_int timeout-minutes "${RCLONE_TIMEOUT_MINUTES}"
rclone_setup

install -d "${DATA_DIR}/storage"

# A first run, or one after the remote was cleared, simply starts cold.
if ! ci_rclone lsf --max-depth 1 "${REMOTE}" >/dev/null 2>&1; then
  warn "No generation at ${REMOTE} yet; starting from an empty cache."
  emit_output pulled false
  exit 0
fi

# copy, not sync: the local side is a fresh runner and therefore empty, so there is nothing to mirror away, and copy can never delete.
group 'Pulling NAR storage'
ci_rclone copy "${REMOTE}/storage" "${DATA_DIR}/storage"
endgroup

# The database is fetched last so a torn pull leaves NARs without a database rather than a database referencing NARs that never arrived.
if ci_rclone lsf "${REMOTE}/server.db" >/dev/null 2>&1; then
  ci_rclone copyto "${REMOTE}/server.db" "${DATA_DIR}/server.db"
else
  warn 'The remote has NAR storage but no database; Attic will rebuild one and the orphans get reaped at shutdown.'
fi

notice "Pulled generation: $(du -sh "${DATA_DIR}" | cut -f1) across $(find "${DATA_DIR}/storage" -type f | wc -l) objects."
emit_output pulled true
