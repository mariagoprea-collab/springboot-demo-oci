#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 2
  fi
}

require_env "BACKEND_LB_OCID"
require_env "BACKEND_SET_NAME"
require_env "BACKEND_PORT"
require_env "NEW_INSTANCE_IP"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required on runner but not found" >&2
  exit 2
fi

LB_ID="${BACKEND_LB_OCID}"
BACKEND_SET="${BACKEND_SET_NAME}"
PORT="${BACKEND_PORT}"
NEW_IP="${NEW_INSTANCE_IP}"

echo "Updating LB backend set:"
echo "  - LB:          ${LB_ID}"
echo "  - Backend set: ${BACKEND_SET}"
echo "  - Port:        ${PORT}"
echo "  - New IP:      ${NEW_IP}"

BACKENDS_JSON="$(oci lb backend list --load-balancer-id "${LB_ID}" --backend-set-name "${BACKEND_SET}" --output json)"
mapfile -t existing < <(
  echo "${BACKENDS_JSON}" | jq -r '
    (.data // [])
    | .[]
    | (
        (.ipAddress // ."ip-address" // "") as $ip
        | (.port // ."port" // empty) as $port
        | select(($ip | type) == "string" and ($ip | length) > 0)
        | select($port != null)
        | "\($ip):\($port)"
      )
  ' | sed '/^null/d' | sed '/^[[:space:]]*$/d'
)

has_new=false
for b in "${existing[@]:-}"; do
  if [[ "${b}" == "${NEW_IP}:${PORT}" ]]; then
    has_new=true
    break
  fi
done

if [[ "${has_new}" != "true" ]]; then
  echo "Adding backend ${NEW_IP}:${PORT}"
  oci lb backend create \
    --load-balancer-id "${LB_ID}" \
    --backend-set-name "${BACKEND_SET}" \
    --ip-address "${NEW_IP}" \
    --port "${PORT}" \
    --output json >/dev/null
else
  echo "Backend ${NEW_IP}:${PORT} already exists"
fi

echo "Removing old backends (keeping only ${NEW_IP}:${PORT})"
for b in "${existing[@]:-}"; do
  if [[ -z "${b// }" ]]; then
    continue
  fi
  if [[ "${b}" != "${NEW_IP}:${PORT}" ]]; then
    echo "Deleting backend ${b}"
    oci lb backend delete \
      --load-balancer-id "${LB_ID}" \
      --backend-set-name "${BACKEND_SET}" \
      --backend-name "${b}" \
      --force >/dev/null
  fi
done

echo "LB backend set updated."


