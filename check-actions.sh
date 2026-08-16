#!/usr/bin/env bash
# Check every action.yml against the invariants that only fail at runtime, halfway into a build.
#
# The exec bit is the one that actually bit us: three scripts went in as 100644 and the step died with "Permission denied" (exit 126) after the runner had already been provisioned.
# Naming an interpreter makes the bit irrelevant, so that is what is enforced here rather than the bit itself.
# shellcheck source=lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/ci.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0

while IFS= read -r action; do
  dir="$(dirname "${action}")"

  while IFS= read -r command; do
    [[ "${command}" == *'github.action_path'* ]] || continue

    if [[ ! "${command}" =~ ^(bash|sh|python3)[[:space:]] ]]; then
      fail "${action}: run must name an interpreter, got: ${command}"
      status=1
      continue
    fi

    # Scripts always sit beside their action.yml, so the basename is enough.
    script="${dir}/${command##*/}"
    [[ -f "${script}" ]] || {
      fail "${action}: run references a missing file: ${script}"
      status=1
    }
  done < <(yq -r '.runs.steps[]? | select(.run != null) | .run' "${action}")
done < <(find "${here}" -name action.yml -not -path '*/.devenv/*' -not -path '*/.direnv/*')

((status == 0)) && notice 'All actions invoke their scripts through an interpreter.'
exit "${status}"
