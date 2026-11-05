#!/usr/bin/env bash
# Wrapper: the structural checks live in test_render.py (PyYAML).
set -euo pipefail
exec python3 "$(dirname "$0")/test_render.py"
