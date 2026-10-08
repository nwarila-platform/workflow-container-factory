# runner-selftest

`runner-selftest` reports whether the workflow container runner grants exactly the isolation its
containers expect: the fixed unprivileged user, no capabilities, no new privileges, no network,
read-only image and input mounts, and a restricted writable scratch mount.

## Run the image

Mount a nonempty workspace and at least one nonempty template. The image runs as user `65532`, so
that user must be able to read every mounted file and directory. From this directory:

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
Exit status `2` means the selftest could not run or its arguments were invalid. The F-D6 write flag
does not apply: this container checks runner isolation and has nothing to correct.
