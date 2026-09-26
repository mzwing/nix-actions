#!/usr/bin/env bash
# Build every scheduled target and report both halves of the result.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int timeout-minutes "${BUILD_TIMEOUT_MINUTES}"
require_positive_int max-silent-seconds "${MAX_SILENT_SECONDS}"
require_positive_int builder-probe-seconds "${BUILDER_PROBE_SECONDS}"

# Written by builders/attach; absent when the caller builds without a fleet.
MACHINES_FILE=/etc/nix/machines

build_systems="$(jq -c '[.[].system] | unique' <<<"${TARGETS}")"
: >"${BUILD_LOG}"

# One deadline for the whole step, shared by every pass. Giving each pass its own
# budget could add up past the runner's 6-hour limit, and hitting that limit
# cancels the job -- which makes `if: !cancelled()` false for every step after
# this one, so the push and the reconciliation vanish and the run publishes nothing.
deadline=$((SECONDS + BUILD_TIMEOUT_MINUTES * 60))

lost_builders=()

# Realise every scheduled target, streaming the out-paths to the step summary and
# the full log to the artifact file. Returns nix's own status.
run_build() {
  local budget=$((deadline - SECONDS)) status=0
  ((budget > 0)) || return 124

  set +e
  BUILD_SYSTEMS="${build_systems}" timeout --signal=INT --kill-after=5m "${budget}s" \
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
    while IFS= read -r path; do
      # shellcheck disable=SC2016  # backticks are markdown for the step summary
      printf -- '- `%s`\n' "${path}"
    done >>"${GITHUB_STEP_SUMMARY}"
  status=$?
  set -e
  return "${status}"
}

# Drop builders that stopped answering ssh, recording them in lost_builders.
# Returns 0 when at least one was dropped.
# Nix reschedules a build onto another machine only while dispatching, so a machine that dies fails every derivation in flight on it and the failure cascades up the dependency graph.
# Probing is what names the dead machine: `cannot build on ...` also appears when nix simply falls through to the next machine, and the lines that mark the real event name no host.
evict_lost_builders() {
  local line host
  local kept=()

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    host="${line%% *}"
    host="${host##*@}"
    if ci_ssh -t "${BUILDER_PROBE_SECONDS}" "${host}" true >/dev/null 2>&1; then
      kept+=("${line}")
    else
      lost_builders+=("${host}")
    fi
  done <"${MACHINES_FILE}"

  ((${#lost_builders[@]} > 0)) || return 1

  if ((${#kept[@]} > 0)); then
    printf '%s\n' "${kept[@]}" | sudo tee "${MACHINES_FILE}" >/dev/null
  else
    sudo tee "${MACHINES_FILE}" </dev/null
  fi

  local system
  while IFS= read -r system; do
    awk -v want="${system}" '$2 == want { found = 1 } END { exit !found }' "${MACHINES_FILE}" ||
      warn "No builder left for ${system}; its targets cannot be retried."
  done < <(jq -r '.[]' <<<"${build_systems}")
}

# Whether a builder link dropped mid-build, which the probe cannot see once that builder is back.
# A drop while an output is being copied home is swallowed by build-remote under --keep-going, and nix then aborts the whole pass with `some outputs are unexpectedly invalid`.
# Build output always carries its derivation's name as a prefix, so only nix itself prints these lines.
builder_link_dropped() {
  awk '!/^[^ ]+> / && /Broken pipe|Nix daemon disconnected unexpectedly|some outputs are unexpectedly invalid/ { found = 1; exit } END { exit !found }' "${BUILD_LOG}"
}

retry_build() {
  if [[ ! -s "${MACHINES_FILE}" ]]; then
    warn 'No builders survived, so there is nothing left to retry on.'
    return
  fi
  notice 'Retrying the build once; everything already realised is a no-op.'
  printf '\nRetried the build once.\n' >>"${GITHUB_STEP_SUMMARY}"
  build_status=0
  run_build || build_status=$?
}

printf '### Built outputs\n\n' >>"${GITHUB_STEP_SUMMARY}"

build_status=0
run_build || build_status=$?

# A timeout is a budget problem, not a connectivity one, so it is never retried.
# Nor is a failure with every link intact: that is a broken package, and building it again would only fail the same way.
if ((build_status != 0 && build_status != 124 && build_status != 137)) && [[ -s "${MACHINES_FILE}" ]]; then
  if evict_lost_builders; then
    {
      printf '\n### Builders lost mid-build\n\n'
      for host in "${lost_builders[@]}"; do
        # shellcheck disable=SC2016  # backticks are markdown for the step summary
        printf -- '- `%s`\n' "${host}"
      done
    } >>"${GITHUB_STEP_SUMMARY}"
    warn "Lost ${#lost_builders[@]} builder(s) mid-build: ${lost_builders[*]}"
    retry_build
  elif builder_link_dropped; then
    warn 'A builder link dropped mid-build, though every builder answers again.'
    retry_build
  fi
fi

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
