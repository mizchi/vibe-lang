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

The bootstrap requires Bash and Git. Outside a checkout it shallow-clones
`VIBE_INSTALL_REPO` (default `https://github.com/mizchi/vibe-lang`) at
`VIBE_INSTALL_REF` (default `main`), then reinvokes the installer from that
checkout. The temporary checkout is removed on success, failure, or a handled
signal. The selected ref becomes the default toolchain name unless
`--toolchain` overrides it.

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
