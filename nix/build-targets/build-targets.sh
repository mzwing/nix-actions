#!/usr/bin/env bash
# Build every scheduled target and report both halves of the result.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int timeout-minutes "${BUILD_TIMEOUT_MINUTES}"
require_positive_int max-silent-seconds "${MAX_SILENT_SECONDS}"

build_systems="$(jq -c '[.[].system] | unique' <<<"${TARGETS}")"
: >"${BUILD_LOG}"

set +e
{
  printf '### Built outputs\n\n'
  BUILD_SYSTEMS="${build_systems}" timeout --signal=INT --kill-after=5m "${BUILD_TIMEOUT_MINUTES}m" \
    nix build \
    --impure \
    --file "${BUILD_FILE}" \
    --no-link \
    --no-write-lock-file \
    --print-build-logs \
    --print-out-paths \
    --max-jobs 0 \
    --max-silent-time "${MAX_SILENT_SECONDS}" \
    --keep-going \
    2> >(tee -a "${BUILD_LOG}" >&2) |
    tee "${BUILT_OUTPUTS_FILE}" |
    while IFS= read -r path; do
      # shellcheck disable=SC2016  # backticks are markdown for the step summary
      printf -- '- `%s`\n' "${path}"
    done
} >>"${GITHUB_STEP_SUMMARY}"
build_status=$?
set -e

if ((build_status == 124 || build_status == 137)); then
  fail "The distributed build exceeded its ${BUILD_TIMEOUT_MINUTES}-minute budget; publishing whatever finished."
fi

# `nix build` prints out-paths only when the whole invocation succeeds, so with --keep-going one failure would hide every other realised output from the push set. Re-derive them from the local store, and name the ones still missing — otherwise a failure is only findable by reading the whole build log.
: >"${BUILT_OUTPUTS_FILE}"
: >"${FAILED_TARGETS_FILE}"
while IFS=$'\t' read -r name out; do
  if nix-store --check-validity "${out}" 2>/dev/null; then
    printf '%s\n' "${out}" >>"${BUILT_OUTPUTS_FILE}"
  else
    printf '%s\n' "${name}" >>"${FAILED_TARGETS_FILE}"
  fi
done < <(jq -r '.[] | [.name, .outputPath] | @tsv' <<<"${TARGETS}" | sort --unique)

if [[ -s "${FAILED_TARGETS_FILE}" ]]; then
  sort --unique -o "${FAILED_TARGETS_FILE}" "${FAILED_TARGETS_FILE}"
  {
    printf '\n### Failed targets\n\n'
    while IFS= read -r name; do
      # shellcheck disable=SC2016  # backticks are markdown for the step summary
      printf -- '- `%s`\n' "${name}"
    done <"${FAILED_TARGETS_FILE}"
  } >>"${GITHUB_STEP_SUMMARY}"
  fail "$(wc -l <"${FAILED_TARGETS_FILE}") target(s) failed: $(paste -sd' ' - <"${FAILED_TARGETS_FILE}")"
fi

exit "${build_status}"
