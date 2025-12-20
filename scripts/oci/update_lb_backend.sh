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
HEALTH_TIMEOUT_SECONDS="${LB_HEALTH_TIMEOUT_SECONDS:-600}"
HEALTH_POLL_SECONDS="${LB_HEALTH_POLL_SECONDS:-10}"

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

echo "Waiting for backend ${NEW_IP}:${PORT} to become healthy (timeout=${HEALTH_TIMEOUT_SECONDS}s)"
start="$(date +%s)"
while true; do
  now="$(date +%s)"
  if (( now - start > HEALTH_TIMEOUT_SECONDS )); then
    echo "Timed out waiting for backend health: ${NEW_IP}:${PORT}" >&2
    # Dump health details for debugging.
    oci lb backend-health get \
      --load-balancer-id "${LB_ID}" \
      --backend-set-name "${BACKEND_SET}" \
      --backend-name "${NEW_IP}:${PORT}" \
      --output json || true
    exit 1
  fi

  # OCI is sometimes eventually consistent right after backend create; health endpoint can 404 briefly.
  # Step 1: ensure the backend is visible in list.
  if ! oci lb backend get \
      --load-balancer-id "${LB_ID}" \
      --backend-set-name "${BACKEND_SET}" \
      --backend-name "${NEW_IP}:${PORT}" \
      --output json >/dev/null 2>&1; then
    echo "Backend not visible yet (waiting) (elapsed=$((now-start))s)"
    sleep "${HEALTH_POLL_SECONDS}"
    continue
  fi

  set +e
  health_json="$(
    oci lb backend-health get \
      --load-balancer-id "${LB_ID}" \
      --backend-set-name "${BACKEND_SET}" \
      --backend-name "${NEW_IP}:${PORT}" \
      --output json 2>oci_backend_health_err.log
  )"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    # Treat 404 NotAuthorizedOrNotFound as "not ready yet" until timeout; could be eventual consistency.
    if grep -q '"code": "NotAuthorizedOrNotFound"' oci_backend_health_err.log 2>/dev/null; then
      echo "Backend health endpoint not ready yet (404). Retrying... (elapsed=$((now-start))s)"
      sleep "${HEALTH_POLL_SECONDS}"
      continue
    fi
    echo "Failed to query backend health (rc=${rc}). Error:" >&2
    cat oci_backend_health_err.log >&2 || true
    exit $rc
  fi

  # OCI health status is usually OK/WARNING/CRITICAL/UNKNOWN.
  status="$(echo "${health_json}" | jq -r '.data.status // .data."status" // empty')"
  echo "Backend health status=${status:-unknown} (elapsed=$((now-start))s)"
  if [[ "${status}" == "OK" || "${status}" == "WARNING" ]]; then
    break
  fi
  sleep "${HEALTH_POLL_SECONDS}"
done

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


