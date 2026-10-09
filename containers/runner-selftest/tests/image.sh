#!/usr/bin/env bash
# Image tests: run the selftest through a built image with the same arguments and restrictions as
# the organization's runner, require the exact passing report, then weaken isolation one flag at a
# time and require that the corresponding check alone fails.
# ci.yaml runs this file on each architecture's build, and build.yaml runs it again on each
# candidate image before that image is signed and promoted.
#
# Usage: tests/image.sh <image> <platform>
# Set CONTAINER_RUNTIME=podman to use Podman instead of Docker.
set -euo pipefail
image=$1
platform=$2
runtime=${CONTAINER_RUNTIME:-docker}
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The container runs as an unprivileged user, so it is given a world-readable copy of the example,
# just as the runner makes a checkout world-readable before mounting it.
cp -R example "$work/example"
chmod -R a+rX "$work/example"

# Docker mounts an empty tmpfs; notmpcopyup prevents Podman from populating it from the image.
tmp_options=rw,nosuid,nodev,noexec,size=64m,mode=1777
home_options=rw,nosuid,nodev,noexec,size=16m,mode=1777
if [[ $runtime == podman ]]; then
  tmp_options+=,notmpcopyup
  home_options+=,notmpcopyup
fi

# Keep each runner flag in one array element so a negative case can remove or replace exactly one.
tmp_mount="--tmpfs=/tmp:$tmp_options"
home_mount="--tmpfs=/home/nonroot:$home_options"
workspace_mount="--volume=$work/example/workspace:/workspace:ro"
template_mount="--volume=$work/example/template:/templates/0:ro"
runner_flags=(--network=none --read-only --cap-drop=ALL --security-opt=no-new-privileges
  "$tmp_mount" "$home_mount" "$workspace_mount" "$template_mount")
arguments=(--workspace /workspace --template example/template=/templates/0 --format text)

# A nonzero container status is a test result to inspect, not an immediate failure of this script.
run() {
  status=0
  "$runtime" run --rm --platform "$platform" "$@" >"$work/report" 2>"$work/errors" || status=$?
}

fail() {
  echo "image test failed: $1 (status $status)" >&2
  cat "$work/report" >&2
  cat "$work/errors" >&2
  exit 1
}

# fails_without CHECK FLAG [REPLACEMENT]: remove or replace one flag and require only CHECK to fail.
fails_without() {
  local check=$1 omitted=$2 flag
  local -a flags=()
  shift 2
  for flag in "${runner_flags[@]}"; do
    if [[ $flag == "$omitted" ]]; then
      flags+=("$@")
    else
      flags+=("$flag")
    fi
  done
  run "${flags[@]}" "$image" "${arguments[@]}"
  [[ $status -eq 1 ]] || fail "without $omitted, the selftest should exit with status 1"
  grep -q "^error: $check: " "$work/report" || fail "without $omitted, $check should fail"
  [[ $(tail -n 1 "$work/report") == "runner-selftest: FAIL (11 checks, 1 failed)" ]] ||
    fail "without $omitted, $check should be the only failure"
}

run "${runner_flags[@]}" "$image" "${arguments[@]}"
[[ $status -eq 0 ]] || fail "the runner's flags should pass"
diff - "$work/report" <<'EOF' || fail "the pass report differs"
ok: user
ok: capabilities
ok: no-new-privileges
ok: network
ok: root read-only
ok: workspace readable
ok: workspace read-only
ok: template readable: example/template
ok: template read-only: example/template
ok: scratch
ok: home scratch
runner-selftest: PASS (11 checks)
EOF

fails_without capabilities --cap-drop=ALL
fails_without no-new-privileges --security-opt=no-new-privileges
fails_without network --network=none
fails_without "root read-only" --read-only
fails_without "workspace read-only" "$workspace_mount" "${workspace_mount%:ro}:rw"
fails_without "template read-only: example/template" "$template_mount" "${template_mount%:ro}:rw"

run "${runner_flags[@]}" "$image"
[[ $status -eq 2 && ! -s "$work/report" ]] || fail "a usage error should exit with status 2 and print no report"

echo "image tests passed: $image on $platform"
