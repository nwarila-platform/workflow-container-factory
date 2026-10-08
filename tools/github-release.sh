#!/usr/bin/env bash
# Publish immutable GitHub Release evidence for one verified container release tag.

set -euo pipefail
set -E
shopt -s inherit_errexit
trap 'printf "github-release: refused: check failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

repository=nwarila-platform/workflow-container-factory
certificate_oidc_issuer=https://token.actions.githubusercontent.com

if test "$#" -ne 1; then
  printf 'usage: %s <name>/v<X.Y.Z>\n' "$0" >&2
  exit 1
fi

tag=$1
if [[ ! "$tag" =~ ^([a-z0-9]+(-[a-z0-9]+)*)/v((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$ ]]; then
  printf 'invalid release tag: %q\n' "$tag" >&2
  exit 1
fi
name=${BASH_REMATCH[1]}
version=${BASH_REMATCH[3]}
if (( ${#name} > 91 )); then
  printf 'invalid container name: %q\n' "$name" >&2
  exit 1
fi

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  printf 'github-release: refused: not a Git checkout\n' >&2
  exit 1
}
cd "$root"

if test -n "$(git status --porcelain --untracked-files=normal)"; then
  printf 'github-release: refused: checkout is not clean\n' >&2
  exit 1
fi
if test "$(git branch --show-current)" != main; then
  printf 'github-release: refused: checkout is not on main\n' >&2
  exit 1
fi
case $(git remote get-url origin) in
  https://github.com/nwarila-platform/workflow-container-factory | \
    https://github.com/nwarila-platform/workflow-container-factory.git | \
    git@github.com:nwarila-platform/workflow-container-factory.git) ;;
  *)
    printf 'github-release: refused: origin is not %s\n' "$repository" >&2
    exit 1
    ;;
esac

for tool in gh crane cosign jq python3 curl; do
  if ! command -v "$tool" >/dev/null; then
    printf 'github-release: refused: required command not found: %s\n' "$tool" >&2
    exit 1
  fi
done

repo_json=$(gh api "repos/${repository}")
if test "$(jq -r '.default_branch' <<< "$repo_json")" != main; then
  printf 'github-release: refused: repository default branch is not main\n' >&2
  exit 1
fi
if test "$(jq -r '.permissions.admin' <<< "$repo_json")" != true; then
  printf 'github-release: refused: authenticated user is not a repository admin\n' >&2
  exit 1
fi
main_commit=$(gh api "repos/${repository}/commits/main" --jq .sha)
if test "$(git rev-parse HEAD)" != "$main_commit"; then
  printf 'github-release: refused: HEAD is not the current main commit\n' >&2
  exit 1
fi

ref_json=$(gh api "repos/${repository}/git/ref/tags/${tag}")
test "$(jq -r '.ref' <<< "$ref_json")" = "refs/tags/${tag}"
test "$(jq -r '.object.type' <<< "$ref_json")" = tag
tag_object_sha=$(jq -r '.object.sha' <<< "$ref_json")
[[ "$tag_object_sha" =~ ^[0-9a-f]{40}$ ]]
tag_json=$(gh api "repos/${repository}/git/tags/${tag_object_sha}")
tag_commit=$(jq -r '.object.sha' <<< "$tag_json")
jq -e --arg tag "$tag" --arg object_sha "$tag_object_sha" '
  .sha == $object_sha and .tag == $tag and .object.type == "commit" and
  (.object.sha | test("^[0-9a-f]{40}$")) and .verification.verified == true
' <<< "$tag_json" >/dev/null

comparison=$(gh api "repos/${repository}/compare/${tag_commit}...main")
test "$(jq -r '.base_commit.sha' <<< "$comparison")" = "$tag_commit"
case $(jq -r '.status' <<< "$comparison") in
  ahead | identical) ;;
  *)
    printf 'release commit is not reachable from main: %s\n' "$tag_commit" >&2
    exit 1
    ;;
