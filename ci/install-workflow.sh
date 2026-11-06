#!/bin/sh
# Кладёт workflow сборки туда, где его увидит GitHub Actions.
set -e
cd "$(dirname "$0")/.."
mkdir -p .github/workflows
cp ci/build.yml .github/workflows/build.yml
echo "ok: .github/workflows/build.yml"
