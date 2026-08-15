#!/usr/bin/env bash
# Stay alive while the coordinator uses this runner as a remote builder.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int claim-timeout-seconds "${CLAIM_TIMEOUT_SECONDS}"
require_positive_int max-minutes "${MAX_MINUTES}"

claimed() { [[ -e /tmp/builder_claimed ]]; }

# The heartbeat is the only sign of life in this job's log, since Nix drives the builds from the coordinator.
released() {
  [[ -e /tmp/builder_done ]] && return 0
  notice "Serving... ($((SECONDS / 60))m)"
  return 1
}

ci_wait_until "${CLAIM_TIMEOUT_SECONDS}" 5 'the coordinator to claim this builder' claimed ||
  die "The coordinator did not claim this builder within ${CLAIM_TIMEOUT_SECONDS} seconds."

notice 'Claimed; serving builds.'
if ci_wait_until "$((MAX_MINUTES * 60))" 60 'the coordinator to finish' released; then
  notice 'Released by the coordinator.'
else
  warn "Still unreleased after ${MAX_MINUTES} minutes; exiting so the post steps can run."
fi
