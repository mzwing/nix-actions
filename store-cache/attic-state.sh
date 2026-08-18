# shellcheck shell=bash
# shellcheck disable=SC2034  # these constants exist to be read by the sourcing action
# Runtime state the store-cache actions hand to each other across steps.

ATTIC_CONFIG_FILE=/tmp/attic-server.toml
ATTIC_PID_FILE=/tmp/atticd.pid
ATTIC_BIN_FILE=/tmp/atticd-bin
ATTIC_LOG_FILE=/tmp/atticd.log
ATTIC_CLIENT_FILE=/tmp/attic-client.json
ATTIC_KEEP_PATHS_FILE=/tmp/attic-keep-paths.txt
ATTIC_CHECKPOINT_COUNT_FILE=/tmp/attic-checkpoint-count

# The columns the pruning SQL and the orphan-reaping loop depend on. Attic is pinned, so a mismatch means the restored data is from a different schema.
# Checked at startup so a schema surprise fails there rather than after a multi-hour build.
attic_schema_matches() {
  sqlite3 "$1" 'SELECT store_path, cache_id, nar_id, deriver FROM object LIMIT 0;' >/dev/null 2>&1 &&
    sqlite3 "$1" 'SELECT state FROM chunk LIMIT 0;' >/dev/null 2>&1
}

attic_object_count() { sqlite3 "$1" 'SELECT count(*) FROM object;'; }

attic_running() { [[ -s "${ATTIC_PID_FILE}" ]] && kill -0 "$(cat "${ATTIC_PID_FILE}")" 2>/dev/null; }

# Abort rather than persist a database that pruning has left inconsistent.
attic_assert_consistent() {
  local violations
  violations="$(sqlite3 "$1" 'PRAGMA foreign_key_check;')"
  [[ -z "${violations}" ]] || die "Attic database has foreign-key violations after $2: ${violations}"
}

# Delete every object whose store_path is (or is not) listed in FILE.
attic_prune_by_path_list() {
  local database="$1" list="$2" mode="$3" predicate
  case "${mode}" in
    keep-only) predicate='NOT EXISTS' ;;
    remove) predicate='EXISTS' ;;
    *) die "attic_prune_by_path_list: unknown mode ${mode}" ;;
  esac
  # A one-column import table: a wider one would silently gain NULL columns from a one-column file.
  sqlite3 "${database}" <<SQL
.bail on
PRAGMA foreign_keys = ON;
CREATE TEMP TABLE path_list(path TEXT PRIMARY KEY);
.mode tabs
.import ${list} path_list
DELETE FROM object WHERE ${predicate} (SELECT 1 FROM path_list WHERE path_list.path = object.store_path);
SQL
}
