#!/usr/bin/env bash
# Host tests for template-drift, run from the source tree with nothing built or pulled:
# the checker's unit tests, then the hook launcher against fake git, cosign, Docker and Podman.
# ci.yaml runs this file on every pull request and on every push to main.
set -euo pipefail
shopt -s inherit_errexit
trap 'printf "host tests: failed at line %s\n" "$LINENO" >&2' ERR
component=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$component"
PYTHONPATH=$component python3 -m unittest discover --start-directory tests --verbose

hook=$component/hook/template-drift-hook.sh
test -x "$hook"

# The fakes must be executable, while hardened hosts mount /tmp noexec.
test_root=$(mktemp -d -p "$HOME" template-drift-host.XXXXXX)
trap 'rm -rf "$test_root"' EXIT
fake_bin=$test_root/bin
consumer=$test_root/consumer
case_tmp=$test_root/tmp
log=$test_root/log
mkdir -p "$fake_bin" "$consumer/.github/.config"

oid_a=1111111111111111111111111111111111111111
oid_b=2222222222222222222222222222222222222222
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
real_chmod=$(command -v chmod)
real_git=$(command -v git)
real_rm=$(command -v rm)

# The fakes record security-sensitive arguments and let unexpected Git calls fail.
cat >"$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == rev-parse && "${2:-}" == --show-toplevel ]]; then
  printf '%s\n' "$HOOK_TOP"
  exit 0
fi
if [[ "${1:-}" == rev-parse && "${2:-}" == --local-env-vars ]]; then
  exec "$HOOK_REAL_GIT" "$@"
fi
if [[ "${1:-}" == config && "${2:-}" == --get && "${3:-}" == remote.origin.url ]]; then
  [[ -n "${HOOK_ORIGIN:-}" ]] || exit 1
  printf '%s\n' "$HOOK_ORIGIN"
  exit 0
fi
if [[ "${1:-}" == init ]]; then
  printf '%s|%s|%s|%s|%s|%s|%s\n' "${GIT_DIR-}" "${GIT_INDEX_FILE-}" \
    "${GIT_CONFIG_PARAMETERS-}" "${GIT_CONFIG_COUNT-}" "${GIT_ASKPASS-}" \
    "${SSH_ASKPASS-}" "${GIT_TEMPLATE_DIR-}" >>"$HOOK_LOG/git-environment"
  [[ "${HOOK_GIT_INIT_FAIL:-0}" != 1 ]] || exit 128
  if [[ "${HOOK_USE_REAL_GIT_INIT:-0}" == 1 ]]; then
    exec "$HOOK_REAL_GIT" "$@"
  fi
  mkdir -p "${@: -1}"
  exit 0
fi
if [[ "${1:-}" == -C ]]; then
  printf '%s|%s|%s|%s|%s|%s|%s\n' "${GIT_DIR-}" "${GIT_INDEX_FILE-}" \
    "${GIT_CONFIG_PARAMETERS-}" "${GIT_CONFIG_COUNT-}" "${GIT_ASKPASS-}" \
    "${SSH_ASKPASS-}" "${GIT_TEMPLATE_DIR-}" >>"$HOOK_LOG/git-environment"
  directory=$2
  shift 2
  if [[ " $* " == *" fetch "* ]]; then
    printf '%s %s %s %s\n' "${GIT_CONFIG_GLOBAL-unset}" "${GIT_CONFIG_NOSYSTEM-unset}" \
      "${GIT_TERMINAL_PROMPT-unset}" "$*" >>"$HOOK_LOG/fetch"
    if [[ "${HOOK_USE_REAL_GIT_INIT:-0}" == 1 ]] \
      && "$HOOK_REAL_GIT" config --file "$directory/.git/config" \
        --get-regexp '^url\..*\.insteadof$' >/dev/null; then
      exit 128
    fi
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

cat >"$fake_bin/chmod" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${HOOK_CHMOD_FAIL:-0}" != 1 ]] || exit 1
exec "$HOOK_REAL_CHMOD" "$@"
EOF

cat >"$fake_bin/rm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${HOOK_SIGNAL_DURING_CLEANUP:-0}" == 1 ]]; then
  "$HOOK_REAL_RM" "$@"
  kill -TERM "$PPID"
  exit 0
fi
exec "$HOOK_REAL_RM" "$@"
EOF

cat >"$fake_bin/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$HOOK_LOG/cosign"
signatures() {
  local separator= digest
  printf '['
  for digest; do
    printf '%s{"critical":{"image":{"docker-manifest-digest":"%s"}}}' "$separator" "$digest"
    separator=,
  done
  printf ']\n'
}
case "${HOOK_COSIGN:-ok}" in
  ok) signatures "$HOOK_DIGEST" ;;
  twice) signatures "$HOOK_DIGEST" "$HOOK_DIGEST" ;;
  conflict) signatures "$HOOK_DIGEST" sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
  malformed) signatures sha256:not-a-digest ;;
  empty) signatures ;;
  invalid) printf 'not-json\n' ;;
  fail) printf 'cosign verification detail\n' >&2; exit 1 ;;
