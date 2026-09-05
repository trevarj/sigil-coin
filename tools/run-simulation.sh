#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/tools/simulation-output"
expected="f8086b90e8e9284345af7409abc072fd49603fd87781c205fb98bbcabe4d074f"

case "${1:-}" in
  ""|--check) ;;
  *) echo "usage: tools/run-simulation.sh [--check]" >&2; exit 2 ;;
esac

cd "$root/tools/simulator"
if [[ ! -e .sigil/deps/sigil-crypto || ! -e .sigil/deps/sigil-coin-node ]]; then
  nix develop "$root" -c sigil deps install \
    --redirects "$root/dev-redirects.sgl" >/dev/null
fi
nix develop "$root" -c sigil build \
  --redirects "$root/dev-redirects.sgl" >/dev/null
cd "$root"
rm -f "$out"/*
tools/simulator/build/dev/bin/sigil-coin-simulator

files=(censorship.csv market.csv payouts.csv puzzles.csv results.json shares.csv strategy.csv summary.txt)
(
  cd "$out"
  sha256sum "${files[@]}" > SHA256SUMS
)
actual=$(sha256sum "$out/SHA256SUMS" | cut -d' ' -f1)

if [[ ${1:-} == --check ]]; then
  [[ $actual == "$expected" ]] || {
    echo "reproducibility hash mismatch: expected $expected, got $actual" >&2
    exit 1
  }
  echo "reproducibility hash: $actual"
else
  echo "wrote $out (reproducibility hash $actual)"
fi
