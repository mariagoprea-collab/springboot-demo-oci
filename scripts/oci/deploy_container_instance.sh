#!/usr/bin/env bash
set -euo pipefail

log() {
  # Always log to stderr so command substitutions stay clean.
  echo "$*" >&2
}

wait_for_ci_work_request() {
  local wr_id="$1"
  local label="${2:-work-request}"

  if [[ -z "${wr_id}" || "${wr_id}" == "null" ]]; then
    return 0
  fi

  local start now state
  start="$(date +%s)"
  while true; do
    now="$(date +%s)"
    if (( now - start > 1800 )); then
      log "Timed out waiting for ${label} ${wr_id}"
      return 1
    fi

    state="$(
      oci container-instances work-request get \
        --work-request-id "${wr_id}" \
        --output json | jq -r '.data.status // .data."status" // empty'
    )"
    log "${label} status=${state:-unknown} (elapsed=$((now - start))s)"

    case "${state}" in
      SUCCEEDED|Succeeded)
        return 0
        ;;
      FAILED|Failed)
        log "${label} FAILED. Dumping errors (if any):"
        oci container-instances work-request-error list \
          --work-request-id "${wr_id}" \
          --output json >&2 || true
        return 1
        ;;
      CANCELED|Canceled)
        log "${label} CANCELED."
        return 1
        ;;
      *)
        sleep 15
        ;;
    esac
  done
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
FALLBACK_TO_REPLACE_ON_IMAGE_MISMATCH="${FALLBACK_TO_REPLACE_ON_IMAGE_MISMATCH:-true}" # true | false
SHAPE_OCPUS="${SHAPE_OCPUS:-1}"
SHAPE_MEMORY_GB="${SHAPE_MEMORY_GB:-2}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required on runner but not found" >&2
  exit 2
fi

DEPLOY_GIT_SHA="${GITHUB_SHA:-unknown}"
DEPLOY_REPO="${GITHUB_REPOSITORY:-unknown}"

TAGS_JSON="$(
  jq -nc \
    --arg deployedBy "github-actions" \
    --arg gitSha "${DEPLOY_GIT_SHA}" \
    --arg image "${IMAGE}" \
    --arg repo "${DEPLOY_REPO}" \
    '{deployedBy:$deployedBy, gitSha:$gitSha, image:$image, repo:$repo}'
)"
echo "${TAGS_JSON}" > freeform-tags.json

echo "Deploying OCI Container Instance:"
echo "  - Name:   ${CONTAINER_INSTANCE_NAME}"
echo "  - Image:  ${IMAGE}"
echo "  - Mode:   ${DEPLOY_STRATEGY}"
echo "  - Shape:  ${SHAPE} (ocpus=${SHAPE_OCPUS}, memGB=${SHAPE_MEMORY_GB})"
echo "  - Tags:   gitSha=${DEPLOY_GIT_SHA}"

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
      | map(select((.lifecycleState // ."lifecycle-state" // "") | ascii_upcase | IN("DELETED"; "DELETING") | not))
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

  # Delete is async; OCI typically returns a work-request id we can poll.
  local delete_out wr_id
  delete_out="$(
    oci container-instances container-instance delete \
      --container-instance-id "${id}" \
      --force \
      --output json
  )"
  wr_id="$(echo "${delete_out}" | jq -r '."opc-work-request-id" // .opcWorkRequestId // empty')"

  # Prefer polling work request when available (more reliable than polling GET).
  if [[ -n "${wr_id}" && "${wr_id}" != "null" ]]; then
    log "Delete work request: ${wr_id}"
    wait_for_ci_work_request "${wr_id}" "delete(${id})"
    return 0
  fi

  # Fallback: wait until GET no longer returns the resource (silent delete response).
  local start now
  start="$(date +%s)"
  while true; do
    now="$(date +%s)"
    if (( now - start > 1800 )); then
      log "Timed out waiting for deletion of ${id}"
      return 1
    fi

    if ! oci container-instances container-instance get --container-instance-id "${id}" --output json >/dev/null 2>&1; then
      return 0
    fi
    log "Delete progress for ${id}: still present (elapsed=$((now - start))s)"
    sleep 15
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
      --freeform-tags "$(cat freeform-tags.json)" \
      --output json
  )"
  echo "${out}" | jq -r '.data.id'
}

