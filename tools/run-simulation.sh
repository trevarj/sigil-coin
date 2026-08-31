#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(cd "$root/.." && pwd)
sigil="$workspace/sigil/build/dev/bin/sigil"
out="$root/tools/simulation-output"
expected="0a87130cd6387bf778669516aa806471d7e60e21e24c51ba5b15ca7395a5c277"

case "${1:-}" in
  ""|--check) ;;
  *) echo "usage: tools/run-simulation.sh [--check]" >&2; exit 2 ;;
esac

cd "$root/tools/simulator"
if [[ ! -d .sigil/deps/sigil-crypto ]]; then
  nix develop "$workspace" -c "$sigil" deps install \
    --redirects "$root/dev-redirects.sgl" >/dev/null
fi
nix develop "$workspace" -c "$sigil" build \
  --redirects "$root/dev-redirects.sgl" >/dev/null
cd "$root"
tools/simulator/build/dev/bin/sigil-coin-simulator

files=(censorship.csv ordering.csv payouts.csv puzzles.csv results.json shares.csv summary.txt)
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
