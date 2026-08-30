#!/usr/bin/env bash
# Launch the sampler and return, so the build starts on time.
# Inputs are validated here rather than in the sampler: a bad value must fail this step, not disappear into a background process nobody is watching.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int interval-seconds "${INTERVAL_SECONDS}"
require_positive_int probe-timeout-seconds "${PROBE_TIMEOUT_SECONDS}"
require_positive_int duration-minutes "${DURATION_MINUTES}"
((PROBE_TIMEOUT_SECONDS < INTERVAL_SECONDS)) || die "probe-timeout-seconds (${PROBE_TIMEOUT_SECONDS}) must be shorter than interval-seconds (${INTERVAL_SECONDS})."

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nohup bash "${here}/sampler.sh" >>"${LOG_FILE}" 2>&1 </dev/null &

notice "Sampling builder vitals every ${INTERVAL_SECONDS}s into ${LOG_FILE}."
