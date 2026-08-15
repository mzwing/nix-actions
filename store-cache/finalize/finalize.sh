#!/usr/bin/env bash
# Prune and quiesce the Attic generation so it can be persisted.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../../lib/caches.sh
. "${here}/../../lib/caches.sh"
# shellcheck source=../attic-state.sh
. "${here}/../attic-state.sh"

require_positive_int deadline-minutes "${DEADLINE_MINUTES}"
[[ -s "${ATTIC_PID_FILE}" && -s "${ATTIC_BIN_FILE}" ]] ||
  die 'Attic startup state is missing; store-cache/start did not run here.'

atticd_pid="$(cat "${ATTIC_PID_FILE}")"
atticd="$(cat "${ATTIC_BIN_FILE}")"
database="${DATA_DIR}/server.db"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# An early-finishing coordinator may have created the done file already, in which case this returns at once.
coordinator_done() {
  [[ -e /tmp/cache_done ]] && return 0
  attic_running || {
    cat "${ATTIC_LOG_FILE}"
    die 'Attic stopped while builders were active.'
  }
  return 1
}
ci_wait_until "$((DEADLINE_MINUTES * 60))" 15 'the coordinator to finish' coordinator_done ||
  die 'Timed out waiting for the coordinator; refusing to save an active Attic database.'

if kill -0 "${atticd_pid}" 2>/dev/null; then
  kill "${atticd_pid}" 2>/dev/null || true
  wait "${atticd_pid}" 2>/dev/null || true
fi

# On a red or cancelled coordinator run there is no keep-set; preserve everything uploaded rather than pruning from an incomplete closure.
if [[ -s "${ATTIC_KEEP_PATHS_FILE}" ]]; then
  attic_schema_matches "${database}" || die 'Attic database schema no longer matches deterministic pruning.'
  sort --unique "${ATTIC_KEEP_PATHS_FILE}" >"${work}/keep.txt"
  before="$(attic_object_count "${database}")"
  attic_prune_by_path_list "${database}" "${work}/keep.txt" keep-only
  attic_assert_consistent "${database}" 'deterministic pruning'
  after="$(attic_object_count "${database}")"
  notice "Pruned $((before - after)) stale Attic objects; ${after} current objects remain."
else
  warn 'No current closure keep-set was received; preserving all Attic objects.'
fi

# Attic's upstream-signature filter covers new uploads; this pass catches restored objects that became public since an earlier run.
sqlite3 "${database}" 'SELECT store_path FROM object;' >"${work}/current.txt"
mapfile -t public_caches < <(ci_public_cache_urls)
python3 "${here}/../../lib/probe-public-paths.py" "${public_caches[@]}" \
  <"${work}/current.txt" >"${work}/public.txt"

public_count="$(wc -l <"${work}/public.txt")"
if ((public_count > 0)); then
  attic_prune_by_path_list "${database}" "${work}/public.txt" remove
fi
attic_assert_consistent "${database}" 'upstream pruning'
notice "Removed ${public_count} objects now available from public substituters."

# Reap NARs orphaned by either pruning pass, including interrupted uploads from red builds.
"${atticd}" -f "${ATTIC_CONFIG_FILE}" --mode garbage-collector-once
sqlite3 "${database}" 'PRAGMA wal_checkpoint(TRUNCATE); VACUUM;'
integrity="$(sqlite3 "${database}" 'PRAGMA integrity_check;')"
[[ "${integrity}" == ok ]] || die "Attic database failed final integrity_check: ${integrity}"

emit_output save-ready true
notice "Final persisted Attic data size: $(du -sh "${DATA_DIR}" | cut -f1)."
