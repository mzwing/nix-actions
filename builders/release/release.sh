#!/usr/bin/env bash
# Best-effort shutdown signal to every builder and the store cache host.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int timeout-seconds "${TIMEOUT_SECONDS}"

# Signal in parallel: the cache job may still be restoring a multi-GiB entry, and one slow host must not delay releasing the others.
signal() {
  local host="$1" marker="$2"
  if ci_wait_until "${TIMEOUT_SECONDS}" 5 "${host}" ci_ssh "${host}" "touch ${marker}"; then
    notice "Signalled ${host}."
  else
    warn "Could not signal ${host} within ${TIMEOUT_SECONDS} seconds."
  fi
}

pids=()
while IFS= read -r id; do
  signal "${BUILDER_PREFIX}-${id}" /tmp/builder_done &
  pids+=("$!")
done < <(builder_ids "${BUILDERS_JSON}")

if [[ -n "${CACHE_HOST}" ]]; then
  signal "${CACHE_HOST}" /tmp/cache_done &
  pids+=("$!")
fi

# Failures are already reported as warnings; releasing is best effort by design.
ci_wait_all "${pids[@]}" || true