resolve_instance_ips() {
  local id="$1"
  local vnics_json priv pub
  priv=""
  pub=""

  # Prefer list-vnics if available (most reliable).
  set +e
  vnics_json="$(oci container-instances container-instance list-vnics --container-instance-id "${id}" --output json 2>oci_list_vnics_stderr.log)"
  local rc=$?
  set -e

  if [[ $rc -eq 0 && -n "${vnics_json}" ]]; then
    priv="$(echo "${vnics_json}" | jq -r '
      (if type=="array" then . else (.data // []) end)
      | .[0]
      | (.privateIp // ."private-ip" // .privateIpAddress // ."private-ip-address" // empty)
    ' | sed '/^null$/d' | head -n1)"
    pub="$(echo "${vnics_json}" | jq -r '
      (if type=="array" then . else (.data // []) end)
      | .[0]
      | (.publicIp // ."public-ip" // .publicIpAddress // ."public-ip-address" // empty)
    ' | sed '/^null$/d' | head -n1)"
  else
    log "Note: container-instance list-vnics not available or failed (rc=${rc}). Falling back to network VNIC lookup."
    if [[ -s oci_list_vnics_stderr.log ]]; then
      log "list-vnics stderr:"
      sed -n '1,120p' oci_list_vnics_stderr.log >&2 || true
    fi
  fi

  # Fallback: read VNIC OCID(s) from container-instance get response, then query Core Networking.
  if [[ -z "${priv}" || -z "${pub}" ]]; then
    local details vnic_id vnic_json
    details="$(oci container-instances container-instance get --container-instance-id "${id}" --output json)"

    # Best-effort: some responses include IPs directly.
    if [[ -z "${priv}" ]]; then
      priv="$(
        echo "${details}" | jq -r '
          .data
          | (
              (.vnics[0].privateIp // .vnics[0]."private-ip")
              // (.primaryVnic?.privateIp // .primaryVnic?."private-ip")
              // empty
            )
        ' | sed '/^null$/d' | head -n1
      )"
    fi
    if [[ -z "${pub}" ]]; then
      pub="$(
        echo "${details}" | jq -r '
          .data
          | (
              (.vnics[0].publicIp // .vnics[0]."public-ip")
              // (.primaryVnic?.publicIp // .primaryVnic?."public-ip")
              // empty
            )
        ' | sed '/^null$/d' | head -n1
      )"
    fi

    # If still missing, extract VNIC OCID and query `oci network vnic get`.
    if [[ -z "${priv}" || -z "${pub}" ]]; then
      vnic_id="$(
        echo "${details}" | jq -r '
          .data
          | (
              .vnics[0].vnicId
              // .vnics[0]."vnic-id"
              // .vnics[0].id
              // .vnics[0]."id"
              // .primaryVnic?.vnicId
              // .primaryVnic?."vnic-id"
              // empty
            )
        ' | sed '/^null$/d' | head -n1
      )"

      if [[ -n "${vnic_id}" ]]; then
        log "Resolving IPs via Core Networking VNIC: ${vnic_id}"
        vnic_json="$(oci network vnic get --vnic-id "${vnic_id}" --output json)"
        # Helpful debug if parsing fails (safe: no secrets here).
        echo "${vnic_json}" > oci_vnic_get.json

        if [[ -z "${priv}" ]]; then
          priv="$(echo "${vnic_json}" | jq -r '
            .data
            | (
                .privateIp
                // ."private-ip"
                // .privateIpAddress
                // ."private-ip-address"
                // .ipAddress
                // ."ip-address"
                // empty
              )
          ' | sed '/^null$/d' | head -n1)"
        fi
        if [[ -z "${pub}" ]]; then
          pub="$(echo "${vnic_json}" | jq -r '
            .data
            | (
                .publicIp
                // ."public-ip"
                // .publicIpAddress
                // ."public-ip-address"
                // empty
              )
          ' | sed '/^null$/d' | head -n1)"
        fi

        # Super-defensive fallback: search for IPv4-looking strings in the VNIC payload.
        if [[ -z "${priv}" ]]; then
          # Prefer explicit key names when present anywhere in the tree.
          priv="$(echo "${vnic_json}" | jq -r '
            .. | objects
            | (.privateIp? // .privateIpAddress? // .ipAddress? // ."private-ip"? // ."private-ip-address"? // ."ip-address"? // empty)
            | select(type=="string")
            | gsub("\\s+$";"")
            | select(test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"))
          ' | head -n1)"
        fi
        if [[ -z "${priv}" ]]; then
          # Last resort: first IPv4-looking string anywhere.
          priv="$(echo "${vnic_json}" | jq -r '
            .. | select(type=="string")
            | gsub("\\s+$";"")
            | select(test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"))
          ' | head -n1)"
        fi
        if [[ -z "${pub}" ]]; then
          pub="$(echo "${vnic_json}" | jq -r '
            .. | objects
            | (.publicIp? // .publicIpAddress? // ."public-ip"? // ."public-ip-address"? // empty)
            | select(type=="string")
            | gsub("\\s+$";"")
            | select(test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"))
          ' | head -n1)"
        fi

        # If public IP still missing, try publicIpId -> public-ip get.
        if [[ -z "${pub}" ]]; then
          local pub_id
          pub_id="$(echo "${vnic_json}" | jq -r '.data.publicIpId // .data."public-ip-id" // empty' | sed '/^null$/d' | head -n1)"
          if [[ -n "${pub_id}" ]]; then
            local pub_json
            pub_json="$(oci network public-ip get --public-ip-id "${pub_id}" --output json)"
            pub="$(echo "${pub_json}" | jq -r '.data.ipAddress // .data."ip-address" // empty' | sed '/^null$/d' | head -n1)"
          fi
        fi

        if [[ -z "${priv}" ]]; then
          log "Could not parse private IP from `oci network vnic get` response. Debug keys:"
          jq -r '.data | keys[]' oci_vnic_get.json 2>/dev/null | head -n 50 | while read -r k; do log "  - ${k}"; done
          log "VNIC field sample:"
          jq -r '.data | {privateIp, publicIp, privateIpAddress, publicIpId, subnetId, vcnId} | tostring' oci_vnic_get.json 2>/dev/null >&2 || true
        fi
      else
        log "Could not find VNIC OCID on container instance get response; cannot resolve IPs automatically."
      fi
    fi
  fi

  [[ -n "${priv:-}" && "${priv}" != "null" ]] && echo "NEW_INSTANCE_PRIVATE_IP=${priv}" >> "${GITHUB_ENV}"
  [[ -n "${pub:-}" && "${pub}" != "null" ]] && echo "NEW_INSTANCE_PUBLIC_IP=${pub}" >> "${GITHUB_ENV}"
}

get_instance_images() {
  local id="$1"
  oci container-instances container-instance get \
    --container-instance-id "$id" \
    --output json | jq -r '
      def containers:
        (
          (.data.containers? // empty),
          (.data."containers"? // empty),
          (.data.containerConfig.containers? // empty),
          (.data."container-config".containers? // empty),
          (.data.containerConfiguration.containers? // empty)
        )
        | if type == "array" then . else empty end;

      [containers]
      | add
      | if type == "array" then . else [] end
      | map(
          .imageUrl
          // ."image-url"
          // .image
          // ."image"
          // empty
        )
      | .[]
    ' | sed '/^$/d' || true
}

get_instance_containers_debug() {
  local id="$1"
  oci container-instances container-instance get \
    --container-instance-id "$id" \
    --output json | jq -r '
      .data as $d
      | [
          ("lifecycleState=" + ($d.lifecycleState // $d."lifecycle-state" // "unknown")),
          ("displayName=" + ($d.displayName // $d."display-name" // "unknown")),
          ("has.data.containers=" + ((($d.containers? // $d."containers"?) | type) // "missing")),
          ("has.data.containerConfig.containers=" + (((($d.containerConfig? // $d."container-config"? // $d.containerConfiguration?) | .containers?) | type) // "missing"))
        ]
      | .[]
    ' 2>/dev/null || true
}

update_instance() {
  local id="$1"
  log "Updating container instance: ${id}"

  # OCI CLI for Container Instances has differed across versions.
  # We try the newer/cleaner "update details" form first, then fall back to --from-json.
  cat > update-details.json <<EOF
{
  "containers": $(cat containers.json),
  "containerConfig": { "containers": $(cat containers.json) },
  "shapeConfig": $(cat shape-config.json),
  "freeformTags": $(cat freeform-tags.json)
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
    --output json 1>oci_update_stdout_1.log 2>oci_update_stderr_1.log
  local rc=$?
  local out_file="oci_update_stdout_1.log"
  local err_file="oci_update_stderr_1.log"

  if [[ $rc -ne 0 ]]; then
    # Fallback: try from-json format (older/newer CLI variants).
    oci container-instances container-instance update \
      --from-json file://update-from-json.json \
      --output json 1>oci_update_stdout_2.log 2>oci_update_stderr_2.log
    rc=$?
    out_file="oci_update_stdout_2.log"
    err_file="oci_update_stderr_2.log"
  fi
  set -e

  if [[ $rc -ne 0 ]]; then
    log "OCI update failed (rc=$rc). STDOUT/STDERR below:"
    log "=============== UPDATE STDOUT ==============="
    cat "${out_file}" >&2 || true
    log "=============== UPDATE STDERR ==============="
    cat "${err_file}" >&2 || true
    return $rc
  fi

  # If the update returns a work request, wait for it. This avoids "deploy succeeded"
  # while the instance is still pulling/restarting containers.
  local wr_id
  wr_id="$(jq -r '."opc-work-request-id" // .opcWorkRequestId // empty' "${out_file}" 2>/dev/null || true)"
  if [[ -n "${wr_id}" && "${wr_id}" != "null" ]]; then
    log "Update work request: ${wr_id}"
    wait_for_ci_work_request "${wr_id}" "update(${id})"
  fi
}

NEW_INSTANCE_ID=""
if [[ "${DEPLOY_STRATEGY}" == "replace" ]]; then
  echo "Replace strategy: delete all matching instances, then create a fresh one."
  echo "DID_REPLACE=true" >> "${GITHUB_ENV}"
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
    # Ensure instance is back to ACTIVE after update.
    wait_for_state_in "${NEW_INSTANCE_ID}" 1800 "ACTIVE" "Active"

    # Validate OCI reports the intended image (some update paths can be a no-op).
    # Give OCI a moment for eventual consistency if fields are lagging.
    reported_images=()
    for attempt in 1 2 3 4; do
      mapfile -t reported_images < <(get_instance_images "${NEW_INSTANCE_ID}")
      if (( ${#reported_images[@]} > 0 )); then
        break
      fi
      sleep 10
    done

    if (( ${#reported_images[@]} == 0 )); then
      log "Warning: OCI did not report any container image values for ${NEW_INSTANCE_ID} (after update)."
      log "OCI response shape hints:"
      get_instance_containers_debug "${NEW_INSTANCE_ID}" | while read -r line; do log "  - ${line}"; done

      if [[ "${FALLBACK_TO_REPLACE_ON_IMAGE_MISMATCH}" == "true" ]]; then
        log "Falling back to REPLACE because we cannot verify the running image via OCI API fields."
        echo "DID_REPLACE=true" >> "${GITHUB_ENV}"
        for id in "${ids[@]}"; do
          delete_instance_and_wait_gone "${id}"
        done
        NEW_INSTANCE_ID="$(create_instance)"
        wait_for_state_in "${NEW_INSTANCE_ID}" 1800 "ACTIVE" "Active"
      else
        log "FALLBACK_TO_REPLACE_ON_IMAGE_MISMATCH=false so not replacing. Exiting with failure."
        exit 1
      fi
    else
      log "OCI reports container image(s):"
      for img in "${reported_images[@]}"; do
        log "  - ${img}"
      done
      local matched=false
      for img in "${reported_images[@]}"; do
        if [[ "${img}" == "${IMAGE}" ]]; then
          matched=true
          break
        fi
      done

      if [[ "${matched}" != "true" ]]; then
        log "OCI still does NOT report the desired image (${IMAGE}) after update."
        if [[ "${FALLBACK_TO_REPLACE_ON_IMAGE_MISMATCH}" == "true" ]]; then
          log "Falling back to REPLACE to guarantee the new image is deployed."
          echo "DID_REPLACE=true" >> "${GITHUB_ENV}"
          for id in "${ids[@]}"; do
            delete_instance_and_wait_gone "${id}"
          done
          NEW_INSTANCE_ID="$(create_instance)"
          wait_for_state_in "${NEW_INSTANCE_ID}" 1800 "ACTIVE" "Active"
        else
          log "FALLBACK_TO_REPLACE_ON_IMAGE_MISMATCH=false so not replacing. Exiting with failure."
          exit 1
        fi
      fi
    fi

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

# Resolve instance IPs for LB update.
resolve_instance_ips "${NEW_INSTANCE_ID}" || true

# Choose IP to use for LB update.
BACKEND_IP_TYPE="${BACKEND_IP_TYPE:-private}" # private | public
NEW_INSTANCE_IP=""
if [[ "${BACKEND_IP_TYPE}" == "public" ]]; then
  NEW_INSTANCE_IP="${NEW_INSTANCE_PUBLIC_IP:-}"
else
  NEW_INSTANCE_IP="${NEW_INSTANCE_PRIVATE_IP:-}"
fi
if [[ -n "${NEW_INSTANCE_IP}" ]]; then
  echo "NEW_INSTANCE_IP=${NEW_INSTANCE_IP}" >> "${GITHUB_ENV}"
fi

# Try to extract a reasonable IP for downstream steps (LB update).
DETAILS="$(oci container-instances container-instance get --container-instance-id "${NEW_INSTANCE_ID}" --output json)"

log "Post-deploy verification (OCI):"
echo "${DETAILS}" | jq -r '.data | "  - lifecycleState=\(.lifecycleState // ."lifecycle-state" // "unknown")\n  - displayName=\(.displayName // ."display-name" // "unknown")"' >&2 || true
echo "${DETAILS}" | jq -r '.data | "  - freeformTags=" + ((.freeformTags // ."freeform-tags" // {})|tostring)' >&2 || true
echo "${DETAILS}" | jq -r '
  def containers:
    (
      (.data.containers? // empty),
      (.data."containers"? // empty),
      (.data.containerConfig.containers? // empty),
      (.data."container-config".containers? // empty),
      (.data.containerConfiguration.containers? // empty)
    )
    | if type == "array" then . else empty end;

  ([containers] | add) as $cs
  | "  - containers:\n"
    + (
      ($cs // [])
      | map(
          "    - "
          + ((.displayName // ."display-name" // "container")|tostring)
          + ": "
          + ((.imageUrl // ."image-url" // .image // ."image" // "unknown")|tostring)
        )
      | join("\n")
    )
' >&2 || true

if [[ -n "${NEW_INSTANCE_IP:-}" ]]; then
  log "Resolved NEW_INSTANCE_IP (${BACKEND_IP_TYPE}) = ${NEW_INSTANCE_IP}"
else
  log "Could not resolve NEW_INSTANCE_IP; LB update will not work until IP resolution is fixed or provided manually."
  if [[ -f oci_vnic_get.json ]]; then
    log "Debug: first IPv4-ish strings found in VNIC payload:"
    jq -r '.. | select(type=="string") | select(test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"))' oci_vnic_get.json 2>/dev/null | head -n 10 | while read -r ip; do log "  - ${ip}"; done
  fi
fi


