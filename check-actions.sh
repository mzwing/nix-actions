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

# The shared libraries' public surface. shellcheck cannot help here: to it an
# undefined helper is indistinguishable from an external command, so deleting
# one only surfaces as "command not found" mid-run — which is exactly how
# `group` was lost in a comment cleanup and took out a cache job.
# Add a name here when the scripts start depending on it.
required_helpers=(
  notice warn fail die emit_output group endgroup
  require_positive_int require_non_negative_int require_port require_file require_signing_key
  ci_ssh ci_scp ci_wait_until ci_wait_all builder_ids
  ci_build_substituters ci_build_trusted_keys ci_public_cache_urls ci_public_cache_key_names
  attic_schema_matches attic_object_count attic_running attic_assert_consistent attic_prune_by_path_list
  rclone_setup ci_rclone
)
missing="$(
  # shellcheck source=lib/caches.sh
  . "${here}/lib/caches.sh"
  # shellcheck source=store-cache/attic-state.sh
  . "${here}/store-cache/attic-state.sh"
  # shellcheck source=store-cache/rclone.sh
  . "${here}/store-cache/rclone.sh"
  for helper in "${required_helpers[@]}"; do
    declare -F "${helper}" >/dev/null || printf '%s ' "${helper}"
  done
)"
if [[ -n "${missing}" ]]; then
  fail "Helpers the action scripts rely on are no longer defined: ${missing}"
  status=1
fi

((status == 0)) && notice 'All actions invoke their scripts through an interpreter, and every shared helper still exists.'
exit "${status}"
