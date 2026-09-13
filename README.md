<p align="center">
  <a href="https://sigilcoin.lol">
    <img src="packages/sigil-coin-site/assets/sigilcoin-symbol.png" width="160" alt="SigilCoin logo">
  </a>
</p>

<h1 align="center">SigilCoin</h1>

<p align="center">
  <strong>Short programs. Daily slots.</strong><br>
  An experimental proof-of-golf blockchain with no nonce grinding.
</p>

<p align="center">
  <a href="https://github.com/trevarj/sigil-coin/releases"><img alt="Version 0.1.0" src="https://img.shields.io/badge/version-0.1.0-9b7fef?style=flat-square"></a>
  <a href="docs/consensus.md"><img alt="Experimental network" src="https://img.shields.io/badge/network-experimental-f7c744?style=flat-square"></a>
  <a href="https://usesigil.org"><img alt="Built with Sigil" src="https://img.shields.io/badge/language-Sigil-9b7fef?style=flat-square"></a>
  <a href="package.sgl"><img alt="BSD 3-Clause license" src="https://img.shields.io/badge/license-BSD--3--Clause-5ee7f1?style=flat-square"></a>
  <a href="https://github.com/trevarj/sigil-coin/commits/master"><img alt="Last commit" src="https://img.shields.io/github/last-commit/trevarj/sigil-coin?style=flat-square"></a>
</p>

<p align="center">
  <a href="https://sigilcoin.lol"><strong>Website</strong></a> ·
  <a href="https://explorer.sigilcoin.lol"><strong>Mainnet explorer</strong></a> ·
  <a href="https://explorer.testnet.sigilcoin.lol"><strong>Testnet explorer</strong></a> ·
  <a href="docs/whitepaper.md"><strong>Whitepaper</strong></a> ·
  <a href="docs/consensus.md"><strong>Consensus</strong></a> ·
  <a href="docs/deployment.md"><strong>Run a node</strong></a>
</p>

---

