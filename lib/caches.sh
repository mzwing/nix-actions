# shellcheck shell=bash
# The binary caches every repository gets. Each entry is `url<TAB>signing-key`, so key names can never drift from the keys.
# A repository adds its own through plan-builds' caches-file; ci_load_repo_caches reads them, and nix/setup exports them to the rest of the job.

CI_FIRN_SERVER=https://nix-cache.service.mzwing.eu.org
CI_FIRN_KEY=nix-cache.service.mzwing.eu.org-1:ZI+74ziFu8O5j5jSAz45VTPo09uLYH7O8F2dBYBQYsk=

_ci_build_caches=(
  "${CI_FIRN_SERVER}	${CI_FIRN_KEY}"
  "https://cache.nixos.org	cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
)

# Only jobs that install devenv build against it, but its paths are never worth uploading either way
_ci_devenv_caches=(
  "https://devenv.cachix.org	devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
)

_ci_field() { cut -d'	' -f"$1"; }

_ci_words() { awk '{ for (i = 1; i <= NF; i++) print $i }' <<<"$1"; }

_ci_unique() { awk '!seen[$0]++'; }

_ci_join() { _ci_unique | paste -sd' ' -; }

# ci_load_repo_caches <json> — the {substituters, trustedPublicKeys} a repository's caches-file evaluates to.
ci_load_repo_caches() {
  local url key
  jq -e '[.substituters, .trustedPublicKeys] | all(type == "array" and all(.[]; type == "string" and test("^\\S+$")))' <<<"$1" >/dev/null ||
    die "Repository caches must be {\"substituters\": [...], \"trustedPublicKeys\": [...]} of whitespace-free strings, got: $1"
  CI_REPO_SUBSTITUTERS="$(jq -r '.substituters | join(" ")' <<<"$1")"
  CI_REPO_TRUSTED_KEYS="$(jq -r '.trustedPublicKeys | join(" ")' <<<"$1")"
  while IFS= read -r url; do
    [[ "${url}" =~ ^https?:// ]] || die "Repository cache ${url} is not an http(s) URL."
  done < <(_ci_words "${CI_REPO_SUBSTITUTERS}")
  while IFS= read -r key; do
    require_signing_key "Repository cache key ${key}" "${key}"
  done < <(_ci_words "${CI_REPO_TRUSTED_KEYS}")
}

# ci_build_substituters [all|essential] — space-separated, for nix.conf.
# `essential` leaves out the repository's caches. The coordinator substitutes before it dispatches, so a builder only pays for them: one narinfo round trip per miss, and a cold Rust graph misses thousands of times.
ci_build_substituters() {
  {
    printf '%s\n' "${_ci_build_caches[@]}" | _ci_field 1
    [[ "${1:-all}" == essential ]] || _ci_words "${CI_REPO_SUBSTITUTERS:-}"
  } | _ci_join
}

# Always the full set: trusting a key the machine never queries costs nothing, while missing one turns a valid substitute into a rebuild.
ci_build_trusted_keys() {
  {
    printf '%s\n' "${_ci_build_caches[@]}" | _ci_field 2
    _ci_words "${CI_REPO_TRUSTED_KEYS:-}"
  } | _ci_join
}

ci_devenv_substituters() { printf '%s\n' "${_ci_devenv_caches[@]}" | _ci_field 1 | paste -sd' ' -; }

ci_devenv_trusted_keys() { printf '%s\n' "${_ci_devenv_caches[@]}" | _ci_field 2 | paste -sd' ' -; }

# Signature prefixes for `firn push --skip-signed-by`: whatever another cache already serves is never uploaded
ci_upstream_cache_key_names() {
  {
    printf '%s\n' "${_ci_build_caches[@]}" "${_ci_devenv_caches[@]}" | _ci_field 2
    _ci_words "${CI_REPO_TRUSTED_KEYS:-}"
  } | grep -vxF "${CI_FIRN_KEY}" | cut -d: -f1 | _ci_unique | sed 's/$/:/'
}
