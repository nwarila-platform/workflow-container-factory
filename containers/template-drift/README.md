<!-- markdownlint-configure-file {"MD013":{"code_blocks":false,"tables":false}} -->

# template-drift

`template-drift` reads manifests from pinned template checkouts and reports
every declared rule that the target repository breaks. It compares files byte
for byte or by leading lines, requires files to exist, and requires paths to be
absent. It is report-only: it never updates, deletes, or creates files in the
repository.

Current release: `3.1.1` at
`sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834`.

## Inputs

The entry point accepts:

- `--workspace DIRECTORY`: the repository to inspect; required once.
- `--template OWNER/REPO=DIRECTORY`: a template label and its mounted checkout;
  required and repeatable.
- `--fail-on error|warning`: the lowest severity that returns status 1; default
  `error`.
- `--format text`: the report format. Text is currently the only format.

Mount the workspace and every template read-only. The organization runner uses
`/workspace` and numbered template mounts under `/templates`.

## Manifest

Each template has `template-drift.json` at its root. The supported manifest
version is 3. A manifest must contain exactly `version` and a nonempty `checks`
array. The bundled example is:

```json
{
  "version": 3,
  "checks": [
    {"mode": "bytes_equal", "path": "lint.toml"},
    {"mode": "head_lines_equal", "source": "pipeline.yaml", "target": "ci/pipeline.yaml", "head_lines": 4},
    {"mode": "must_exist", "path": "CHANGELOG.md"},
    {"mode": "must_exist", "path": "SECURITY.md", "severity": "warning"},
    {"mode": "must_be_absent", "path": "legacy.cfg"}
  ]
}
```

That block is copied byte for byte from
[`example/template/template-drift.json`](example/template/template-drift.json).

The modes are:

| Mode               | Rule                                                                       |
| ------------------ | -------------------------------------------------------------------------- |
| `bytes_equal`      | The target file equals the template file byte for byte.                    |
| `head_lines_equal` | The requested number of leading lines equals the template's leading lines. |
| `must_exist`       | A regular file exists at the target path.                                  |
| `must_be_absent`   | Nothing exists at the target path.                                         |

Comparison modes accept `path` when source and target names are the same, or
separate `source` and `target` names. `head_lines_equal` also requires a
positive integer `head_lines`. Severity defaults to `error` and may be
`warning`. Paths are relative, slash-separated, and limited to letters, digits,
`.`, `_`, and `-` in each segment. Symbolic links are not followed.

## Output and exit status

Text output has one line for each broken rule, sorted by target path, followed
by one summary line:

```text
warning: SECURITY.md: must_exist/target_missing (template example/template): target is missing
error: legacy.cfg: must_be_absent/target_present (template example/template): target must be absent
error: lint.toml: bytes_equal/content_mismatch (template example/template): target content differs from the pinned template
template-drift: FAIL (1 template, 5 checks, 2 errors, 1 warning)
```

The status is:

| Status | Meaning                                                                                 |
| ------ | --------------------------------------------------------------------------------------- |
| `0`    | No finding met the failure threshold. The summary is `PASS` or `WARNING`.               |
| `1`    | At least one finding met the failure threshold. The summary is `FAIL`.                  |
| `2`    | Arguments, a manifest, an input path, or another runtime condition prevented the check. |

Status 1 is an expected check result, not an execution error. With the default
`--fail-on error`, warnings alone return 0; `--fail-on warning` makes them
return 1.

## Run locally

From this directory, first make the mounted example world-readable because the
image runs as user `65532:65532`:

```sh
chmod -R a+rX example
```

Then run the bundled example with Docker:

```sh
docker run --rm --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --volume "$PWD/example/repository:/workspace:ro" \
  --volume "$PWD/example/template:/templates/0:ro" \
  'ghcr.io/nwarila-platform/workflow-template-drift@sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834' \
  --workspace /workspace \
  --template example/template=/templates/0 \
  --format text
```

The bundled repository intentionally has drift, so the report above is produced
and the command returns 1. For Podman, replace `docker` with `podman` and add
`--read-only-tmpfs=false`.

To build and test the working tree from the repository root instead:

```sh
bash containers/template-drift/tests/host.sh
docker build -f containers/template-drift/Containerfile -t workflow-template-drift:test containers/template-drift
bash containers/template-drift/tests/image.sh workflow-template-drift:test linux/amd64
```

For Podman:

```sh
podman build -f containers/template-drift/Containerfile -t workflow-template-drift:test containers/template-drift
CONTAINER_RUNTIME=podman bash containers/template-drift/tests/image.sh workflow-template-drift:test linux/amd64
```

## Run in CI

A consumer calls the shared contract-2 runner with the released version and
index digest:

```yaml
jobs:
  template-drift:
    permissions:
      contents: read
      security-events: write
    uses: nwarila-platform/.github/.github/workflows/run-container.yaml@95ca3c2332c8037f1ede76d1c2bd1a6b6ee43d4f
    with:
      name: template-drift
      # renovate: datasource=docker depName=ghcr.io/nwarila-platform/workflow-template-drift
      version: 3.1.1
      digest: sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834
      contract: 2
```

The consumer also commits `.github/.config/template-drift.yaml`, listing
template identities in order, and `.github/.config/template-drift.lock`, giving
one 40-character commit ID for every template other than the consumer itself.
Their grammar is:

```yaml
templates:
  - .github
  - OWNER/REPOSITORY
  - THIS_REPOSITORY
```

```text
OWNER/.github 0123456789abcdef0123456789abcdef01234567
OWNER/REPOSITORY 89abcdef0123456789abcdef0123456789abcdef
```

A one-part identity is resolved under the consumer's owner. The lock entries
must use the same order and spelling as the identity list after the consumer
repository is omitted. In pull requests, the runner reads the identity and prior
lock from the protected base branch, requires each template to be public, proves
each new pin reachable from its default branch, and refuses a lock rewind. It
then checks out the pins and runs the image offline with the workspace and
templates read-only.

## Pre-commit hook

The repository also publishes a `pre-push` hook. Pin it to the commit behind the
signed release tag, while retaining the tag in pre-commit's frozen comment:

```yaml
repos:
  - repo: https://github.com/nwarila-platform/workflow-container-factory
    rev: a429cb73d95fbb2d074ee43ca7104167b8acf7b6 # frozen: template-drift/v3.1.1
    hooks:
      - id: template-drift
```

Run it from the top of a GitHub repository checkout. It needs Bash 4.4 or later,
Git, Cosign, `jq`, Python 3, and a working Docker or Podman engine. Set
`TEMPLATE_DRIFT_ENGINE=docker` or `TEMPLATE_DRIFT_ENGINE=podman` to select one;
otherwise the hook tries Docker and then Podman. It reads the same identity and
lock files, fetches the pinned public commits anonymously, verifies the version
tag's image signature, extracts the verified digest, and runs that digest with
the same read-only, offline container restrictions.

The local hook has a deliberately narrower trust model than CI. It proves that
each requested commit can be fetched anonymously and that the checkout matches
the lock, but it does not use the GitHub API to prove default-branch
reachability and it does not compare old and new locks to prevent a rewind. The
contract-2 runner performs both checks in pull-request CI.

## Verify this release

```sh
cosign verify \
  'ghcr.io/nwarila-platform/workflow-template-drift@sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834' \
  --certificate-identity \
  'https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/template-drift/v3.1.1' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository nwarila-platform/workflow-container-factory \
  --certificate-github-workflow-ref refs/tags/template-drift/v3.1.1
```

The command verifies the signature on this exact index digest and restricts the
signing identity to the factory's build workflow at `template-drift/v3.1.1`.
