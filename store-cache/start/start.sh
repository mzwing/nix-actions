#!/usr/bin/env bash
# Bring up this run's Attic server and publish bootstrap data for the clients.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/ci.sh
. "${here}/../../lib/ci.sh"
# shellcheck source=../../lib/caches.sh
. "${here}/../../lib/caches.sh"
# shellcheck source=../../lib/pins.sh
. "${here}/../../lib/pins.sh"
# shellcheck source=../attic-state.sh
. "${here}/../attic-state.sh"

require_port port "${PORT}"

# A fresh runner carries no signals across runs, but the coordinator may legitimately finish while this parallel job is still starting.
rm -f "${ATTIC_CLIENT_FILE}"

# Both outputs are prebuilt for this Linux host; max-jobs=0 turns a missing substitute into a failure rather than a local Rust build.
attic_server="$(nix eval --raw "github:NixOS/nixpkgs/${CI_NIXPKGS_REV}#attic-server.outPath")"
attic_client="$(nix eval --raw "github:NixOS/nixpkgs/${CI_NIXPKGS_REV}#attic-client.outPath")"
nix-store --realise --option max-jobs 0 "${attic_server}" "${attic_client}" >/dev/null
atticd="${attic_server}/bin/atticd"
atticadm="${attic_server}/bin/atticadm"
attic="${attic_client}/bin/attic"

sudo install -d -o "$(id -u)" -g "$(id -g)" "${DATA_DIR}"
install -d "${DATA_DIR}/storage"
database="${DATA_DIR}/server.db"
touch "${database}"

# The Attic revision is pinned, so a restored generation that no longer matches must not replace the last known-good entry.
if [[ -s "${database}" ]]; then
  integrity="$(sqlite3 "${database}" 'PRAGMA integrity_check;' 2>&1 || true)"
  [[ "${integrity}" == ok ]] || die "Restored Attic database failed integrity_check: ${integrity}"
  attic_schema_matches "${database}" || die 'Restored Attic database does not have the expected pinned schema.'
fi

# narinfo queries sit on the build scheduling critical path and must not queue behind push writes; WAL persists in the database header.
sqlite3 "${database}" 'PRAGMA journal_mode=WAL;'

api_endpoint="http://${CACHE_HOST}:${PORT}/"
cache_endpoint="${api_endpoint}${CACHE_NAME}"
sed -e "s|@PORT@|${PORT}|g" \
  -e "s|@API_ENDPOINT@|${api_endpoint}|g" \
  -e "s|@DATA_DIR@|${DATA_DIR}|g" \
  -e "s|@JWT_SECRET@|$(head -c 32 /dev/urandom | base64 | tr -d '\n')|g" \
  "${here}/attic-server.toml.in" >"${ATTIC_CONFIG_FILE}"
chmod 600 "${ATTIC_CONFIG_FILE}"

# atticd must outlive this step, so it is not trapped here; store-cache/finalize stops it via the pid file.
"${atticd}" -f "${ATTIC_CONFIG_FILE}" >"${ATTIC_LOG_FILE}" 2>&1 &
atticd_pid=$!
printf '%s\n' "${atticd_pid}" >"${ATTIC_PID_FILE}"
printf '%s\n' "${atticd}" >"${ATTIC_BIN_FILE}"

listening() {
  kill -0 "${atticd_pid}" 2>/dev/null || {
    cat "${ATTIC_LOG_FILE}"
    die 'Attic exited before becoming ready.'
  }
  (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null
}
ci_wait_until 120 2 'Attic to listen' listening || {
  cat "${ATTIC_LOG_FILE}"
  die 'Timed out waiting for Attic to listen.'
}

admin_token="$("${atticadm}" -f "${ATTIC_CONFIG_FILE}" make-token \
  --sub nix-ci-admin --validity '8 hours' \
  --pull "${CACHE_NAME}" --push "${CACHE_NAME}" --delete "${CACHE_NAME}" \
  --create-cache "${CACHE_NAME}" --configure-cache "${CACHE_NAME}" \
  --configure-cache-retention "${CACHE_NAME}" --destroy-cache "${CACHE_NAME}" | tr -d '\r\n')"

export XDG_CONFIG_HOME=/tmp/attic-admin-config
install -d -m 700 "${XDG_CONFIG_HOME}/attic"
"${attic}" login --set-default ci "${api_endpoint}" "${admin_token}"

upstream_args=()
while IFS= read -r key_name; do
  [[ -n "${key_name}" ]] && upstream_args+=(--upstream-cache-key-name "${key_name}")
done < <(ci_public_cache_key_names)

if "${attic}" cache info "ci:${CACHE_NAME}" >/dev/null 2>&1; then
  # Rotate every run so the key inside a restored generation is already stale; clients only ever trust this run's fetched key.
  "${attic}" cache configure --regenerate-keypair --public "${upstream_args[@]}" "ci:${CACHE_NAME}"
else
  "${attic}" cache create --public "${upstream_args[@]}" "ci:${CACHE_NAME}"
fi

# `attic cache info` writes its report to stderr.
cache_info="$("${attic}" cache info "ci:${CACHE_NAME}" 2>&1)"
public_key="$(sed -n 's/^[[:space:]]*Public Key:[[:space:]]*//p' <<<"${cache_info}")"
require_signing_key 'the Attic cache signing key' "${public_key}"
curl --fail --silent --show-error "${cache_endpoint}/nix-cache-info" >/dev/null

# Builders get pull/push only; cache creation, deletion, retention and key rotation never leave this machine.
push_token="$("${atticadm}" -f "${ATTIC_CONFIG_FILE}" make-token \
  --sub nix-ci-builder --validity '8 hours' \
  --pull "${CACHE_NAME}" --push "${CACHE_NAME}" | tr -d '\r\n')"

jq -n --arg apiEndpoint "${api_endpoint}" --arg cacheEndpoint "${cache_endpoint}" \
  --arg publicKey "${public_key}" --arg token "${push_token}" \
  '{apiEndpoint: $apiEndpoint, cacheEndpoint: $cacheEndpoint, publicKey: $publicKey, token: $token}' \
  >"${ATTIC_CLIENT_FILE}"
chmod 600 "${ATTIC_CLIENT_FILE}"

notice "Attic is ready at ${cache_endpoint}; persisted data currently uses $(du -sh "${DATA_DIR}" | cut -f1)."
