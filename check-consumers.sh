#!/usr/bin/env bash
# Verify that every `uses: mzwing/nix-actions/...` in the given repositories names an action or reusable workflow that exists here and passes only inputs and secrets it declares.
# Renaming one or dropping an input otherwise fails at runtime, halfway through a six-hour build.
. "$(dirname "${BASH_SOURCE[0]}")/lib/ci.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0

# Every lookup below runs in a process substitution, where a missing yq would leave the loops empty and the whole check falsely green.
command -v yq >/dev/null || die 'yq is required; run this inside the devenv shell.'

# " a b c ", so a key can be matched as a substring without splitting again.
declared_keys() { printf ' %s' "$(yq -r "${2} // {} | keys | .[]" "$1" | tr '\n' ' ')"; }

required_keys() { yq -r "${2} // {} | to_entries | .[] | select(.value.required == true) | .key" "$1"; }

for repo in "$@"; do
  workflows="${repo}/.github/workflows"
  [[ -d "${workflows}" ]] || continue

  for workflow in "${workflows}"/*.yml "${workflows}"/*.yaml; do
    [[ -f "${workflow}" ]] || continue

    while IFS=$'\t' read -r uses with_keys secret_keys; do
      [[ "${uses}" == mzwing/nix-actions/* ]] || continue
      path="${uses#mzwing/nix-actions/}"
      path="${path%@*}"

      # A reusable workflow is referenced by its file; an action by its directory.
      if [[ "${path}" == .github/workflows/* ]]; then
        reusable=true
        definition="${here}/${path}"
        inputs='.on.workflow_call.inputs'
      else
        reusable=false
        definition="${here}/${path}/action.yml"
        inputs='.inputs'
      fi

      if [[ ! -f "${definition}" ]]; then
        fail "${workflow}: no such action or workflow: ${path}"
        status=1
        continue
      fi

      declared="$(declared_keys "${definition}" "${inputs}")"
      for key in ${with_keys}; do
        [[ "${declared}" == *" ${key} "* ]] || {
          fail "${workflow}: ${path} has no input '${key}'"
          status=1
        }
      done

      # Only a reusable workflow declares secrets, and only it refuses to start when a required one is missing — for an action GitHub ignores `required` entirely.
      "${reusable}" || continue

      declared="$(declared_keys "${definition}" '.on.workflow_call.secrets')"
      for key in ${secret_keys}; do
        [[ "${declared}" == *" ${key} "* ]] || {
          fail "${workflow}: ${path} has no secret '${key}'"
          status=1
        }
      done

      while IFS= read -r key; do
        [[ " ${with_keys} " == *" ${key} "* ]] || {
          fail "${workflow}: ${path} requires input '${key}'"
          status=1
        }
      done < <(required_keys "${definition}" "${inputs}")

      while IFS= read -r key; do
        [[ " ${secret_keys} " == *" ${key} "* ]] || {
          fail "${workflow}: ${path} requires secret '${key}'"
          status=1
        }
      done < <(required_keys "${definition}" '.on.workflow_call.secrets')
    done < <(yq -r '
      [.jobs[] | (., .steps[]?)] | .[]
      | select(.uses != null)
      | [.uses, ((.with // {}) | keys | join(" ")), (((.secrets // {}) | select(kind == "map") | keys | join(" ")) // "")]
      | @tsv
    ' "${workflow}")
  done
done

((status == 0)) && notice 'All consumer references resolve.'
exit "${status}"
