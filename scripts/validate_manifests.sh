#!/usr/bin/env bash

set -euo pipefail

find_manifests() {
  local repo_root="$1"
  find "$repo_root" -type f -name '*.yaml' \
    ! -path "$repo_root/scripts/*" \
    ! -path "$repo_root/examples/*" \
    ! -path "$repo_root/.github/*" \
    ! -path "$repo_root/.git/*" \
    | sort
}

append_error() {
  local message="$1"
  VALIDATION_ERRORS+=("$message")
}

get_field_value() {
  yq e -r "${2} // \"\"" "$1"
}

get_field_type() {
  yq e "${2} | type" "$1" 2>/dev/null || echo ""
}

validate_field_type() {
  local file="$1" key_path="$2" expected_type="$3" relative="$4"
  local actual_type
  actual_type=$(get_field_type "$file" "$key_path")
  
  if [[ "$actual_type" != "$expected_type" ]]; then
    append_error "$relative: \`${key_path#.?}\` must be a ${expected_type#!!}"
    return 1
  fi
  return 0
}

require_string() {
  local file="$1" key_path="$2" allow_empty="${3:-false}" relative="${4:-$file}"
  local type value
  
  type=$(get_field_type "$file" "$key_path")
  value=$(get_field_value "$file" "$key_path")

  if [[ "$type" != "!!str" ]]; then
    append_error "$relative: \`${key_path#.?}\` must be a string"
    return 1
  fi

  if [[ "$allow_empty" != "true" && -z "$value" ]]; then
    append_error "$relative: \`${key_path#.?}\` must not be empty"
    return 1
  fi
  return 0
}

