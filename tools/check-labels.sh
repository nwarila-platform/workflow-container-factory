#!/usr/bin/env bash
# Keep this release gate aligned with contract 2 in nwarila-platform/.github's run-container.yaml.
set -euo pipefail

if test "$#" -ne 0; then
  printf 'usage: <image config JSON> | %s\n' "$0" >&2
  exit 1
fi

config=$(jq -c '.')
if ! jq -e '.User == "65532:65532"' <<<"$config" >/dev/null; then
  echo "image user must be 65532:65532" >&2
  exit 1
fi

labels=$(jq -c '.Labels' <<<"$config")
values=()

for requirement in scratch full-history second-input sarif image-input; do
  key="org.nwarila.workflow.${requirement}"
  value=$(jq -er --arg key "$key" '.[$key] | select(. == "true" or . == "false")' <<<"$labels") || {
    echo "invalid or missing label: $key" >&2
    exit 1
  }
  if [[ "$value" == true && "$requirement" =~ ^(full-history|sarif|image-input)$ ]]; then
    echo "label $key is true, but contract 2 does not provide $requirement yet" >&2
    exit 1
  fi
  values+=("$key=$value")
done

echo "labels ok: ${values[*]}"
