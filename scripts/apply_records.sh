#!/usr/bin/env bash

set -euo pipefail

CF_TOKEN="$1"
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BASE="https://api.cloudflare.com/client/v4"

DOMAIN_DIRS=()
DOMAIN_ZONES=()

for mapping in "$@"; do
  DOMAIN_DIRS+=("${mapping%%=*}")
  DOMAIN_ZONES+=("${mapping#*=}")
done

jq_field() { jq -r "${2} // empty" 2>/dev/null <<<"$1" || echo ""; }
is_json() { [[ -n "$1" ]] && jq -e '.' >/dev/null 2>&1 <<<"$1"; }
api_success() { [[ "$(jq -r '.success' <<<"$1")" == "true" ]]; }
api_error() { jq -r '.errors | map(.message) | join("; ")' <<<"$1"; }

build_payload() {
  jq -c '{type,name,content,ttl}
    + (if (.comment // "") != "" then {comment} else {} end)
    + (if (.priority // null) != null then {priority} else {} end)
    + (if (.type == "A" or .type == "CNAME") then {proxied: (.proxied // false)} else {} end)
  ' <<<"$1"
}

cf_api() {
  local method="$1" url="$2" payload="${3:-}"
  curl -sS -X "$method" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    ${payload:+--data "$payload"} "$url"
}

process_records() {
  local action="$1" records_json="$2" zone_id="$3"
  
  while IFS= read -r -d '' item; do
    [[ -n "$item" ]] || continue
    is_json "$item" || { echo "   ! Skipping invalid JSON" >&2; continue; }
    
    local id type name file payload method url
    
    case "$action" in
      DELETE)
        id=$(jq_field "$item" ".id")
        type=$(jq_field "$item" ".type")
        name=$(jq_field "$item" ".name")
        [[ -n "$id" && -n "$type" && -n "$name" ]] || { echo "   ! Missing fields" >&2; continue; }
        method="DELETE"
        url="$API_BASE/zones/$zone_id/dns_records/$id"
        ;;
      UPDATE)
        local desired existing_id
        desired=$(jq '.desired' 2>/dev/null <<<"$item" || echo "{}")
        existing_id=$(jq_field "$item" ".existing.id")
        type=$(jq_field "$item" ".desired.type")
        name=$(jq_field "$item" ".desired.name")
        file=$(jq_field "$item" ".desired.file")
        [[ -n "$existing_id" && -n "$type" && -n "$name" ]] || { echo "   ! Missing fields" >&2; continue; }
        payload=$(build_payload "$desired")
        method="PUT"
        url="$API_BASE/zones/$zone_id/dns_records/$existing_id"
        ;;
      CREATE)
        type=$(jq_field "$item" ".type")
        name=$(jq_field "$item" ".name")
        file=$(jq_field "$item" ".file")
        [[ -n "$type" && -n "$name" ]] || { echo "   ! Missing fields" >&2; continue; }
        payload=$(build_payload "$item")
        method="POST"
        url="$API_BASE/zones/$zone_id/dns_records"
        ;;
    esac
    
    echo "   • $action $type $name${file:+ (from $file)}"
    local resp
    resp=$(cf_api "$method" "$url" "$payload")
    
    if ! api_success "$resp"; then
      echo "   ! Failed: $(api_error "$resp")" >&2
      return 1
    fi
  done < <(jq -j '.[] | @json, "\u0000"' 2>/dev/null <<<"$records_json")
}

fetch_cloudflare_records() {
  local zone_id="$1" output_file="$2" manifest_input="$3"
  : >"$output_file"
  local page=1 total_pages=1
  
  while (( page <= total_pages )); do
    local resp
    resp=$(cf_api "GET" "$API_BASE/zones/$zone_id/dns_records?per_page=100&page=$page")
    api_success "$resp" || { echo "[$manifest_input] Fetch failed: $(api_error "$resp")" >&2; return 1; }
    
    jq -c '.result[] | select(.type == "A" or .type == "CNAME" or .type == "TXT") |
      {id,type,name,content,ttl,proxied:(if has("proxied") then .proxied else null end),
       priority:(if has("priority") then .priority else null end),comment:(.comment // null)}
    ' <<<"$resp" >>"$output_file"
    
    total_pages=$(jq '.result_info.total_pages // 1' <<<"$resp")
    ((page++))
  done
}

load_manifest_records() {
  local manifest_dir="$1" output_file="$2"
  : >"$output_file"
  local count=0
  
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    yq e -o=json -I=0 '.record' "$file" | jq -c --arg file "${file#$REPO_ROOT/}" '
      {file:$file,type,name,content:.value,ttl,
       proxied:(if has("proxied") then .proxied else null end),
       priority:(if has("priority") then .priority else null end),
       comment:(if has("comment") then .comment else null end)}
    ' >>"$output_file"
    ((count++))
  done < <(find "$manifest_dir" -type f -name '*.yaml' | sort)
  
  echo "$count"
}

compute_diff() {
  local manifests="$1" cloud="$2"
  
  jq -n --argjson m "$manifests" --argjson c "$cloud" '{
    delete: [$c[] as $cf | select(($m | any(.type == $cf.type and .name == $cf.name)) | not)],
    create: [$m[] as $mf | select(($c | any(.type == $mf.type and .name == $mf.name)) | not)],
    update: [$m[] as $d | ($c | map(select(.type == $d.type and .name == $d.name))[0]) as $cur |
      select($cur != null) | select(
        ($cur.content != $d.content) or ($cur.ttl != $d.ttl) or
        (($d.type == "A" or $d.type == "CNAME") and (($cur.proxied // false) != ($d.proxied // false))) or
        (($cur.priority // null) != ($d.priority // null)) or (($cur.comment // "") != ($d.comment // ""))
      ) | {existing: $cur, desired: $d}]
  }'
}

sync_domain() {
  local manifest_input="$1" zone_id="$2"
  local manifest_dir="${manifest_input#/}"
  [[ "$manifest_input" = /* ]] || manifest_dir="$REPO_ROOT/$manifest_input"
  
  [[ -d "$manifest_dir" ]] || { echo "Directory '$manifest_input' not found." >&2; return 1; }
  
  local tmp_manifest tmp_cloud
  tmp_manifest="$(mktemp)" tmp_cloud="$(mktemp)"
  
  local count
  count=$(load_manifest_records "$manifest_dir" "$tmp_manifest")
  (( count == 0 )) && { echo "No manifests in $manifest_dir. Skipping."; return 0; }
  
  fetch_cloudflare_records "$zone_id" "$tmp_cloud" "$manifest_input" || return 1
  
  local diff
  diff=$(compute_diff "$(jq -s '.' "$tmp_manifest")" "$(jq -s '.' "$tmp_cloud")")
  
  local del cre upd
  del=$(jq '.delete | length' <<<"$diff")
  cre=$(jq '.create | length' <<<"$diff")
  upd=$(jq '.update | length' <<<"$diff")
  
  echo "== Syncing ${manifest_dir#$REPO_ROOT/} (zone: $zone_id) =="
  echo " - to create: $cre, update: $upd, delete: $del"
  
  (( del > 0 )) && { echo "Deleting..."; process_records DELETE "$(jq '.delete' <<<"$diff")" "$zone_id" || return 1; }
  (( upd > 0 )) && { echo "Updating..."; process_records UPDATE "$(jq '.update' <<<"$diff")" "$zone_id" || return 1; }
  (( cre > 0 )) && { echo "Creating..."; process_records CREATE "$(jq '.create' <<<"$diff")" "$zone_id" || return 1; }
  
  echo "Finished syncing ${manifest_dir#$REPO_ROOT/}."
}

main() {
  local i status=0
  for i in "${!DOMAIN_DIRS[@]}"; do
    sync_domain "${DOMAIN_DIRS[$i]}" "${DOMAIN_ZONES[$i]}" || status=1
  done
  
  if (( status == 0 )); then
    echo "All domains synced successfully."
  else
    echo "Some domains failed to sync." >&2
  fi
  exit "$status"
}

main