esac
EOF

cat >"$fake_bin/docker" <<'EOF'
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
chmod +x "$fake_bin/git" "$fake_bin/cosign" "$fake_bin/docker" "$fake_bin/chmod" "$fake_bin/rm"
cp "$fake_bin/docker" "$fake_bin/podman"

reset_inputs() {
  printf 'templates:\n  - .github\n  - octo/template\n  - octo/consumer\n' \
    >"$consumer/.github/.config/template-drift.yaml"
  printf 'octo/.github %s\nocto/template %s\n' "$oid_a" "$oid_b" \
    >"$consumer/.github/.config/template-drift.lock"
}

# Start each case with an empty temporary directory and log.
new_case() {
  rm -rf "${case_tmp:?}" "${log:?}"
  mkdir -p "$case_tmp" "$log"
}

# Replace the calling subshell with the hook, using the case's VARIABLE=VALUE arguments.
exec_hook() {
  cd "$consumer" && exec env -u TEMPLATE_DRIFT_ENGINE -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_NOSYSTEM \
    -u GIT_TERMINAL_PROMPT PATH="$fake_bin:$PATH" TMPDIR="$case_tmp" \
    HOOK_TOP="$consumer" HOOK_ORIGIN=https://github.com/octo/consumer.git \
    HOOK_LOG="$log" HOOK_DIGEST="$digest" HOOK_REAL_CHMOD="$real_chmod" \
    HOOK_REAL_GIT="$real_git" HOOK_REAL_RM="$real_rm" \
    "$@" "$hook"
}

check_case() {
  local name=$1 expected=$2 actual=$3 leftover
  if [[ "$actual" != "$expected" ]]; then
    cat "$log/output" >&2
    [[ ! -e "$log/engine-info" ]] || cat "$log/engine-info" >&2
    printf 'hook test %s: exit %s, expected %s\n' "$name" "$actual" "$expected" >&2
    return 1
  fi
  leftover=$(find "$case_tmp" -mindepth 1 -print -quit)
  [[ -z "$leftover" ]] || {
    printf 'hook test %s: temporary directory was not removed\n' "$name" >&2
    return 1
  }
}

# run_hook NAME STATUS [VARIABLE=VALUE...]
run_hook() {
  local name=$1 expected=$2 actual=0
  shift 2
  new_case
  (exec_hook "$@") >"$log/output" 2>&1 || actual=$?
  check_case "$name" "$expected" "$actual"
}

