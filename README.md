# workflow-container-factory

This repository builds and releases the organization's workflow containers. Each container has an
independent version and image. The factory gives them one CI gate and one release process.
A workflow container is a small image that a CI workflow runs as one check, with no network access.

Every image declares five requirement labels whose values are the strings `true` or `false`:

- `org.nwarila.workflow.scratch`: the container needs a writable, restricted `/tmp` mount.
- `org.nwarila.workflow.full-history`: the workspace checkout must contain full Git history.
- `org.nwarila.workflow.second-input`: pinned template checkouts must be mounted read-only.
- `org.nwarila.workflow.sarif`: the container produces a SARIF report for the runner to upload.
- `org.nwarila.workflow.image-input`: a separately built image must be made available to the container.

CI checks these labels on locally built images, and the release checks every candidate child image.

## Layout

Each `containers/<name>/` directory holds a `Containerfile`, a `VERSION`, tests, and a bundled
example. Shared release tools live in `tools/`. The build and release workflows under
`.github/workflows/` discover containers from this layout.

## Checks and releases

CI runs on every pull request and every push to `main`. It runs each container's host tests. At the
same time, it builds and tests the container's image on `amd64` and `arm64`. The stable `CI result`
job reports the combined result.

The runner acceptance workflow calls the organization runner at a pinned commit with released
images: one must pass and four must be refused.

A `feat` or `fix` commit, or a breaking change, that changes `containers/<name>/` makes release-please
open or update that container's release pull request. Types that release-please leaves out of the
changelog, such as `docs` or `chore`, do not. Merging the pull request creates a signed annotated tag
named `<name>/v<X.Y.Z>`. The tagging job runs in the `release` environment, which is restricted to `main`,
and pushes over SSH with the repository's release deploy key. That push starts the release workflow.
The tag rules allow only repository admins and that deploy key to create a release tag, so an admin
can still push a signed tag by hand as a fallback.

The release workflow checks the tag, its reachability from `main`, and the container's `VERSION`.
It then builds a candidate image and pushes it by digest only, with no tag. It tests both
architectures, signs and attests the candidate, verifies its evidence, and promotes it to the
version and `sha-<commit>` tags. There is no `latest` tag.

After that workflow succeeds, the repository owner publishes the immutable GitHub Release from a
full, clean checkout of the current `main`:

```sh
tools/github-release.sh '<name>/v<X.Y.Z>'
```

The script requires `gh` authenticated as a repository admin, plus `git`, `crane`, `cosign`,
`curl`, `jq`, and `python3`. It verifies the signed tag, index and SBOMs, image signatures, and
provenance before it creates, repairs, or verifies a release containing the index and child digests,
both child-bound SPDX SBOM statements, and the GitHub provenance bundle. Publication is manual
because GitHub blocks the Actions workflow token from creating a release for the protected tag in this
organization. An organization-owned GitHub App is the intended way to automate this step later.

## Verify template-drift 3.0.2

After 3.0.2 is published, these commands verify its keyless signatures and its GitHub build
provenance. They need `crane`, `cosign` and the GitHub CLI. The GitHub CLI must be logged in
(`gh auth login`), because it reads the attestation through the GitHub API.

```sh
digest=$(crane digest ghcr.io/nwarila-platform/workflow-template-drift:3.0.2)
cosign verify "ghcr.io/nwarila-platform/workflow-template-drift@${digest}" \
  --certificate-identity "https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/template-drift/v3.0.2" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify "oci://ghcr.io/nwarila-platform/workflow-template-drift@${digest}" \
  --repo nwarila-platform/workflow-container-factory \
  --signer-workflow nwarila-platform/workflow-container-factory/.github/workflows/build.yaml \
  --source-ref refs/tags/template-drift/v3.0.2
```

## Containers

| Container | Version | Image |
| --- | --- | --- |
| runner-selftest | 1.0.0 | `ghcr.io/nwarila-platform/workflow-runner-selftest` |
| template-drift | 3.0.2 | `ghcr.io/nwarila-platform/workflow-template-drift` |

A version here is released when its release tag's run succeeds; its GitHub Release follows when the
owner runs `tools/github-release.sh`.

## Status

Consumers must keep using the standalone `workflow-template-drift` release for now. They switch
after the organization's shared workflow that runs these containers accepts the factory's signing
identity, template-drift gains its local write mode, and its GitHub Release is published with its digest,
provenance and SBOM.
