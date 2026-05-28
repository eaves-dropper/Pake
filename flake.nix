{
  description = "Turn any webpage into a desktop app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, flake-utils, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rustfmt" "clippy" ];
        };

        # Tauri system dependencies — libraries needed when pake builds an app
        tauriLibDeps = with pkgs; [
          dbus
          gtk3
          libsoup_3
          librsvg
          xdotool
          libayatana-appindicator
          openssl
          webkitgtk_4_1
        ];

        # Tauri tooling dependencies (no .pc files, just binaries for the build)
        tauriBinDeps = with pkgs; [
          curl
          file
          wget
        ];

        tauriDeps = tauriLibDeps ++ tauriBinDeps ++ [ pkgs.pkg-config ];

        # All transitive .pc directories from library deps
        allTauriPkgs = pkgs.lib.closePropagation tauriLibDeps;
        hasDev = p: builtins.hasAttr "dev" p;
        pcPath = p:
          let base = if hasDev p then "${p.dev}" else "${p}";
          in "${base}/lib/pkgconfig:${base}/share/pkgconfig";
        pkgconfigPaths = map pcPath allTauriPkgs;

        pnpmVersion = pkgs.lib.getVersion pkgs.pnpm_10;

        pnpmDeps = pkgs.fetchPnpmDeps {
          pnpm = pkgs.pnpm_10;
          fetcherVersion = 3;
          pname = "pake-cli";
          src = ./.;
          hash = "sha256-YZZTzZQe2U/Uxu90yWHdamfKPByl8kl72/gata0LQpA=";
        };

        # Store paths to embed in the wrapper script
        nodeBinary = "${pkgs.nodejs_22}/bin/node";
        runtimePath = pkgs.lib.makeBinPath ([
          pkgs.pnpm_10
          pkgs.nodejs_22
          pkgs.pkg-config
          rustToolchain
        ] ++ tauriDeps);
        pkgConfigPath = pkgs.lib.concatStringsSep ":" pkgconfigPaths;

        pake-cli = pkgs.stdenv.mkDerivation {
          pname = "pake-cli";
          version = "3.11.7";
          src = ./.;

          nativeBuildInputs = with pkgs; [
            nodejs_22
            pnpm_10
            zstd
          ];

          buildInputs = tauriDeps;

          buildPhase = ''
            export HOME="$TMPDIR"
            export COREPACK_ENABLE=0

            # pnpm self-installs if the version in packageManager doesn't match.
            # We patch it to the Nix-provided version to prevent network fetch.
            cp package.json package.json.orig
            sed -i 's/"packageManager": "[^"]*"/"packageManager": "pnpm@${pnpmVersion}"/' package.json

            # Extract the pre-fetched pnpm store to a writable location
            mkdir -p "$TMPDIR/pnpm-store"
            zstd -dc "${pnpmDeps}/pnpm-store.tar.zst" | tar -xf - -C "$TMPDIR/pnpm-store"
            chmod -R +w "$TMPDIR/pnpm-store"

            pnpm install --frozen-lockfile --store-dir "$TMPDIR/pnpm-store" --offline
            pnpm run cli:build

            # Install only production dependencies for runtime
            pnpm install --frozen-lockfile --store-dir "$TMPDIR/pnpm-store" --offline --prod
          '';

          installPhase = ''
            mkdir -p $out/lib/pake $out/bin
            cp -r dist $out/lib/pake/dist
            cp -r src-tauri $out/lib/pake/src-tauri
            cp -r node_modules $out/lib/pake/node_modules
            cp package.json $out/lib/pake/package.json
            rm -f package.json.orig pnpm-lock.yaml

            # Write the wrapper that copies the store to a writable cache dir
            # Use __PAKE_STORE__ placeholder to avoid Nix / bash escaping conflicts
            cat > $out/bin/pake << 'WRAPPER_EOF'
#!${pkgs.bash}/bin/bash
set -euo pipefail

PAKE_STORE="__PAKE_STORE__/lib/pake"
HASH="$(echo "$PAKE_STORE" | md5sum | cut -c1-12)"
CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/pake"
CACHE_TARGET="$CACHE_DIR/$HASH"

if [ ! -d "$CACHE_TARGET" ]; then
  mkdir -p "$CACHE_TARGET"
  cp -r --reflink=auto "$PAKE_STORE"/* "$CACHE_TARGET/" 2>/dev/null || \
  cp -r "$PAKE_STORE"/* "$CACHE_TARGET/"
  chmod -R u+w "$CACHE_TARGET"
fi

export PATH='${runtimePath}':"''${PATH:+:$PATH}"
export PKG_CONFIG_PATH='${pkgConfigPath}'
export COREPACK_ENABLE=0

exec '${nodeBinary}' "$CACHE_TARGET/dist/cli.js" "$@"
WRAPPER_EOF
            sed -i "s|__PAKE_STORE__|$out|g" $out/bin/pake
            chmod +x $out/bin/pake
          '';

          meta = with pkgs.lib; {
            description = "Turn any webpage into a desktop app";
            homepage = "https://github.com/tw93/Pake";
            license = licenses.mit;
            platforms = platforms.linux;
            mainProgram = "pake";
          };
        };
      in
      {
        packages.default = pake-cli;
        packages.pake = pake-cli;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            nodejs_22
            pnpm_10
            rustToolchain
          ] ++ tauriDeps;
        };

        apps.default = {
          type = "app";
          program = "${pake-cli}/bin/pake";
          meta = {
            description = "Turn any webpage into a desktop app";
            platforms = pkgs.lib.platforms.linux;
          };
        };
      }
    );
}
