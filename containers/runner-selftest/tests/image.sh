#!/usr/bin/env bash
# Image tests: prove the runner flags pass and that a writable workspace binds the read-only probe.
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
  "$runtime" run --rm --platform "$platform" --network=none --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --tmpfs "/tmp:$tmp_options" \
    --tmpfs "/home/nonroot:$home_options" "$@" >"$work/report" 2>"$work/errors" || status=$?
}

fail() {
  echo "image test failed: $1 (status $status)" >&2
  cat "$work/report" >&2
  cat "$work/errors" >&2
  exit 1
}

arguments=("$image" --workspace /workspace --template example/template=/templates/0 --format text)
run --volume "$work/example/workspace:/workspace:ro" \
  --volume "$work/example/template:/templates/0:ro" "${arguments[@]}"
[[ $status -eq 0 ]] || fail "the runner-isolated invocation should pass"
[[ $(tail -n 1 "$work/report") == "runner-selftest: PASS (10 checks)" ]] || fail "pass summary differs"

run --volume "$work/example/workspace:/workspace:rw" \
  --volume "$work/example/template:/templates/0:ro" "${arguments[@]}"
[[ $status -eq 1 ]] || fail "the writable workspace should fail"
grep -q '^error: workspace read-only: ' "$work/report" || fail "workspace failure is absent"
[[ $(tail -n 1 "$work/report") == "runner-selftest: FAIL (10 checks, 1 failed)" ]] || fail "fail summary differs"

run "$image"
[[ $status -eq 2 && ! -s "$work/report" ]] || fail "a usage error should exit with status 2 and print no report"

echo "image tests passed: $image on $platform"
