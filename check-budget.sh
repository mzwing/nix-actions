#!/usr/bin/env bash
# Assert the timing relations the distributed build depends on.
#
# These are the failures that cost a whole run: nothing complains at push time, the pipeline just dies four hours in with
# nothing published. The caps themselves are tuned by hand and documented on the cache job; only their relations are checked here.
# shellcheck source=lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/ci.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0

workflow="${here}/.github/workflows/distributed-build.yml"

# Time a job needs on top of its longest internal wait: setup, tailnet join, and the post steps.
headroom=25

job_timeout() { yq -r ".jobs.${1}.\"timeout-minutes\"" "${workflow}"; }
input_default() { yq -r ".inputs.\"${2}\".default" "${here}/${1}/action.yml"; }

at_most() {
  local description="$1" left="$2" right="$3"
  if ((left <= right)); then
    notice "  ${description}: ${left} <= ${right}"
  else
    fail "${description}: ${left} exceeds ${right}"
    status=1
  fi
}

# GitHub terminates a job at 360 minutes, and termination — like a timeout-minutes cancellation — skips every `if: !cancelled()` step, taking the Cachix push and the reconciliation with it.
while IFS=$'\t' read -r job minutes; do
  at_most "job ${job} finishes before GitHub kills it" "${minutes}" 359
done < <(yq -r '.jobs | to_entries | .[] | select(.value.["timeout-minutes"] != null) | [.key, .value.["timeout-minutes"]] | @tsv' "${workflow}")

# A builder that stops serving before its job ends strands the coordinator mid-build.
at_most 'builders serve for as long as their job lasts' \
  "$(($(input_default builders/serve max-minutes) + headroom))" "$(job_timeout builder)"
at_most 'vitals sampling ends before its job does' \
  "$(($(input_default builders/vitals duration-minutes) + headroom))" "$(job_timeout builder)"

# Builders reach store-cache/connect about a minute in and then wait; the cache host only publishes bootstrap data once its restore finishes.
at_most 'builders wait out the cache restore' \
  "$((($(input_default store-cache/restore timeout-minutes) + 10) * 60))" \
  "$(input_default store-cache/connect timeout-seconds)"

((status == 0)) && notice 'The build budget holds.'
exit "${status}"
