#!/usr/bin/env bash
# Stage a consistent mid-run snapshot of the live Attic generation.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../attic-state.sh
. "${here}/../attic-state.sh"

require_positive_int timeout-minutes "${TIMEOUT_MINUTES}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

signalled() { [[ -e /tmp/cache_checkpoint || -e /tmp/cache_done ]] || ! attic_running; }
ci_wait_until "$((TIMEOUT_MINUTES * 60))" 20 'a checkpoint signal' signalled || true

if [[ -e /tmp/cache_done ]] || ! attic_running; then
  notice 'The run is already finishing; leaving the final save to store-cache/finalize.'
  emit_output checkpoint-ready false
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

# The database goes first because an online backup reads through the WAL, so it names exactly the chunks that had finished uploading by the time it ran.
sqlite3 "${DATA_DIR}/server.db" ".backup '${CHECKPOINT_DIR}/server.db'"

# Attic's local backend streams an upload straight into its final path, and chunking is disabled, so a chunk file grows for as long as a whole NAR takes to arrive.
# Hardlinking the tree wholesale therefore stages files that keep changing under whatever persists the snapshot next: rclone refuses them outright ("source file is being updated") and tar stores them truncated.
# A chunk the backup already marks valid has finished arriving, and its name is a fresh UUID that is never written twice, so restricting the snapshot to those makes it immutable.
cp -al "${DATA_DIR}/storage" "${CHECKPOINT_DIR}/storage"
sqlite3 "${CHECKPOINT_DIR}/server.db" \
  "SELECT substr(remote_file_id, 7) FROM chunk WHERE state = 'V' AND remote_file_id LIKE 'local:%';" \
  >"${work}/valid.txt"
find "${CHECKPOINT_DIR}/storage" -type f -printf '%f\t%p\n' >"${work}/staged.txt"

# A valid chunk with no file behind it would publish a database referencing a NAR that was never uploaded, which is the one state the save ordering exists to rule out.
missing="$(awk -F'\t' 'NR == FNR { staged[$1]; next } !($0 in staged) { n++ } END { print n + 0 }' \
  "${work}/staged.txt" "${work}/valid.txt")"
if ((missing > 0)); then
  find "${CHECKPOINT_DIR}" -mindepth 1 -delete
  warn "${missing} valid Attic chunks have no file on disk; abandoning this checkpoint round."
  emit_output checkpoint-ready false
  exit 0
fi

# Everything else is mid-upload, deduplicated or already deleted, so dropping the link both makes the snapshot safe to read and keeps that garbage off the remote.
awk -F'\t' 'NR == FNR { valid[$0]; next } !($1 in valid) { print $2 }' \
  "${work}/valid.txt" "${work}/staged.txt" >"${work}/excluded.txt"
xargs -r -d '\n' rm -f <"${work}/excluded.txt"

printf '%s\n' "${count}" >"${ATTIC_CHECKPOINT_COUNT_FILE}"
emit_output checkpoint-ready true
notice "Checkpoint staged: $(du -sh "${CHECKPOINT_DIR}" | cut -f1) across $(wc -l <"${work}/valid.txt") chunks, leaving out $(wc -l <"${work}/excluded.txt") that were not complete."
