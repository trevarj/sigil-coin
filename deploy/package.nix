# Derivations for the SigilCoin deployment.
#
# Two outputs:
#
#   sigil-toolchain   the Sigil compiler: `make stdlib` for the bootstrap CLI,
#                     then that CLI building the real one
#   sigilcoin         `bin/sigilcoin` AND `bin/sigilcoin-explorer`, both of
#                     which fall out of the same `sigil build` of the
#                     sigil-coin workspace
#
# There is no vendoring derivation and no `depsHash`. `sigil build` only
# reaches the network when a declared dependency is missing from disk, and
# every dependency here is redirected to a store path — including the
# `from-git` Sigil libraries, which enter as flake inputs and are therefore
# fetched by Nix, outside the sandbox, under the lock file. A fixed-output
# derivation running `sigil deps install` would only re-do what the flake
# already did, and would do it with a hash that has to be re-captured by hand
# every time a dependency moves.
{
  lib,
  stdenv,
  gcc,
  gnumake,
  pkg-config,
  git,
  secp256k1,
  mbedtls,

  # The two sibling checkouts and the sigil-coin tree.
  sigilSrc,
  sigilBitcoinSrc,
  sigilCoinSrc,

  # Attrset of `codeberg:sigil/<name>` -> source, covering every `from-git`
  # library declared anywhere in the two dependency graphs below.
  sigilDeps,
}:

