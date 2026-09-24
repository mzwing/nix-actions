#!/usr/bin/env bash
# Resolve the shared and repository caches, then hand off to the planner.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../../lib/caches.sh
. "${here}/../../lib/caches.sh"

require_file 'the builder pool file' "${BUILDERS_FILE}"

caches='{"substituters":[],"trustedPublicKeys":[]}'
if [[ -e "${CACHES_FILE}" ]]; then
  caches="$(nix eval --json --file "${CACHES_FILE}")"
fi
ci_load_repo_caches "${caches}"
emit_output caches "$(jq -c . <<<"${caches}")"

notice "Probing $(ci_build_substituters all)."

PROBE_CACHES="$(ci_build_substituters essential)" REPO_CACHES="${CI_REPO_SUBSTITUTERS}" exec python3 "${here}/plan-builds.py"
