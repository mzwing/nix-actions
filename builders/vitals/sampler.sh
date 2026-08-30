#!/usr/bin/env bash
# One tab-separated line per builder per round, on the coordinator's disk.
# Started detached by vitals.sh, so nothing here reaches the job log; the caller redirects stdout to the artifact.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

probe() {
  local id="$1" stamp vitals
  stamp="$(date -u +%FT%TZ)"
  if ! vitals="$(ci_ssh -t "${PROBE_TIMEOUT_SECONDS}" -i "${BUILDER_PREFIX}-${id}" sh -s <"${here}/probe.sh" 2>/dev/null)" || [[ -z "${vitals}" ]]; then
    vitals=UNREACHABLE
  fi
  printf '%s\t%s\t%s\n' "${stamp}" "${id}" "${vitals}" >"${work}/line.${id}"
}

# Never returns 0: ci_wait_until is the repo's only loop primitive, so the sampling window is expressed as its deadline.
round() {
  local pids=() id
  while IFS= read -r id; do
    probe "${id}" &
    pids+=("$!")
  done < <(builder_ids "${BUILDERS_JSON}")
  ci_wait_all "${pids[@]}" || true
  cat "${work}"/line.* 2>/dev/null || true
  return 1
}

ci_wait_until "$((DURATION_MINUTES * 60))" "${INTERVAL_SECONDS}" 'the sampling window to close' round || true
