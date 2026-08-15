#!/usr/bin/env bash
# Build the extra_nix_config blob handed to cachix/install-nix-action.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"
# shellcheck source=../../lib/caches.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/caches.sh"

[[ -z "${MAX_JOBS}" ]] || require_non_negative_int max-jobs "${MAX_JOBS}"
[[ "${SUBSTITUTER_SET}" =~ ^(all|essential)$ ]] || die "substituter-set must be all or essential, got '${SUBSTITUTER_SET}'."

{
  echo 'extra_nix_config<<NIX_CONFIG_EOF'
  echo 'accept-flake-config = false'
  [[ -z "${GITHUB_TOKEN_INPUT}" ]] ||
    echo "access-tokens = github.com=${GITHUB_TOKEN_INPUT}"
  [[ -z "${MAX_JOBS}" ]] || echo "max-jobs = ${MAX_JOBS}"
  echo "substituters = $(ci_build_substituters "${SUBSTITUTER_SET}") ${EXTRA_SUBSTITUTERS}"
  echo "trusted-public-keys = $(ci_build_trusted_keys) ${EXTRA_TRUSTED_PUBLIC_KEYS}"
  echo 'NIX_CONFIG_EOF'
} >>"${GITHUB_OUTPUT}"
