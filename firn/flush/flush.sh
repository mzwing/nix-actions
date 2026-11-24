#!/usr/bin/env bash
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../state.sh
. "${here}/../state.sh"
require_positive_int timeout-minutes "${TIMEOUT_MINUTES}"
if [[ -s "${PATHS_FILE}" ]]; then
  sudo env OUT_PATHS="$(cat "${PATHS_FILE}")" /etc/nix/firn-post-build-hook
fi
sudo touch "${FIRN_REQUEST}"
status=0
ci_wait_until "$((TIMEOUT_MINUTES * 60))" 5 'Firn upload' test -e "${FIRN_DONE}" || status=1
group 'Firn uploader log'
cat "${FIRN_LOG}"
endgroup
((status == 0)) || die 'Timed out waiting for Firn uploader'
if [[ -s "${FIRN_FAILED}" ]]; then die "$(wc -l <"${FIRN_FAILED}") paths failed to upload to Firn"; fi
