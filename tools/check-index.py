#!/usr/bin/env python3
"""Validate a factory image index and its child-bound SPDX attestations."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn


DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")
NAME_RE = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")
VERSION_RE = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
INDEX_MEDIA_TYPES = {
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
}


class Refusal(Exception):
    def __init__(self, predicate: str, detail: str) -> None:
        super().__init__(detail)
        self.predicate = predicate
        self.detail = detail


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise RuntimeError(message)


def refuse(predicate: str, detail: str) -> NoReturn:
    raise Refusal(predicate, detail)


def crane(crane_path: str, operation: str, image: str, digest: str) -> bytes:
    command = [crane_path, operation, f"{image}@{digest}"]
    try:
        return subprocess.check_output(command)
    except PermissionError:
        if "CHECK_INDEX_CRANE" not in os.environ:
            raise
        return subprocess.check_output(["bash", *command])


def load_json(raw: bytes, description: str) -> dict:
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError(f"invalid {description} JSON: {error}") from error
    if not isinstance(value, dict):
        raise RuntimeError(f"{description} must be a JSON object")
    return value


def validate(args: argparse.Namespace) -> None:
    if DIGEST_RE.fullmatch(args.index_digest) is None:
        raise RuntimeError(f"invalid index digest: {args.index_digest!r}")
    if args.sbom_dir is None and (args.name is not None or args.version is not None):
        raise RuntimeError("--name and --version require --sbom-dir")
    if args.sbom_dir is not None:
        if args.name is None or NAME_RE.fullmatch(args.name) is None or len(args.name) > 91:
            raise RuntimeError("--sbom-dir requires a valid --name")
        if args.version is None or VERSION_RE.fullmatch(args.version) is None:
            raise RuntimeError("--sbom-dir requires a valid --version")

    crane_path = os.environ.get("CHECK_INDEX_CRANE", "crane")
    observed = crane(crane_path, "digest", args.image, args.index_digest).decode().strip()
    if observed != args.index_digest:
        raise RuntimeError(f"index digest readback mismatch: {observed!r}")
    index = load_json(crane(crane_path, "manifest", args.image, args.index_digest), "index")

    if index.get("mediaType") not in INDEX_MEDIA_TYPES:
        refuse("media-type", f"unexpected index media type: {index.get('mediaType')!r}")
    manifests = index.get("manifests")
    if not isinstance(manifests, list) or len(manifests) != 4:
        refuse("descriptor-count", "index must contain exactly four descriptors")

    runnable: dict[tuple[str, str], str] = {}
    for descriptor in manifests:
        if not isinstance(descriptor, dict):
            refuse("runnable-platforms", "every descriptor must be an object")
        digest = descriptor.get("digest")
        if not isinstance(digest, str) or DIGEST_RE.fullmatch(digest) is None:
            refuse("runnable-platforms", f"invalid descriptor digest: {digest!r}")
        annotations = descriptor.get("annotations") or {}
        if isinstance(annotations, dict) and annotations.get("vnd.docker.reference.type") == "attestation-manifest":
            continue
        platform = descriptor.get("platform") or {}
        if not isinstance(platform, dict):
            refuse("runnable-platforms", "runnable platform must be an object")
        key = (platform.get("os"), platform.get("architecture"))
        if key not in {("linux", "amd64"), ("linux", "arm64")} or key in runnable:
            refuse("runnable-platforms", f"unexpected or duplicate runnable platform: {key!r}")
        runnable[key] = digest
    if set(runnable) != {("linux", "amd64"), ("linux", "arm64")}:
        refuse("runnable-platforms", f"runnable platform set mismatch: {sorted(runnable)!r}")

    attestations: dict[str, str] = {}
    for descriptor in manifests:
        annotations = descriptor.get("annotations") or {}
        if not isinstance(annotations, dict):
            refuse("attestation-per-child", "descriptor annotations must be an object")
        if annotations.get("vnd.docker.reference.type") != "attestation-manifest":
            continue
        subject = annotations.get("vnd.docker.reference.digest")
        if not isinstance(subject, str) or subject in attestations:
            refuse("attestation-per-child", f"invalid or duplicate attestation subject: {subject!r}")
        attestations[subject] = descriptor["digest"]
    if set(attestations) != set(runnable.values()):
        refuse("attestation-per-child", "each runnable child must have exactly one attestation manifest")

    attestation_manifests: dict[str, dict] = {}
    for arch in ("amd64", "arm64"):
        child = runnable[("linux", arch)]
        attestation_manifests[arch] = load_json(
            crane(crane_path, "manifest", args.image, attestations[child]),
            f"{arch} attestation manifest",
        )

    layers: dict[str, dict] = {}
    for arch in ("amd64", "arm64"):
        candidate_layers = attestation_manifests[arch].get("layers")
        if not isinstance(candidate_layers, list) or len(candidate_layers) != 1:
            refuse("layer-count", f"{arch} attestation must contain exactly one layer")
        layers[arch] = candidate_layers[0]

    for arch in ("amd64", "arm64"):
        layer = layers[arch]
        if not isinstance(layer, dict) or layer.get("mediaType") != "application/vnd.in-toto+json":
            refuse("layer-media-type", f"{arch} attestation layer is not in-toto JSON")

    for arch in ("amd64", "arm64"):
        annotations = layers[arch].get("annotations") or {}
        if not isinstance(annotations, dict) or annotations.get("in-toto.io/predicate-type") != "https://spdx.dev/Document":
            refuse("predicate-annotation", f"{arch} attestation layer is not annotated as SPDX")

    layer_digests: dict[str, str] = {}
    for arch in ("amd64", "arm64"):
        layer_digest = layers[arch].get("digest")
        if not isinstance(layer_digest, str) or DIGEST_RE.fullmatch(layer_digest) is None:
            refuse("layer-digest", f"invalid {arch} attestation layer digest: {layer_digest!r}")
        layer_digests[arch] = layer_digest

    statements: dict[str, bytes] = {}
    statement_objects: dict[str, dict] = {}
    for arch in ("amd64", "arm64"):
        raw_statement = crane(crane_path, "blob", args.image, layer_digests[arch])
        statements[arch] = raw_statement
        statement_objects[arch] = load_json(raw_statement, f"{arch} SPDX statement")

    for arch in ("amd64", "arm64"):
        statement = statement_objects[arch]
        if statement.get("_type") not in {
            "https://in-toto.io/Statement/v0.1",
            "https://in-toto.io/Statement/v1",
        }:
            refuse("statement-type", f"{arch} SBOM is not an in-toto statement")

    for arch in ("amd64", "arm64"):
        if statement_objects[arch].get("predicateType") != "https://spdx.dev/Document":
            refuse("predicate-type", f"{arch} SBOM predicate type is not SPDX")

    for arch in ("amd64", "arm64"):
        child = runnable[("linux", arch)]
        statement = statement_objects[arch]
        subjects = statement.get("subject")
        expected_hex = child.removeprefix("sha256:")
        if (
            not isinstance(subjects, list)
            or len(subjects) != 1
            or not isinstance(subjects[0], dict)
            or not isinstance(subjects[0].get("digest"), dict)
            or subjects[0]["digest"].get("sha256") != expected_hex
        ):
            refuse("subject", f"{arch} SBOM subject does not bind the runnable child")

    predicates: dict[str, dict] = {}
    for arch in ("amd64", "arm64"):
        predicate = statement_objects[arch].get("predicate")
        if not isinstance(predicate, dict) or predicate.get("spdxVersion") != "SPDX-2.3":
            refuse("spdx-version", f"{arch} predicate is not SPDX 2.3")
        predicates[arch] = predicate

    for arch in ("amd64", "arm64"):
        if predicates[arch].get("SPDXID") != "SPDXRef-DOCUMENT":
            refuse("spdx-id", f"{arch} SPDX document identifier is invalid")

    for arch in ("amd64", "arm64"):
        packages = predicates[arch].get("packages")
        if not isinstance(packages, list) or not packages:
            refuse("packages", f"{arch} SPDX package inventory is empty")

    if args.sbom_dir is not None:
        args.sbom_dir.mkdir(parents=True, exist_ok=True)
        for arch, statement in statements.items():
            path = args.sbom_dir / f"{args.name}-{args.version}-linux-{arch}.spdx.json"
            path.write_bytes(statement)

    print(f"index ok: {args.image}@{args.index_digest}")
    for arch in ("amd64", "arm64"):
        print(f"child ok: linux/{arch} {runnable[('linux', arch)]}")


def parse_args() -> argparse.Namespace:
    parser = ArgumentParser()
    parser.add_argument("image")
    parser.add_argument("index_digest")
    parser.add_argument("--sbom-dir", type=Path)
    parser.add_argument("--name")
    parser.add_argument("--version")
    return parser.parse_args()


def main() -> int:
    try:
        validate(parse_args())
    except Refusal as error:
        print(f"check-index: refused: {error.predicate}: {error.detail}", file=sys.stderr)
        return 1
    except Exception as error:
        detail = str(error).replace("\r", r"\r").replace("\n", r"\n")
        print(f"check-index: error: {detail}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
