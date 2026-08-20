# Compiler Bundle Size Fixtures

> **This benchmark does not run.** Nothing in the repository drives it, and the
> `just bench-bundle-size-compiler*` recipes this README described went with
> the MoonBit host and `just` (#594) without a replacement. See
> `bench/bundle_size/README.md` — the shared driver there is a 0-byte file.
>
> The fixtures under `cases/` and `cases.txt` are kept as the inputs a revival
> would need. The commands below name nothing that exists.

`bench/compiler_size/` contains **fixed input fixtures** for compiler bundle-size regression checks.

## Goal

Track compiler/codegen size regressions independently from `examples/` evolution.

## Case Set

Case entries are defined in `bench/compiler_size/cases.txt`.

Each non-comment line is:

`<group> <path> <prefer_no_dce>`

- `group`: report grouping key (e.g. `bench/compiler`, `bench/importers`)
- `path`: repository-relative `.vibe` source path
- `prefer_no_dce`: `1` for no-dce-first probe, `0` for runtime-first probe

## Golden Rule

- Budget source: `bench/golden/compiler_bundle_size_budget.tsv`
- Rule: mode/bytes for each active case must not regress
- `unsupported` is explicit baseline (mode change requires budget update)

## Update Flow

1. Edit fixture files or `cases.txt`
2. Run `just bench-bundle-size-compiler-update`
3. Re-run `just bench-bundle-size-compiler` and ensure green

## Notes

- Keep these fixture files stable. Do not replace them with live `examples/` paths.
- Product-level size monitoring remains in `bench-bundle-size`.
- Combined monitor runner:
  `just bench-bundle-size-monitor`
