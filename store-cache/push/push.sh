#!/usr/bin/env bash
# Persist the Attic generation to the rclone remote.
#
# The order is what keeps the remote consistent under an interrupted push: new NARs go up first, then the database, then deletions.
# Dying partway can therefore only leave the remote with NARs nothing references, which the next run's shutdown pruning reaps. It can never leave a database pointing at objects that were never uploaded.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../rclone.sh
. "${here}/../rclone.sh"

require_positive_int transfers "${RCLONE_TRANSFERS}"
require_positive_int timeout-minutes "${RCLONE_TIMEOUT_MINUTES}"
require_positive_int max-delete "${MAX_DELETE}"
require_file 'the Attic data directory' "${DATA_DIR}"
rclone_setup

group 'Uploading new NARs'
ci_rclone copy "${DATA_DIR}/storage" "${REMOTE}/storage"
endgroup

# Swap the database in through a rename so a reader never observes a half-written one.
if [[ -s "${DATA_DIR}/server.db" ]]; then
  ci_rclone copyto "${DATA_DIR}/server.db" "${REMOTE}/server.db.incoming"
  ci_rclone moveto "${REMOTE}/server.db.incoming" "${REMOTE}/server.db"
  notice "Database published ($(du -h "${DATA_DIR}/server.db" | cut -f1))."
else
  warn 'No database to publish; leaving the remote one in place.'
fi

if [[ "${PRUNE}" == 'true' ]]; then
  group 'Pruning objects dropped at shutdown'
  ci_rclone sync "${DATA_DIR}/storage" "${REMOTE}/storage" --max-delete "${MAX_DELETE}"
  endgroup
else
  notice 'Additive push; deletions are left for the finalizing push.'
fi

notice "Remote generation now: $(ci_rclone size "${REMOTE}" 2>/dev/null | tail -2 | tr '\n' ' ')"
