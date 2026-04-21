#!/usr/bin/env bash
set -euo pipefail

# Package the Kite language extension as a VSIX file in the `tmp` directory.
cd "$(dirname "$0")/language"
npx --yes @vscode/vsce package --out ../tmp/kite-language.vsix