SigilCoin is a for-fun blockchain written in [Sigil](https://usesigil.org) and built on the [`sigil-bitcoin`](https://github.com/trevarj/sigil-bitcoin) libraries. Each block solves a deterministic programming puzzle in an exact scheduled slot. A valid at-par program earns one point; each saved byte adds one point, capped at eight saved bytes. That score displays competition quality; canonical fork choice uses longest height, bounded by hardcoded release checkpoints.

> [!IMPORTANT]
> SigilCoin is experimental software. SGL is intended to have no monetary value. There is no premine, no sale, no bridge, and no promise of future value. Do not use funds or infrastructure you cannot afford to lose.
>
> This is a hobby chain, not settlement-grade security. Equal-height branches are cheap to construct, missed slots offer takeover opportunities, and partitions can leave nodes with different incumbents. Reorgs remain possible above the latest checkpoint; producers can still manipulate parent templates to influence later puzzles.

The previously launched nonce-PoW genesis was retired **before height 1** because its compute burn contradicted the project's intent. Proof-of-golf began replacement networks at height 0 with new genesis markers and network magic. Archive retired nonce-PoW state; never open it with the replacement network. [LAUNCH.md](LAUNCH.md) preserves the superseded launch evidence.

## How proof-of-golf works

1. Every node derives the same input/output examples and syntactic constraint from the parent block.
2. A producer supplies a valid program no longer than the generated par solution. The printed par witness is always a valid fallback.
3. `savings = min(8, max(0, par - length))`; the block adds `1 + savings` points, from 1 at par to 9 at `par - 8` or better. Genesis adds zero.
4. The header timestamp is exactly `parent.time + 86400` on mainnet, with no future allowance. Test networks use their configured shorter slots. A missed slot can be filled later; the rule does not guarantee a block arrives every day.
5. The builder creates a complete block once: header nonce and coinbase locktime are zero, non-genesis graffiti is empty, and `bits` is fixed per-network for 80-byte-header compatibility. There is no hash search, hash admission target, or hash difficulty retarget.
6. Nodes independently validate the puzzle, exact source length, resource limits, block body, schedule, and checkpoint ancestry. The existing puzzle-complexity retarget remains. Golf scores are displayed quality metrics; they do not select branches or currently alter subsidy.

A valid branch replaces the active chain only at a **strictly greater height**. Equal height retains the durable active incumbent, even across a restart; score, hash, and arrival metadata do not break the tie. Different nodes can therefore retain different equal-height branches.

Each network's chain config hardcodes `(height . internal-hash)` checkpoints. An incompatible branch cannot cross a checkpoint. Checkpoints advance only in reviewed software releases, and nodes must upgrade to share a newer one; there is no automatic or signed-checkpoint finality service. **Mainnet pins H0 and the live H1 block**; public testnet and regtest still pin **H0 only**, protecting genesis but no later history. Mainnet rejects reorgs below H1; reorgs above H1 remain possible.

Mainnet H1 internal hash: `24f2cbbf4a5dbbce67abbcc047e300cda17c600e7ab3565846d27a0eb6b041d2`. Its reversed display ID is `d241b0b60e7ad2465856b37a0e607ca1cd00e347c0bcab67cebb5d4abfcbf224`.

The longest-height/checkpoint cutover preserves proof-of-golf block bytes, genesis hashes, and genesis timestamps. Transport magic changes to `SGM3` / `SGT3` / `SGR3` (mainnet / testnet / regtest) to isolate older score-ranked nodes. Existing proof-of-golf H0 state may be reused; retired nonce-PoW state may not.

## Network

| Parameter | Mainnet |
|---|---|
| Status | Replacement proof-of-golf network; prior launch retired at H0 |
| DNS seed | `seed.sigilcoin.lol:19444` |
| Explorer | [explorer.sigilcoin.lol](https://explorer.sigilcoin.lol) |
| Address prefix | `sgl1…` |
| Block timestamp spacing | Exactly 86400 seconds; no future slots |
| Fixed header bits | `0x1c2bcf04` (compatibility field, not a hash target) |
| Genesis time | `2026-09-12T16:00:00Z` |
| Genesis identity | [Generated proof-of-golf constants](packages/sigil-coin-node/src/sigil/coin/node/genesis.sgl) |
| Maximum block size | 16 KiB |
| Maximum solution size | 512 bytes |

Public testnet uses `seed.testnet.sigilcoin.lol:19446`, [`explorer.testnet.sigilcoin.lol`](https://explorer.testnet.sigilcoin.lol), and `tsgl1…` addresses. Testnet coins and keys are disposable and must never be reused on mainnet.

## Components

| Package | Responsibility |
|---|---|
| [`sigil-coin-puzzle`](packages/sigil-coin-puzzle) | Frozen puzzle language, interpreter, and deterministic generator |
| [`sigil-coin-consensus`](packages/sigil-coin-consensus) | Emission, solution rules, payouts, and deterministic retarget formulas |
| [`sigil-coin-node`](packages/sigil-coin-node) | Chain configuration, header rules, fork choice, and node runtime on `sigil-bitcoin-node` |
| [`sigil-coin-cli`](packages/sigil-coin-cli) | The `sigilcoin` wallet, node, puzzle, and scheduled-producer CLI |
| [`sigil-coin-explorer`](packages/sigil-coin-explorer) | Read-only HTML and JSON explorer |
| [`sigil-coin-site`](packages/sigil-coin-site) | Deterministic static website generator |

Consensus-critical code is deliberately direct and boring. Interpreter divergence is a chain split.

## Getting started

### Development checkout

The development flake currently uses the Sigil and `sigil-bitcoin` sibling checkouts. Place all three repositories next to one another:

```text
workspace/
├── sigil/
├── sigil-bitcoin/
└── sigil-coin/
```

Enter the pinned Nix environment with those local sources:

```sh
nix develop \
  --override-input sigil path:../sigil \
  --override-input sigil-bitcoin path:../sigil-bitcoin

sigilcoin version
```

The shell supplies the Sigil compiler, C toolchain, secp256k1, and the built `sigilcoin` and `sigilcoin-explorer` commands. No global packages are required.

### Create a wallet

Keep a mainnet wallet on your personal machine, not on a public seed:

```sh
install -d -m 0700 "$HOME/.sigilcoin-main-proof-of-golf"

sigilcoin address \
  --chain sigilcoin-main \
  --data-dir "$HOME/.sigilcoin-main-proof-of-golf"
```

The command creates `wallet/wallet.key` with mode `0600`. That 32-byte key is the wallet: there is no seed phrase or recovery service. Back it up encrypted and offline before receiving rewards. Never commit it, paste it into chat, or place it in the Nix store.

Use this fresh directory for proof-of-golf. Back up and archive the retired network's directory separately; copying its database into the new directory is not a migration.

### Sync and inspect the puzzle

```sh
sigilcoin sync \
  --chain sigilcoin-main \
  --data-dir "$HOME/.sigilcoin-main-proof-of-golf"

sigilcoin puzzle \
  --chain sigilcoin-main \
  --data-dir "$HOME/.sigilcoin-main-proof-of-golf"
```

### Produce a scheduled block

`sigilcoin puzzle` prints the next slot time and guaranteed par witness. When
`--solution` is omitted, `sigilcoin mine` uses that witness for a score-1 block.
Once the slot is due, the command builds and submits one complete candidate;
it does not search a nonce or locktime. Use the wallet address created above:

```sh
PAYOUT_ADDRESS=$(
  sigilcoin address \
    --chain sigilcoin-main \
    --data-dir "$HOME/.sigilcoin-main-proof-of-golf" |
  sed -n 's/^address: //p'
)

sigilcoin mine \
  --address "$PAYOUT_ADDRESS" \
  --chain sigilcoin-main \
  --data-dir "$HOME/.sigilcoin-main-proof-of-golf"
```

For the guarded, restart-safe low-CPU scheduled producer, see the [deployment guide](docs/deployment.md).

## Build and test

From the development shell above, install or refresh dependencies and run the
suite:

```sh
sigil deps install --redirects ./dev-redirects.sgl
sigil test --redirects ./dev-redirects.sgl --no-color
```

Check the root package and deployment module with the same sibling sources:

```sh
nix flake check \
  --override-input sigil path:../sigil \
  --override-input sigil-bitcoin path:../sigil-bitcoin

nix flake check 'path:.?dir=deploy' \
  --override-input sigil path:../sigil \
  --override-input sigil-bitcoin path:../sigil-bitcoin
```

See [`AGENTS.md`](AGENTS.md) for repository conventions and exact focused-test commands.

## Documentation

- [Whitepaper](docs/whitepaper.md) — design, incentives, limitations, and rationale
- [Consensus specification](docs/consensus.md) — normative formulas, encodings, and validation rules
- [Deployment guide](docs/deployment.md) — Docker, exposure gates, backups, and scheduled production
- [Operator runbook](deploy/RUNBOOK.md) — NixOS service operation and incident handling
- [Public testnet guide](docs/testnet.md) — reset boundary, relay, and testnet operations
- [Simulation notes](docs/simulation.md) — deterministic puzzle, payout, and strategy experiments
- [Launch record](LAUNCH.md) — replacement-network cutover and explicitly superseded launch evidence

## Security and consensus

Changes to the puzzle interpreter, generator, emission, solution rules, slot schedule, block validation, fork choice, or released checkpoints can split nodes running different rules. Exact timestamps and fixed nonce and coinbase fields remove sustained hash grinding, not cheap equal-height branch construction, missed-slot takeovers, partitions, or parent-template manipulation. Confirmations above the latest release checkpoint are not final settlement.

Report reproducible defects through [GitHub Issues](https://github.com/trevarj/sigil-coin/issues). Never include wallet keys, unrevealed solutions, commitment blinds, or private deployment data.

## License

SigilCoin is available under the BSD 3-Clause license, as declared by the workspace and package manifests.
