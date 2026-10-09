#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

fail() {
  printf 'template-drift hook: %s\n' "$1" >&2
  exit 2
}

temporary_directory=
# shellcheck disable=SC2317 # Called through the traps below.
cleanup() {
  if [[ -n "$temporary_directory" ]]; then
    rm -rf "$temporary_directory"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 2' HUP INT TERM

launcher_directory=$(cd -- "$(dirname -- "$0")" && pwd -P) || fail "cannot locate the launcher"
factory_root=$(cd -- "$launcher_directory/../../.." && pwd -P) || fail "cannot locate the factory checkout"
version_file="$factory_root/containers/template-drift/VERSION"
[[ -f "$version_file" ]] || fail "missing VERSION"
version_with_sentinel=$(cat "$version_file"; printf x)
version_with_lf=${version_with_sentinel%x}
[[ "$version_with_lf" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'\n'$ ]] || fail "invalid VERSION"
version=${version_with_lf%$'\n'}

for command_name in git jq python3 cosign; do
  command -v "$command_name" >/dev/null || fail "missing $command_name"
done

engine=${TEMPLATE_DRIFT_ENGINE:-}
if [[ -z "$engine" ]]; then
  for candidate in docker podman; do
    if command -v "$candidate" >/dev/null && "$candidate" info >/dev/null 2>&1; then
      engine=$candidate
      break
    fi
  done
  [[ -n "$engine" ]] || fail "no working docker or podman"
fi
case "$engine" in
  docker | podman) ;;
  *) fail "unsupported engine: $engine" ;;
esac
command -v "$engine" >/dev/null || fail "missing $engine"
"$engine" info >/dev/null 2>&1 || fail "$engine is not working"

checkout=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not in a Git work tree"
[[ "$checkout" == "$(pwd -P)" ]] || fail "run from the top of the work tree"
origin=$(git config --get remote.origin.url) || fail "no origin"
if [[ "$origin" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] \
  || [[ "$origin" =~ ^git@github\.com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]] \
  || [[ "$origin" =~ ^ssh://git@github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
  consumer_owner=${BASH_REMATCH[1]}
  consumer_repository=${BASH_REMATCH[2]%.git}
else
  fail "origin is not a GitHub repository URL"
fi
[[ -n "$consumer_repository" ]] || fail "origin has no repository name"

# Ported from run-container.yaml@95ca3c2332c8037f1ede76d1c2bd1a6b6ee43d4f lines 230-263.
pins=$(python3 - .github/.config/template-drift.yaml .github/.config/template-drift.lock \
  "$consumer_owner" "$consumer_owner/$consumer_repository" <<'PY'
import re
import sys

identity, lock, owner, own = sys.argv[1:]


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(2)


def read(path):
    raw = open(path, "rb").read()
    if not raw.endswith(b"\n") or b"\r" in raw or b"\0" in raw:
        fail(f"invalid LF grammar: {path}")
    try:
        return raw.decode("ascii").splitlines()
    except UnicodeDecodeError:
        fail(f"non-ASCII input: {path}")


def main():
    lines = read(identity)
    item = re.compile(r"  - ([A-Za-z0-9_.-]+)(?:/([A-Za-z0-9_.-]+))?")
    if not lines or lines[0] != "templates:" or any(not item.fullmatch(line) for line in lines[1:]):
        fail("invalid identity grammar")
    templates = []
    for line in lines[1:]:
        match = item.fullmatch(line)
        templates.append(f"{match[1]}/{match[2]}" if match[2] else f"{owner}/{match[1]}")
    folded = [template.lower() for template in templates]
    if not templates or len(set(folded)) != len(folded):
        fail("identity entries must be nonempty and unique")
    expected = [template for template in templates if template.lower() != own.lower()]
    result = []
    for line in read(lock):
        match = re.fullmatch(r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) ([0-9a-f]{40})", line)
        if not match:
            fail("invalid lock grammar")
        result.append(match.groups())
    if [name for name, _ in result] != expected:
        fail("lock list does not match the identity")
    for name, oid in result:
        print(name, oid)


try:
    main()
except SystemExit:
    raise
except Exception:
    fail("cannot read pinned inputs")
PY
) || fail "invalid template identity or lock"
[[ -n "$pins" ]] || fail "no templates to check"

temporary_directory=$(mktemp -d) || fail "cannot create a temporary directory"
export GIT_TERMINAL_PROMPT=0
template_mounts=()
checker_templates=()
index=0
# Fetch and checkout follow runner lines 264-271; local operation deliberately omits lines 272-278's
# default-branch reachability and pull-request non-rewind checks.
while read -r identity oid; do
  template_directory="$temporary_directory/$index"
  git init -q "$template_directory"
  git -C "$template_directory" -c credential.helper= fetch --quiet --no-tags --depth=1 \
    "https://github.com/$identity.git" "$oid" || fail "cannot fetch $identity@$oid"
  git -C "$template_directory" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD \
    || fail "cannot check out $identity@$oid"
  [[ $(git -C "$template_directory" rev-parse HEAD) == "$oid" ]] \
    || fail "checkout of $identity is not $oid"
  template_mounts+=(-v "$template_directory:/templates/$index:ro")
  checker_templates+=(--template "$identity=/templates/$index")
  index=$((index + 1))
done <<<"$pins"
chmod -R a+rX "$temporary_directory"

image=ghcr.io/nwarila-platform/workflow-template-drift
certificate_identity="https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/template-drift/v$version"
verification=$(cosign verify "$image:$version" \
  --certificate-identity "$certificate_identity" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository nwarila-platform/workflow-container-factory \
  --certificate-github-workflow-ref "refs/tags/template-drift/v$version" \
  -o json 2>/dev/null) || fail "image signature not verified"
digest=$(jq -er '
  if type == "array" and length > 0 then
    [.[].critical.image["docker-manifest-digest"]] | unique |
    if length == 1 then .[0] else error("conflicting digests") end
  else
    error("no signatures")
  end
' <<<"$verification" 2>/dev/null) || fail "unusable verification result"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid verified digest"

engine_arguments=(run --rm --network=none --read-only --cap-drop=ALL --security-opt=no-new-privileges)
if [[ "$engine" == podman ]]; then
  engine_arguments+=("--userns=keep-id:uid=65532,gid=65532")
fi
if "$engine" "${engine_arguments[@]}" -v "$checkout:/workspace:ro" "${template_mounts[@]}" \
  "$image@$digest" --workspace /workspace "${checker_templates[@]}" --format text; then
  status=0
else
  status=$?
fi
case "$status" in
  0 | 1 | 2) exit "$status" ;;
  *) exit 2 ;;
esac
