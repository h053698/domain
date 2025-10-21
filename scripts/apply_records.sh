#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/apply_records.sh <cloudflare_token> <domain_dir>=<zone_id> [<domain_dir>=<zone_id>...]

Synchronises multiple Cloudflare zones with the manifests stored under each domain directory.

Example:
  scripts/apply_records.sh "$CF_TOKEN" \
    "sunrin.io=$CF_ZONE_SUNRIN_IO" \
    "swfestival.kr=$CF_ZONE_SWFESTIVAL_KR"
USAGE
}

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 1
fi

CF_TOKEN="$1"
shift

if [[ -z "$CF_TOKEN" ]]; then
  echo "Cloudflare token must be provided as the first argument." >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required but not found in PATH." >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required but not found in PATH." >&2
  exit 127
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BASE="https://api.cloudflare.com/client/v4"

DOMAIN_DIRS=()
DOMAIN_ZONES=()

for mapping in "$@"; do
  if [[ "$mapping" != *=* ]]; then
    echo "Invalid mapping '$mapping'. Use <domain_dir>=<zone_id>." >&2
    exit 1
  fi
  dir="${mapping%%=*}"
  zone="${mapping#*=}"

  if [[ -z "$dir" || -z "$zone" ]]; then
    echo "Invalid mapping '$mapping'. Directory and zone id must be non-empty." >&2
    exit 1
  fi

  DOMAIN_DIRS+=("$dir")
  DOMAIN_ZONES+=("$zone")
done

TMP_ITEMS=()
cleanup() {
  for item in "${TMP_ITEMS[@]}"; do
    rm -f "$item" 2>/dev/null || true
  done
}
trap cleanup EXIT

