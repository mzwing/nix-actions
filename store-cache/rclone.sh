# shellcheck shell=bash
# Shared rclone bootstrap for store-cache/restore and store-cache/persist.
# Sourced, never executed.

# shellcheck source=lib/pins.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/pins.sh"

# The config arrives base64-encoded in a secret so the token survives GitHub's line-based masking intact.
# It lands in RUNNER_TEMP at mode 600 and is never echoed; rclone rewrites this file when it refreshes an OAuth token, and that rewrite is discarded with the runner, so the secret has to be reissued whenever the provider rotates the refresh token.
rclone_setup() {
  [[ -n "${RCLONE_CONFIG_BASE64:-}" ]] || die 'RCLONE_CONFIG_BASE64 is empty; the calling job must pass the rclone config secret.'

  RCLONE_CONFIG="${RUNNER_TEMP:-/tmp}/rclone.conf"
  export RCLONE_CONFIG
  (
    umask 077
    base64 -d <<<"${RCLONE_CONFIG_BASE64}" >"${RCLONE_CONFIG}"
  ) || die 'Could not decode RCLONE_CONFIG_BASE64.'
  [[ -s "${RCLONE_CONFIG}" ]] || die 'The decoded rclone config is empty.'

  # Prebuilt for this Linux host; max-jobs=0 turns a missing substitute into a failure rather than a local Go build.
  local rclone_path
  rclone_path="$(nix eval --raw "github:NixOS/nixpkgs/${CI_NIXPKGS_REV}#rclone.outPath")"
  nix-store --realise --option max-jobs 0 "${rclone_path}" >/dev/null
  _rclone_bin="${rclone_path}/bin/rclone"

  "${_rclone_bin}" --config "${RCLONE_CONFIG}" listremotes >/dev/null ||
    die 'rclone rejected the supplied config.'
}

# ci_rclone SUBCOMMAND ARGS...
# --checkers/--transfers matter because the storage tree is tens of thousands of small files: throughput here is dominated by per-object round trips, not bandwidth.
ci_rclone() {
  timeout --signal=INT --kill-after=1m "${RCLONE_TIMEOUT_MINUTES}m" \
    "${_rclone_bin}" \
    --config "${RCLONE_CONFIG}" \
    --transfers "${RCLONE_TRANSFERS}" \
    --checkers "$((RCLONE_TRANSFERS * 2))" \
    --retries 5 \
    --low-level-retries 20 \
    --stats 30s \
    --stats-one-line \
    "$@"
}
