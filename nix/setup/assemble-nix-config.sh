#!/usr/bin/env bash
# Build the extra_nix_config blob handed to cachix/install-nix-action.
# shellcheck source=../../lib/ci.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"
# shellcheck source=../../lib/caches.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/caches.sh"

[[ -z "${MAX_JOBS}" ]] || require_non_negative_int max-jobs "${MAX_JOBS}"
[[ "${SUBSTITUTER_SET}" =~ ^(all|essential)$ ]] || die "substituter-set must be all or essential, got '${SUBSTITUTER_SET}'."

substituters="$(ci_build_substituters "${SUBSTITUTER_SET}")"
trusted_keys="$(ci_build_trusted_keys)"

# Without the key every devenv path is rebuilt from source, and devenv-nixpkgs-patched sets allowSubstitutes = false, so it cannot be built on a foreign system at all.
if [[ "${INSTALL_DEVENV}" == 'true' ]]; then
  substituters+=" $(ci_devenv_substituters)"
  trusted_keys+=" $(ci_devenv_trusted_keys)"
fi

{
  echo 'extra_nix_config<<NIX_CONFIG_EOF'
  echo 'accept-flake-config = false'
  [[ -z "${GITHUB_TOKEN_INPUT}" ]] ||
    echo "access-tokens = github.com=${GITHUB_TOKEN_INPUT}"
  [[ -z "${MAX_JOBS}" ]] || echo "max-jobs = ${MAX_JOBS}"
  echo "substituters = ${substituters}"
  echo "trusted-public-keys = ${trusted_keys}"
  echo 'NIX_CONFIG_EOF'
} >>"${GITHUB_OUTPUT}"
