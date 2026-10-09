"""The command line: read the arguments, run the checks, print the report.

Exit status: 0 every check passed, 1 at least one check failed, 2 the selftest could not run.
The runner requires the PASS summary to be the report's final line when the command exits 0.
"""

import argparse
import os
import re
import sys
from pathlib import Path

from .checks import run

LABEL = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


def _template(value: str) -> tuple[str, Path]:
    label, _, directory = value.partition("=")
    if not (LABEL.fullmatch(label) and directory):
        raise argparse.ArgumentTypeError(f"expected OWNER/REPO=DIRECTORY, got {value!r}")
    return label, Path(directory)


def _write(file_descriptor: int, text: str) -> None:
    """Write directly, without Python's output buffer.

    A buffered write that fails may be discovered only while the interpreter exits, after the exit
    status has been chosen. Written directly, a report that cannot be delivered is an error here.
    """
    data = text.encode()
    while data:
        written = os.write(file_descriptor, data)
        if written == 0:
            raise OSError("could not write output")
        data = data[written:]


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="runner-selftest",
        description="Report whether the workflow container runner's isolation holds.",
        allow_abbrev=False,
    )
    parser.add_argument(
        "--workspace",
        required=True,
        type=Path,
        metavar="DIRECTORY",
        help="the mounted workspace, which must be nonempty and read-only",
    )
    parser.add_argument(
        "--template",
        required=True,
        action="append",
        type=_template,
        metavar="OWNER/REPO=DIRECTORY",
        help="a mounted template and the name to report it under; repeat for each template",
    )
    parser.add_argument(
        "--format",
        choices=("text",),
        default="text",
        help="the report format; text is the only one, and the organization's runner passes it",
    )
    arguments = parser.parse_args()

    # Status 1 means "a check failed", and Python itself exits with 1 on an uncaught exception.
    # Catch runtime failures, including an undeliverable report, so they exit with status 2.
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
        _write(sys.stdout.fileno(), "\n".join(lines) + "\n")
    except Exception as error:
        try:
            _write(
                sys.stderr.fileno(),
                f"runner-selftest: error: {type(error).__name__}: {error}\n",
            )
        except Exception:
            pass
        return 2
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
