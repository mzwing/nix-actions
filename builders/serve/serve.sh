#!/usr/bin/env bash
# Stay alive while the coordinator uses this runner as a remote builder.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int claim-timeout-seconds "${CLAIM_TIMEOUT_SECONDS}"
require_positive_int max-minutes "${MAX_MINUTES}"
require_positive_int max-silent-seconds "${MAX_SILENT_SECONDS}"

# Bound a wedged build on the machine that actually runs it; see the input's description for why the coordinator's own --max-silent-time does not cover this.
# Remote ssh-ng sessions read /etc/nix/nix.conf directly, so no daemon restart is needed, and this lands before the coordinator claims us.
printf 'max-silent-time = %s\n' "${MAX_SILENT_SECONDS}" | sudo tee -a /etc/nix/nix.conf >/dev/null
notice "Builds here fail after ${MAX_SILENT_SECONDS}s of silence."

claimed() { [[ -e /tmp/builder_claimed ]]; }

released() {
  [[ -e /tmp/builder_done ]] && return 0
  notice "Serving... ($((SECONDS / 60))m)"
  # Everything upstream watches the coordinator's view of us, so a builder whose tailscaled dies mid-run would
  # otherwise keep heartbeating for hours while billing a macOS minute every minute. A bare exit-code check misses
  # the "daemon alive but off the tailnet" case (stopped daemon still answers exit 0); only BackendState "Running"
  # means we are actually connected.
  [[ "$(sudo tailscale status --json 2>/dev/null | jq -r .BackendState)" == 'Running' ]] ||
    die 'Lost the tailnet link; exiting so the coordinator stops waiting on us.'
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
