# Structured Shell Design: Shell-Script Superset with Nushell-Style Data Pipelines

## Vision

Vibe shell's POSIX mode is designed as a **superset of shell script**.

1. **Existing shell scripts keep working** — unrecognized commands fall back to `sh_lines()`.
2. **Recognized commands return structured data** — `ls` returns `Array[FileEntry]`, and `cat` returns `String`.
3. **Vibe expressions extend the shell** — `|>`, `match`, `if`, `let`, and lambdas remain available.

In short: `all bash commands + typed Vibe pipelines + Nushell-style structured data`.

## Design Principles

### 1. Shell-script compatibility through fallback

```bash
# All of these work: unrecognized commands delegate to /bin/sh through sh_lines().
git status
docker build -t myapp .
curl -s https://api.example.com
grep -r "TODO" src/
```

### 2. Recognized commands produce structured data

```bash
# ls returns Array[FileEntry] and displays it as a table.
ls .

# cat returns String and displays it directly.
cat README.md

# env returns String.
env HOME
```

### 3. Vibe expressions extend pipelines directly

```bash
# Filter structured data through a pipeline.
ls . |> where_entry(e -> e.is_dir)

# Bind a result with let.
let files = ls .
Array::length(files)

# if and match can coexist with shell expressions.
if exists "package.json" { cat package.json |> jq .name } else { "no package" }
```

### 4. Add recognized commands incrementally

Commands such as `grep`, `find`, `sort`, `head`, and `tail` can eventually be
replaced by Vibe implementations. The fallback always remains available, so an
unimplemented command does not block the user.

## Current State

### Existing foundation

- `vibe/shell/types.vibe`: `FileEntry { name, path, is_dir }`
- `vibe/shell/pipeline.vibe`: grep, cut, lines, split, jq, where_entry, filter_str, and related helpers
- `vibe/shell/commands.vibe`: ls returns `Array[FileEntry]`; cat returns `String`
- Vibe's `|>` pipeline operator: `expr |> f` is `f(expr)`
- POSIX preprocessor: `ls /tmp` becomes `Fs::readdir("/tmp")`

### Gaps

- `|>` works in compiled Wasm, but the shell's POSIX preprocessor does not interpret pipelines.
- `where` exists as a function call, but there is no POSIX-style `ls | where is_dir` syntax.
- There is no table formatter.

## Design

### Phase 1: Pipeline expressions in the POSIX preprocessor

```bash
# Current Vibe expression; this works.
Fs::readdir(".") |> where_entry(e -> e.is_dir)

# Target POSIX-style syntax.
ls . |> where is_dir
ls . |> where name == "src"
ls . |> sort_by name |> take 5
cat data.csv |> from_csv |> where age > 30
```

The POSIX preprocessor transforms `ls . |> where is_dir` into:

```vibe skip
// doctest-skip: design sketch: the syntax below is not implemented (preprocessor output sketch)
Fs::readdir(".") |> where_entry(e -> e.is_dir)
```

### Phase 2: Table display

```
vibe> ls .
┌─────┬──────────┬───────┐
│ #   │ name     │ is_dir│
├─────┼──────────┼───────┤
│ 0   │ src      │ true  │
│ 1   │ vibe     │ true  │
│ 2   │ README.md│ false │
└─────┴──────────┴───────┘
```

Values such as `Array[FileEntry]` and `Array[Record]` display automatically as tables.

### Phase 3: Structured-data conversion

```
# JSON to table
cat package.json |> jq .dependencies |> from_json

# CSV to table
cat data.csv |> from_csv

# YAML to table
cat config.yaml |> from_yaml

# Table to JSON
ls . |> to_json

# Select table columns
ls . |> select name, is_dir

# Sort a table
ls . |> sort_by name

# Aggregate a table
ls . |> group_by is_dir |> count
```

## Pipeline Transformation Rules

The POSIX preprocessor gains these transformations:

