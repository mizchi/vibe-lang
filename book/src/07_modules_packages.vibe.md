# 07 — Modules and packages

Previous: [06 Tests](06_tests.vibe.md)
(run from the repository root, or in an environment where @vibe/core has been
materialized)

日本語版: [07_modules_packages.vibe.md](../ja/07_modules_packages.vibe.md)

## export and relative import

This first section is the part a beginner needs: one file is one module, mark
what you want visible with `export`, and the consumer imports selectively —
a local two-file module. The package contract / pin / publish material in the
second half is an advanced distribution workflow, and you can skip it until you
need it.

```vibe skip
// skip: a syntax overview (./lib.vibe and ./subdir are illustrative paths that
// do not exist in this repository) -- the working example is the run block
// below, which imports triple from support/mathx.vibe
// support/mathx.vibe
export fn triple(x: Int) -> Int {
  x * 3
}

// the consumer
import ./support/mathx.vibe {
  triple
}
import ./lib.vibe {
  f as renamed
}
// rename
import ./subdir {
  helper
}
// a directory import -> index.vibe(i)
```

An import path cannot escape the entry file's root directory — that is the
sandbox rule.

Here it is for real, importing `triple` from
[support/mathx.vibe](support/mathx.vibe):

```vibe run
import @vibe/prelude {
  stdout_write
}
import ./support/mathx.vibe {
  triple
}

fn main with Stdout {
  stdout_write("triple(14) = \{triple(14)}\n")
}
```

```output
triple(14) = 42
```

## @scope/name packages

`@scope/name` is searched in ADR-0065's resolution order: `.vibe/store/`
(pin-verified) → the workspace `lib/` → `VIBE_LIB` (default `~/.vibe/lib`, where
the curl installer puts the stdlib).

```vibe run
import @vibe/prelude {
  stdout_write
}
import @vibe/core {
  hex_encode, sha1
}

fn main with Stdout {
  stdout_write("length(sha1(\"vibe\")) = \{String::length(sha1("vibe"))}\n")
  stdout_write("hex_encode(\"hi\") = \{hex_encode("hi")}\n")
}
```

```output
length(sha1("vibe")) = 40
hex_encode("hi") = 6869
```

## Advanced: the contract (`index.vpkg`) and versions

> The canonical statement of the boundary, visibility and pin rules is the
> "現行モデル" section of
> [docs/module-system-oracle.md](../module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述)
> (#1269). What follows is the tutorial-level summary.

A package's boundary is its `index.vpkg` — a **contract** listing the public API
as bodyless declarations, which the compiler checks the implementation against.
Since #1128 the structured header (`name =` / `version =` / `description =` /
`deps = { ... }`) is the standard form:

```text
// An example index.vpkg header (see docs/adding-modules.md). The header is not
// vibe syntax, hence ```text -- for the real spelling read lib/@vibe/*/index.vpkg
name = @you/counter
version = 1.0.0
description =
  #|A tiny counter contract
deps = {}

generated_hash =

type Counter
// bodyless: the definition lives on the impl side
fn add(x: Int, y: Int) -> Int
// a mismatched implementation is a compile error
```

Ordinary `*.vibe` files in the same directory are implicit build roots.
Subdirectories are not walked recursively, so import or export the sources you
need relative to the root. `*_test.vibe` and `*_bench.vibe` are excluded from
the normal build and hash, but when run explicitly they may use the
package-private modules and shared imports of the nearest `index.vpkg`.
`_*.vibe` and `*.draft.vibe` are not implicit roots either, but when explicitly
imported they inherit the same shared imports and count toward the package hash.

## Advanced: pins — the content hash is the only truth

A reproducible build pins the **content hash** on the require line. The build
re-verifies that hash offline every time, so neither the location nor the
transport has to be trusted.

```text
// The require directive sits in the module header, independent of
// import/export. A directive is not vibe syntax, hence ```text (the loader's
// accepted forms are what contract.vibe's "malformed require line" diagnostic
// describes)
require @vibe/core 0.2.0 = #pkg:sha1:<40hex>
// compute <40hex> with `vibe hash`

import @vibe/core {
  sha1
}
```

Under `VIBE_REQUIRE_PINS=1` (the release/publish freeze) unpinned dev-mode
resolution becomes an error.

## Advanced: distribution commands (`vibe pkg` / scripts/vibe_pkg.sh)

With an installed toolchain it is `vibe pkg <cmd>`; inside the repo it is
`scripts/vibe_pkg.sh <cmd>` (the same implementation). publish and yank append
to the transparency log (`$VIBE_HOME/log`, #805), and install verifies the
inclusion proof against it.

```bash
vibe pkg publish lib/@you/pkg                 # semver gate + cache + append to the log
vibe pkg install @you/pkg@1.0.0               # materialize into ~/.vibe/lib (log-verified)
vibe pkg add github:owner/repo/dir@ref [#pin] # fetch from git with hash verification
vibe pkg yank @you/pkg@1.0.0                  # mark withdrawn (append-only)
vibe pkg update @you/pkg                      # move to the latest non-yanked (shows the contract diff)
```

More detail: [docs/adding-modules.md](../adding-modules.md) /
[docs/registry-design.md](../registry-design.md)

— that is the end of the tour. From the [README](README.md) you can re-run any
chapter.
