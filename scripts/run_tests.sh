#!/usr/bin/env bash
set -euo pipefail

# Run analytics unit tests from repository root
cd "$(dirname "$0")/.."
python -m pytest scripts/tests "$@"
