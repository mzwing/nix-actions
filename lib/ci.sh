# shellcheck shell=bash
# Shared helpers. Every action script starts with:
#   . "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

set -euo pipefail

# ── logging ──

notice() { printf '%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }
fail() { printf '::error::%s\n' "$*" >&2; }
die() {
  fail "$*"
  exit 1
}

emit_output() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT}"; }

# ── input validation ──

require_positive_int() {
  [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer, got '$2'."
}

# max-jobs = 0 is meaningful, so it needs its own rule.
require_non_negative_int() {
  [[ "$2" =~ ^(0|[1-9][0-9]*)$ ]] || die "$1 must be a non-negative integer, got '$2'."
}

require_port() {
  require_positive_int "$1" "$2"
  ((10#$2 <= 65535)) || die "$1 must be between 1 and 65535, got '$2'."
}

require_file() { [[ -e "$2" ]] || die "$1 does not exist: $2"; }

require_signing_key() {
  [[ "$2" =~ ^[a-zA-Z0-9._-]+:[A-Za-z0-9+/]{43}=$ ]] || die "$1 is not a valid Nix cache signing key."
}

# ── ssh ──
#
# A CI tailnet link can black-hole instead of resetting, and ssh without liveness probes then blocks in read() forever.
# Since most callers here sit in a poll loop, one such stall wedges the whole job — so these options are correctness, not tuning.
# ConnectTimeout bounds the handshake, ServerAlive* bounds a dead-but-established link, and the outer timeout bounds a remote command that hangs over a healthy link.
#
# Multiplexing is on because the control plane polls builders in loops.
# It is deliberately absent from /etc/ssh/ssh_config.d (see builders/attach) so Nix's own ssh-ng build links stay independent of the control plane.

CI_SSH_CONNECT_TIMEOUT="${CI_SSH_CONNECT_TIMEOUT:-15}"
CI_SSH_ALIVE_INTERVAL="${CI_SSH_ALIVE_INTERVAL:-15}"
CI_SSH_ALIVE_COUNT="${CI_SSH_ALIVE_COUNT:-4}"
CI_SSH_TIMEOUT="${CI_SSH_TIMEOUT:-120}"

# %C hashes the connection tuple; a literal %h would overflow the ~104-byte socket path limit under macOS's RUNNER_TEMP.
_ci_ssh_control_dir="${RUNNER_TEMP:-/tmp}/ci-ssh"
_ci_ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o "ConnectTimeout=${CI_SSH_CONNECT_TIMEOUT}"
  -o ConnectionAttempts=2
  -o "ServerAliveInterval=${CI_SSH_ALIVE_INTERVAL}"
  -o "ServerAliveCountMax=${CI_SSH_ALIVE_COUNT}"
  -o ControlMaster=auto
  -o "ControlPath=${_ci_ssh_control_dir}/%C"
  -o ControlPersist=120
)
mkdir -p "${_ci_ssh_control_dir}"
chmod 700 "${_ci_ssh_control_dir}"

# GitHub's macOS runners ship no GNU timeout, and store-cache/connect calls ci_ssh there, so fall back to a watchdog rather than silently dropping the bound.
if command -v timeout >/dev/null 2>&1; then
  _ci_bounded() {
    local seconds="$1"
    shift
    timeout --signal=TERM --kill-after=10s "${seconds}s" "$@"
  }
elif command -v gtimeout >/dev/null 2>&1; then
  _ci_bounded() {
    local seconds="$1"
    shift
    gtimeout --signal=TERM --kill-after=10s "${seconds}s" "$@"
  }
else
  _ci_bounded() {
    local seconds="$1"
    shift
    # The explicit `<&0` overrides bash's default of /dev/null for background jobs, which ci_ssh -i relies on.
    "$@" <&0 &
    local pid=$! status=0
    {
      sleep "${seconds}"
      kill -TERM "${pid}" 2>/dev/null && {
        sleep 10
        kill -KILL "${pid}" 2>/dev/null
      }
    } >/dev/null 2>&1 &
    local watchdog=$!
    wait "${pid}" || status=$?
    kill "${watchdog}" 2>/dev/null || true
    wait "${watchdog}" 2>/dev/null || true
    return "${status}"
  }
fi

# ci_ssh [-t SECONDS] [-i] HOST COMMAND...  (-i forwards stdin; default /dev/null)
ci_ssh() {
  local command_timeout="${CI_SSH_TIMEOUT}" stdin=(-n) option
  local OPTIND=1
  while getopts ':t:i' option; do
    case "${option}" in
      t) command_timeout="${OPTARG}" ;;
      i) stdin=() ;;
      *) die "ci_ssh: unknown option -${OPTARG}" ;;
    esac
  done
  shift $((OPTIND - 1))
  local host="$1"
  shift
  _ci_bounded "${command_timeout}" ssh "${stdin[@]}" "${_ci_ssh_opts[@]}" "root@${host}" "$@"
}

# ci_scp [-t SECONDS] LOCAL HOST REMOTE
ci_scp() {
  local command_timeout="${CI_SSH_TIMEOUT}" option
  local OPTIND=1
  while getopts ':t:' option; do
    case "${option}" in
      t) command_timeout="${OPTARG}" ;;
      *) die "ci_scp: unknown option -${OPTARG}" ;;
    esac
  done
  shift $((OPTIND - 1))
  _ci_bounded "${command_timeout}" scp -q "${_ci_ssh_opts[@]}" "$1" "root@$2:$3"
}

# ── bounded waiting ──
# The only loop primitive the actions use, so every wait carries a deadline by construction.

# ci_wait_until TIMEOUT INTERVAL DESCRIPTION COMMAND...
ci_wait_until() {
  local deadline_seconds="$1" interval="$2" description="$3"
  shift 3
  local deadline=$((SECONDS + deadline_seconds))
  while true; do
    if "$@"; then return 0; fi
    if ((SECONDS >= deadline)); then
      notice "Timed out after ${deadline_seconds}s waiting for ${description}."
      return 1
    fi
    sleep "${interval}"
  done
}

# ── parallelism ──

# Wait for every pid, returning 1 if any failed. Per-builder work runs concurrently so one slow host never serialises the rest.
ci_wait_all() {
  local pid status=0
  for pid in "$@"; do
    wait "${pid}" || status=1
  done
  return "${status}"
}

builder_ids() { jq -r '.include[].id' <<<"$1"; }
