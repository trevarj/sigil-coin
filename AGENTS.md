# Agent Instructions

## Project Goal

SigilCoin is a for-fun blockchain written in Sigil, built on the
`sigil-bitcoin` libraries. Instead of hash grinding, blocks are mined by
program golf: each block publishes a generated puzzle, and miners compete to
submit the shortest program, in a small consensus-critical puzzle language,
that solves it. `sigil-coin-puzzle` owns the interpreter and puzzle generator,
`sigil-coin-consensus` owns emission, fork choice, and solution rules,
`sigil-coin-node` supplies the chain config and node runtime on top of
`sigil-bitcoin-node`, `sigil-coin-cli` ships the `sigilcoin` binary, and
`sigil-coin-explorer` serves a read-only web explorer.

These instructions apply to the whole repository unless a more specific
`AGENTS.md` exists in a subdirectory.

## Development Environment

- The host runs NixOS. Do not use apt, dnf, pacman, brew, global npm, or global
  pip, and do not install into user or system profiles.
- Build tools (gcc, make, pkg-config, secp256k1) come from the shared devshell
  one level up. Run project commands as:
  `nix develop /home/trev/Workspace/sigil -c <command>`.
- Use the development toolchain binary at
  `/home/trev/Workspace/sigil/sigil/build/dev/bin/sigil`; put its directory on
  `PATH` before running commands.
- There is no `flake.nix` in this repo on purpose; the workspace flake at
  `/home/trev/Workspace/sigil/flake.nix` covers it.
- Sibling checkouts `../sigil` (language monorepo) and `../sigil-bitcoin` are
  resolved through `dev-redirects.sgl`.
- Prefer `rg` for content search and `fd` for file search.

## Sigil Standards

Follow the Sigil implementation standards from the sibling checkout:
`/home/trev/Workspace/sigil/sigil/CLAUDE.md`, and mirror `../sigil-bitcoin`
conventions for package layout, naming, and API shape.

Key rules for this repo:

- Use hyphenated filenames and `.sgl` for Sigil sources.
- Modules live under `packages/<pkg>/src/sigil/coin/...`, tests under
  `packages/<pkg>/test/test-<short>.sgl`.
- Exported procedures get `;;;` doc comments with example usage; internal and
  section comments use `;;`.
- Add inline `(: ...)` specs with an explicit return type to public or
  nontrivial procedures.
- Keep consensus-critical code (puzzle interpreter, solution and emission
  rules) boring, direct, deterministic, and testable. Any divergence in the
  interpreter is a chain split.
- Keep package boundaries clear; prefer existing helpers over new ones.

## Testing

Every meaningful behavior change needs tests.

```sh
nix develop /home/trev/Workspace/sigil -c sigil test \
  --redirects ./dev-redirects.sgl --no-color
```

Install or refresh dependencies with:

```sh
nix develop /home/trev/Workspace/sigil -c sigil deps install \
  --redirects ./dev-redirects.sgl
```

Run a single package harness from its directory, pointing at the root
redirects file:

```sh
cd packages/sigil-coin-puzzle
nix develop /home/trev/Workspace/sigil -c sigil test test/test-puzzle.sgl \
  --redirects ../../dev-redirects.sgl --no-color
```

## Git and Handoff

- Use Conventional Commits: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`,
  `build`, `ci`, `perf`, or `style`.
- Keep commits focused on one logical change.
- Do not commit automatically. Commit only when the user explicitly asks.
- All commits must be GPG-signed.
- Do not commit secrets or credential files.
- Do not add README-style documentation unless requested.
- Final handoff must list changed behavior, tests run, and skipped checks with
  reasons.
