#!/usr/bin/env bash

set -euo pipefail

CF_TOKEN="$1"
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_BASE="https://api.cloudflare.com/client/v4"

REC_FIELDS='{id,type,name,content,ttl,proxied:(.proxied//null),priority:(.priority//null),comment:(.comment//null)}'
SKIP_NAMES_JSON='["cf2024-1._domainkey"]'

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
log() { echo "   $1" >&2; }
log_action() { echo "   • $1" >&2; }
log_step() { log "$1..."; }
log_fail() { log "! $1"; }

build_payload() {
  jq -c '{type,name,content,ttl} + (if .comment != null and .comment != "" then {comment} else {} end) + (if .priority != null then {priority} else {} end) + (if (.type == "A" or .type == "AAAA" or .type == "CNAME") then {proxied: (.proxied // false)} else {} end)' <<<"$1"
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
    is_json "$item" || { log "! Skipping invalid JSON"; continue; }
    
    local method url payload="" type name file
    
    case "$action" in
      DELETE)
        local id=$(jq_field "$item" ".id")
        type=$(jq_field "$item" ".type")
        name=$(jq_field "$item" ".name")
        [[ -n "$id" && -n "$type" && -n "$name" ]] || { log "! Missing fields"; continue; }
        method="DELETE"
        url="$API_BASE/zones/$zone_id/dns_records/$id"
        ;;
      UPDATE)
        local existing_id=$(jq_field "$item" ".existing.id")
        type=$(jq_field "$item" ".desired.type")
        name=$(jq_field "$item" ".desired.name")
        file=$(jq_field "$item" ".desired.file")
        [[ -n "$existing_id" && -n "$type" && -n "$name" ]] || { log "! Missing fields"; continue; }
        payload=$(build_payload "$(jq '.desired' 2>/dev/null <<<"$item" || echo "{}")")
        method="PUT"
        url="$API_BASE/zones/$zone_id/dns_records/$existing_id"
        ;;
      CREATE)
        type=$(jq_field "$item" ".type")
        name=$(jq_field "$item" ".name")
        file=$(jq_field "$item" ".file")
        [[ -n "$type" && -n "$name" ]] || { log "! Missing fields"; continue; }
        payload=$(build_payload "$item")
        method="POST"
        url="$API_BASE/zones/$zone_id/dns_records"
        ;;
    esac
    
    log_action "$action $type $name${file:+ (from $file)}"
    local resp=$(cf_api "$method" "$url" "$payload")
    if ! api_success "$resp"; then
      log "! Failed: $(api_error "$resp")"
      return 1
    fi
  done < <(jq -j '.[] | @json, "\u0000"' 2>/dev/null <<<"$records_json")
}

