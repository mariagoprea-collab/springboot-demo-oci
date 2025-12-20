#!/usr/bin/env bash
set -euo pipefail

log() {
  # Always log to stderr so command substitutions stay clean.
  echo "$*" >&2
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: ${name}" >&2
    exit 2
  fi
}

require_env "COMPARTMENT_ID"
require_env "SUBNET_ID"
require_env "SHAPE"
require_env "CONTAINER_INSTANCE_NAME"
require_env "CONTAINER_DISPLAY_NAME"
require_env "IMAGE"
require_env "DB_HOST"
require_env "DB_NAME"
require_env "DB_USER"
require_env "DB_PASS"

DEPLOY_STRATEGY="${DEPLOY_STRATEGY:-update}" # update | replace
CLEANUP_DUPLICATES="${CLEANUP_DUPLICATES:-true}" # true | false (only used for update strategy)
SHAPE_OCPUS="${SHAPE_OCPUS:-1}"
SHAPE_MEMORY_GB="${SHAPE_MEMORY_GB:-2}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required on runner but not found" >&2
  exit 2
fi

echo "Deploying OCI Container Instance:"
echo "  - Name:   ${CONTAINER_INSTANCE_NAME}"
echo "  - Image:  ${IMAGE}"
echo "  - Mode:   ${DEPLOY_STRATEGY}"
echo "  - Shape:  ${SHAPE} (ocpus=${SHAPE_OCPUS}, memGB=${SHAPE_MEMORY_GB})"

AVAILABILITY_DOMAIN="$(
  oci iam availability-domain list \
    --compartment-id "${COMPARTMENT_ID}" \
    --output json | jq -r '.data[0].name'
)"
if [[ -z "${AVAILABILITY_DOMAIN}" || "${AVAILABILITY_DOMAIN}" == "null" ]]; then
  echo "Failed to discover availability domain." >&2
  exit 1
fi
echo "Using availability domain: ${AVAILABILITY_DOMAIN}"

cat > containers.json <<EOF
[
  {
    "displayName": "${CONTAINER_DISPLAY_NAME}",
    "imageUrl": "${IMAGE}",
    "environmentVariables": {
      "SPRING_DATASOURCE_URL": "jdbc:postgresql://${DB_HOST}:5432/${DB_NAME}",
      "SPRING_DATASOURCE_USERNAME": "${DB_USER}",
      "SPRING_DATASOURCE_PASSWORD": "${DB_PASS}",
      "SERVER_ADDRESS": "0.0.0.0"
    },
    "portMappings": [
      { "containerPort": 8080, "protocol": "TCP" }
    ]
  }
]
EOF

cat > vnics.json <<EOF
[
  { "subnetId": "${SUBNET_ID}", "assignPublicIp": true }
]
EOF

cat > shape-config.json <<EOF
{ "ocpus": ${SHAPE_OCPUS}, "memoryInGBs": ${SHAPE_MEMORY_GB} }
EOF

