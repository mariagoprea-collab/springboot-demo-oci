#!/usr/bin/env bash
set -euo pipefail

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 2
  fi
}

require_env "OLD_INSTANCE_IDS"
require_env "CONTAINER_INSTANCE_ID" # the new one

NEW_ID="${CONTAINER_INSTANCE_ID}"

log() { echo "$*" >&2; }

delete_if_needed() {
  local id="$1"
  if [[ -z "${id}" ]]; then
    return 0
  fi
  if [[ "${id}" == "${NEW_ID}" ]]; then
    return 0
  fi

  # Skip if already deleted/not found.
  set +e
  local state
  state="$(oci container-instances container-instance get --container-instance-id "${id}" --output json 2>/dev/null | jq -r '.data.lifecycleState // .data."lifecycle-state" // empty')"
  local rc=$?
  set -e
  if [[ $rc -ne 0 || -z "${state}" ]]; then
    log "Skip delete (not found): ${id}"
    return 0
  fi
  case "$(echo "${state}" | tr '[:lower:]' '[:upper:]')" in
    DELETED)
      log "Skip delete (already DELETED): ${id}"
      return 0
      ;;
  esac

  log "Deleting old container instance: ${id} (state=${state})"
  local out wr_id
  out="$(oci container-instances container-instance delete --container-instance-id "${id}" --force --output json)"
  wr_id="$(echo "${out}" | jq -r '."opc-work-request-id" // .opcWorkRequestId // empty')"
  if [[ -n "${wr_id}" && "${wr_id}" != "null" ]]; then
    log "Delete work request: ${wr_id}"
  fi
}

log "Cleaning up old instances after cutover (keeping ${NEW_ID})"

# OLD_INSTANCE_IDS is newline-separated.
while IFS= read -r id; do
  # Trim whitespace
  id="$(echo "${id}" | sed 's/[[:space:]]//g')"
  delete_if_needed "${id}"
done <<< "${OLD_INSTANCE_IDS}"

log "Cleanup complete."


