"""The command line: read the arguments, run the check, print the report.

Exit status: 0 the repository passes, 1 it has drifted, 2 the check could not be carried out.
"""

import argparse
import os
import re
import sys
from pathlib import Path

from .checker import DriftError, check_repository

# Labels appear in every report line; restricting their characters prevents line injection.
LABEL = re.compile(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")


def _workspace(value: str) -> Path:
    if not value:
        raise argparse.ArgumentTypeError("expected a DIRECTORY, got an empty value")
    return Path(value)


def _template(value: str) -> tuple[str, Path]:
    """Split one ``--template`` value, ``OWNER/REPO=DIRECTORY``, into its label and directory."""
    label, _, directory = value.partition("=")
    if not (LABEL.fullmatch(label) and directory):
        raise argparse.ArgumentTypeError(f"expected OWNER/REPO=DIRECTORY, got {value!r}")
    return label, Path(directory)


def _write(file_descriptor: int, text: str) -> None:
    """Write directly so a failed buffered flush cannot replace the intended exit status."""
    data = text.encode()
    while data:
        written = os.write(file_descriptor, data)
        if written == 0:
            raise OSError("could not write output")
        data = data[written:]


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="template-drift",
        description="Report where a repository has drifted from the templates it follows.",
        allow_abbrev=False,
    )
    parser.add_argument(
        "--workspace",
        required=True,
        type=_workspace,
        metavar="DIRECTORY",
        help="the repository to check",
    )
    parser.add_argument(
        "--template",
        required=True,
        action="append",
        type=_template,
        dest="templates",
        metavar="OWNER/REPO=DIRECTORY",
        help="a template's checkout and the name to report it under; repeat for each template",
    )
    parser.add_argument(
        "--fail-on",
        choices=("error", "warning"),
        default="error",
        help="the lowest severity that fails the check (default: error)",
    )
    parser.add_argument(
        "--format",
        choices=("text",),
        default="text",
        help="the report format; text is the only one, and the organization's runner passes it",
    )
    arguments = parser.parse_args()

    # Status 1 means "the repository has drifted", and Python itself exits with 1 on an uncaught
    # exception. Every failure, including a failure to write the report, is therefore caught here
    # and leaves with status 2 instead.
    try:
        report, status = check_repository(
            arguments.workspace, arguments.templates, arguments.fail_on
        )
        _write(sys.stdout.fileno(), report)
    except Exception as error:
        detail = str(error) if isinstance(error, DriftError) else f"{type(error).__name__}: {error}"
        try:
            _write(sys.stderr.fileno(), f"template-drift: error: {detail}\n")
        except Exception:
            pass
        return 2
    return status


if __name__ == "__main__":
    sys.exit(main())
