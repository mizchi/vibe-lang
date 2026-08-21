# 09 — Modules and packages

Previous: [Option and the railway](08_option.vibe.md)

日本語版: [09_modules_packages.vibe.md](../ja/09_modules_packages.vibe.md)

One file is one module. Nothing in it is visible to another file unless
you write `export`, and nothing arrives in your file unless you write
`import`. Those two words are most of what you need.

## Two files

Here is a real one. [support/mathx.vibe](support/mathx.vibe) contains an
exported function:

```vibe
export fn triple(x: Int) -> Int {
  x * 3
}
```

and this chapter imports it by relative path, naming what it wants:

```vibe run
import ./support/mathx.vibe {
  triple
}

fn main with Console {
  println("triple(14) = \{triple(14)}")
}
```

```output
triple(14) = 42
```

Two variations on the import line:

- `import ./lib.vibe { f as renamed }` renames on the way in, for when
  two modules disagree about a good name.
- `import ./subdir { helper }` imports a *directory*, which resolves to
  its `index.vibe`.

A relative import *may* climb above the entry file's own directory —
`import ../../../helper.vibe` from a nested entry resolves. What bounds
it is not the entry's directory but what the host made visible to the
compiler: the preopened directory it was given. A path outside that is
not found, whatever the `../` count.

Crossing into a package is a different boundary again: a directory with
an `index.vpkg` publishes that contract, so a name it does not export is
rejected at check time rather than silently imported.

## Packages by name

An import starting with `@` names a package rather than a path:

```vibe run
import @vibe/core {
  hex_encode, sha1
}

fn main with Console {
  println("length(sha1(\"vibe\")) = \{String::length(sha1("vibe"))}")
  println("hex_encode(\"hi\") = \{hex_encode("hi")}")
}
```

```output
length(sha1("vibe")) = 40
hex_encode("hi") = 6869
```

The name is looked for in three places, in order: the project's pinned
store, the workspace's own `lib/`, and the installed standard library.
The first hit wins, so a local copy shadows the installed one while you
are working on it.

## The contract file

A package does not export whatever its files happen to export. It
declares a public API in `index.vpkg` — a **contract** of bodyless
declarations — and the compiler checks the implementation against it. If
they disagree, that is a compile error, not a surprise for a consumer.

```text
name = @you/counter
version = 1.0.0
description =
  #|A tiny counter contract
deps = {}

generated_hash =

type Counter
fn add(x: Int, y: Int) -> Int
```

`type Counter` with no definition means consumers get the name but not
the representation, so you can change it later. The header above the
declarations is not vibe syntax — it is package metadata, and
[docs/adding-modules.md](../../docs/adding-modules.md) is the reference
for it.

The practical consequence, and the thing that surprises people: to share
a helper between two files of the *same* package, exporting it is not
enough. It also has to be declared in the contract and imported
explicitly by the file that wants it. Package-private-by-default is the
rule.

## Reproducible builds

When you depend on someone else's package, the version number is not
what gets verified — the **content hash** is:

```text
require @vibe/core 0.2.0 = #pkg:sha1:<40hex>
```

The build re-checks that hash offline on every build, so neither the
registry nor the network has to be trusted between builds. `vibe hash`
computes the value. Set `VIBE_REQUIRE_PINS=1` and an unpinned dependency
becomes an error, which is what a release build should do.

## Publishing

When you are ready to hand a package to someone else:

```bash
vibe pkg publish lib/@you/pkg     # version check, then append to the log
vibe pkg install @you/pkg@1.0.0   # fetch and verify against the log
vibe pkg add github:owner/repo/dir@ref
vibe pkg yank @you/pkg@1.0.0      # withdraw a version
vibe pkg update @you/pkg          # move to the newest, showing the contract diff
```

Publish and yank append to a transparency log, and install verifies its
proof — so a version cannot be swapped underneath you after the fact.
[docs/registry-design.md](../../docs/registry-design.md) has the design.

Next: [Writing tests](10_tests.vibe.md).
