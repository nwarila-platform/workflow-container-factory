#!/usr/bin/env bash
set -euo pipefail

config=$1
keys=(
  org.nwarila.workflow.scratch
  org.nwarila.workflow.full-history
  org.nwarila.workflow.second-input
  org.nwarila.workflow.sarif
  org.nwarila.workflow.image-input
)
values=()

for key in "${keys[@]}"; do
  value=$(jq -er --arg key "$key" '.Labels[$key] | select(type == "string" and (. == "true" or . == "false"))' "$config") || {
    echo "invalid or missing label: $key" >&2
    exit 1
  }
  values+=("$key=$value")
done

echo "labels ok: ${values[*]}"
