#!/usr/bin/env bash
# Host tests: the unit tests, run straight from the source tree with nothing installed.
# ci.yaml runs this file on every pull request and on every push to main.
set -euo pipefail
shopt -s inherit_errexit
component=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$component"
python3 -m unittest discover --start-directory tests --verbose

hook=$component/hook/template-drift-hook.sh
test -x "$hook"

test_root=$(mktemp -d -p "$HOME" template-drift-host.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
fake_bin=$test_root/bin
consumer=$test_root/consumer
case_tmp=$test_root/tmp
log=$test_root/log
mkdir -p "$fake_bin" "$consumer/.github/.config" "$case_tmp" "$log"

oid_a=1111111111111111111111111111111111111111
oid_b=2222222222222222222222222222222222222222
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\037%s' "$PWD" "${GIT_TERMINAL_PROMPT-unset}" >>"$HOOK_LOG/git"
printf '\037%s' "$@" >>"$HOOK_LOG/git"
printf '\n' >>"$HOOK_LOG/git"
if [[ "${1:-}" == rev-parse && "${2:-}" == --show-toplevel ]]; then
  printf '%s\n' "$HOOK_TOP"
  exit 0
fi
if [[ "${1:-}" == config && "${2:-}" == --get && "${3:-}" == remote.origin.url ]]; then
  [[ -n "${HOOK_ORIGIN:-}" ]] || exit 1
  printf '%s\n' "$HOOK_ORIGIN"
  exit 0
fi
if [[ "${1:-}" == init ]]; then
  mkdir -p "${@: -1}"
  exit 0
fi
if [[ "${1:-}" == -C ]]; then
  directory=$2
  shift 2
  if [[ " $* " == *" fetch "* ]]; then
    printf '%s\n' "${@: -1}" >"$directory/.hook-head"
    [[ "${HOOK_FETCH_FAIL:-0}" != 1 ]]
    exit
  fi
  if [[ " $* " == *" checkout "* ]]; then
    exit 0
  fi
  if [[ " $* " == *" rev-parse HEAD "* ]]; then
    if [[ "${HOOK_HEAD_MISMATCH:-0}" == 1 ]]; then
      printf '%040d\n' 0
    else
      cat "$directory/.hook-head"
    fi
    exit 0
  fi
fi
exit 1
EOF

cat >"$fake_bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$HOOK_LOG/cosign"
case "${HOOK_COSIGN:-ok}" in
  ok) printf '[{"critical":{"image":{"docker-manifest-digest":"%s"}}}]\n' "$HOOK_DIGEST" ;;
  empty) printf '[]\n' ;;
  invalid) printf 'not-json\n' ;;
  conflict) printf '[{"critical":{"image":{"docker-manifest-digest":"%s"}}},{"critical":{"image":{"docker-manifest-digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}]\n' "$HOOK_DIGEST" ;;
esac
EOF

