{
  description = "vibe-lang development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    moonbit-overlay.url = "github:moonbit-community/moonbit-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, moonbit-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # Rust 1.91+ required for wasmtime (edition 2024)
        rustToolchain = pkgs.rust-bin.stable."1.91.0".default.override {
          targets = [ "wasm32-wasip1" "wasm32-wasip2" ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # MoonBit toolchain (from moonbit-overlay)
            moonbit-overlay.packages.${system}.moon-patched_latest

            # Rust toolchain (for wasmtime build + wasm components)
            rustToolchain

            # Wasm tooling
            pkgs.wasmtime
            pkgs.wasm-tools
            pkgs.wac-cli

            # Node.js (for moon test --target js)
            pkgs.nodejs_24

            # Build tools
            pkgs.just
            pkgs.ripgrep
            pkgs.ast-grep
          ];

          shellHook = ''
            export VIBE_USE_WASMTIME_SUBMODULE=0

            # Fetch mooncakes registry on first use
            if [ ! -d .mooncakes ]; then
              echo "Running moon update to fetch dependencies..."
              moon update 2>/dev/null || true
            fi
          '';
        };
      }
    );
}
