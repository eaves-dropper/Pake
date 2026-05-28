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

        # Only library deps that ship .pc files go into PKG_CONFIG_PATH
        hasDev = p: builtins.hasAttr "dev" p;
        pcPath = p: if hasDev p then "${p.dev}/lib/pkgconfig" else "${p}/lib/pkgconfig";
        pkgconfigPaths = map pcPath (with pkgs; [
          dbus
          gtk3
          libsoup_3
          librsvg
          xdotool
          libayatana-appindicator
          openssl
          webkitgtk_4_1
        ]);

        pnpmVersion = pkgs.lib.getVersion pkgs.pnpm_10;

        pnpmDeps = pkgs.fetchPnpmDeps {
          pnpm = pkgs.pnpm_10;
          fetcherVersion = 3;
          pname = "pake-cli";
          src = ./.;
          hash = "sha256-YZZTzZQe2U/Uxu90yWHdamfKPByl8kl72/gata0LQpA=";
        };

        pake-cli = pkgs.stdenv.mkDerivation {
          pname = "pake-cli";
          version = "3.11.7";
          src = ./.;

          nativeBuildInputs = with pkgs; [
            nodejs_22
            pnpm_10
            makeWrapper
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

            makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/pake \
              --add-flags "$out/lib/pake/dist/cli.js" \
              --prefix PATH : ${pkgs.lib.makeBinPath ([
                pkgs.pnpm_10
                pkgs.nodejs_22
                pkgs.pkg-config
                rustToolchain
              ] ++ tauriDeps)} \
              --set PKG_CONFIG_PATH "${pkgs.lib.concatStringsSep ":" pkgconfigPaths}"
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
