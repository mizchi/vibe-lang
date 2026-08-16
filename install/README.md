# vibe installer

`install/install.sh` is the public installation entry point. It supports both
curl-based installation and installation from an existing checkout.

## Install the development channel

```sh
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh | bash
```

`main` is mutable. For a reproducible installation, pin a release tag or commit
with `VIBE_INSTALL_REF`:

```sh
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh \
  | VIBE_INSTALL_REF=v1.0.0 bash
```

The bootstrap requires Bash and Git. The default install also requires Node.js
to acquire or build the gitignored compiler seed; Node.js is optional only when
an existing compiler is supplied with `--cli-wasm PATH`. Outside a checkout it
shallow-fetches the exact `VIBE_INSTALL_REF` (default `main`) from the configured
`VIBE_INSTALL_REPO` (default `https://github.com/mizchi/vibe-lang`), then
reinvokes the installer from that
detached checkout. Branches, tags, and reachable commit IDs are supported. The
temporary checkout is removed on success, failure, or a handled signal. A safe
form of the selected ref becomes the default toolchain name unless `--toolchain`
overrides it; explicit toolchain names must contain only ASCII letters, digits,
`.`, `_`, or `-`.

Installer options can be passed after `bash -s --`:

```sh
curl -fsSL https://raw.githubusercontent.com/mizchi/vibe-lang/main/install/install.sh \
  | bash -s -- --no-modify-path --prefix "$HOME/.vibe"
```

## Install from a checkout

```sh
bash install/install.sh
```

Run `bash install/install.sh --help` for the full option list. The existing
`VIBE_HOME`, `VIBE_BIN_DIR`, `VIBE_INSTALL_REPO`, and `VIBE_INSTALL_REF`
environment variables remain supported. See [the complete installation guide](../docs/install.md)
for the layout, dependencies, and toolchain behavior.
