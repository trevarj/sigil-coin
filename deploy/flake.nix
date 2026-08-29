{
  description = "SigilCoin seed node and explorer: packages plus a NixOS module";

  # HOW THIS FLAKE FINDS ITS SOURCES
  #
  # The sigil-coin checkout is NOT an input. This flake.nix lives in
  # `deploy/`, and `self.sourceInfo.outPath` is the root of the tree the
  # flake was fetched from, so evaluating it with `?dir=deploy` (which is
  # also what `nix build .#…` from inside `deploy/` of a git checkout does)
  # makes the whole sigil-coin repository the source. That is the only way a
  # flake can legally see a directory above itself.
  #
  #   nix build /path/to/sigil-coin?dir=deploy#sigilcoin      # explicit
  #   cd deploy && nix build .#sigilcoin                      # equivalent
  #   nix build path:/path/to/sigil-coin/deploy#sigilcoin     # WRONG, throws
  #
  # The last form roots the flake at `deploy/` and is rejected with an
  # explanation rather than silently building nothing.
  #
  # The two sibling checkouts ARE inputs, because they are outside the tree
  # entirely and a relative `path:` input would resolve against the store
  # copy of this flake rather than the working tree. They default to the
  # operator's local clones, pinned by revision, because sigil-coin's
  # dependency set is currently ahead of what is pushed: at the time of
  # writing, local sigil-bitcoin HEAD is 5362a80 while
  # `github:trevarj/sigil-bitcoin` master is 4721ae5. Pinning by rev also
  # means an uncommitted change in a sibling checkout can never leak into a
  # deployment build, and that the flake still locks while a sibling working
  # tree is dirty.
  #
  # Point them anywhere with --override-input:
  #
  #   nix build /path/to/sigil-coin?dir=deploy#sigilcoin \
  #     --override-input sigil-bitcoin github:trevarj/sigil-bitcoin/<rev>
  #
  # and bump the pins the same way a lock file is bumped:
  #
  #   nix flake update sigil-bitcoin \
  #     --override-input sigil-bitcoin git+file:///path/to/sigil-bitcoin?rev=<new>
  inputs = {
    # The same nixpkgs revision the workspace devshell at
    # /home/trev/Workspace/sigil/flake.nix locks.
    nixpkgs.url = "github:NixOS/nixpkgs/e72e4f299401a3689d4b3d5fc6496b11db7064eb";

    sigil = {
      url = "git+file:///home/trev/Workspace/sigil/sigil?rev=7e5a6c21cf46a326cfb937c23270a408bb10278f";
      flake = false;
    };
    sigil-bitcoin = {
      url = "git+file:///home/trev/Workspace/sigil/sigil-bitcoin?rev=5362a808d295f7435f3c37d0897a8707016dcc0b";
      flake = false;
    };

    # The `from-git` Sigil libraries, pinned to the revisions
    # `sigil deps install` resolved for the trees the test suite is green
    # against. Taking them as flake inputs is what lets the build sandbox
    # stay offline: Nix fetches them, the lock file records them, and
    # `sigil build` finds them already on disk through a generated redirects
    # file. It is also why there is no `depsHash` to keep up to date.
    #
    # The list is this long because it is the union of two dependency graphs:
    # sigil-coin needs sqlite, json, crypto, ansi and version, and building
    # the Sigil CLI itself needs json, log, nrepl, http, tls, ffi, sqlite,
    # mcp, lsp and crypto, which in turn pull ansi, docs and socket. Adding
    # one is mechanical: the build names what is missing.
    sigil-ansi = {
      url = "git+https://codeberg.org/sigil/sigil-ansi?ref=master&rev=1e14b6f9d034ca8ef9f404e2ded316d0780ad7cf";
      flake = false;
    };
    sigil-crypto = {
      url = "git+https://codeberg.org/sigil/sigil-crypto?ref=master&rev=debba4462b7ff4de143db9e0792b8606fdc455bc";
      flake = false;
    };
    sigil-docs = {
      url = "git+https://codeberg.org/sigil/sigil-docs?ref=master&rev=105327cf559c31945fa3239b770460ca323ea8ed";
      flake = false;
    };
    sigil-ffi = {
      url = "git+https://codeberg.org/sigil/sigil-ffi?ref=master&rev=43283237fae5abdba324769ad4a7a2baf694e660";
      flake = false;
    };
    sigil-http = {
      url = "git+https://codeberg.org/sigil/sigil-http?ref=master&rev=c24a14cabdb5ceed6273d7a6c1004baee07d69a0";
      flake = false;
    };
    sigil-json = {
      url = "git+https://codeberg.org/sigil/sigil-json?ref=master&rev=55c9e74712b5f79b45d41c65cfe0aef2c8f7e155";
      flake = false;
    };
    sigil-log = {
      url = "git+https://codeberg.org/sigil/sigil-log?ref=master&rev=56e4fc5a52dc370c037ef14502bb8d6d2876dc53";
      flake = false;
    };
    sigil-lsp = {
      url = "git+https://codeberg.org/sigil/sigil-lsp?ref=master&rev=98d35fe94e05e315ea9871899d686297e4e056b1";
      flake = false;
    };
    sigil-mcp = {
      url = "git+https://codeberg.org/sigil/sigil-mcp?ref=master&rev=52d7e90e6d718b72a886dfb74e774e6cf0845fd7";
      flake = false;
    };
    sigil-nrepl = {
      url = "git+https://codeberg.org/sigil/sigil-nrepl?ref=master&rev=e5618482fb4adb2ed3851bef980bef91d3ad2ff7";
      flake = false;
    };
    sigil-socket = {
      url = "git+https://codeberg.org/sigil/sigil-socket?ref=master&rev=6b9e36eb4d4a944b463e5f6826bd711186ba6710";
      flake = false;
    };
    sigil-sqlite = {
      url = "git+https://codeberg.org/sigil/sigil-sqlite?ref=master&rev=3d441fb32a216aaf99d0e2732bef5877e91d5d48";
      flake = false;
    };
    sigil-tls = {
      url = "git+https://codeberg.org/sigil/sigil-tls?ref=master&rev=fe4b756f2f46eacf5e3a4eb5d17f2681d88c5ee8";
      flake = false;
    };
    sigil-version = {
      url = "git+https://codeberg.org/sigil/sigil-version?ref=master&rev=2d2c9ef9c2694466f65abc14cddf9bfb9cada4a4";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sigil,
      sigil-bitcoin,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # The tree this flake was fetched from — the sigil-coin repository when
      # evaluated with ?dir=deploy, and `deploy/` itself otherwise.
      fetched = self.sourceInfo.outPath;
      sigilCoinSrc =
        if builtins.pathExists "${fetched}/package.sgl" then
          # Only what `sigil build` reads. Without this every edit to
          # RUNBOOK.md or this file would change the source hash and rebuild
          # the whole workspace, and a stray `result` symlink or `.sigilcoin`
          # data directory would be copied into the store.
          # `lib.fileset` is not usable here: it needs a real path, and
          # sourceInfo.outPath is a store-path string, which Nix refuses to
          # concatenate onto `/.`. cleanSourceWith takes the string.
          nixpkgs.lib.cleanSourceWith {
            name = "sigil-coin-source";
            src = fetched;
            filter =
              path: _type:
              let
                rel = nixpkgs.lib.removePrefix "${fetched}/" path;
              in
              rel == "package.sgl" || rel == "packages" || nixpkgs.lib.hasPrefix "packages/" rel;
          }
        else
          throw ''
            deploy/flake.nix was evaluated with `deploy/` as the flake root, so
            it cannot see the sigil-coin workspace above it (no package.sgl at
            ${fetched}).

            Build it with the repository as the root instead:
              nix build /path/to/sigil-coin?dir=deploy#sigilcoin
            or, from inside a git checkout:
              cd /path/to/sigil-coin/deploy && nix build .#sigilcoin
          '';

      # Every input whose name is a `codeberg:sigil/<name>` library, keyed by
      # that name. Derived rather than listed twice, so adding an input to
      # the block above is the only edit a new dependency needs.
      sigilDeps = nixpkgs.lib.filterAttrs (
        name: _:
        !builtins.elem name [
          "self"
          "nixpkgs"
          "sigil"
          "sigil-bitcoin"
        ]
      ) inputs;

      args = {
        sigilSrc = sigil;
        sigilBitcoinSrc = sigil-bitcoin;
        inherit sigilCoinSrc sigilDeps;
      };

      built = pkgs.callPackage ./package.nix args;
    in
    {
      packages.${system} = {
        inherit (built) sigil-toolchain sigilcoin;
        default = built.sigilcoin;
      };

      overlays.default = _final: prev: {
        sigilcoin = (prev.callPackage ./package.nix args).sigilcoin;
      };

      nixosModules.default = ./module.nix;
      nixosModules.sigilcoin = ./module.nix;

      checks.${system} = {
        # Builds the real binaries and runs one of them. This is the check
        # that fails when the toolchain, the redirects or a bundle break.
        sigilcoin-runs = pkgs.runCommand "sigilcoin-runs" { } ''
          test "$(${built.sigilcoin}/bin/sigilcoin version)" = "sigilcoin 0.1.0"
          test -x ${built.sigilcoin}/bin/sigilcoin-explorer
          touch $out
        '';

        # Proves the module's options and the systemd units it generates are
        # well-formed without building anything. This is the check that
        # catches a typo in a unit before it reaches the seed host.
        module-eval =
          let
            host = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                ./module.nix
                (
                  { ... }:
                  {
                    boot.loader.grub.enable = false;
                    fileSystems."/" = {
                      device = "/dev/null";
                      fsType = "ext4";
                    };
                    system.stateVersion = "25.05";
                    nixpkgs.hostPlatform = system;

                    services.sigilcoin = {
                      enable = true;
                      # Substituted so the check never builds the toolchain.
                      package = pkgs.writeShellScriptBin "sigilcoin" "exit 0";
                      openFirewall = true;
                      peers = [ "seed.example:19444" ];
                    };
                    services.sigilcoin-explorer = {
                      enable = true;
                      package = pkgs.writeShellScriptBin "sigilcoin-explorer" "exit 0";
                    };
                  }
                )
              ];
            };
            units = host.config.systemd.units;
          in
          pkgs.runCommand "sigilcoin-module-eval" { } ''
            test -n "${units."sigilcoin-listen.service".unit}"
            test -n "${units."sigilcoin-sync.service".unit}"
            test -n "${units."sigilcoin-explorer.service".unit}"

            # The socket proxy is gone for good: the node binds its own
            # public port. Any unit named after the proxy is a regression,
            # and so is a listen unit that went back to loopback.
            test -z "${
              toString (
                builtins.attrNames (
                  nixpkgs.lib.filterAttrs (name: _: nixpkgs.lib.hasPrefix "sigilcoin-listen-proxy" name) units
                )
              )
            }"
            grep -q "0.0.0.0" ${units."sigilcoin-listen.service".unit}/sigilcoin-listen.service
            grep -q "19444" ${units."sigilcoin-listen.service".unit}/sigilcoin-listen.service

            touch $out
          '';
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
