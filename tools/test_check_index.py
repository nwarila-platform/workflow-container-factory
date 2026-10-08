#!/usr/bin/env python3
"""Offline, table-driven tests for check-index.py's public contract."""

from __future__ import annotations

import copy
import json
import os
import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CHECKER = ROOT / "tools" / "check-index.py"
IMAGE = "registry.invalid/example"
INDEX_DIGEST = "sha256:" + "1" * 64
AMD64 = "sha256:" + "2" * 64
ARM64 = "sha256:" + "3" * 64
AMD64_ATT = "sha256:" + "4" * 64
ARM64_ATT = "sha256:" + "5" * 64
AMD64_LAYER = "sha256:" + "6" * 64
ARM64_LAYER = "sha256:" + "7" * 64


def statement(child: str) -> dict:
    return {
        "_type": "https://in-toto.io/Statement/v1",
        "predicateType": "https://spdx.dev/Document",
        "subject": [{"name": IMAGE, "digest": {"sha256": child.removeprefix("sha256:")}}],
        "predicate": {
            "spdxVersion": "SPDX-2.3",
            "SPDXID": "SPDXRef-DOCUMENT",
            "packages": [{"SPDXID": "SPDXRef-Package"}],
        },
    }


def fixture() -> dict[str, dict]:
    index = {
        "mediaType": "application/vnd.oci.image.index.v1+json",
        "manifests": [
            {"digest": AMD64, "platform": {"os": "linux", "architecture": "amd64"}},
            {"digest": ARM64, "platform": {"os": "linux", "architecture": "arm64"}},
            {
                "digest": AMD64_ATT,
                "platform": {"os": "unknown", "architecture": "unknown"},
                "annotations": {
                    "vnd.docker.reference.type": "attestation-manifest",
                    "vnd.docker.reference.digest": AMD64,
                },
            },
            {
                "digest": ARM64_ATT,
                "platform": {"os": "unknown", "architecture": "unknown"},
                "annotations": {
                    "vnd.docker.reference.type": "attestation-manifest",
                    "vnd.docker.reference.digest": ARM64,
                },
            },
        ],
    }

    def layer(digest: str) -> dict:
        return {
            "layers": [{
                "mediaType": "application/vnd.in-toto+json",
                "digest": digest,
                "annotations": {"in-toto.io/predicate-type": "https://spdx.dev/Document"},
            }]
        }

    return {
        "manifests": {
            INDEX_DIGEST: index,
            AMD64: {"mediaType": "application/vnd.oci.image.manifest.v1+json"},
            ARM64: {"mediaType": "application/vnd.oci.image.manifest.v1+json"},
            AMD64_ATT: layer(AMD64_LAYER),
            ARM64_ATT: layer(ARM64_LAYER),
        },
        "blobs": {AMD64_LAYER: statement(AMD64), ARM64_LAYER: statement(ARM64)},
    }


def write_fixture(root: Path, data: dict[str, dict]) -> None:
    for group, values in data.items():
        directory = root / group
        directory.mkdir()
        for digest, value in values.items():
            (directory / digest).write_text(json.dumps(value), encoding="utf-8")


def run(data: dict[str, dict], extra: list[str] | None = None) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as raw:
        root = Path(raw)
        write_fixture(root, data)
        fake = root / "fake-crane"
        fake.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "cmd=$1; digest=${2##*@}\n"
            "case $cmd in\n"
            "  manifest) cat \"$FAKE_ROOT/manifests/$digest\" ;;\n"
            "  blob) cat \"$FAKE_ROOT/blobs/$digest\" ;;\n"
            "  digest) test -f \"$FAKE_ROOT/manifests/$digest\"; printf '%s\\n' \"$digest\" ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)
        command = ["python3", str(CHECKER), IMAGE, INDEX_DIGEST]
        if extra:
            command.extend(extra)
        env = os.environ.copy()
        env.update({"CHECK_INDEX_CRANE": str(fake), "FAKE_ROOT": str(root)})
        return subprocess.run(command, env=env, text=True, capture_output=True, check=False)


def mutations() -> list[tuple[str, Callable[[dict[str, dict]], None]]]:
    return [
        ("media-type", lambda d: d["manifests"][INDEX_DIGEST].update(mediaType="application/json")),
        ("descriptor-count", lambda d: d["manifests"][INDEX_DIGEST]["manifests"].append(copy.deepcopy(d["manifests"][INDEX_DIGEST]["manifests"][-1]))),
        ("runnable-platforms", lambda d: d["manifests"][INDEX_DIGEST]["manifests"][1]["platform"].update(architecture="s390x")),
        ("attestation-per-child", lambda d: d["manifests"][INDEX_DIGEST]["manifests"][2]["annotations"].update({"vnd.docker.reference.digest": ARM64})),
        ("layer-count", lambda d: d["manifests"][AMD64_ATT]["layers"].append(copy.deepcopy(d["manifests"][AMD64_ATT]["layers"][0]))),
        ("layer-media-type", lambda d: d["manifests"][AMD64_ATT]["layers"][0].update(mediaType="application/json")),
        ("predicate-annotation", lambda d: d["manifests"][AMD64_ATT]["layers"][0]["annotations"].update({"in-toto.io/predicate-type": "wrong"})),
        ("layer-digest", lambda d: d["manifests"][AMD64_ATT]["layers"][0].update(digest="sha256:XYZ")),
        ("statement-type", lambda d: d["blobs"][AMD64_LAYER].update(_type="wrong")),
        ("predicate-type", lambda d: d["blobs"][AMD64_LAYER].update(predicateType="wrong")),
        ("subject", lambda d: d["blobs"][AMD64_LAYER]["subject"][0]["digest"].update(sha256="0" * 64)),
        ("spdx-version", lambda d: d["blobs"][AMD64_LAYER]["predicate"].update(spdxVersion="SPDX-2.2")),
        ("spdx-id", lambda d: d["blobs"][AMD64_LAYER]["predicate"].update(SPDXID="SPDXRef-OTHER")),
        ("packages", lambda d: d["blobs"][AMD64_LAYER]["predicate"].update(packages=[])),
    ]


def main() -> None:
    valid = run(fixture())
    assert valid.returncode == 0, (valid.stdout, valid.stderr)
    assert valid.stdout.splitlines() == [
        f"index ok: {IMAGE}@{INDEX_DIGEST}",
        f"child ok: linux/amd64 {AMD64}",
        f"child ok: linux/arm64 {ARM64}",
    ]
    for predicate, mutate in mutations():
        data = fixture()
        mutate(data)
        result = run(data)
        assert result.returncode == 1, (predicate, result.stdout, result.stderr)
        assert result.stdout == "", (predicate, result.stdout)
        assert result.stderr.startswith(f"check-index: refused: {predicate}: "), result.stderr

    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory)
        result = run(
            fixture(),
            ["--sbom-dir", str(output), "--name", "example", "--version", "1.2.3"],
        )
        assert result.returncode == 0, result.stderr
        for arch, expected in (("amd64", AMD64), ("arm64", ARM64)):
            saved = json.loads((output / f"example-1.2.3-linux-{arch}.spdx.json").read_text())
            assert saved["subject"][0]["digest"]["sha256"] == expected.removeprefix("sha256:")


if __name__ == "__main__":
    main()
