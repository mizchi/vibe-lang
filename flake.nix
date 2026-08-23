{
  description = "vibe-lang development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # pkfire (pkf) — canonical task runner (Taskfile.pkl). Not in nixpkgs;
    # pinned to the same tag CI and the session-start hook use (v0.14.2).
    pkfire = {
      url = "git+https://github.com/mizchi/pkfire?ref=refs/tags/v0.14.2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, pkfire }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # Rust 1.93+ required for wasmtime 45+.
        rustToolchain = pkgs.rust-bin.stable."1.93.0".default.override {
          targets = [ "wasm32-wasip1" "wasm32-wasip2" ];
        };

        wasmtimeVersion = "47.0.2";
        wasmtimeArtifact = {
          aarch64-darwin = {
            arch = "aarch64";
            os = "macos";
            hash = "sha256-BtU69C7zy+9cfUTBSmaTs0Vqw9nfAJUPsgIHXicxTz4=";
          };
          x86_64-darwin = {
            arch = "x86_64";
            os = "macos";
            hash = "sha256-VIs393TVXoRfHQQH2dm7uoeZy6vkXWF9XQEncGut0Is=";
          };
          aarch64-linux = {
            arch = "aarch64";
            os = "linux";
            hash = "sha256-W7P+BodqHD9AQ3gVkLTApp6SN1SQI8zUQcGAg/Ed7NU=";
          };
          x86_64-linux = {
            arch = "x86_64";
            os = "linux";
            hash = "sha256-nshXUWSROXEbalBhxPSKQUEr+bGrmKCLmSTKc/IspXU=";
          };
        }.${system};
        wasmtimeRelease = pkgs.stdenvNoCC.mkDerivation {
          pname = "wasmtime";
          version = wasmtimeVersion;
          src = pkgs.fetchurl {
            url = "https://github.com/bytecodealliance/wasmtime/releases/download/v${wasmtimeVersion}/wasmtime-v${wasmtimeVersion}-${wasmtimeArtifact.arch}-${wasmtimeArtifact.os}.tar.xz";
            hash = wasmtimeArtifact.hash;
          };
          installPhase = ''
            runHook preInstall
            install -Dm755 wasmtime "$out/bin/wasmtime"
            runHook postInstall
          '';
          meta = {
            mainProgram = "wasmtime";
            platforms = builtins.attrNames {
              aarch64-darwin = null;
              x86_64-darwin = null;
              aarch64-linux = null;
              x86_64-linux = null;
            };
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # Rust toolchain (for wasmtime build + wasm components)
            rustToolchain

            # Wasm tooling
            wasmtimeRelease
            pkgs.wasm-tools
            pkgs.wac-cli

            # Node.js (selfhost wasm runner host)
            pkgs.nodejs_24

            # Build tools
            pkgs.ripgrep
            pkgs.ast-grep

            # Pkl CLI — required by pkfire (Taskfile.pkl) and by
            # pkspec for evaluating local schemas.
            # See docs/pkfire-pkspec.md for usage.
            pkgs.pkl

            # pkfire (pkf) — canonical task runner, pinned to v0.14.2 via the
            # `pkfire` flake input. Not in nixpkgs.
            pkfire.packages.${system}.default
          ];

          shellHook = ''
            export VIBE_USE_WASMTIME_SUBMODULE=0

            # pkf (pkfire) is provided by the `pkfire` flake input above. Keep
            # a fallback hint in case the shell is entered without it on PATH
            # (e.g. flake input fetch failed offline).
            if ! command -v pkf >/dev/null 2>&1; then
              echo ""
              echo "warn: pkf not on PATH — install pkfire to run tasks:"
              echo "  nix run github:mizchi/pkfire -- list"
              echo "  go install github.com/mizchi/pkfire/cmd/pkf@latest"
              echo "see docs/pkfire-pkspec.md"
              echo ""
            fi
          '';
        };
      }
    );
}
