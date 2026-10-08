# runner-selftest

`runner-selftest` checks, from inside a container, the isolation that the organization's runner applies.
It prints one line per check, in this order:

- `user`: the process runs as user and group 65532.
- `capabilities`: the effective and bounding capability sets are empty.
- `no-new-privileges`: the process cannot gain privileges.
- `network`: the only network interface is loopback.
- `root read-only`: the image's root file system cannot be written.
- `workspace readable` and `workspace read-only`: the workspace has an entry and cannot be written.
- `template readable` and `template read-only`: the same, once for each template.
- `scratch`: a file can be written in `/tmp`, which is mounted `nosuid`, `nodev` and `noexec`.
- `home scratch`: a file can be written in `/home/nonroot`, which is mounted `nosuid`, `nodev` and `noexec`.

It does not look for other writable mounts, such as `/dev/shm`.

Example output with one template:

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

## Run the image

Mount a nonempty workspace and at least one nonempty template. The image runs as user `65532`, so
that user must be able to read every mounted file and directory. From this directory:

Set `version` to the release you want from the factory's
[Releases page](https://github.com/nwarila-platform/workflow-container-factory/releases), then verify
the image:

```sh
version='<release version>'
digest=$(crane digest "ghcr.io/nwarila-platform/workflow-runner-selftest:${version}")
cosign verify "ghcr.io/nwarila-platform/workflow-runner-selftest@${digest}" \
  --certificate-identity "https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/runner-selftest/v${version}" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

```sh
docker run --rm --platform linux/amd64 --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777 \
  --tmpfs /home/nonroot:rw,nosuid,nodev,noexec,size=16m,mode=1777 \
  --volume "$PWD/example/workspace:/workspace:ro" \
  --volume "$PWD/example/template:/templates/0:ro" \
  "ghcr.io/nwarila-platform/workflow-runner-selftest@${digest}" \
  --workspace /workspace \
  --template example/template=/templates/0 \
  --format text
```

Exit status `0` means every check passed. Exit status `1` means at least one isolation check failed.
Exit status `2` means the selftest could not run or its arguments were invalid. This container has no
write mode because it checks the runner's isolation and has nothing to correct.
