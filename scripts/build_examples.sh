#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
lua transpile.lua examples/hello.alua -o examples/hello.lua
lua transpile.lua examples/chain.alua -o examples/chain.lua
echo "Built examples/hello.lua and examples/chain.lua"