esac

if ! git cat-file -e "${tag_commit}^{commit}" 2>/dev/null; then
  printf 'github-release: refused: release commit %s is not in this checkout (shallow clone?)\n' "$tag_commit" >&2
  exit 1
fi

immutable=$(gh api "repos/${repository}/immutable-releases")
if test "$(jq -r '.enabled' <<< "$immutable")" != true; then
  printf 'github-release: refused: immutable releases are not enabled\n' >&2
  exit 1
fi

release_work=$(mktemp -d)
cleanup() {
  rm -rf -- "$release_work"
}
trap cleanup EXIT
install -d -m 0700 "$release_work/assets" "$release_work/docker" "$release_work/provenance"
assets=$release_work/assets
export DOCKER_CONFIG=$release_work/docker

image=ghcr.io/nwarila-platform/workflow-${name}
index_digest=$(crane digest "${image}:${version}")
[[ "$index_digest" =~ ^sha256:[0-9a-f]{64}$ ]]
result=$(python3 -I tools/check-index.py \
  "$image" "$index_digest" --sbom-dir "$assets" --name "$name" --version "$version")
printf '%s\n' "$result"
amd64_digest=$(awk '$1 == "child" && $2 == "ok:" && $3 == "linux/amd64" { print $4 }' <<< "$result")
arm64_digest=$(awk '$1 == "child" && $2 == "ok:" && $3 == "linux/arm64" { print $4 }' <<< "$result")
[[ "$amd64_digest" =~ ^sha256:[0-9a-f]{64}$ ]]
[[ "$arm64_digest" =~ ^sha256:[0-9a-f]{64}$ ]]

identity=https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/${tag}
for digest in "$index_digest" "$amd64_digest" "$arm64_digest"; do
  cosign verify "${image}@${digest}" \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer "$certificate_oidc_issuer" \
    --certificate-github-workflow-repository "$repository" \
    --certificate-github-workflow-sha "$tag_commit" \
    --certificate-github-workflow-ref "refs/tags/${tag}"
done
gh attestation verify "oci://${image}@${index_digest}" \
  --repo "$repository" \
  --signer-workflow "$repository/.github/workflows/build.yaml" \
  --source-ref "refs/tags/${tag}"
(
  cd "$release_work/provenance"
  gh attestation download "oci://${image}@${index_digest}" \
    --repo "$repository" \
    --predicate-type https://slsa.dev/provenance/v1
)
mapfile -t bundles < <(find "$release_work/provenance" -mindepth 1 -maxdepth 1 -type f -name 'sha256*.jsonl' -print)
test "${#bundles[@]}" -eq 1
test "$(find "$release_work/provenance" -mindepth 1 -maxdepth 1 -type f | wc -l)" -eq 1
mv "${bundles[0]}" "$assets/${name}-${version}-provenance.sigstore.json"
printf 'index %s\nlinux/amd64 %s\nlinux/arm64 %s\n' \
  "$index_digest" "$amd64_digest" "$arm64_digest" \
  > "$assets/${name}-${version}-digests.txt"
test ! -e "$DOCKER_CONFIG/config.json"

changelog=$release_work/changelog.md
if git cat-file -e "${tag_commit}:containers/${name}/CHANGELOG.md" 2>/dev/null; then
  git show "${tag_commit}:containers/${name}/CHANGELOG.md" > "$changelog"
else
  : > "$changelog"
fi
export RELEASE_CHANGELOG=$changelog
export RELEASE_INDEX_DIGEST=$index_digest
export RELEASE_NAME=$name
export RELEASE_NOTES=$release_work/notes.md
export RELEASE_TAG=$tag
export RELEASE_VERSION=$version
python3 -I - <<'PY'
import os
import re
from pathlib import Path

