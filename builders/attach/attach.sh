#!/usr/bin/env bash
# Claim every builder in the matrix and register it with the local nix daemon.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"

require_positive_int timeout-seconds "${TIMEOUT_SECONDS}"

# Nix passes no timeout options of its own to ssh, so this file is the only thing bounding a dead ssh-ng build connection.
# It matters because those connections stay open and silent for the whole of a slow compile: when the tailnet path drops under one it black-holes instead of resetting.
# Nix's worker reads the build-remote hook's verdict synchronously and that hook connects before answering, so one ssh blocked in read() freezes *every* concurrent build until the job hits its 6-hour limit.
# ControlMaster is deliberately absent here: build links must stay independent of each other and of the control plane in lib/ci.sh.
sudo mkdir -p /etc/ssh/ssh_config.d
sudo tee /etc/ssh/ssh_config.d/nix-builders.conf >/dev/null <<EOF
Host ${SSH_HOST_PATTERN}
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  BatchMode yes
  LogLevel ERROR
  ConnectTimeout 30
  ConnectionAttempts 3
  ServerAliveInterval 20
  ServerAliveCountMax 9
  TCPKeepAlive yes
EOF

# Claim builders concurrently; serial probing would charge the whole fleet for the slowest runner to boot.
claim_builder() {
  local id="$1" builder="${BUILDER_PREFIX}-$1"
  if ! ci_wait_until "${TIMEOUT_SECONDS}" 5 "builder ${builder}" ci_ssh "${builder}" true; then
    die "Builder ${builder} did not become reachable within ${TIMEOUT_SECONDS} seconds."
  fi
  ci_ssh "${builder}" 'touch /tmp/builder_claimed'
  notice "Claimed ${builder}."
}

pids=()
while IFS= read -r id; do
  claim_builder "${id}" &
  pids+=("$!")
done < <(builder_ids "${BUILDERS_JSON}")
ci_wait_all "${pids[@]}" || die 'Not every builder could be claimed.'

sudo tee /etc/nix/machines </dev/null
while IFS=$'\t' read -r id system max_jobs; do
  printf 'ssh-ng://root@%s %s - %s 1 big-parallel,benchmark\n' \
    "${BUILDER_PREFIX}-${id}" "${system}" "${max_jobs}" |
    sudo tee -a /etc/nix/machines >/dev/null
done < <(jq -r '.include[] | [.id, .system, .maxJobs] | @tsv' <<<"${BUILDERS_JSON}")

sudo tee -a /etc/nix/nix.conf >/dev/null <<'EOF'
builders = @/etc/nix/machines
builders-use-substitutes = true
max-jobs = 0
EOF
sudo systemctl restart nix-daemon.service