sync_domain() {
  local manifest_input="$1"
  local zone_id="$2"
  local response message

  local manifest_dir
  if [[ "$manifest_input" = /* ]]; then
    manifest_dir="$manifest_input"
  else
    manifest_dir="$REPO_ROOT/$manifest_input"
  fi

  if [[ ! -d "$manifest_dir" ]]; then
    echo "Manifest directory '$manifest_input' not found." >&2
    return 1
  fi

  local tmp_manifest tmp_cloud
  tmp_manifest="$(mktemp)"
  tmp_cloud="$(mktemp)"
  TMP_ITEMS+=("$tmp_manifest" "$tmp_cloud")

  : >"$tmp_manifest"

  local manifest_count=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    local absolute_path="$file"
    local relative="${absolute_path#$REPO_ROOT/}"
    local record_json
    record_json="$(yq e -o=json -I=0 '.record' "$absolute_path")"
    jq -c --arg file "$relative" '
      {
        file: $file,
        type: .type,
        name: .name,
        content: .value,
        ttl: .ttl,
        proxied: (if has("proxied") then .proxied else null end),
        priority: (if has("priority") then .priority else null end),
        comment: (if has("comment") then .comment else null end)
      }
    ' <<<"$record_json" >>"$tmp_manifest"
    manifest_count=$((manifest_count + 1))
  done < <(find "$manifest_dir" -type f -name '*.yaml' | sort)

  if (( manifest_count == 0 )); then
    echo "No manifest files found in $manifest_dir. Skipping."
    return 0
  fi

  local manifest_records_json
  manifest_records_json="$(jq -s '.' "$tmp_manifest")"

  : >"$tmp_cloud"
  local page=1
  local total_pages=1

  while (( page <= total_pages )); do
    response="$(curl -sS -X GET \
      -H "Authorization: Bearer $CF_TOKEN" \
      -H "Content-Type: application/json" \
      "$API_BASE/zones/$zone_id/dns_records?per_page=100&page=$page")"

    if [[ "$(jq -r '.success' <<<"$response")" != "true" ]]; then
      message="$(jq -r '.errors | map(.message) | join("; ")' <<<"$response")"
      echo "[$manifest_input] Failed to fetch DNS records: ${message:-unknown error}" >&2
      return 1
    fi

    jq -c '
      .result[]
      | select(.type == "A" or .type == "CNAME" or .type == "TXT")
      | {
          id: .id,
          type: .type,
          name: .name,
          content: .content,
          ttl: .ttl,
          proxied: (if has("proxied") then .proxied else null end),
          priority: (if has("priority") then .priority else null end),
          comment: (.comment // null)
        }
    ' <<<"$response" >>"$tmp_cloud"

    total_pages=$(jq '.result_info.total_pages // 1' <<<"$response")
    page=$((page + 1))
  done

  local cloudflare_records_json
  cloudflare_records_json="$(jq -s '.' "$tmp_cloud")"

  local records_to_delete
  records_to_delete="$(jq --argjson manifests "$manifest_records_json" '
    [ .[] as $cf
      | select(($manifests | any(.type == $cf.type and .name == $cf.name)) | not)
    ]
  ' <<<"$cloudflare_records_json")"

  local records_to_create
  records_to_create="$(jq --argjson cloud "$cloudflare_records_json" '
    [ .[] as $manifest
      | select(($cloud | any(.type == $manifest.type and .name == $manifest.name)) | not)
    ]
  ' <<<"$manifest_records_json")"

  local records_to_update
  records_to_update="$(jq --argjson cloud "$cloudflare_records_json" '
    [ .[] as $desired
      | ($cloud | map(select(.type == $desired.type and .name == $desired.name))[0]) as $current
      | select($current != null)
      | select(
          ($current.content != $desired.content)
          or ($current.ttl != $desired.ttl)
          or (
            ($desired.type == "A" or $desired.type == "CNAME")
            and (($current.proxied // false) != ($desired.proxied // false))
          )
          or (($current.priority // null) != ($desired.priority // null))
          or (($current.comment // "") != ($desired.comment // ""))
        )
      | {existing: $current, desired: $desired}
    ]
  ' <<<"$manifest_records_json")"

  local records_deleted records_created records_updated
  records_deleted=$(jq 'length' <<<"$records_to_delete")
  records_created=$(jq 'length' <<<"$records_to_create")
  records_updated=$(jq 'length' <<<"$records_to_update")

  echo "== Syncing ${manifest_dir#$REPO_ROOT/} (zone: $zone_id) =="
  echo " - to create: $records_created"
  echo " - to update: $records_updated"
  echo " - to delete: $records_deleted"

  if (( records_deleted > 0 )); then
    echo "Deleting records..."
    while IFS= read -r record; do
      id=$(jq -r '.id' <<<"$record")
      name=$(jq -r '.name' <<<"$record")
      type=$(jq -r '.type' <<<"$record")
      echo "   • DELETE $type $name"
      resp="$(curl -sS -X DELETE \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        "$API_BASE/zones/$zone_id/dns_records/$id")"
      if [[ "$(jq -r '.success' <<<"$resp")" != "true" ]]; then
        message="$(jq -r '.errors | map(.message) | join("; ")' <<<"$resp")"
        echo "   ! Failed to delete $type $name: ${message:-unknown error}" >&2
        return 1
      fi
    done < <(jq -c '.[]' <<<"$records_to_delete")
  fi

  if (( records_updated > 0 )); then
    echo "Updating records..."
    while IFS= read -r entry; do
      desired=$(jq '.desired' <<<"$entry")
      existing_id=$(jq -r '.existing.id' <<<"$entry")
      type=$(jq -r '.desired.type' <<<"$entry")
      name=$(jq -r '.desired.name' <<<"$entry")
      file=$(jq -r '.desired.file' <<<"$entry")

      payload=$(jq -c '
        {
          type,
          name,
          content,
          ttl
        }
        + (if (.comment // "") != "" then {comment: .comment} else {} end)
        + (if (.priority // null) != null then {priority: .priority} else {} end)
        + (if (.type == "A" or .type == "CNAME") then {proxied: (.proxied // false)} else {} end)
      ' <<<"$desired")

      echo "   • UPDATE $type $name (from $file)"
      resp="$(curl -sS -X PUT \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$API_BASE/zones/$zone_id/dns_records/$existing_id")"
      if [[ "$(jq -r '.success' <<<"$resp")" != "true" ]]; then
        message="$(jq -r '.errors | map(.message) | join("; ")' <<<"$resp")"
        echo "   ! Failed to update $type $name: ${message:-unknown error}" >&2
        return 1
      fi
    done < <(jq -c '.[]' <<<"$records_to_update")
  fi

  if (( records_created > 0 )); then
    echo "Creating records..."
    while IFS= read -r record; do
      type=$(jq -r '.type' <<<"$record")
      name=$(jq -r '.name' <<<"$record")
      file=$(jq -r '.file' <<<"$record")

      payload=$(jq -c '
        {
          type,
          name,
          content,
          ttl
        }
        + (if (.comment // "") != "" then {comment: .comment} else {} end)
        + (if (.priority // null) != null then {priority: .priority} else {} end)
        + (if (.type == "A" or .type == "CNAME") then {proxied: (.proxied // false)} else {} end)
      ' <<<"$record")

      echo "   • CREATE $type $name (from $file)"
      resp="$(curl -sS -X POST \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "$API_BASE/zones/$zone_id/dns_records")"
      if [[ "$(jq -r '.success' <<<"$resp")" != "true" ]]; then
        message="$(jq -r '.errors | map(.message) | join("; ")' <<<"$resp")"
        echo "   ! Failed to create $type $name: ${message:-unknown error}" >&2
        return 1
      fi
    done < <(jq -c '.[]' <<<"$records_to_create")
  fi

  echo "Finished syncing ${manifest_dir#$REPO_ROOT/}."
  return 0
}

overall_status=0
for i in "${!DOMAIN_DIRS[@]}"; do
  dir="${DOMAIN_DIRS[$i]}"
  zone="${DOMAIN_ZONES[$i]}"
  if ! sync_domain "$dir" "$zone"; then
    overall_status=1
  fi
done

if (( overall_status == 0 )); then
  echo "All domains synced successfully."
else
  echo "Some domains failed to sync." >&2
fi

exit "$overall_status"
