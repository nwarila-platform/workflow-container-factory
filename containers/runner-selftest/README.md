<!-- markdownlint-configure-file {"MD013":{"code_blocks":false,"tables":false}} -->

# runner-selftest

`runner-selftest` reports whether the runtime environment supplied by the shared
workflow-container runner has the isolation required by contract 2. It diagnoses
the environment from inside the container. It does not configure the host, add
restrictions, repair a failing runner, inspect the calling repository's content,
or replace the runner's own signature and input checks.

Current release: `1.1.0` at
`sha256:44ec1f7813f872af2587fae4d6006de1919c3a2ae3ebf417bc429ac7332b2ac6`.

## Checks

The report covers:

- effective UID and GID are `65532:65532`;
- inherited, permitted, effective, bounding, and ambient Linux capability sets
  are empty;
- `NoNewPrivs` is enabled;
- no network interface other than loopback is present;
- the image root is read-only;
- the workspace is nonempty, readable, and read-only;
- every template is nonempty, readable, and read-only; and
- `/tmp` and `/home/nonroot` are writable tmpfs mounts with `nosuid`, `nodev`,
  and `noexec`.

The probes create temporary files only where they are testing writability. They
do not alter the read-only workspace or template mounts.

## Inputs and mounts

The entry point accepts:

- `--workspace DIRECTORY`: the mounted workspace; required once.
- `--template OWNER/REPO=DIRECTORY`: the label and mount for a template;
  required and repeatable.
- `--format text`: the report format. Text is currently the only format.

The contract-2 runner mounts the workspace at `/workspace`, templates under
`/templates`, and scratch tmpfs filesystems at `/tmp` and `/home/nonroot`. The
workspace and template example files are under [`example/`](example/).

## Output and exit status

Text output contains one `ok:` or `error:` line for every probe and ends with
exactly one summary:

```text
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
```

The status is:

| Status | Meaning                                                                               |
| ------ | ------------------------------------------------------------------------------------- |
| `0`    | Every isolation check passed; the final line is `runner-selftest: PASS (...)`.        |
| `1`    | One or more isolation checks failed; the final line is `runner-selftest: FAIL (...)`. |
| `2`    | Invalid arguments or another runtime failure prevented a complete report.             |

## Run locally

From this directory, Docker can reproduce the runner's passing environment:

```sh
docker run --rm --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777 \
  --tmpfs /home/nonroot:rw,nosuid,nodev,noexec,size=16m,mode=1777 \
  --volume "$PWD/example/workspace:/workspace:ro" \
  --volume "$PWD/example/template:/templates/0:ro" \
  'ghcr.io/nwarila-platform/workflow-runner-selftest@sha256:44ec1f7813f872af2587fae4d6006de1919c3a2ae3ebf417bc429ac7332b2ac6' \
  --workspace /workspace \
  --template example/template=/templates/0 \
  --format text
```

With Podman, replace `docker` with `podman`, add
`--userns=keep-id:uid=65532,gid=65532`, and add `notmpcopyup` to both `--tmpfs`
option lists.

To build and test the working tree instead:

```sh
bash tests/host.sh
docker build -t workflow-runner-selftest:test .
bash tests/image.sh workflow-runner-selftest:test linux/amd64
```

Set `CONTAINER_RUNTIME=podman` on the image-test command to use Podman. The
image suite first requires the full passing report, then removes one isolation
flag at a time and requires only the corresponding probe to fail.

## Run in CI

The repository's acceptance workflow uses the current release through the shared
runner:

```yaml
jobs:
  runner-selftest:
    permissions:
      contents: read
      security-events: write
    uses: nwarila-platform/.github/.github/workflows/run-container.yaml@95ca3c2332c8037f1ede76d1c2bd1a6b6ee43d4f
    with:
      name: runner-selftest
      # renovate: datasource=docker depName=ghcr.io/nwarila-platform/workflow-runner-selftest
      version: 1.1.0
      digest: sha256:44ec1f7813f872af2587fae4d6006de1919c3a2ae3ebf417bc429ac7332b2ac6
      contract: 2
```

`runner-selftest` declares that it needs scratch space and a second input. A
caller therefore commits `.github/.config/runner-selftest.yaml` and
`.github/.config/runner-selftest.lock` in the same identity-and-lock format used
by other second-input containers. The factory's acceptance fixture mounts
`nwarila-platform/workflow-container-template` at commit
`0b366f86a1d78defe8a05098aa881e8998ce8a4b`. The runner verifies the image and
tag, validates the requirement labels, prepares the mounts, runs the image
without networking, and restores its exit status.

The factory's CI also runs Python unit tests on the host and builds and executes
the image on Linux AMD64 and ARM64. The release workflow repeats the image suite
against both release children before signing and promotion.

## Verify this release

```sh
cosign verify \
  'ghcr.io/nwarila-platform/workflow-runner-selftest@sha256:44ec1f7813f872af2587fae4d6006de1919c3a2ae3ebf417bc429ac7332b2ac6' \
  --certificate-identity \
  'https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/runner-selftest/v1.1.0' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository nwarila-platform/workflow-container-factory \
  --certificate-github-workflow-ref refs/tags/runner-selftest/v1.1.0
```

The command verifies the signature on this exact index digest and restricts the
signing identity to the factory's build workflow at `runner-selftest/v1.1.0`.
