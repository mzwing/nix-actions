# shellcheck shell=bash
# Public binary caches, previously duplicated as `inputs.*.default` across four actions (which is how they drifted).
# Each entry is `url<TAB>signing-key<TAB>tier`, so key names can never drift from the keys.
#
# Tier `essential` means the cache realistically serves a build here. Builders take only those, because a cache miss costs one narinfo round trip per configured substituter and a cold Rust graph misses thousands of times.
# Coordinators and the update job take everything, where the extra hits are worth more than the extra latency.

_ci_build_caches=(
  "https://mzwing.cachix.org	mzwing.cachix.org-1:tOO3NqAwrXyPCnecEl/0wXwparCRksM5TeuS/wZK+KA=	essential"
  "https://cache.nixos.org	cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=	essential"
  "https://nix-community.cachix.org	nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=	extra"
  "https://cache.nixos-cuda.org	cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M=	extra"
  "https://attic.xuyh0120.win/lantian	lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=	extra"
)

# devenv's own cache. Only jobs that install devenv build against it, but it makes a path public either way, so pruning always counts it.
_ci_devenv_caches=(
  "https://devenv.cachix.org	devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=	devenv"
)

_ci_field() { cut -d'	' -f"$1"; }

_ci_essential_only() { awk -F'\t' '$3 == "essential"'; }

# ci_build_substituters [all|essential] — space-separated, for nix.conf.
ci_build_substituters() {
  if [[ "${1:-all}" == essential ]]; then
    printf '%s\n' "${_ci_build_caches[@]}" | _ci_essential_only | _ci_field 1 | paste -sd' ' -
  else
    printf '%s\n' "${_ci_build_caches[@]}" | _ci_field 1 | paste -sd' ' -
  fi
}

# Always the full set: trusting a key the machine never queries costs nothing, while missing one turns a valid substitute into a rebuild.
ci_build_trusted_keys() { printf '%s\n' "${_ci_build_caches[@]}" | _ci_field 2 | paste -sd' ' -; }

ci_devenv_substituters() { printf '%s\n' "${_ci_devenv_caches[@]}" | _ci_field 1 | paste -sd' ' -; }

ci_devenv_trusted_keys() { printf '%s\n' "${_ci_devenv_caches[@]}" | _ci_field 2 | paste -sd' ' -; }

# Newline-separated, for the pruning passes: anything already public must not be stored privately.
ci_public_cache_urls() {
  printf '%s\n' "${_ci_build_caches[@]}" "${_ci_devenv_caches[@]}" | _ci_field 1
}

ci_public_cache_key_names() {
  printf '%s\n' "${_ci_build_caches[@]}" "${_ci_devenv_caches[@]}" | _ci_field 2 | cut -d: -f1
}
