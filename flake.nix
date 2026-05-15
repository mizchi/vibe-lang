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

        # MoonBit code duplication detector (crates.io / github:mizchi/similarity)
        similarity-mbt = pkgs.rustPlatform.buildRustPackage rec {
          pname = "similarity-mbt";
          version = "0.5.2";
          src = pkgs.fetchCrate {
            inherit pname version;
            hash = "sha256-PTsTXYk6keh92HHbb8E3XD2qi49sg/JPwFKWzPoeqtw=";
          };
          cargoHash = "sha256-U5c+C99+bwCTpkEDV3nLFITmIk+n56eWQoq0oqc7qMI=";
          doCheck = false;
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
            pkgs.ripgrep
            pkgs.ast-grep
            similarity-mbt

            # Pkl CLI — required by pkfire (Taskfile.pkl) and by
            # pkspec for evaluating local schemas. pkfire / pkspec binaries
            # are not in nixpkgs; fetch them via `nix run github:mizchi/pkfire`
            # or `go install github.com/mizchi/pkfire/cmd/pkf@latest`.
            # See docs/pkfire-pkspec.md for usage.
            pkgs.pkl
          ];

          shellHook = ''
            export VIBE_USE_WASMTIME_SUBMODULE=0

            # Fetch mooncakes registry on first use
            if [ ! -d .mooncakes ]; then
              echo "Running moon update to fetch dependencies..."
              moon update 2>/dev/null || true
            fi

            # pkf (pkfire) is the canonical task runner but is not in
            # nixpkgs. Warn if it is missing so new contributors aren't
            # blocked by `pkf: command not found` mid-task.
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
