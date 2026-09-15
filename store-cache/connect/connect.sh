#!/usr/bin/env bash
# Fetch this run's Attic credentials over the tailnet and wire them into nix.conf.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../../lib/pins.sh
. "${here}/../../lib/pins.sh"
# shellcheck source=../attic-state.sh
. "${here}/../attic-state.sh"

require_positive_int timeout-seconds "${TIMEOUT_SECONDS}"

bootstrap=''
fetch_bootstrap() {
  bootstrap="$(ci_ssh "${CACHE_HOST}" "cat ${ATTIC_CLIENT_FILE}" 2>/dev/null)" || return 1
  jq -e '
    (.apiEndpoint | type == "string" and endswith("/")) and
    (.cacheEndpoint | type == "string") and
    (.publicKey | type == "string" and contains(":")) and
    (.token | type == "string" and length > 0)
  ' <<<"${bootstrap}" >/dev/null
}

ci_wait_until "${TIMEOUT_SECONDS}" 5 "Attic bootstrap data from ${CACHE_HOST}" fetch_bootstrap ||
  die "Attic bootstrap data was not available from ${CACHE_HOST}."

api_endpoint="$(jq -r '.apiEndpoint' <<<"${bootstrap}")"
cache_endpoint="$(jq -r '.cacheEndpoint' <<<"${bootstrap}")"
public_key="$(jq -r '.publicKey' <<<"${bootstrap}")"
token="$(jq -r '.token' <<<"${bootstrap}")"
require_signing_key 'the Attic cache signing key' "${public_key}"

if [[ "${POST_BUILD_HOOK}" == 'true' ]]; then
  # attic-client is prebuilt in cache.nixos.org for every builder system; max-jobs=0 fails rather than compiling it here.
  attic_client="$(nix eval --raw "github:NixOS/nixpkgs/${CI_NIXPKGS_REV}#attic-client.outPath")"
  nix-store --realise --option max-jobs 0 "${attic_client}" >/dev/null

  sudo install -d -m 700 /etc/attic
  sudo tee /etc/attic/config.toml >/dev/null <<EOF
default-server = "ci"

[servers.ci]
endpoint = "${api_endpoint}"
token = "${token}"
EOF
  printf '%s\n' "${attic_client}/bin/attic" | sudo tee /etc/attic/attic-bin >/dev/null
  printf '%s\n' "ci:${CACHE_NAME}" | sudo tee /etc/attic/cache >/dev/null
  sudo chmod 600 /etc/attic/config.toml /etc/attic/attic-bin /etc/attic/cache

  sudo install -m 755 "${here}/post-build-hook.sh" /etc/nix/push-to-builder-cache
  sudo install -m 755 "${here}/attic-drainer.sh" /usr/local/bin/attic-drainer
  sudo sh -c 'nohup /usr/local/bin/attic-drainer >>/tmp/attic-drainer.log 2>&1 </dev/null &'
fi

{
  echo
  echo "extra-substituters = ${cache_endpoint}"
  echo "extra-trusted-public-keys = ${public_key}"
  [[ "${POST_BUILD_HOOK}" == 'true' ]] && echo 'post-build-hook = /etc/nix/push-to-builder-cache'
  echo 'connect-timeout = 5'
} | sudo tee -a /etc/nix/nix.conf >/dev/null

# Remote ssh-ng sessions read /etc/nix/nix.conf directly, so no daemon restart is needed. The marker tells the coordinator bootstrap is complete.
sudo touch /tmp/builder-cache-ready