fetch_cloudflare_json() {
  local zone_id="$1"
  local page=1 total_pages=1
  local out='[]'
  
  while (( page <= total_pages )); do
    local resp
    resp=$(cf_api "GET" "$API_BASE/zones/$zone_id/dns_records?per_page=100&page=$page")
    api_success "$resp" || { log_fail "[zone:$zone_id] Fetch failed: $(api_error "$resp")"; return 1; }
    out=$(jq -c --argjson acc "$out" --argjson skip "$SKIP_NAMES_JSON" '
      def should_skip($n): reduce $skip[] as $s (false; . or ($n | contains($s)));
      $acc + ([.result[]
        | select(.type == "A" or .type == "AAAA" or .type == "CNAME" or .type == "TXT")
        | select(should_skip(.name // "") | not)
        | {id,type,name,content,ttl,proxied:(.proxied//null),priority:(.priority//null),comment:(.comment//null)}])
    ' <<<"$resp")
    total_pages=$(jq '.result_info.total_pages // 1' <<<"$resp")
    ((page++))
  done
  echo "$out"
}

load_manifest_json() {
  local manifest_dir="$1"
  local items='[]'
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    local rec
    rec=$(yq e -o=json -I=0 '.record' "$file" | jq -c --arg file "${file#$REPO_ROOT/}" --argjson skip "$SKIP_NAMES_JSON" '
      def should_skip($n): reduce $skip[] as $s (false; . or ($n | contains($s)));
      select(.type == "A" or .type == "AAAA" or .type == "CNAME" or .type == "TXT")
      | select(should_skip(.name // "") | not)
      | {file:$file,type,name,content:.value,ttl,proxied:(.proxied//null),priority:(.priority//null),comment:(.comment//null)}')
    [[ -z "$rec" ]] && continue
    is_json "$rec" || { log_fail "Invalid manifest JSON in $file"; continue; }
    items=$(jq -c --argjson rec "$rec" '. + [ $rec ]' <<<"$items")
  done < <(find "$manifest_dir" -type f -name '*.yaml' | sort)
  echo "$items"
}

compute_diff() {
  jq -n --argjson m "$1" --argjson c "$2" '{
    delete: [$c[] as $cf | select(($m | any(.type == $cf.type and .name == $cf.name)) | not)],
    create: [$m[] as $d | ($c | map(select(.type == $d.type and .name == $d.name))) as $cs | select(($cs | length) == 0) | $d],
    update: [$m[] as $d | ($c | map(select(.type == $d.type and .name == $d.name))) as $cs
      | select(($cs | length) > 0)
      | select(($cs | any(
          (.content == $d.content) and
          (.ttl == $d.ttl) and
          (if $d.type == "A" or $d.type == "AAAA" or $d.type == "CNAME" then ((.proxied // false) == ($d.proxied // false)) else true end) and
          ((.priority // null) == ($d.priority // null)) and
          ((.comment // "") == ($d.comment // ""))
        )) | not)
      | {existing: ($cs[0]), desired: $d}]
  }'
}

sync_domain() {
  local manifest_input="$1" zone_id="$2"
  local manifest_dir="${manifest_input#/}"
  [[ "$manifest_input" = /* ]] || manifest_dir="$REPO_ROOT/$manifest_input"
  
  [[ -d "$manifest_dir" ]] || { log_fail "Directory '$manifest_input' not found."; return 1; }
  
  local manifests_json
  manifests_json=$(load_manifest_json "$manifest_dir")
  local mf_count
  mf_count=$(jq -r 'length // 0' <<<"$manifests_json" 2>/dev/null || echo 0)
  (( mf_count == 0 )) && { log "No manifests in $manifest_dir. Skipping."; return 0; }
  
  local cloud_json
  cloud_json=$(fetch_cloudflare_json "$zone_id") || return 1
  
  local diff del upd cre del_cnt upd_cnt cre_cnt
  diff=$(compute_diff "$manifests_json" "$cloud_json")
  is_json "$diff" || { log_fail "Failed to compute diff (invalid JSON)."; return 1; }
  del=$(jq -c '.delete // []' <<<"$diff")
  upd=$(jq -c '.update // []' <<<"$diff")
  cre=$(jq -c '.create // []' <<<"$diff")
  del_cnt=$(jq length <<<"$del" 2>/dev/null || echo 0)
  upd_cnt=$(jq length <<<"$upd" 2>/dev/null || echo 0)
  cre_cnt=$(jq length <<<"$cre" 2>/dev/null || echo 0)
  
  log_step "Syncing ${manifest_dir#$REPO_ROOT/} (zone: $zone_id)"
  log " - to create: $cre_cnt, update: $upd_cnt, delete: $del_cnt"
  
  (( del_cnt > 0 )) && { log_step "Deleting"; process_records DELETE "$del" "$zone_id" || return 1; }
  (( upd_cnt > 0 )) && { log_step "Updating"; process_records UPDATE "$upd" "$zone_id" || return 1; }
  (( cre_cnt > 0 )) && { log_step "Creating"; process_records CREATE "$cre" "$zone_id" || return 1; }
  
  log "Finished syncing ${manifest_dir#$REPO_ROOT/}."
}

main() {
  local status=0
  for i in "${!DOMAIN_DIRS[@]}"; do
    sync_domain "${DOMAIN_DIRS[$i]}" "${DOMAIN_ZONES[$i]}" || status=1
  done
  
  (( status == 0 )) && echo "All domains synced successfully." || echo "Some domains failed to sync." >&2
  exit "$status"
}

main
