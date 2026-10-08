#!/usr/bin/env bash
# Image tests: prove the runner flags pass and that a writable workspace binds the read-only probe.
# Usage: tests/image.sh <image> <platform>
# Set CONTAINER_RUNTIME=podman to use Podman instead of Docker.
set -euo pipefail
image=$1
platform=$2
runtime=${CONTAINER_RUNTIME:-docker}
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R example "$work/example"
chmod -R a+rX "$work/example"

tmp_options=rw,nosuid,nodev,noexec,size=64m,mode=1777
home_options=rw,nosuid,nodev,noexec,size=16m,mode=1777
if [[ $runtime == podman ]]; then
  tmp_options+=,notmpcopyup
  home_options+=,notmpcopyup
fi

run() {
  status=0
  "$runtime" run --rm --platform "$platform" --network=none --read-only \
    "$@" >"$work/report" 2>"$work/errors" || status=$?
}

fail() {
  echo "image test failed: $1 (status $status)" >&2
  cat "$work/report" >&2
  cat "$work/errors" >&2
  exit 1
}

arguments=("$image" --workspace /workspace --template example/template=/templates/0 --format text)
security=(--cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs "/tmp:$tmp_options" --tmpfs "/home/nonroot:$home_options")

run "${security[@]}" --volume "$work/example/workspace:/workspace:ro" \
  --volume "$work/example/template:/templates/0:ro" "${arguments[@]}"
[[ $status -eq 0 ]] || fail "the runner-isolated invocation should pass"
diff <(printf '%s\n' 'ok: user' 'ok: capabilities' 'ok: no-new-privileges' 'ok: network' \
  'ok: root read-only' 'ok: workspace readable' 'ok: workspace read-only' \
  'ok: template readable: example/template' 'ok: template read-only: example/template' \
  'ok: scratch' 'ok: home scratch' 'runner-selftest: PASS (11 checks)') "$work/report" || fail "pass report differs"

run "${security[@]}" --volume "$work/example/workspace:/workspace:rw" \
  --volume "$work/example/template:/templates/0:ro" "${arguments[@]}"
[[ $status -eq 1 ]] || fail "the writable workspace should fail"
grep -q '^error: workspace read-only: ' "$work/report" || fail "workspace failure is absent"
[[ $(tail -n 1 "$work/report") == "runner-selftest: FAIL (11 checks, 1 failed)" ]] || fail "fail summary differs"

run "${security[@]}" "$image"
[[ $status -eq 2 && ! -s "$work/report" ]] || fail "a usage error should exit with status 2 and print no report"

run --security-opt=no-new-privileges --tmpfs "/tmp:$tmp_options" \
  --tmpfs "/home/nonroot:$home_options" --volume "$work/example/workspace:/workspace:ro" \
  --volume "$work/example/template:/templates/0:ro" "${arguments[@]}"
[[ $status -eq 1 ]] || fail "the invocation without dropped capabilities should fail"
grep -q '^error: capabilities: CapBnd is ' "$work/report" || fail "capabilities failure is absent"
[[ $(tail -n 1 "$work/report") == "runner-selftest: FAIL (11 checks, 1 failed)" ]] || fail "fail summary differs"

echo "image tests passed: $image on $platform"
