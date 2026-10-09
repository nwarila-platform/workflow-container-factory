<!-- markdownlint-configure-file {"MD013":{"code_blocks":false,"tables":false}} -->

# Workflow container factory

This repository builds the single-purpose containers that organization
repositories run through the shared workflow-container runner. Each image has
one checker, an explicit command-line and exit-status contract, and the
requirement labels understood by runner contract 2. Releases are pinned by
version and digest, signed with GitHub Actions' keyless identity, and
accompanied by build provenance and per-platform SPDX SBOMs.

## Containers

### template-drift

[`template-drift`](containers/template-drift/README.md) compares a repository
with one or more pinned template checkouts. Template-owned manifests define
byte, leading-line, presence, and absence checks. The container only reports
differences; it does not edit the repository.

Current release: `3.1.1` at
`sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834`.

### runner-selftest

[`runner-selftest`](containers/runner-selftest/README.md) probes the environment
created by the shared runner. It checks the user and group, Linux capabilities,
no-new-privileges setting, network interfaces, read-only mounts, and the two
scratch mounts. It diagnoses isolation; it does not establish that isolation.

Current release: `1.1.0` at
`sha256:44ec1f7813f872af2587fae4d6006de1919c3a2ae3ebf417bc429ac7332b2ac6`.

## Use a container in a repository

Call the organization workflow with `contents: read` and
`security-events: write`. Pin the workflow itself to a commit, and give the
runner the image name, version, contract, and index digest. This example runs
the current `template-drift` release:

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

The runner verifies that the signature identity matches the requested name and
version, that the version tag resolves to the pinned digest, and that the
image's requirement labels are valid. It then mounts the checkout and any locked
templates read-only, disables networking, drops all capabilities, enables
no-new-privileges, and restores the checker's `0`, `1`, or `2` status.

The `renovate` comment and adjacent `version` and `digest` fields match the
organization's custom manager. Renovate therefore updates the version and digest
together. Its GitHub Actions manager updates the commit pin on `uses`
separately. A `template-drift` caller also needs the identity and lock files
described in the [container documentation](containers/template-drift/README.md).

## Verify an image

Install Cosign, then verify the immutable digest rather than a mutable-looking
tag:

```sh
cosign verify \
  'ghcr.io/nwarila-platform/workflow-template-drift@sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834' \
  --certificate-identity \
  'https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/template-drift/v3.1.1' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository nwarila-platform/workflow-container-factory \
  --certificate-github-workflow-ref refs/tags/template-drift/v3.1.1
```

A successful result proves that the exact digest has a valid Sigstore signature
issued to this repository's `build.yaml` workflow on the `template-drift/v3.1.1`
tag. It does not inspect the container's behavior or prove that the tag still
points to that digest; the shared runner performs those additional checks before
execution.

Verify the index's GitHub build-provenance attestation separately:

```sh
gh attestation verify \
  'oci://ghcr.io/nwarila-platform/workflow-template-drift@sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834' \
  --repo nwarila-platform/workflow-container-factory \
  --signer-workflow nwarila-platform/workflow-container-factory/.github/workflows/build.yaml \
  --source-ref refs/tags/template-drift/v3.1.1
```

## Release flow

1. A conventional commit scoped to a container, such as
   `fix(template-drift): reject an invalid manifest`, lands on `main`.
2. Release Please maintains a separate release pull request for each container.
   The pull request updates its `VERSION`, changelog, and the release manifest.
3. After that pull request is merged, the release workflow creates and pushes a
   signed annotated tag named `<container>/v<X.Y.Z>`.
4. The tag workflow requires a verified tag reachable from `main`, builds Linux
   AMD64 and ARM64 images, tests both children, attaches SPDX SBOMs, signs the
   index and children recursively, creates GitHub build provenance for the
   index, and verifies all of that evidence anonymously.
5. Only after verification does the workflow create the version and
   source-commit tags in GHCR.
6. The owner checks out the current clean `main` branch and publishes the GitHub
   Release:

   ```sh
   tools/github-release.sh template-drift/v3.1.1
   ```

   Release Please deliberately skips GitHub Release creation. The owner-run
   command rechecks the signed tag, image index, child images, signatures,
   provenance, and SBOMs before publishing four release assets. Published
   releases are immutable, so this separate step prevents incomplete or
   unverified evidence from becoming the permanent release record.

## Repository layout

```text
containers/
  runner-selftest/       Probe, Containerfile, examples, and tests
  template-drift/        Checker, hook, Containerfile, examples, and tests
.github/workflows/
  ci.yaml                 Host and image tests on pull requests and main
  release-please.yaml     Release pull requests and signed release tags
  release.yaml            Tag validation and release entry point
  build.yaml              Build, test, sign, attest, verify, and promote
  runner-acceptance.yaml  Contract-2 acceptance and refusal cases
tools/                    Image validation and GitHub Release scripts
```

Each container owns its source, `Containerfile`, `VERSION`, changelog, examples,
and host and image tests. The top-level release manifest keeps the independently
released versions.

## Test locally

The host suites need Bash and Python 3. The `template-drift` suite also
exercises its hook with local fakes for Git, Cosign, Docker, and Podman:

```sh
bash containers/template-drift/tests/host.sh
bash containers/runner-selftest/tests/host.sh
python3 tools/test_check_index.py
python3 tools/test_check_labels.py
```

Image suites need a working Docker or Podman engine. Build and run one
architecture as follows; set `CONTAINER_RUNTIME=podman` for Podman:

```sh
docker build -t workflow-template-drift:test containers/template-drift
bash containers/template-drift/tests/image.sh workflow-template-drift:test linux/amd64

docker build -t workflow-runner-selftest:test containers/runner-selftest
bash containers/runner-selftest/tests/image.sh workflow-runner-selftest:test linux/amd64
```

CI repeats every host suite and builds and tests each image on Linux AMD64 and
ARM64.

## Status

The repository is active and not archived. The current supported releases are
`template-drift` 3.1.1 and `runner-selftest` 1.1.0; see
[the security policy](SECURITY.md) for support and reporting. The project is
licensed under the [MIT License](LICENSE).
