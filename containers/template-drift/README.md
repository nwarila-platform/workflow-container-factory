# template-drift

`template-drift` compares a repository with pinned template checkouts. It reports broken rules in
path order, followed by a summary. It only reads its inputs and uses no network access.
A template is a repository whose files other repositories copy.

The supported rules require a file to match template bytes, require its leading lines to match,
require it to exist, or require it to be absent. Warnings are reported without failing unless
`--fail-on warning` is used.

## Run the image

Mount the repository and each template read-only. The image runs as user `65532`, so that user must
be able to read every mounted file and directory. The image test copies the example and runs
`chmod -R a+rX` on the copy for this reason. Do the same if your checkout is not world-readable.
This example uses the same arguments and runtime restrictions as the image test:

Verify the image first with the factory's [release verification steps](../../README.md#verify-a-release-yourself).
They set `digest`.

```sh
docker run --rm --platform linux/amd64 --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --volume "$PWD/example/repository:/workspace:ro" \
  --volume "$PWD/example/template:/templates/0:ro" \
  "ghcr.io/nwarila-platform/workflow-template-drift@${digest}" \
  --workspace /workspace \
  --template example/template=/templates/0 \
  --fail-on error \
  --format text
```

Exit status `0` means the repository passes. Exit status `1` means it has drifted, or a warning
meets the selected failure threshold. Exit status `2` means the check could not run, such as from
invalid arguments, a malformed manifest, an unreadable compared file, or an incomplete report
write.

## Bundled example

The `example/` directory contains a small template and a repository that has drifted from it. The
template's rules are in `example/template/template-drift.json`. Each rule names a mode:
`bytes_equal`, `head_lines_equal`, `must_exist` or `must_be_absent`.

```json
{
  "version": 3,
  "checks": [
    {"mode": "bytes_equal", "path": "lint.toml"},
    {"mode": "head_lines_equal", "path": "pipeline.yaml", "head_lines": 4},
    {"mode": "must_exist", "path": "CHANGELOG.md"},
    {"mode": "must_exist", "path": "SECURITY.md", "severity": "warning"},
    {"mode": "must_be_absent", "path": "legacy.cfg"}
  ]
}
```

Run the example from this directory without a container, using Python 3.12:

```sh
python3 -m workflow_template_drift \
  --workspace example/repository \
  --template example/template=example/template
```

It prints the report in `example/expected-report.txt`:

```text
warning: SECURITY.md: must_exist/target_missing (template example/template): target is missing
error: legacy.cfg: must_be_absent/target_present (template example/template): target must be absent
error: lint.toml: bytes_equal/content_mismatch (template example/template): target content differs from the pinned template
template-drift: FAIL (1 template, 5 checks, 2 errors, 1 warning)
```
