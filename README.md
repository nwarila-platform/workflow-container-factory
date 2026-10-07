# workflow-container-factory

This repository builds and releases the organization's workflow containers. Each container has an
independent version and image. The factory gives them one CI gate and one release process.
A workflow container is a small image that a CI workflow runs as one check, with no network access.

## Layout

Each `containers/<name>/` directory holds a `Containerfile`, a `VERSION`, tests, and a bundled
example. Shared release tools live in `tools/`. The workflows under `.github/workflows/` discover
containers from this layout.

## Checks and releases

CI runs on every pull request and every push to `main`. It runs each container's host tests. At the
same time, it builds and tests the container's image on `amd64` and `arm64`. The stable `CI result`
job reports the combined result.

A release starts with a signed annotated tag named `<name>/v<X.Y.Z>`. The release workflow checks
the tag and the container's `VERSION`. It then builds a candidate image and pushes it by digest
only, with no tag. It tests both architectures, signs and attests the candidate, verifies its
evidence, and promotes it to the version and `sha-<commit>` tags. There is no `latest` tag.

## Verify template-drift 3.0.1

After 3.0.1 is published, these commands verify its keyless signatures and its GitHub build
provenance. They need `crane`, `cosign` and the GitHub CLI. The GitHub CLI must be logged in
(`gh auth login`), because it reads the attestation through the GitHub API.

```sh
digest=$(crane digest ghcr.io/nwarila-platform/workflow-template-drift:3.0.1)
cosign verify "ghcr.io/nwarila-platform/workflow-template-drift@${digest}" \
  --certificate-identity "https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/template-drift/v3.0.1" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify "oci://ghcr.io/nwarila-platform/workflow-template-drift@${digest}" \
  --repo nwarila-platform/workflow-container-factory \
  --signer-workflow nwarila-platform/workflow-container-factory/.github/workflows/build.yaml \
  --source-ref refs/tags/template-drift/v3.0.1
```

## Containers

| Container | Version | Image |
| --- | --- | --- |
| template-drift | 3.0.1 | `ghcr.io/nwarila-platform/workflow-template-drift` |

## Status

Consumers must keep using the standalone `workflow-template-drift` release for now. They switch
after the organization's shared workflow that runs these containers accepts the factory's signing
identity, this container gains its local write mode, and its GitHub Release is published with its
digest, provenance and SBOM.
