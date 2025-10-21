#!/usr/bin/env bash

set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "yq command not found. Install mikefarah yq v4+ to run this validator." >&2
  exit 127
fi

if ! yq --version 2>&1 | grep -q 'mikefarah/yq'; then
  echo "validate_manifests.sh requires mikefarah yq v4+. Current yq: $(yq --version 2>&1)" >&2
  exit 127
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MANIFESTS=()
while IFS= read -r manifest; do
  MANIFESTS+=("$manifest")
done < <(
  find "$REPO_ROOT" -type f -name '*.yaml' \
    ! -path "$REPO_ROOT/scripts/*" \
    ! -path "$REPO_ROOT/examples/*" \
    ! -path "$REPO_ROOT/.github/*" \
    ! -path "$REPO_ROOT/.git/*" \
    | sort
)

if [ ${#MANIFESTS[@]} -eq 0 ]; then
  echo "No manifest files found."
  exit 0
fi

allowed_types=(A CNAME TXT)
errors=()

add_error() {
  errors+=("$1")
}

is_in_array() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

for file in "${MANIFESTS[@]}"; do
  relative="${file#$REPO_ROOT/}"

  meta_type="$(yq e '.meta | type' "$file")"
  if [[ "$meta_type" != "!!map" ]]; then
    add_error "$relative: \`meta\` section must be a mapping"
    continue
  fi

  owner="$(yq e -r '.meta.owner // ""' "$file")"
  owner_type="$(yq e '.meta.owner | type' "$file")"
  if [[ "$owner" == "" || "$owner_type" != "!!str" ]]; then
    add_error "$relative: \`meta.owner\` must be a non-empty string"
  fi

  for date_key in registered_at valid_until; do
    date_value="$(yq e -r ".meta.${date_key} // \"\"" "$file")"
    date_type="$(yq e ".meta.${date_key} | type" "$file")"
    if [[ "$date_value" == "" || "$date_type" != "!!str" ]]; then
      add_error "$relative: \`meta.${date_key}\` must be a string"
    elif ! [[ "$date_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      add_error "$relative: \`meta.${date_key}\` must follow YYYY-MM-DD format"
    fi
  done

  purpose_type="$(yq e '.meta.purpose | type' "$file")"
  if [[ "$purpose_type" != "!!str" ]]; then
    add_error "$relative: \`meta.purpose\` must be a string (can be empty)"
  fi

  record_type="$(yq e '.record | type' "$file")"
  if [[ "$record_type" != "!!map" ]]; then
    add_error "$relative: \`record\` section must be a mapping"
    continue
  fi

  dns_name="$(yq e -r '.record.name // ""' "$file")"
  name_type="$(yq e '.record.name | type' "$file")"
  if [[ "$dns_name" == "" || "$name_type" != "!!str" ]]; then
    add_error "$relative: \`record.name\` must be a non-empty string"
  fi

  record_kind="$(yq e -r '.record.type // ""' "$file")"
  type_type="$(yq e '.record.type | type' "$file")"
  if [[ "$record_kind" == "" || "$type_type" != "!!str" ]]; then
    add_error "$relative: \`record.type\` must be a string"
  elif ! is_in_array "$record_kind" "${allowed_types[@]}"; then
    add_error "$relative: \`record.type\` must be one of ${allowed_types[*]}"
  fi

  value="$(yq e -r '.record.value // ""' "$file")"
  value_type="$(yq e '.record.value | type' "$file")"
  if [[ "$value" == "" || "$value_type" != "!!str" ]]; then
    add_error "$relative: \`record.value\` must be a non-empty string"
  fi

  ttl="$(yq e '.record.ttl // 0' "$file")"
  ttl_type="$(yq e '.record.ttl | type' "$file")"
  if [[ "$ttl_type" != "!!int" ]]; then
    add_error "$relative: \`record.ttl\` must be an integer"
  elif (( ttl <= 0 )); then
    add_error "$relative: \`record.ttl\` must be positive"
  fi

  priority_type="$(yq e '.record.priority | type' "$file")"
  if [[ "$priority_type" != "!!null" && "$priority_type" != "!!int" ]]; then
    add_error "$relative: \`record.priority\` must be an integer or null"
  fi

  proxied_present="$(yq e '.record | has("proxied")' "$file")"
  proxied_type="$(yq e '.record.proxied | type' "$file")"
  proxied_value="$(yq e -r '.record.proxied // ""' "$file")"
  if [[ "$record_kind" == "TXT" ]]; then
    if [[ "$proxied_value" == "true" ]]; then
      add_error "$relative: \`record.proxied\` should not be true for TXT records"
    fi
  else
    if [[ "$proxied_present" != "true" ]]; then
      add_error "$relative: \`record.proxied\` is required for ${record_kind} records"
    elif [[ "$proxied_type" != "!!bool" ]]; then
      add_error "$relative: \`record.proxied\` must be boolean"
    fi
  fi

  comment="$(yq e -r '.record.comment // ""' "$file")"
  comment_type="$(yq e '.record.comment | type' "$file")"
  if [[ "$comment" == "" || "$comment_type" != "!!str" ]]; then
    add_error "$relative: \`record.comment\` must be a non-empty string"
  fi

  maintainers_type="$(yq e '.maintainers | type' "$file")"
  if [[ "$maintainers_type" != "!!seq" ]]; then
    add_error "$relative: \`maintainers\` must be an array"
    continue
  fi

  maintainer_count="$(yq e '.maintainers | length' "$file")"
  if (( maintainer_count == 0 )); then
    add_error "$relative: \`maintainers\` must include at least one entry"
    continue
  fi

  for ((i = 0; i < maintainer_count; i++)); do
    base=".maintainers[$i]"
    idx=$((i + 1))
    for key in name email url; do
      value="$(yq e -r "${base}.${key} // \"\"" "$file")"
      value_type="$(yq e "${base}.${key} | type" "$file")"
      if [[ "$value" == "" || "$value_type" != "!!str" ]]; then
        add_error "$relative: maintainer #${idx} \`${key}\` must be a non-empty string"
      fi
    done
  done
done

if [ ${#errors[@]} -eq 0 ]; then
  echo "All manifests valid (${#MANIFESTS[@]} files checked)."
else
  echo "Validation failed:"
  for err in "${errors[@]}"; do
    echo "  - $err"
  done
  exit 1
fi
