"""Command line for reporting the workflow runner's isolation."""

import argparse
import os
import re
import sys
from pathlib import Path

from .checks import run

LABEL = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


def _template(value: str) -> tuple[str, Path]:
    label, separator, directory = value.partition("=")
    if not (separator and LABEL.fullmatch(label) and directory):
        raise argparse.ArgumentTypeError(f"expected OWNER/REPO=DIRECTORY, got {value!r}")
    return label, Path(directory)


def _write(report: str) -> None:
    data = report.encode()
    while data:
        written = os.write(sys.stdout.fileno(), data)
        if written == 0:
            raise OSError("could not write the report")
        data = data[written:]


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="runner-selftest",
        description="Report whether the workflow container runner's isolation holds.",
        allow_abbrev=False,
    )
    parser.add_argument("--workspace", required=True, type=Path, metavar="DIRECTORY")
    parser.add_argument(
        "--template", required=True, action="append", type=_template, metavar="OWNER/REPO=DIRECTORY"
    )
    parser.add_argument("--format", choices=("text",), default="text")
    arguments = parser.parse_args()

    try:
        results = run(arguments.workspace, arguments.template)
        failed = sum(not result.passed for result in results)
        lines = [
            f"ok: {result.name}" if result.passed else f"error: {result.name}: {result.detail}"
            for result in results
        ]
        if failed:
            lines.append(f"runner-selftest: FAIL ({len(results)} checks, {failed} failed)")
        else:
            lines.append(f"runner-selftest: PASS ({len(results)} checks)")
        _write("\n".join(lines) + "\n")
    except Exception as error:
        print(f"runner-selftest: error: {type(error).__name__}: {error}", file=sys.stderr)
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