cat >"$fake_bin/engine" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name=${0##*/}
if [[ "${1:-}" == info ]]; then
  printf '%s info\n' "$name" >>"$HOOK_LOG/engine-info"
  if [[ "$name" == docker ]]; then exit "${HOOK_DOCKER_INFO:-0}"; fi
  exit "${HOOK_PODMAN_INFO:-0}"
fi
{ printf '%s\n' "$name"; printf '%s\n' "$@"; } >"$HOOK_LOG/engine"
if [[ "${HOOK_BLOCK:-0}" == 1 ]]; then
  : >"$HOOK_LOG/engine-started"
  sleep 2
fi
printf 'template-drift: FAKE CHECKER %s\n' "${HOOK_ENGINE_EXIT:-0}"
exit "${HOOK_ENGINE_EXIT:-0}"
EOF
chmod +x "$fake_bin/git" "$fake_bin/cosign" "$fake_bin/engine"
cp "$fake_bin/engine" "$fake_bin/docker"
cp "$fake_bin/engine" "$fake_bin/podman"
rm "$fake_bin/engine"

reset_inputs() {
  printf 'templates:\n  - .github\n  - octo/template\n  - octo/consumer\n' \
    >"$consumer/.github/.config/template-drift.yaml"
  printf 'octo/.github %s\nocto/template %s\n' "$oid_a" "$oid_b" \
    >"$consumer/.github/.config/template-drift.lock"
}

run_hook() {
  local name=$1 expected=$2 actual
  shift 2
  rm -rf "${case_tmp:?}" "${log:?}"
  mkdir -p "$case_tmp" "$log"
  set +e
  (cd "$consumer" && env PATH="$fake_bin:$PATH" TMPDIR="$case_tmp" \
    HOOK_TOP="$consumer" HOOK_ORIGIN=https://github.com/octo/consumer.git \
    HOOK_LOG="$log" HOOK_DIGEST="$digest" "$@" "$hook") >"$log/output" 2>&1
  actual=$?
  set -e
  if [[ "$actual" != "$expected" ]]; then
    cat "$log/output" >&2
    [[ ! -e "$log/engine-info" ]] || cat "$log/engine-info" >&2
    printf 'hook test %s: exit %s, expected %s\n' "$name" "$actual" "$expected" >&2
    return 1
  fi
  [[ -z "$(find "$case_tmp" -mindepth 1 -print -quit)" ]] || {
    printf 'hook test %s: temporary directory was not removed\n' "$name" >&2
    return 1
  }
}

check_engine_arguments() {
  python3 - "$log/engine" "$1" "$consumer" "$case_tmp" "$digest" <<'PY'
import sys

path, engine, consumer, tmpdir, digest = sys.argv[1:]
args = open(path, encoding="utf-8").read().splitlines()
expected = [engine, "run", "--rm", "--network=none", "--read-only", "--cap-drop=ALL",
            "--security-opt=no-new-privileges"]
if engine == "podman":
    expected.append("--userns=keep-id:uid=65532,gid=65532")
expected += ["-v", f"{consumer}:/workspace:ro", "-v", "MOUNT0", "-v", "MOUNT1",
             f"ghcr.io/nwarila-platform/workflow-template-drift@{digest}",
             "--workspace", "/workspace", "--template", "octo/.github=/templates/0",
             "--template", "octo/template=/templates/1", "--format", "text"]
mounts = [arg for arg in args if arg.endswith(":/templates/0:ro") or arg.endswith(":/templates/1:ro")]
assert len(mounts) == 2, args
normalized = ["MOUNT0" if arg == mounts[0] else "MOUNT1" if arg == mounts[1] else arg for arg in args]
assert normalized == expected, (normalized, expected)
parents = set()
for index, mount in enumerate(mounts):
    source, destination, mode = mount.rsplit(":", 2)
    assert source.startswith(tmpdir + "/")
    assert destination == f"/templates/{index}" and mode == "ro"
    parents.add(source.rsplit("/", 1)[0])
assert len(parents) == 1
PY
}

reset_inputs
run_hook "docker arguments" 0
check_engine_arguments docker
reset_inputs
run_hook "podman arguments" 0 TEMPLATE_DRIFT_ENGINE=podman
check_engine_arguments podman

for origin in \
  https://github.com/octo/consumer https://github.com/octo/consumer.git \
  git@github.com:octo/consumer git@github.com:octo/consumer.git \
  ssh://git@github.com/octo/consumer ssh://git@github.com/octo/consumer.git; do
  reset_inputs
  run_hook "origin $origin" 0 HOOK_ORIGIN="$origin"
done
reset_inputs
run_hook "malformed origin" 2 HOOK_ORIGIN=https://gitlab.com/octo/consumer.git

for file in template-drift.yaml template-drift.lock; do
  path=$consumer/.github/.config/$file
  reset_inputs; printf 'non-ascii \303\251\n' >"$path"; run_hook "$file non-ASCII" 2
  reset_inputs; printf 'carriage\r\n' >"$path"; run_hook "$file CR" 2
  reset_inputs; printf 'nul\0byte\n' >"$path"; run_hook "$file NUL" 2
  reset_inputs; printf 'no final LF' >"$path"; run_hook "$file no final LF" 2
done

reset_inputs
printf 'templates:\n  - bad identity!\n' >"$consumer/.github/.config/template-drift.yaml"
run_hook "bad identity" 2
reset_inputs
printf 'templates:\n  - octo/template\n  - Octo/Template\n' >"$consumer/.github/.config/template-drift.yaml"
run_hook "case-insensitive duplicate" 2
reset_inputs
printf 'templates:\n  - octo/consumer\n' >"$consumer/.github/.config/template-drift.yaml"
: >"$consumer/.github/.config/template-drift.lock"
run_hook "self-only identity" 2

reset_inputs
printf 'octo/template %s\nocto/.github %s\n' "$oid_b" "$oid_a" >"$consumer/.github/.config/template-drift.lock"
run_hook "lock order mismatch" 2
reset_inputs
printf 'Octo/.github %s\nocto/template %s\n' "$oid_a" "$oid_b" >"$consumer/.github/.config/template-drift.lock"
run_hook "lock case mismatch" 2
reset_inputs
printf 'octo/.github %s\n' "$oid_a" >"$consumer/.github/.config/template-drift.lock"
run_hook "lock list mismatch" 2
reset_inputs
run_hook "fetched HEAD mismatch" 2 HOOK_HEAD_MISMATCH=1

for cosign_mode in empty invalid conflict; do
  reset_inputs
  run_hook "cosign $cosign_mode" 2 HOOK_COSIGN="$cosign_mode"
done

for status_pair in 0:0 1:1 2:2 17:2; do
  reset_inputs
  engine_status=${status_pair%%:*}
  run_hook "engine status $engine_status" "${status_pair##*:}" HOOK_ENGINE_EXIT="$engine_status"
  grep -qxF "template-drift: FAKE CHECKER $engine_status" "$log/output"
done

# Exercise signal cleanup while the fake checker is running.
reset_inputs
rm -rf "${case_tmp:?}" "${log:?}"
mkdir -p "$case_tmp" "$log"
set +e
(cd "$consumer" && exec env PATH="$fake_bin:$PATH" TMPDIR="$case_tmp" \
  HOOK_TOP="$consumer" HOOK_ORIGIN=https://github.com/octo/consumer.git \
  HOOK_LOG="$log" HOOK_DIGEST="$digest" HOOK_BLOCK=1 "$hook") >"$log/output" 2>&1 &
hook_pid=$!
for _ in $(seq 1 50); do
  [[ -e "$log/engine-started" ]] && break
  sleep 0.05
done
[[ -e "$log/engine-started" ]] || { printf 'hook TERM test: engine did not start\n' >&2; exit 1; }
kill -TERM "$hook_pid"
wait "$hook_pid"
term_status=$?
set -e
[[ "$term_status" == 2 ]]
[[ -z "$(find "$case_tmp" -mindepth 1 -print -quit)" ]]

printf 'hook tests: PASS\n'