name = os.environ["RELEASE_NAME"]
version = os.environ["RELEASE_VERSION"]
text = Path(os.environ["RELEASE_CHANGELOG"]).read_text(encoding="utf-8")
match = re.search(
    rf"(?ms)^## (?:\[{re.escape(version)}\](?=\(|[ \t]|$)|{re.escape(version)}(?=[ \t]|$)).*?(?=^## |\Z)",
    text,
)
section = match.group(0).strip() if match is not None else ""
if not section:
    section = "This release was backfilled from the existing signed tag."
image = f"ghcr.io/nwarila-platform/workflow-{name}"
digest = os.environ["RELEASE_INDEX_DIGEST"]
tag = os.environ["RELEASE_TAG"]
notes = (
    f"{section}\n\nImage: `{image}@{digest}`\n\n"
    "```sh\n"
    f"cosign verify '{image}@{digest}' --certificate-identity "
    f"'https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/{tag}' "
    "--certificate-oidc-issuer https://token.actions.githubusercontent.com\n"
    f"gh attestation verify 'oci://{image}@{digest}' --repo nwarila-platform/workflow-container-factory "
    "--signer-workflow nwarila-platform/workflow-container-factory/.github/workflows/build.yaml "
    f"--source-ref 'refs/tags/{tag}'\n"
    "```\n"
)
Path(os.environ["RELEASE_NOTES"]).write_text(notes, encoding="utf-8")
PY

expected=$release_work/expected-names
printf '%s\n' \
  "${name}-${version}-digests.txt" \
  "${name}-${version}-linux-amd64.spdx.json" \
  "${name}-${version}-linux-arm64.spdx.json" \
  "${name}-${version}-provenance.sigstore.json" \
  | sort > "$expected"

find_release_id() {
  local pages matches count
  pages=$(gh api "repos/${repository}/releases?per_page=100" --paginate --slurp)
  matches=$(jq -c --arg tag "$tag" '[.[][] | select(.tag_name == $tag)]' <<< "$pages")
  count=$(jq 'length' <<< "$matches")
  if test "$count" -gt 1; then
    printf 'refusing duplicate releases for tag: %s\n' "$tag" >&2
    exit 1
  fi
  if test "$count" -eq 1; then
    jq -er '.[0].id | select(type == "number" and . > 0 and floor == .)' <<< "$matches"
  fi
}

read_release() {
  gh api "repos/${repository}/releases/${release_id}"
}

upload_asset() {
  local file=$1 asset_name=$2 status
  status=$(curl --disable --silent --show-error --output "$release_work/upload-response" --write-out '%{http_code}' \
    --request POST \
    --header 'Accept: application/vnd.github+json' \
    --header "@${auth_header}" \
    --header 'Content-Type: application/octet-stream' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --data-binary "@${file}" \
    "https://uploads.github.com/repos/${repository}/releases/${release_id}/assets?name=${asset_name}")
  if test "$status" != 201; then
    cat "$release_work/upload-response" >&2
    printf 'release asset upload returned HTTP %s, expected 201\n' "$status" >&2
    exit 1
  fi
}

verify_bundle() {
  gh attestation verify "oci://${image}@${index_digest}" \
    --bundle "$1" --repo "$repository" \
    --signer-workflow "$repository/.github/workflows/build.yaml" \
    --source-ref "refs/tags/${tag}" >/dev/null
}

compare_asset() {
  local current=$1 expected_file=$2
  if [[ "$current" == *-provenance.sigstore.json ]]; then
    verify_bundle "$current"
  else
    cmp -s "$current" "$expected_file"
  fi
}

require_release_identity() {
  local data=$1
  jq -e --arg tag "$tag" --arg target "$tag_commit" '
    .tag_name == $tag and .target_commitish == $target
  ' <<< "$data" >/dev/null
}

