{
  description = "SigilCoin development environment and packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e72e4f299401a3689d4b3d5fc6496b11db7064eb";

    sigil = {
      url = "git+file:///home/trev/Workspace/sigil/sigil?rev=7e5a6c21cf46a326cfb937c23270a408bb10278f";
      flake = false;
    };
    sigil-bitcoin = {
      url = "git+file:///home/trev/Workspace/sigil/sigil-bitcoin?rev=4ecc1f188c51887450eb448b991dae28ba36dfa0";
      flake = false;
    };

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
      url = "git+https://codeberg.org/sigil/sigil-http?ref=master&rev=0b4617ac000d6f3ed9f3d0906e6b746ad995ea03";
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
    sigil-sxml = {
      url = "git+https://codeberg.org/sigil/sigil-sxml?rev=5a4f043247600f58bdabae19de55664d759a30c9";
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
      fetched = self.sourceInfo.outPath;
      sigilCoinSrc = nixpkgs.lib.cleanSourceWith {
        name = "sigil-coin-source";
        src = fetched;
        filter =
          path: _type:
          let
            rel = nixpkgs.lib.removePrefix "${fetched}/" path;
          in
          rel == "package.sgl" || rel == "packages" || nixpkgs.lib.hasPrefix "packages/" rel;
      };
      sigilDeps = nixpkgs.lib.filterAttrs (
        name: _:
        !builtins.elem name [
          "self"
          "nixpkgs"
          "sigil"
          "sigil-bitcoin"
        ]
      ) inputs;
      built = pkgs.callPackage ./deploy/package.nix {
        sigilSrc = sigil;
        sigilBitcoinSrc = sigil-bitcoin;
        inherit sigilCoinSrc sigilDeps;
      };
    in
    {
      packages.${system} = {
        inherit (built) sigil-toolchain sigilcoin;
        default = built.sigilcoin;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          built.sigil-toolchain
          built.sigilcoin
        ]
        ++ (with pkgs; [
          gcc
          gnumake
          pkg-config
          git
          curl
          jq
          python3
          mbedtls
          secp256k1
          rsync
          openssh
          file
          binutils
          patchelf
          gdb
          valgrind
          strace
        ]);

        shellHook = ''
          if [[ -f $PWD/package.sgl ]]; then
            export PATH="$PWD/tools/local-testnet/build/dev/bin:$PWD/tools/simulator/build/dev/bin:$PWD/../sigil-bitcoin/build/dev/bin:$PATH"
          fi
        '';
      };

      checks.${system}.sigilcoin-runs = pkgs.runCommand "sigilcoin-runs" { } ''
        test "$(${built.sigilcoin}/bin/sigilcoin version)" = "sigilcoin 0.1.0"
        test -x ${built.sigilcoin}/bin/sigilcoin-explorer
        touch $out
      '';

      formatter.${system} = pkgs.nixfmt;
    };
}
