#!/usr/bin/env bash
# Runs on a builder, fed over ssh stdin. Reads realised paths from $1 and reports which ones this builder can expand.
# Emits `FOUND<TAB>path` for each input path whose deriver lives here, then `PATH<TAB>path` for every output in those derivers' closures.
# Best-effort enrichment only: a path the coordinator substituted rather than delegated has no deriver on any builder, so a miss is ordinary and never fatal.
set -euo pipefail

input="$1"
work="$(mktemp -d)"
trap 'rm -rf "${work}" "${input}"' EXIT

: >"${work}/top-drvs"
while IFS= read -r path; do
  drv="$(nix-store --query --deriver "${path}" 2>/dev/null || true)"
  if [[ "${drv}" == /nix/store/*.drv ]] && nix-store --check-validity "${drv}" 2>/dev/null; then
    printf 'FOUND\t%s\n' "${path}"
    printf '%s\n' "${drv}" >>"${work}/top-drvs"
  fi
done <"${input}"

sort --unique -o "${work}/top-drvs" "${work}/top-drvs"
[[ -s "${work}/top-drvs" ]] || exit 0

xargs -n 128 nix-store --query --requisites <"${work}/top-drvs" |
  grep '\.drv$' | sort --unique >"${work}/drvs" || true
xargs -n 128 nix-store --query --outputs <"${work}/drvs" | sed 's/^/PATH\t/'
