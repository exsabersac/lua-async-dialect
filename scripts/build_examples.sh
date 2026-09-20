#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
for f in examples/*.alua; do
  out="${f%.alua}.lua"
  lua transpile.lua "$f" -o "$out"
done
echo "Built all examples/*.alua → *.lua"
