#!/usr/bin/env bash
# Realise the full closure of PATHS_FILE locally, then hand it to cachix.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

if [[ -n "${CLOSURE_PATHS_FILE}" ]]; then
  rm -f "${CLOSURE_PATHS_FILE}" "${CLOSURE_PATHS_FILE}.tmp"
fi

if [[ ! -s "${PATHS_FILE}" ]]; then
  notice 'Nothing to push.'
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
closure="${work}/closure.txt"

mapfile -t outputs <"${PATHS_FILE}"

# References only become known once a path is realised, so this is a fixed point rather than a single pass.
previous=-1
while true; do
  nix-store --query --requisites "${outputs[@]}" | sort --unique >"${closure}"
  count="$(wc -l <"${closure}")"
  [[ "${count}" == "${previous}" ]] && break
  # The roots stop a concurrent GC collecting paths between realise and push.
  xargs nix-store --realise --add-root "${ROOT_PREFIX}" <"${closure}" >/dev/null
  previous="${count}"
done

notice "Pushing ${#outputs[@]} outputs (closure: ${count} paths) to ${CACHE_NAME}."
xargs cachix push "${CACHE_NAME}" <"${PATHS_FILE}"

if [[ -n "${CLOSURE_PATHS_FILE}" ]]; then
  mkdir -p "$(dirname "${CLOSURE_PATHS_FILE}")"
  cp "${closure}" "${CLOSURE_PATHS_FILE}.tmp"
  mv "${CLOSURE_PATHS_FILE}.tmp" "${CLOSURE_PATHS_FILE}"
fi
rm -f "${ROOT_PREFIX}"*
