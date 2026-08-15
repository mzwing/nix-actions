#!/usr/bin/env bash
# Prove the Attic cache is reachable from here and from a builder before builds start.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_port cache-port "${CACHE_PORT}"
require_positive_int timeout-seconds "${TIMEOUT_SECONDS}"

first_id="$(jq -r '.include[0].id // empty' <<<"${BUILDERS_JSON}")"
[[ -n "${first_id}" ]] || die 'Builder matrix is empty.'
first_builder="${BUILDER_PREFIX}-${first_id}"
cache_url="http://${CACHE_HOST}:${CACHE_PORT}/${CACHE_NAME}/nix-cache-info"

fetch='curl --connect-timeout 5 --max-time 10 --fail --silent --show-error'
remote_probe="test -e /tmp/builder-cache-ready && ${fetch} '${cache_url}' >/dev/null"

reachable() {
  ${fetch} "${cache_url}" >/dev/null 2>&1 &&
    ci_ssh "${first_builder}" "${remote_probe}" 2>/dev/null
}

if ! ci_wait_until "${TIMEOUT_SECONDS}" 5 'the Attic cache to answer' reachable; then
  direct="$(${fetch} "${cache_url}" 2>&1 || true)"
  via_builder="$(ci_ssh "${first_builder}" "${remote_probe}" 2>&1 || true)"
  die "The Attic builder cache is not reachable over HTTP. Direct: ${direct} / via builder: ${via_builder}"
fi

# Diagnostics only: a relayed (DERP) path shows up as slow uploads and narinfo queries for the whole build.
tailscale ping -c 2 "${CACHE_HOST}" 2>&1 | tail -2 | sed 's/^/tailscale coordinator->cache: /' || true
ci_ssh "${first_builder}" "tailscale ping -c 2 '${CACHE_HOST}' 2>&1 | tail -2" 2>/dev/null |
  sed 's/^/tailscale builder->cache: /' || true
