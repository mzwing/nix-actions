#!/usr/bin/env bash
# Verify that every `uses: mzwing/nix-actions/...` in the given repositories names an action that exists here and passes only inputs it declares.
# Renaming an action or dropping an input otherwise fails at runtime, halfway through a six-hour build.
. "$(dirname "${BASH_SOURCE[0]}")/lib/ci.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0

for repo in "$@"; do
  workflows="${repo}/.github/workflows"
  [[ -d "${workflows}" ]] || continue

  for workflow in "${workflows}"/*.yml; do
    while IFS=$'\t' read -r action keys; do
      [[ "${action}" == mzwing/nix-actions/* ]] || continue
      path="${action#mzwing/nix-actions/}"
      path="${path%@*}"

      if [[ ! -f "${here}/${path}/action.yml" ]]; then
        fail "${workflow}: no such action: ${path}"
        status=1
        continue
      fi

      declared=" $(yq -r '.inputs // {} | keys | .[]' "${here}/${path}/action.yml" | tr '\n' ' ')"
      for key in ${keys}; do
        [[ "${declared}" == *" ${key} "* ]] || {
          fail "${workflow}: ${path} has no input '${key}'"
          status=1
        }
      done
    done < <(yq -r '
      [.jobs[].steps[]?] | .[]
      | select(.uses != null)
      | [.uses, ((.with // {}) | keys | join(" "))]
      | @tsv
    ' "${workflow}")
  done
done

((status == 0)) && notice 'All consumer references resolve.'
exit "${status}"