require_release_metadata() {
  local data=$1
  jq -e --arg title "${name} ${version}" --arg image "${image}@${index_digest}" '
    .name == $title and ((.body // "") | contains($image))
  ' <<< "$data" >/dev/null
}

require_exact_assets() {
  local data=$1
  jq -r '.assets[].name' <<< "$data" | sort > "$release_work/observed-names"
  cmp -s "$expected" "$release_work/observed-names"
}

release_id=$(find_release_id)
if test -n "$release_id"; then
  release=$(read_release)
  state=$(jq -r 'if .draft then "draft" else "published" end' <<< "$release")
else
  state=absent
fi

if test "$state" = absent; then
  gh release create "$tag" --repo "$repository" --draft --verify-tag \
    --target "$tag_commit" --title "${name} ${version}" --notes-file "$release_work/notes.md"
  release_id=
  for attempt in 1 2 3 4 5; do
    release_id=$(find_release_id)
    test -n "$release_id" && break
    test "$attempt" -eq 5 || sleep 1
  done
  test -n "$release_id"
  release=$(read_release)
  state=draft
fi

require_release_identity "$release"
if test "$state" = draft; then
  jq -n --arg name "${name} ${version}" --rawfile body "$release_work/notes.md" \
    '{name: $name, body: $body}' > "$release_work/update-release.json"
  gh api --method PATCH "repos/${repository}/releases/${release_id}" \
    --input "$release_work/update-release.json" >/dev/null
  release=$(read_release)
  require_release_identity "$release"
  require_release_metadata "$release"
  mkdir "$release_work/existing"
  auth_header=$release_work/auth-header
  install -m 0600 /dev/null "$auth_header"
  auth_token=$(gh auth token)
  printf 'Authorization: Bearer %s\n' "$auth_token" > "$auth_header"
  unset auth_token
  while read -r asset; do
    expected_file=$assets/$asset
    if jq -e --arg name "$asset" 'any(.assets[]; .name == $name)' <<< "$release" >/dev/null; then
      current=$release_work/existing/$asset
      asset_id=$(jq -er --arg name "$asset" '
        [.assets[] | select(.name == $name)] |
        select(length == 1) | .[0].id |
        select(type == "number" and . > 0 and floor == .)
      ' <<< "$release")
      gh api -H 'Accept: application/octet-stream' \
        "repos/${repository}/releases/assets/${asset_id}" > "$current"
      if ! compare_asset "$current" "$expected_file"; then
        printf 'draft asset mismatch; replacing: %s\n' "$asset"
        gh api --method DELETE "repos/${repository}/releases/assets/${asset_id}" >/dev/null
        upload_asset "$expected_file" "$asset"
      fi
    else
      upload_asset "$expected_file" "$asset"
    fi
  done < "$expected"
  rm -f -- "$auth_header"
  release=$(read_release)
  require_release_identity "$release"
  require_exact_assets "$release"
  printf '{"draft":false}\n' > "$release_work/publish-release.json"
  gh api --method PATCH "repos/${repository}/releases/${release_id}" \
    --input "$release_work/publish-release.json" >/dev/null
else
  jq -e '.draft == false and .immutable == true' <<< "$release" >/dev/null
  require_release_metadata "$release"
  require_exact_assets "$release"
  mkdir "$release_work/published"
  while read -r asset; do
    current=$release_work/published/$asset
    asset_id=$(jq -er --arg name "$asset" '
      [.assets[] | select(.name == $name)] |
      select(length == 1) | .[0].id |
      select(type == "number" and . > 0 and floor == .)
    ' <<< "$release")
    gh api -H 'Accept: application/octet-stream' \
      "repos/${repository}/releases/assets/${asset_id}" > "$current"
    compare_asset "$current" "$assets/$asset"
  done < "$expected"
fi

release=$(read_release)
require_release_identity "$release"
jq -e '.draft == false and .immutable == true' <<< "$release" >/dev/null
require_release_metadata "$release"
require_exact_assets "$release"
printf 'github-release: published %s\n' "$tag"
