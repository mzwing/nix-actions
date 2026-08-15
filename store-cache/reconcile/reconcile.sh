#!/usr/bin/env bash
# Make the Attic generation match what this run actually built, then install the retention set.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../../lib/caches.sh
. "${here}/../../lib/caches.sh"
# shellcheck source=../attic-state.sh
. "${here}/../attic-state.sh"

require_positive_int transfer-jobs "${TRANSFER_JOBS}"
require_positive_int transfer-timeout-minutes "${TRANSFER_TIMEOUT_MINUTES}"
require_file 'the active derivation file' "${ACTIVE_DRVS_FILE}"

export LC_ALL=C
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mapfile -t builder_id_list < <(builder_ids "${BUILDERS_JSON}")
builder_host() { printf '%s-%s' "${BUILDER_PREFIX}" "$1"; }

for_each_builder() {
  local pids=() id
  for id in "${builder_id_list[@]}"; do
    "$@" "${id}" &
    pids+=("$!")
  done
  ci_wait_all "${pids[@]}"
}

# Batch roots so this is one nix process per 128 derivations rather than per derivation.
expand_drv_closure() {
  : >"$2"
  [[ -s "$1" ]] || return 0
  xargs -n 128 nix-store --query --requisites <"$1" | grep '\.drv$' | sort --unique >"$2" || true
}

# ── flush the builders' upload spools ──
# The drain runs while evaluation proceeds below; no new builds arrive after this point, so anything landing late is simply re-offered by the probe.

request_drain() { ci_ssh "$(builder_host "$1")" 'touch /tmp/attic-drain-request' || true; }
for_each_builder request_drain || true
notice 'Signalled all Attic drainers to flush and exit.'

# ── retention and transfer roots ──

notice 'Evaluating the full current-lock derivation set...'
nix eval --json --impure --file "${DRVS_FILE}" | jq -r '.[]' | sort --unique >"${work}/top-drvs.txt"
sort --unique "${ACTIVE_DRVS_FILE}" >"${work}/active-top-drvs.txt"

[[ -z "$(comm -23 "${work}/active-top-drvs.txt" "${work}/top-drvs.txt")" ]] ||
  die 'Active derivations are not a subset of the full retention set.'
notice "Retention roots: $(wc -l <"${work}/top-drvs.txt"); scheduled roots: $(wc -l <"${work}/active-top-drvs.txt")."

notice 'Expanding full and scheduled derivation closures...'
expand_drv_closure "${work}/top-drvs.txt" "${work}/drvs.txt"
expand_drv_closure "${work}/active-top-drvs.txt" "${work}/active-drvs.txt"
notice "Derivation closure: $(wc -l <"${work}/drvs.txt") total; $(wc -l <"${work}/active-drvs.txt") scheduled."

unexpanded="$(
  comm -23 "${work}/top-drvs.txt" "${work}/drvs.txt"
  comm -23 "${work}/active-top-drvs.txt" "${work}/active-drvs.txt"
)"
[[ -z "${unexpanded}" ]] || die "Could not expand top-level derivations: ${unexpanded}"

# `nix derivation show` reports null paths for fixed-output and floating-CA outputs, so resolve them from the store in batches instead.
: >"${work}/active-outputs.txt"
if [[ -s "${work}/active-drvs.txt" ]]; then
  xargs -n 128 nix-store --query --outputs <"${work}/active-drvs.txt" |
    sort --unique >"${work}/active-outputs.txt"
fi
notice "Scheduled derivation closure has $(wc -l <"${work}/active-outputs.txt") output paths."

# ── outputs with no static derivation (devenv and friends) ──

: >"${work}/extra-expected.txt"
if [[ -n "${EXTRA_PATHS_FILE}" && -s "${EXTRA_PATHS_FILE}" ]]; then
  expand_extra_on() {
    local host remote=/tmp/reconcile-extra-paths.txt
    host="$(builder_host "$1")"
    ci_scp "${EXTRA_PATHS_FILE}" "${host}" "${remote}" || return 0
    ci_ssh -t 600 -i "${host}" /usr/bin/env bash -s "${remote}" \
      <"${here}/remote-expand-extra-paths.sh" >"${work}/extra-frag.$1" || true
  }
  for_each_builder expand_extra_on || true
  cat "${work}"/extra-frag.* >"${work}/extra.fragments" 2>/dev/null || : >"${work}/extra.fragments"

  awk -F'\t' '$1 == "FOUND" {print $2}' "${work}/extra.fragments" | sort --unique >"${work}/extra-found.txt"
  sort --unique "${EXTRA_PATHS_FILE}" >"${work}/extra-required.txt"
  if ! cmp -s "${work}/extra-required.txt" "${work}/extra-found.txt"; then
    comm -23 "${work}/extra-required.txt" "${work}/extra-found.txt" >&2
    die 'Not every extra realised output had a deriver on a live builder.'
  fi
  awk -F'\t' '$1 == "PATH" {print $2}' "${work}/extra.fragments" | sort --unique >"${work}/extra-expected.txt"
fi

# ── wait for the drainers, then snapshot Attic ──
# One round trip per builder per round, all builders in parallel: the old two-per-builder serial poll cost more than the drain it was watching.

drain_state_file="${work}/drain-state"
poll_drain() {
  local id="$1" host
  host="$(builder_host "$1")"
  ci_ssh "${host}" 'test -e /tmp/attic-drain-done && echo done || wc -l < /tmp/attic-spool 2>/dev/null || echo unknown' \
    2>/dev/null >"${work}/drain.${id}" || printf 'unreachable\n' >"${work}/drain.${id}"
}

