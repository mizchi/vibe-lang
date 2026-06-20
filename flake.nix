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
    # pkfire (pkf) — canonical task runner (Taskfile.pkl). Not in nixpkgs;
    # pinned to the same tag CI and the session-start hook use (v0.10.0).
    pkfire = {
      url = "git+https://github.com/mizchi/pkfire?ref=refs/tags/v0.10.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, moonbit-overlay, pkfire }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # Rust 1.93+ required for wasmtime 45.
        rustToolchain = pkgs.rust-bin.stable."1.93.0".default.override {
          targets = [ "wasm32-wasip1" "wasm32-wasip2" ];
        };

        wasmtimeVersion = "45.0.0";
        wasmtimeArtifact = {
          aarch64-darwin = {
            arch = "aarch64";
            os = "macos";
            hash = "sha256-jFiaH+tleN39dtTuB7rFUdfzBp1s75sq5eh+YwtRmNs=";
          };
          x86_64-darwin = {
            arch = "x86_64";
            os = "macos";
            hash = "sha256-sBtCFhPZ4GcQPvtwHNZvQ2Agsy9ulVEl+snq80+lvOc=";
          };
          aarch64-linux = {
            arch = "aarch64";
            os = "linux";
            hash = "sha256-SicIO6jTxkUmstRp9Q5lOctMHdnQgzbg2JU7ymFnN+M=";
          };
          x86_64-linux = {
            arch = "x86_64";
            os = "linux";
            hash = "sha256-nZLm3ARjD2F+Dl1TIyelqResSJhYfgf0+3pfx//+92A=";
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
        # NB: the MoonBit toolchain here (moonbit-overlay, pinned via flake.lock)
        # is NOT the project's canonical compiler. vibe-lang tracks the official
        # CDN "latest" moon — CI installs it via scripts/install_moonbit.sh and
        # the CDN cannot serve pinned versions. The flake/devShell is a
        # convenience for nix users and may lag behind what builds the current
        # source. The Claude Code on the web SessionStart hook deliberately
        # installs moon via scripts/install_moonbit.sh (CI-aligned), not nix.
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # MoonBit toolchain (from moonbit-overlay)
            moonbit-overlay.packages.${system}.moon-patched_latest

            # Rust toolchain (for wasmtime build + wasm components)
            rustToolchain

            # Wasm tooling
            wasmtimeRelease
            pkgs.wasm-tools
            pkgs.wac-cli
            # wasm-opt — dist artifact optimization (scripts/build_selfhost_dist.sh).
            # Scripts degrade gracefully without it, but the optimized dist needs it.
            pkgs.binaryen

            # Node.js (for moon test --target js)
            pkgs.nodejs_24

            # Build tools
            pkgs.ripgrep
            pkgs.ast-grep
            similarity-mbt

            # Pkl CLI — required by pkfire (Taskfile.pkl) and by
            # pkspec for evaluating local schemas.
            # See docs/pkfire-pkspec.md for usage.
            pkgs.pkl

            # pkfire (pkf) — canonical task runner, pinned to v0.10.0 via the
            # `pkfire` flake input. Not in nixpkgs.
            pkfire.packages.${system}.default
          ];

          shellHook = ''
            export VIBE_USE_WASMTIME_SUBMODULE=0

            # Fetch mooncakes registry on first use
            if [ ! -d .mooncakes ]; then
              echo "Running moon update to fetch dependencies..."
              moon update 2>/dev/null || true
            fi

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
