#!/usr/bin/env bash
# Resolve the cache list from the shared definition, then hand off to the planner.
# Doing it here rather than in Python is what keeps the list from drifting per repo, which is how the two copies of this script ended up probing three and five caches respectively.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../../lib/caches.sh
. "${here}/../../lib/caches.sh"

[[ -n "${PROBE_CACHES}" ]] || PROBE_CACHES="$(ci_build_substituters essential)"
require_file 'the builder pool file' "${BUILDERS_FILE}"

PROBE_CACHES="${PROBE_CACHES}" exec python3 "${here}/plan-builds.py"