check_engine_arguments() {
  python3 -I - "$log/engine" "$1" "$consumer" "$case_tmp" "$digest" <<'PY'
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

check_cosign_arguments() {
  local identity version
  version=$(<"$component/VERSION")
  identity="https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/template-drift/v$version"
  printf '%s\n' verify "ghcr.io/nwarila-platform/workflow-template-drift:$version" \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-github-workflow-repository nwarila-platform/workflow-container-factory \
    --certificate-github-workflow-ref "refs/tags/template-drift/v$version" \
    -o json | diff -u - "$log/cosign"
}

check_fetches() {
  diff -u - "$log/fetch" <<EOF
/dev/null 1 0 -c credential.helper= fetch --quiet --no-tags --depth=1 https://github.com/octo/.github.git $oid_a
/dev/null 1 0 -c credential.helper= fetch --quiet --no-tags --depth=1 https://github.com/octo/template.git $oid_b
EOF
}

reset_inputs
run_hook "docker arguments" 0
[[ $(wc -l <"$log/engine-info") == 1 ]]
check_engine_arguments docker
check_cosign_arguments
check_fetches
reset_inputs
run_hook "podman arguments" 0 TEMPLATE_DRIFT_ENGINE=podman
[[ $(wc -l <"$log/engine-info") == 1 ]]
check_engine_arguments podman
reset_inputs
run_hook "podman when docker is not working" 0 HOOK_DOCKER_INFO=1
check_engine_arguments podman
reset_inputs
run_hook "no working engine" 2 HOOK_DOCKER_INFO=1 HOOK_PODMAN_INFO=1
reset_inputs
run_hook "configured engine not working" 2 TEMPLATE_DRIFT_ENGINE=podman HOOK_PODMAN_INFO=1
reset_inputs
run_hook "engine given as a path" 2 TEMPLATE_DRIFT_ENGINE="$fake_bin/docker"

for origin in \
  https://github.com/octo/consumer https://github.com/octo/consumer.git \
  git@github.com:octo/consumer git@github.com:octo/consumer.git \
  ssh://git@github.com/octo/consumer ssh://git@github.com/octo/consumer.git; do
  reset_inputs
  run_hook "origin $origin" 0 HOOK_ORIGIN="$origin"
done
reset_inputs
run_hook "malformed origin" 2 HOOK_ORIGIN=https://gitlab.com/octo/consumer.git
reset_inputs
run_hook "no origin" 2 HOOK_ORIGIN=
reset_inputs
run_hook "not run from the top of the work tree" 2 HOOK_TOP="$test_root"

for file in template-drift.yaml template-drift.lock; do
  path=$consumer/.github/.config/$file
  reset_inputs; printf 'non-ascii \303\251\n' >"$path"; run_hook "$file non-ASCII" 2
  reset_inputs; printf 'nul\0byte\n' >"$path"; run_hook "$file NUL" 2
  reset_inputs; content=$(<"$path")
  printf '%s\r\n' "${content//$'\n'/$'\r\n'}" >"$path"; run_hook "$file CRLF" 2
  reset_inputs; printf '%s' "$content" >"$path"; run_hook "$file no final LF" 2
  reset_inputs; printf '%s\n' "${content/$'\n'/$'\v'}" >"$path"; run_hook "$file vertical tab" 0
done

reset_inputs
printf 'templates:\n  - bad identity!\n' >"$consumer/.github/.config/template-drift.yaml"
run_hook "bad identity" 2
reset_inputs
printf 'templates:\n  - octo/template\n  - Octo/Template\n' >"$consumer/.github/.config/template-drift.yaml"
printf 'octo/template %s\nOcto/Template %s\n' "$oid_b" "$oid_b" >"$consumer/.github/.config/template-drift.lock"
run_hook "case-insensitive duplicate" 2

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
reset_inputs
run_hook "git init failure" 2 HOOK_GIT_INIT_FAIL=1
reset_inputs
run_hook "fetch failure" 2 HOOK_FETCH_FAIL=1
reset_inputs
run_hook "repository-local Git environment isolation" 0 \
  GIT_DIR="$consumer/.git" GIT_INDEX_FILE="$consumer/index" \
  GIT_CONFIG_PARAMETERS="'foo.bar'='baz'" GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=foo.bar GIT_CONFIG_VALUE_0=baz \
  GIT_ASKPASS="$test_root/askpass" SSH_ASKPASS="$test_root/ssh-askpass" \
  GIT_TEMPLATE_DIR="$test_root/template"
[[ -s "$log/git-environment" ]]
if grep -vxF "||'foo.bar'='baz'|1|||" "$log/git-environment"; then
  exit 1
fi
reset_inputs
git_template=$test_root/git-template
global_git_config=$test_root/global.gitconfig
mkdir -p "$git_template"
cat >"$git_template/config" <<'EOF'
[url "file:///missing/"]
  insteadOf = https://github.com/
EOF
"$real_git" config --file "$global_git_config" init.templateDir "$git_template"
run_hook "global init.templateDir URL rewrite isolation" 0 HOOK_USE_REAL_GIT_INIT=1 \
  HOOK_REAL_GIT="$real_git" GIT_CONFIG_GLOBAL="$global_git_config"
reset_inputs
run_hook "environment init template isolation" 0 HOOK_USE_REAL_GIT_INIT=1 \
  GIT_TEMPLATE_DIR="$git_template"
reset_inputs
run_hook "chmod failure" 2 HOOK_CHMOD_FAIL=1
reset_inputs
run_hook "TERM during final cleanup" 2 HOOK_SIGNAL_DURING_CLEANUP=1

for cosign_mode in empty invalid conflict malformed; do
  reset_inputs
  run_hook "cosign $cosign_mode" 2 HOOK_COSIGN="$cosign_mode"
done
reset_inputs
run_hook "cosign empty detail" 2 HOOK_COSIGN=empty
grep -qF "no signatures" "$log/output"
reset_inputs
run_hook "cosign conflicting detail" 2 HOOK_COSIGN=conflict
grep -qF "conflicting digests" "$log/output"
reset_inputs
run_hook "cosign two signatures on one digest" 0 HOOK_COSIGN=twice
reset_inputs
run_hook "cosign failure output" 2 HOOK_COSIGN=fail
grep -qxF "cosign verification detail" "$log/output"

for status_pair in 0:0 1:1 2:2 17:2; do
  reset_inputs
  engine_status=${status_pair%%:*}
  run_hook "engine status $engine_status" "${status_pair##*:}" HOOK_ENGINE_EXIT="$engine_status"
  grep -qxF "template-drift: FAKE CHECKER $engine_status" "$log/output"
done

# Exercise signal cleanup while the fake checker is running.
reset_inputs
new_case
(exec_hook HOOK_BLOCK=1) >"$log/output" 2>&1 &
hook_pid=$!
for _ in {1..50}; do
  [[ -e "$log/engine-started" ]] && break
  sleep 0.05
done
[[ -e "$log/engine-started" ]] || { printf 'hook TERM test: engine did not start\n' >&2; exit 1; }
kill -TERM "$hook_pid"
term_status=0
wait "$hook_pid" || term_status=$?
check_case "TERM while the checker runs" 2 "$term_status"

printf 'hook tests: PASS\n'