let
  version = "0.1.0";

  # `sigil build` WRITES into the source tree of whatever it compiles:
  # sigil-lib gets a generated `src/version_info.c`, and the vendored C in
  # sigil-sqlite and sigil-crypto builds in place. A redirect pointing
  # straight at a store path therefore fails with
  #   Error (io-error): cannot open file for writing:
  #   /nix/store/…/packages/sigil-lib/src/version_info.c.tmp.73
  # so every redirect target is copied into $TMPDIR first, and the redirects
  # file is written in the build phase rather than with `writeText`.
  copyDeps = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: src: ''copy ${src} "${name}"'') sigilDeps
  );

  # `repos:` entries, matched on the declared URL. Required for a dep like
  # `(from-git url: "codeberg:sigil/sigil-sqlite")` that names neither `name:`
  # nor `package:` — `apply-redirects` asks `dep-name` for those, gets #f, and
  # never consults the `packages:` list, so a by-name redirect silently does
  # nothing and the build dies with "Missing external dependencies".
  repoRedirects = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: _: ''(repo "codeberg:sigil/${name}" "$deps/${name}")'') sigilDeps
  );

  # `packages:` entries, matched on the dependency's derived package name.
  # These cover the deps that DO name a package, which the URL match would
  # miss because one repo (codeberg:sigil/sigil) holds several packages.
  pkgRedirect = dir: name: ''(pkg "${name}" "$deps/${dir}/packages/${name}")'';
  coinPkgRedirects = lib.concatStringsSep "\n" (
    map (pkgRedirect "sigil") [
      "sigil-lib"
      "sigil-stdlib"
      "sigil-test"
      "sigil-test-runner"
    ]
    ++ map (pkgRedirect "sigil-bitcoin") [
      "sigil-bitcoin-utils"
      "sigil-bitcoin-primitives"
      "sigil-bitcoin-encoding"
      "sigil-secp256k1"
      "sigil-bitcoin-keys"
      "sigil-bitcoin-script"
      "sigil-bitcoin-tx"
      "sigil-bitcoin-consensus"
      "sigil-bitcoin-p2p"
      "sigil-bitcoin-node"
    ]
  );

  redirectsPreamble = ''
    deps=$TMPDIR/deps
    mkdir -p $deps
    copy() { cp -R --no-preserve=mode,ownership "$1" "$deps/$2"; }
    ${copyDeps}
  '';

  # The Sigil toolchain is built in the two stages upstream intends.
  #
  #   make stdlib                     -> build/boot/bin/sigil, the BOOTSTRAP
  #                                      CLI (version 0.0.0-boot)
  #   build/boot/bin/sigil build      -> build/dev/bin/sigil, the real one
  #     sigil-cli
  #
  # The second stage is not optional. The bootstrap CLI compiles itself and
  # sigil's own stdlib, but it cannot compile sigil-coin: it dies expanding
  # `(define coin-genesis-seed (hash256 coin-genesis-seed-tag))` in
  # sigil-coin-consensus with
  #   Error (type-error): call: not a procedure
  #     0: hash256 at seed.sgl:46:31
  # inside %syntax-template-instantiate. Reproduced outside Nix with the same
  # bootstrap binary, so it is the compiler, not the sandbox.
  #
  # `sigil-run` looks for its modules in `<exe dir>/../lib`, so bin/ and lib/
  # install together or the toolchain is not a toolchain.
  sigil-toolchain = stdenv.mkDerivation {
    pname = "sigil-toolchain";
    version = "0.20.0";
    src = sigilSrc;

    nativeBuildInputs = [
      gcc
      gnumake
      pkg-config
      git # only for the commit-sha stamp; the Makefile tolerates its absence
    ];
    buildInputs = [ mbedtls ];

    enableParallelBuilding = true;

    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR

      make -j$NIX_BUILD_CORES stdlib

      ${redirectsPreamble}
      chmod -R u+w $deps

      cat > $TMPDIR/nix-redirects.sgl <<EOF
      (define (repo url dir)
        (for-repo url: url use: (from-path dir: dir)))
      (redirects
        repos: (list
      ${repoRedirects}))
      EOF

      ./build/boot/bin/sigil build sigil-cli --redirects $TMPDIR/nix-redirects.sgl
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/lib
      cp -r build/dev/bin/. $out/bin/
      cp -r build/dev/lib/. $out/lib/
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      $out/bin/sigil --version
    '';

    meta = {
      description = "Sigil compiler and package tool";
      mainProgram = "sigil";
      platforms = lib.platforms.linux;
    };
  };

  sigilcoin = stdenv.mkDerivation {
    pname = "sigilcoin";
    inherit version;
    src = sigilCoinSrc;

    nativeBuildInputs = [
      sigil-toolchain
      gcc
      gnumake
      pkg-config
    ];
    buildInputs = [
      # sigil-secp256k1 links libsecp256k1; sigil-sqlite and sigil-crypto
      # compile their own vendored C and need nothing from the host.
      secp256k1
      mbedtls
    ];

    # The workspace's package.sgl declares exactly one config, `dev`. There is
    # no `release` config to pass to --config, and `sigil build` bundles every
    # package that has an `entry:` regardless, so the default config is the
    # whole build. Both bundles land in build/dev/bin.
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR

      ${redirectsPreamble}
      copy ${sigilSrc} sigil
      copy ${sigilBitcoinSrc} sigil-bitcoin
      chmod -R u+w $deps

      cat > $TMPDIR/nix-redirects.sgl <<EOF
      (define (repo url dir)
        (for-repo url: url use: (from-path dir: dir)))
      (define (pkg name dir)
        (for-package name: name use: (from-path dir: dir)))
      (redirects
        repos: (list
      ${repoRedirects})
        packages: (list
      ${coinPkgRedirects}))
      EOF

      sigil build --redirects $TMPDIR/nix-redirects.sgl
      runHook postBuild
    '';

    # The workspace's only config, `dev`, sets `bundle?: #f`, so what lands
    # in build/dev/bin is the Sigil runtime host rather than a self-contained
    # executable: it loads its modules from `<exe dir>/../lib` and fails with
    #   Error loading (sigil coin cli): import: library not found
    # if they are not there. bin/ and lib/ therefore install together, the
    # same way the toolchain does. Both binaries share the one lib tree.
    #
    # build/dev/bin also holds a copy of the `sigil` host itself. Install the
    # two programs by name rather than globbing, so a stray artifact never
    # becomes a shipped binary.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin $out/lib
      cp -r build/dev/lib/. $out/lib/
      install -Dm755 build/dev/bin/sigilcoin $out/bin/sigilcoin
      install -Dm755 build/dev/bin/sigilcoin-explorer $out/bin/sigilcoin-explorer
      runHook postInstall
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      test "$($out/bin/sigilcoin version)" = "sigilcoin ${version}"
    '';

    meta = {
      description = "SigilCoin node, wallet, miner and read-only explorer";
      mainProgram = "sigilcoin";
      platforms = lib.platforms.linux;
    };
  };
in
{
  inherit sigil-toolchain sigilcoin;
}