validate_date_field() {
  local file="$1" key_path="$2" relative="$3"
  local date_type date_value
  
  date_value=$(get_field_value "$file" "$key_path")
  date_type=$(get_field_type "$file" "$key_path")
  
  if [[ "$date_type" != "!!str" ]]; then
    append_error "$relative: \`${key_path#.?}\` must be a string"
    return 1
  elif ! [[ "$date_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    append_error "$relative: \`${key_path#.?}\` must follow YYYY-MM-DD format"
    return 1
  fi
  return 0
}

validate_meta() {
  local file="$1" relative="$2"

  validate_field_type "$file" ".meta" "!!map" "$relative" || return
  
  require_string "$file" ".meta.owner" "false" "$relative"
  require_string "$file" ".meta.purpose" "true" "$relative"
  
  validate_date_field "$file" ".meta.registered_at" "$relative"
  validate_date_field "$file" ".meta.valid_until" "$relative"
}

validate_record_type() {
  local file="$1" relative="$2"
  local record_kind kind_type
  
  record_kind=$(get_field_value "$file" ".record.type")
  kind_type=$(get_field_type "$file" ".record.type")
  
  case "$record_kind" in
    A|CNAME|TXT) return 0 ;;
    "")
      append_error "$relative: \`record.type\` must be provided"
      return 1
      ;;
    *)
      if [[ "$kind_type" != "!!str" ]]; then
        append_error "$relative: \`record.type\` must be a string"
      else
        append_error "$relative: \`record.type\` must be one of A, CNAME, TXT"
      fi
      return 1
      ;;
  esac
}

validate_ttl() {
  local file="$1" relative="$2"
  local ttl_type ttl_value
  
  ttl_type=$(get_field_type "$file" ".record.ttl")
  ttl_value=$(get_field_value "$file" ".record.ttl")
  
  if [[ "$ttl_type" != "!!int" ]]; then
    append_error "$relative: \`record.ttl\` must be an integer"
    return 1
  elif (( ttl_value <= 0 )); then
    append_error "$relative: \`record.ttl\` must be positive"
    return 1
  fi
  return 0
}

validate_priority() {
  local file="$1" relative="$2"
  local priority_type
  
  priority_type=$(get_field_type "$file" ".record.priority")
  
  if [[ "$priority_type" != "!!null" && "$priority_type" != "!!int" ]]; then
    append_error "$relative: \`record.priority\` must be an integer or null"
    return 1
  fi
  return 0
}

validate_proxied() {
  local file="$1" relative="$2" record_kind="$3"
  local proxied_present proxied_type proxied_value
  
  proxied_present="$(yq e '.record | has("proxied")' "$file")"
  proxied_type=$(get_field_type "$file" ".record.proxied")
  proxied_value=$(get_field_value "$file" ".record.proxied")
  
  if [[ "$record_kind" == "TXT" ]]; then
    if [[ "$proxied_value" == "true" ]]; then
      append_error "$relative: \`record.proxied\` should not be true for TXT records"
      return 1
    fi
  else
    if [[ "$proxied_present" != "true" ]]; then
      append_error "$relative: \`record.proxied\` is required for ${record_kind} records"
      return 1
    elif [[ "$proxied_type" != "!!bool" ]]; then
      append_error "$relative: \`record.proxied\` must be boolean"
      return 1
    fi
  fi
  return 0
}

validate_record() {
  local file="$1" relative="$2"
  local record_kind

  validate_field_type "$file" ".record" "!!map" "$relative" || return
  
  require_string "$file" ".record.name" "false" "$relative"
  validate_record_type "$file" "$relative"
  require_string "$file" ".record.value" "false" "$relative"
  validate_ttl "$file" "$relative"
  validate_priority "$file" "$relative"
  
  record_kind=$(get_field_value "$file" ".record.type")
  validate_proxied "$file" "$relative" "$record_kind"
  
  require_string "$file" ".record.comment" "false" "$relative"
}

validate_maintainer_entry() {
  local file="$1" index="$2" relative="$3"
  local base=".maintainers[$index]"
  
  require_string "$file" "${base}.name" "false" "$relative"
  require_string "$file" "${base}.email" "false" "$relative"
  require_string "$file" "${base}.url" "false" "$relative"
}

validate_maintainers() {
  local file="$1" relative="$2"
  local maintainer_count i

  validate_field_type "$file" ".maintainers" "!!seq" "$relative" || return

  maintainer_count="$(yq e '.maintainers | length' "$file")"
  
  if (( maintainer_count == 0 )); then
    append_error "$relative: \`maintainers\` must include at least one entry"
    return
  fi

  for ((i = 0; i < maintainer_count; i++)); do
    validate_maintainer_entry "$file" "$i" "$relative"
  done
}

validate_manifest() {
  local file="$1" relative="$2"

  validate_field_type "$file" "." "!!map" "$relative" || return

  validate_meta "$file" "$relative"
  validate_record "$file" "$relative"
  validate_maintainers "$file" "$relative"
}

collect_manifests() {
  local repo_root="$1"
  local -n manifests_ref="$2"
  local manifest
  
  while IFS= read -r manifest; do
    manifests_ref+=("$manifest")
  done < <(find_manifests "$repo_root")
}

validate_all_manifests() {
  local repo_root="$1"
  local -a manifests_list
  local file relative
  shift
  manifests_list=("$@")
  
  for file in "${manifests_list[@]}"; do
    relative="${file#$repo_root/}"
    validate_manifest "$file" "$relative"
  done
}

print_validation_results() {
  local total_count="$1"
  
  if [[ ${#VALIDATION_ERRORS[@]} -eq 0 ]]; then
    echo "All manifests valid ($total_count files checked)."
    return 0
  else
    echo "Validation failed:"
    for err in "${VALIDATION_ERRORS[@]}"; do
      echo "  - $err"
    done
    return 1
  fi
}

main() {
  local repo_root manifests=()

  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  collect_manifests "$repo_root" manifests

  if [[ ${#manifests[@]} -eq 0 ]]; then
    echo "No manifest files found."
    exit 0
  fi

  VALIDATION_ERRORS=()
  validate_all_manifests "$repo_root" "${manifests[@]}"
  print_validation_results "${#manifests[@]}" || exit 1
}

main "$@"
