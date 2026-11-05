#!/usr/bin/env bash
# Validate renovate.json with the config validator of the Renovate major the
# cluster runs (chart appVersion 44.x). Usage: bash scripts/renovate/validate.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
npx --yes --package renovate@44 renovate-config-validator --strict renovate.json
