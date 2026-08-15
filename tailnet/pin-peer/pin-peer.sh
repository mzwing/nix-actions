#!/usr/bin/env bash
# Resolve a tailnet peer once and pin it in /etc/hosts.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int timeout-seconds "${TIMEOUT_SECONDS}"

peer_ip=''
resolve_peer() {
  peer_ip="$(sudo tailscale status --json |
    jq -r --arg host "${PEER_HOSTNAME}" \
      '[.Peer[]? | select(.HostName == $host) | .TailscaleIPs[0]] | first // empty')"
  [[ -n "${peer_ip}" ]]
}

ci_wait_until "${TIMEOUT_SECONDS}" 5 "tailnet peer ${PEER_HOSTNAME}" resolve_peer ||
  die "The tailnet peer ${PEER_HOSTNAME} did not appear within ${TIMEOUT_SECONDS} seconds."

printf '%s %s\n' "${peer_ip}" "${PEER_HOSTNAME}" | sudo tee -a /etc/hosts