drained() {
  for_each_builder poll_drain || true
  local id state backlog=''
  for id in "${builder_id_list[@]}"; do
    state="$(cat "${work}/drain.${id}" 2>/dev/null || true)"
    [[ "${state}" == 'done' ]] || backlog+="${id}=${state} "
  done
  printf '%s' "${backlog}" >"${drain_state_file}"
  [[ -z "${backlog}" ]]
}

if ! ci_wait_until 300 15 'the Attic drainers to flush' drained; then
  warn "Attic drainers did not finish in time (backlog: $(cat "${drain_state_file}")); continuing with the probe."
fi

ci_ssh "${CACHE_HOST}" \
  "sqlite3 '${CACHE_DATA_DIR}/server.db' \"SELECT store_path || char(9) || COALESCE(deriver, '') FROM object;\"" \
  >"${work}/attic-objects.txt" ||
  die 'Could not read Attic object metadata from the cache host.'
cut -f1 "${work}/attic-objects.txt" | sort --unique >"${work}/attic-paths.txt"

# Existing objects record their producing derivation, so unscheduled targets still contribute retention by deriver.
awk -F'\t' '
  NR == FNR { current[$0] = 1; basename = $0; sub(/^.*\//, "", basename); current[basename] = 1; next }
  $2 in current { print $1 }
' "${work}/drvs.txt" "${work}/attic-objects.txt" | sort --unique >"${work}/current-attic-paths.txt"

# ── what to keep, and what the builders must still supply ──

: >"${work}/public.txt"
[[ -s "${PUBLIC_PATHS_FILE}" ]] && sort --unique "${PUBLIC_PATHS_FILE}" >"${work}/public.txt"

cat "${work}/active-outputs.txt" "${work}/extra-expected.txt" "${work}/current-attic-paths.txt" |
  sort --unique >"${work}/expected.all.txt"
cat "${work}/active-outputs.txt" "${work}/extra-expected.txt" |
  sort --unique >"${work}/required.all.txt"

comm -23 "${work}/expected.all.txt" "${work}/public.txt" >"${work}/expected.txt"
comm -23 "${work}/required.all.txt" "${work}/public.txt" >"${work}/required.txt"

[[ ! -s "${work}/active-top-drvs.txt" || -s "${work}/required.txt" ]] ||
  die 'The non-empty active build closure produced no realised output paths.'
notice "Retention set has $(wc -l <"${work}/expected.txt") current private paths; builders must supply $(wc -l <"${work}/required.txt") of them."

# An already-cached path need not still live on a builder.
comm -23 "${work}/required.txt" "${work}/attic-paths.txt" >"${work}/wanted.txt"
notice "Attic already has $(($(wc -l <"${work}/required.txt") - $(wc -l <"${work}/wanted.txt"))) of them; $(wc -l <"${work}/wanted.txt") remain to probe."

# Attic would skip public paths server-side anyway, but each attempt still costs a narinfo round trip and a server call.
if [[ -s "${work}/wanted.txt" ]]; then
  mapfile -t public_caches < <(ci_public_cache_urls)
  python3 "${here}/../../lib/probe-public-paths.py" "${public_caches[@]}" \
    <"${work}/wanted.txt" >"${work}/wanted-public.txt"
  comm -23 "${work}/wanted.txt" "${work}/wanted-public.txt" >"${work}/wanted.filtered.txt"
  mv "${work}/wanted.filtered.txt" "${work}/wanted.txt"
  notice "$(wc -l <"${work}/wanted-public.txt") are already public; $(wc -l <"${work}/wanted.txt") transfer candidates left."
fi

# ── stream each builder's store and upload what is wanted ──

upload_from() {
  local id="$1" host remote=/tmp/reconcile-wanted-paths.txt
  host="$(builder_host "${id}")"
  : >"${work}/event.${id}"
  if ! ci_scp "${work}/wanted.txt" "${host}" "${remote}"; then
    warn "Could not send the wanted path set to ${host}."
    touch "${work}/pipeline-failed.${id}"
    return 0
  fi
  notice "Streaming store probe and up to ${TRANSFER_JOBS} uploads from ${host}."
  if ! ci_ssh -t "$((TRANSFER_TIMEOUT_MINUTES * 60))" -i "${host}" \
    python3 - "${TRANSFER_JOBS}" "ci:${CACHE_NAME}" "${remote}" "${id}" \
    <"${here}/remote-upload-pipeline.py" >"${work}/event.${id}"; then
    warn "Streaming reconcile pipeline failed on ${host}."
    touch "${work}/pipeline-failed.${id}"
  fi
}
for_each_builder upload_from || true

cat "${work}"/event.* >"${work}/events.all" 2>/dev/null || : >"${work}/events.all"
awk -F'\t' '$1 == "FOUND" {print $2}' "${work}/events.all" | sort --unique >"${work}/found.txt"
awk -F'\t' '$1 == "UPLOADED" {print $2}' "${work}/events.all" | sort --unique >"${work}/uploaded.txt"
comm -23 "${work}/found.txt" "${work}/uploaded.txt" >"${work}/failed.txt"

failed="$(wc -l <"${work}/failed.txt")"
notice "Builders held $(wc -l <"${work}/found.txt") candidate paths; $(wc -l <"${work}/uploaded.txt") were accepted by Attic."
if compgen -G "${work}/pipeline-failed.*" >/dev/null || ((failed > 0)); then
  die "Reconciliation failed for ${failed} paths found on builders; preserving the previous Attic generation instead of pruning it."
fi

# Only now is the retention set trustworthy: everything that existed on a builder has been offered.
ci_scp "${work}/expected.txt" "${CACHE_HOST}" "${ATTIC_KEEP_PATHS_FILE}.next"
ci_ssh "${CACHE_HOST}" "mv ${ATTIC_KEEP_PATHS_FILE}.next ${ATTIC_KEEP_PATHS_FILE}"
