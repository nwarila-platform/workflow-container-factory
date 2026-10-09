<!-- markdownlint-configure-file {"MD013":{"code_blocks":false,"tables":false}} -->

# Security policy

## Supported versions

Security fixes are made against the latest published release of each
independently versioned container.

| Container         | Supported version | Image digest                                                              |
| ----------------- | ----------------- | ------------------------------------------------------------------------- |
| `template-drift`  | 3.1.1             | `sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834` |
| `runner-selftest` | 1.1.0             | `sha256:44ec1f7813f872af2587fae4d6006de1919c3a2ae3ebf417bc429ac7332b2ac6` |

Earlier releases are not supported. Published GitHub Releases remain available
as immutable records, but availability does not mean that an older release
receives fixes.

## Report a vulnerability

Use GitHub's private vulnerability reporting form for this repository:

<https://github.com/nwarila-platform/workflow-container-factory/security/advisories/new>

Include the affected container and version, the image digest, the impact,
reproduction steps, and any suggested mitigation. Do not open a public issue for
an undisclosed vulnerability. The repository has private vulnerability reporting
enabled; no separate security email is published.

## Release evidence

The release workflow builds a multi-platform OCI index for Linux AMD64 and
ARM64. Before promotion it tests both child images, attaches an SPDX SBOM for
each platform, signs the index and both children with Cosign's keyless GitHub
Actions identity, creates GitHub build provenance for the index, and verifies
the resulting evidence. Each immutable GitHub Release carries a digest list, the
two SPDX SBOMs, and the provenance bundle.

### Verify a signature

Use the version, digest, and certificate identity for the release being checked.
For `template-drift` 3.1.1:

```sh
cosign verify \
  'ghcr.io/nwarila-platform/workflow-template-drift@sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834' \
  --certificate-identity \
  'https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/template-drift/v3.1.1' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository nwarila-platform/workflow-container-factory \
  --certificate-github-workflow-ref refs/tags/template-drift/v3.1.1
```

For `runner-selftest` 1.1.0:

```sh
cosign verify \
  'ghcr.io/nwarila-platform/workflow-runner-selftest@sha256:44ec1f7813f872af2587fae4d6006de1919c3a2ae3ebf417bc429ac7332b2ac6' \
  --certificate-identity \
  'https://github.com/nwarila-platform/workflow-container-factory/.github/workflows/build.yaml@refs/tags/runner-selftest/v1.1.0' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository nwarila-platform/workflow-container-factory \
  --certificate-github-workflow-ref refs/tags/runner-selftest/v1.1.0
```

A successful verification ties the exact digest to `build.yaml` running for the
named release tag. Because the build signs recursively, the same identity can
also verify the platform-child digests listed in the release's `*-digests.txt`
asset.

### Verify build provenance

```sh
gh attestation verify \
  'oci://ghcr.io/nwarila-platform/workflow-template-drift@sha256:66a05581898761be72ffbc19c355662b6fd311c6b59573c2b76aa2a7c6c76834' \
  --repo nwarila-platform/workflow-container-factory \
  --signer-workflow nwarila-platform/workflow-container-factory/.github/workflows/build.yaml \
  --source-ref refs/tags/template-drift/v3.1.1
```

This checks the index's GitHub build-provenance attestation against this
repository, the signing workflow, and the release tag. Signature and provenance
verification establish release identity and build origin; they do not replace
review of the source, dependencies, or runtime behavior.