list_matching_instance_ids() {
  oci container-instances container-instance list \
    --compartment-id "${COMPARTMENT_ID}" \
    --all \
    --output json | jq -r --arg name "${CONTAINER_INSTANCE_NAME}" '
      # Normalize list output across OCI CLI variations:
      # - [...]
      # - { data: [...] }
      # - { data: { items: [...] } }
      def items:
        if type == "array" then .
        elif (has("data") and (.data|type) == "array") then .data
        elif (has("data") and (.data|type) == "object" and (.data|has("items"))) then (.data.items // [])
        elif has("items") then (.items // [])
        else [] end;

      items
      | map(select(type == "object"))
      | map(select((.displayName // ."display-name" // "") == $name))
      | sort_by(.timeCreated // ."time-created" // "")
      | reverse
      | .[]
      | (.id // empty)
    ' | sed '/^null$/d' || true
}

get_instance_state() {
  local id="$1"
  oci container-instances container-instance get \
    --container-instance-id "$id" \
    --output json | jq -r '.data.lifecycleState // .data."lifecycle-state" // empty'
}

wait_for_state_in() {
  local id="$1"
  local timeout_seconds="$2"
  shift 2
  local desired=("$@")

  local start
  start="$(date +%s)"
  while true; do
    local now state
    now="$(date +%s)"
    if (( now - start > timeout_seconds )); then
      echo "Timed out waiting for ${id} to reach one of: ${desired[*]}" >&2
      echo "Last known state: $(get_instance_state "$id" || true)" >&2
      return 1
    fi

    state="$(get_instance_state "$id" || true)"
    for s in "${desired[@]}"; do
      if [[ "${state}" == "${s}" ]]; then
        return 0
      fi
    done
    sleep 10
  done
}

delete_instance_and_wait_gone() {
  local id="$1"
  log "Deleting container instance: ${id}"
  oci container-instances container-instance delete --container-instance-id "${id}" --force

  # Wait until get fails or state becomes a terminal one.
  local start now
  start="$(date +%s)"
  while true; do
    now="$(date +%s)"
    if (( now - start > 1200 )); then
      echo "Timed out waiting for deletion of ${id}" >&2
      return 1
    fi

    if ! oci container-instances container-instance get --container-instance-id "${id}" --output json >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
}

create_instance() {
  log "Creating container instance: ${CONTAINER_INSTANCE_NAME}"
  local out
  out="$(
    oci container-instances container-instance create \
      --availability-domain "${AVAILABILITY_DOMAIN}" \
      --compartment-id "${COMPARTMENT_ID}" \
      --display-name "${CONTAINER_INSTANCE_NAME}" \
      --shape "${SHAPE}" \
      --shape-config file://shape-config.json \
      --containers file://containers.json \
      --vnics file://vnics.json \
      --output json
  )"
  echo "${out}" | jq -r '.data.id'
}

update_instance() {
  local id="$1"
  log "Updating container instance: ${id}"

  # OCI CLI for Container Instances has differed across versions.
  # We try the newer/cleaner "update details" form first, then fall back to --from-json.
  cat > update-details.json <<EOF
{
  "containers": $(cat containers.json),
  "shapeConfig": $(cat shape-config.json)
}
EOF

  cat > update-from-json.json <<EOF
{
  "containerInstanceId": "${id}",
  "updateContainerInstanceDetails": $(cat update-details.json)
}
EOF

  set +e
  oci container-instances container-instance update \
    --container-instance-id "${id}" \
    --update-container-instance-details file://update-details.json \
    --output json 1>oci_update_stdout.log 2>oci_update_stderr.log
  local rc=$?

  if [[ $rc -ne 0 ]]; then
    # Fallback: try from-json format (older/newer CLI variants).
    oci container-instances container-instance update \
      --from-json file://update-from-json.json \
      --output json 1>>oci_update_stdout.log 2>>oci_update_stderr.log
    rc=$?
  fi
  set -e

  if [[ $rc -ne 0 ]]; then
    log "OCI update failed (rc=$rc). STDOUT/STDERR below:"
    log "=============== UPDATE STDOUT ==============="
    cat oci_update_stdout.log >&2 || true
    log "=============== UPDATE STDERR ==============="
    cat oci_update_stderr.log >&2 || true
    return $rc
  fi
}

NEW_INSTANCE_ID=""
if [[ "${DEPLOY_STRATEGY}" == "replace" ]]; then
  echo "Replace strategy: delete all matching instances, then create a fresh one."
  mapfile -t ids < <(list_matching_instance_ids)
  if (( ${#ids[@]} > 0 )); then
    for id in "${ids[@]}"; do
      delete_instance_and_wait_gone "${id}"
    done
  else
    echo "No existing instances found for displayName=${CONTAINER_INSTANCE_NAME}"
  fi
  NEW_INSTANCE_ID="$(create_instance)"
  wait_for_state_in "${NEW_INSTANCE_ID}" 1800 "ACTIVE" "Active"
elif [[ "${DEPLOY_STRATEGY}" == "update" ]]; then
  echo "Update strategy: update newest matching instance, otherwise create."
  mapfile -t ids < <(list_matching_instance_ids)
  if (( ${#ids[@]} > 0 )); then
    NEW_INSTANCE_ID="${ids[0]}"
    update_instance "${NEW_INSTANCE_ID}"
    # Some tenants briefly go through UPDATING then ACTIVE.
    wait_for_state_in "${NEW_INSTANCE_ID}" 1800 "ACTIVE" "Active" "UPDATING" "Updating"
    if [[ "${CLEANUP_DUPLICATES}" == "true" ]] && (( ${#ids[@]} > 1 )); then
      log "Found ${#ids[@]} instances named ${CONTAINER_INSTANCE_NAME}. Cleaning up older duplicates (keeping newest: ${NEW_INSTANCE_ID})"
      for ((i=1; i<${#ids[@]}; i++)); do
        delete_instance_and_wait_gone "${ids[$i]}"
      done
    fi
  else
    NEW_INSTANCE_ID="$(create_instance)"
    wait_for_state_in "${NEW_INSTANCE_ID}" 1800 "ACTIVE" "Active"
  fi
else
  echo "Unknown DEPLOY_STRATEGY=${DEPLOY_STRATEGY}. Expected update|replace." >&2
  exit 2
fi

echo "Deployed container instance id: ${NEW_INSTANCE_ID}"
echo "CONTAINER_INSTANCE_ID=${NEW_INSTANCE_ID}" >> "${GITHUB_ENV}"

# Try to extract a reasonable IP for downstream steps (LB update).
DETAILS="$(oci container-instances container-instance get --container-instance-id "${NEW_INSTANCE_ID}" --output json)"
NEW_IP="$(
  echo "${DETAILS}" | jq -r '
    .data
    | (
        .publicIp
        // ."public-ip"
        // .ipAddress
        // ."ip-address"
        // (.vnics[0].publicIp // .vnics[0]."public-ip")
        // (.vnics[0].privateIp // .vnics[0]."private-ip")
      )
  '
)"
if [[ -n "${NEW_IP}" && "${NEW_IP}" != "null" ]]; then
  echo "Resolved new instance IP: ${NEW_IP}"
  echo "NEW_INSTANCE_IP=${NEW_IP}" >> "${GITHUB_ENV}"
else
  echo "Could not resolve instance IP from OCI response; LB update (if enabled) may need manual NEW_INSTANCE_IP." >&2
fi


