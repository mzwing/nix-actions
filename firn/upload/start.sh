#!/usr/bin/env bash
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../../lib/pins.sh
. "${here}/../../lib/pins.sh"
# shellcheck source=../state.sh
. "${here}/../state.sh"
firn="$(nix build --no-link --print-out-paths --max-jobs 1 --option extra-substituters https://cache.so1ve.dev --option extra-trusted-public-keys cache.so1ve.dev-1:SijyzF9iE/VZwMXgMpd/HrNX9iItDZ1tdiNdeGakQGY= "github:so1ve/firn/${CI_FIRN_REF}")/bin/firn"
sudo mkdir -p "${FIRN_SPOOL}"
sudo install -m 755 "${here}/post-build-hook.sh" /etc/nix/firn-post-build-hook
printf '%s\n' 'post-build-hook = /etc/nix/firn-post-build-hook' | sudo tee -a /etc/nix/nix.conf >/dev/null
sudo systemctl restart nix-daemon
export FIRN_BIN="${firn}"
# shellcheck disable=SC2024
sudo --preserve-env=FIRN_BIN,GITHUB_TOKEN,ACTIONS_ID_TOKEN_REQUEST_URL,ACTIONS_ID_TOKEN_REQUEST_TOKEN,CI_REPO_TRUSTED_KEYS nohup bash "${here}/drainer.sh" >"${FIRN_LOG}" 2>&1 &
printf '%s\n' "$!" >"${FIRN_DRAINER_PID}"
