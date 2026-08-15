#!/usr/bin/env bash
# Root the current lock's build closure, then collect everything else.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

notice "Store size before GC: $(du -sh /nix/store | cut -f1)"

nix eval --json --impure --file "${DRVS_FILE}" | jq -r '.[]' >"${work}/drvs.txt"

{
  xargs nix-store --query --requisites --include-outputs <"${work}/drvs.txt"
  [[ -z "${EXTRA_PATHS_JSON}" ]] || jq -r '.. | strings' <<<"${EXTRA_PATHS_JSON}"
} | sort --unique >"${work}/keep.txt"

# --requisites lists closure paths that may not exist locally, so filter to what is actually present before rooting.
while IFS= read -r path; do
  [[ -e "${path}" ]] && printf '%s\n' "${path}"
done <"${work}/keep.txt" >"${work}/roots.txt"

gcroots="/nix/var/nix/gcroots/${GCROOTS_NAME}"
sudo rm -rf "${gcroots}"
sudo install -d "${gcroots}"
notice "Rooting $(wc -l <"${work}/roots.txt") of $(wc -l <"${work}/keep.txt") closure paths."
sudo xargs -a "${work}/roots.txt" -r -n 100 ln -sfn -t "${gcroots}" --

# sudo resets PATH to secure_path, which lacks the Nix profile.
nix_collect_garbage="$(command -v nix-collect-garbage)"
notice 'Paths that will be deleted:'
sudo "${nix_collect_garbage}" --dry-run
sudo "${nix_collect_garbage}"
notice "Store size after GC: $(du -sh /nix/store | cut -f1)"