| Input | Transformation |
|------|------|
| `ls .` | `Fs::readdir(".")` |
| `ls . \|> where is_dir` | `Fs::readdir(".") \|> where_entry(e -> e.is_dir)` |
| `ls . \|> where name == "src"` | `Fs::readdir(".") \|> where_entry(e -> e.name == "src")` |
| `ls . \|> sort_by name` | `Fs::readdir(".") \|> sort_entries_by(e -> e.name)` |
| `ls . \|> count` | `Array::length(Fs::readdir("."))` |
| `cat f.csv \|> from_csv` | `from_csv(Fs::read_file("f.csv"))` |
| `cat f.json \|> jq .name` | `jq(Fs::read_file("f.json"), ".name")` |

## Workflow: REPL to File to Refactoring

A typical Vibe shell development workflow is:

### 1. Explore in the REPL

```
vibe> import @vibe/builtin { trait Iterator }
vibe> let data = cat data.csv |> from_csv
vibe> let filtered = data |> where age > 30
vibe> let names = filtered |> select name
vibe> Array::length(names)
last: 5
vibe> let avg = Iterator::fold(filtered |> select age, 0, (acc, x) -> acc + x) / 5
last: 42
```

### 2. Save the session as a `.vibe` file

```
vibe> :save analysis.vibe
saved: analysis.vibe (6 bindings)
```

The `:save` command normalizes every binding in `scratch_source` and writes the result to a file.

### 3. Clean up with normalize

```bash
vibe normalize analysis.vibe
```

- Organize and sort imports.
- Remove unused bindings.
- Topologically sort function definitions.
- Apply consistent formatting.

### 4. Refactor in an editor

```bash
vim analysis.vibex   # or vscode with vibe extension
vibe check analysis.vibex
vibe run analysis.vibex
```

### 5. Add tests for confidence

```bash
# Add test blocks to the end of analysis.vibex.
vibe test analysis.vibe
```

### Design requirements

- **`scratch_source` accumulates bindings**: `let x = ...` remains visible to later lines.
- **`:save` command**: normalize the current `scratch_source` and write it to a file.
- **`:load` command**: load a file into `scratch_source` and continue in the REPL.
- **`:clear` command**: reset `scratch_source`.
- **Normalize integration**: `:save` applies formatting equivalent to `vibe normalize`.

## Fallback Strategy

```
input line
  │
  ├─ Vibe keyword (let, if, match, ...) → compile as a Vibe expression
  ├─ function call f(...) → compile as a Vibe expression
  ├─ recognized command (cat, ls, cd, ...) → transform into a Vibe builtin call
  └─ unknown command → delegate to the system shell through sh_lines("...")
```

As a result:

- `git push` runs unchanged through `sh_lines`.
- `cat file.txt |> lines |> grep "TODO"` is a structured pipeline.
- `let count = ls . |> where_entry(e -> e.is_dir) |> Array::length` is type-safe.

## Implementation Plan

| Phase | Scope | Dependency |
|-------|------|------|
| Phase 0 | Make `ls .` work through `fs_host_imports` | #44 |
| Phase 1 | Transform the `ls . \|> where is_dir` pipeline | POSIX preprocessor extension |
| Phase 2 | Format `Array[FileEntry]` as a table | Show trait / REPL display |
| Phase 3 | Add from_csv/from_yaml/to_json conversion | Existing vibe/shell/from_*.vibe modules |
| Phase 4 | Implement grep/find/sort and related commands in Vibe | Incremental |

## Mapping to the Existing Library

| Nushell | vibe/shell |
|---------|-----------|
| `ls` | `ls(dir)` → `Array[FileEntry]` |
| `where` | `where_entry(pred)` / `filter_str(pred)` |
| `sort-by` | Not implemented: `sort_entries_by(key_fn)` |
| `select` | Not implemented: `select_fields(fields)` |
| `get` | `jq(data, expr)` |
| `from csv` | `from_csv(text)` |
| `from yaml` | `from_yaml(text)` |
| `lines` | `lines(text)` |
| `count` | `Array::length(arr)` |
