#!/usr/bin/env bash
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../../lib/caches.sh
. "${here}/../../lib/caches.sh"
# shellcheck source=../state.sh
. "${here}/../state.sh"
skip=()
while IFS= read -r key; do skip+=(--skip-signed-by "${key}"); done < <(ci_upstream_cache_key_names)
shopt -s nullglob
while true; do
  entries=("${FIRN_SPOOL}"/[!.]*)
  if ((${#entries[@]} == 0)); then
    if [[ -e "${FIRN_REQUEST}" ]]; then
      touch "${FIRN_DONE}"
      exit 0
    fi
    sleep 2
    continue
  fi
  batch="$(mktemp /tmp/firn-batch.XXXXXX)"
  cat "${entries[@]}" | sort -u >"${batch}"
  rm -f "${entries[@]}"
  split -l 128 "${batch}" "${batch}.part."
  for part in "${batch}".part.*; do
    success=0
    for _ in 1 2 3; do
      if "${FIRN_BIN}" push --stdin --server "${CI_FIRN_SERVER}" --jobs 8 "${skip[@]}" <"${part}"; then
        success=1
        break
      fi
      sleep 2
    done
    if ((success == 0)); then cat "${part}" >>"${FIRN_FAILED}"; fi
    rm -f "${part}"
  done
  rm -f "${batch}"
done
