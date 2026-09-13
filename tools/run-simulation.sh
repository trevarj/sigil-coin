#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/tools/simulation-output"
# Checked schema-4 observations remain in simulation-output-schema-4-historical.

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
files=(censorship.csv market.csv payouts.csv puzzles.csv results.json shares.csv strategy.csv summary.txt)
run_once() {
  tools/simulator/build/dev/bin/sigil-coin-simulator
  (
    cd "$out"
    sha256sum "${files[@]}" > SHA256SUMS
  )
}
run_once
actual=$(sha256sum "$out/SHA256SUMS" | cut -d' ' -f1)

if [[ ${1:-} == --check ]]; then
  expected=$actual
  run_once
  actual=$(sha256sum "$out/SHA256SUMS" | cut -d' ' -f1)
  [[ $actual == "$expected" ]] || {
    echo "reproducibility mismatch between fresh runs: $expected != $actual" >&2
    exit 1
  }
  echo "two-run reproducibility hash: $actual"
else
  echo "wrote $out (reproducibility hash $actual)"
fi
