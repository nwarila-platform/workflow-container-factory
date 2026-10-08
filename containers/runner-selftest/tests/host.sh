#!/usr/bin/env bash
# Host tests: the unit tests, run straight from the source tree with nothing installed.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover --start-directory tests --verbose
