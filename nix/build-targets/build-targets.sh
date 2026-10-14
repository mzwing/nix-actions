#!/usr/bin/env bash
# Build every scheduled target and report both halves of the result.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int timeout-minutes "${BUILD_TIMEOUT_MINUTES}"
require_positive_int max-silent-seconds "${MAX_SILENT_SECONDS}"
require_positive_int builder-probe-seconds "${BUILDER_PROBE_SECONDS}"

# Reconcile reads this regardless of how the build went, so it must exist even when nobody was lost.
: >"${LOST_BUILDERS_FILE}"

# Written by builders/attach; absent when the caller builds without a fleet.
MACHINES_FILE=/etc/nix/machines

build_systems="$(jq -c '[.[].system] | unique' <<<"${TARGETS}")"
: >"${BUILD_LOG}"

# One deadline for the whole step, shared by every pass. Giving each pass its own
# budget could add up past the runner's 6-hour limit, and hitting that limit
# cancels the job -- which makes `if: !cancelled()` false for every step after
# this one, so the push and the reconciliation vanish and the run publishes nothing.
deadline=$((SECONDS + BUILD_TIMEOUT_MINUTES * 60))

# Realise every scheduled target, streaming the out-paths to the step summary and
# the full log to the artifact file. Returns nix's own status.
run_build() {
  local budget=$((deadline - SECONDS)) status=0 watcher=''
  ((budget > 0)) || return 124

  pass_log_line=$(($(wc -l <"${BUILD_LOG}") + 1))
  pass_lost_count=$(wc -l <"${LOST_BUILDERS_FILE}")
  # Every build-remote hook still listing a dead machine spends a full ssh connect timeout on it while nix waits synchronously, freezing the whole build: run 38134424160 lost 157 of its 207 build minutes that way.
  if [[ -s "${MACHINES_FILE}" ]]; then
    ci_wait_until "${budget}" "${BUILDER_PROBE_SECONDS}" 'the build pass to end' evict_round &
    watcher=$!
  fi

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

  if [[ -n "${watcher}" ]]; then
    kill "${watcher}" 2>/dev/null || true
    wait "${watcher}" 2>/dev/null || true
    # A machine can die after the watcher's last round, and both the retry decision and reconciliation need the final fleet.
    evict_lost_builders
  fi
  return "${status}"
}

# Drop builders that stopped answering ssh, appending them to the lost-builders file.
# Nix reschedules a build onto another machine only while dispatching, so a machine that dies fails every derivation in flight on it and the failure cascades up the dependency graph.
# Probing is what names the dead machine: `cannot build on ...` also appears when nix simply falls through to the next machine, and the lines that mark the real event name no host.
evict_lost_builders() {
  local line host
  local kept=() lost=()

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    host="${line%% *}"
    host="${host##*@}"
    # One failed probe is no proof: run 38400088434 evicted a builder whose `true` had just completed on its side. ssh's stderr stays in the log so the next such failure explains itself.
    if ci_wait_until "${BUILDER_PROBE_SECONDS}" 5 "builder ${host}" ci_ssh -t "${BUILDER_PROBE_SECONDS}" "${host}" true; then
      kept+=("${line}")
    else
      lost+=("${host}")
    fi
  done <"${MACHINES_FILE}"

  ((${#lost[@]} > 0)) || return 0
  printf '%s\n' "${lost[@]}" >>"${LOST_BUILDERS_FILE}"
  warn "Evicted ${#lost[@]} unreachable builder(s): ${lost[*]}"

  # Build-remote hooks read this file as they start, and a pass may be running, so swap it in whole.
  if ((${#kept[@]} > 0)); then
    printf '%s\n' "${kept[@]}" | sudo tee "${MACHINES_FILE}.new" >/dev/null
  else
    sudo tee "${MACHINES_FILE}.new" </dev/null
  fi
  sudo mv "${MACHINES_FILE}.new" "${MACHINES_FILE}"

  local system
  while IFS= read -r system; do
    awk -v want="${system}" '$2 == want { found = 1 } END { exit !found }' "${MACHINES_FILE}" ||
      warn "No builder left for ${system}; its targets cannot be retried."
  done < <(jq -r '.[]' <<<"${build_systems}")
}

# One round of the in-pass watcher; never returns 0, so ci_wait_until only supplies the loop and its deadline.
# shellcheck disable=SC2329  # run_build hands it to ci_wait_until
evict_round() {
  evict_lost_builders
  return 1
}

# Whether a builder link dropped during the last pass, which the probe cannot see once that builder is back.
# A drop while an output is being copied home is swallowed by build-remote under --keep-going, and nix then aborts the whole pass with `some outputs are unexpectedly invalid`.
# Build output always carries its derivation's name as a prefix, so only nix itself prints these lines.
builder_link_dropped() {
  awk -v from="${pass_log_line}" 'NR >= from && !/^[^ ]+> / && /Broken pipe|Nix daemon disconnected unexpectedly|some outputs are unexpectedly invalid/ { found = 1; exit } END { exit !found }' "${BUILD_LOG}"
}

printf '### Built outputs\n\n' >>"${GITHUB_STEP_SUMMARY}"

build_status=0
run_build || build_status=$?

# A timeout is a budget problem, not a connectivity one, so it is never retried.
# Nor is a pass that lost no builder and dropped no link: that is a broken package, and building it again would only fail the same way.
# A lost builder retries for as long as any survive, since each pass rebuilds only what the dead ones took down: run 38149666670 gave up after one retry with two darwin builders still alive.
link_retries=1
while ((build_status != 0 && build_status != 124 && build_status != 137)) && [[ -s "${MACHINES_FILE}" ]]; do
  if (($(wc -l <"${LOST_BUILDERS_FILE}") == pass_lost_count)); then
    if ((link_retries == 0)) || ! builder_link_dropped; then
      break
    fi
    link_retries=0
    warn 'A builder link dropped mid-build, though every builder answers again.'
  fi
  notice 'Retrying the build; everything already realised is a no-op.'
  printf '\nRetried the build.\n' >>"${GITHUB_STEP_SUMMARY}"
  build_status=0
  run_build || build_status=$?
done

if [[ -s "${LOST_BUILDERS_FILE}" ]]; then
  sort --unique -o "${LOST_BUILDERS_FILE}" "${LOST_BUILDERS_FILE}"
  {
    printf '\n### Builders lost mid-build\n\n'
    while IFS= read -r host; do
      # shellcheck disable=SC2016  # backticks are markdown for the step summary
      printf -- '- `%s`\n' "${host}"
    done <"${LOST_BUILDERS_FILE}"
  } >>"${GITHUB_STEP_SUMMARY}"
  warn "Excluded $(wc -l <"${LOST_BUILDERS_FILE}") lost builder(s) from reconciliation: $(paste -sd' ' - <"${LOST_BUILDERS_FILE}")"
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
