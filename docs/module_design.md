# vibe Module System Design (Phase 1)

> Historical design draft (non-normative).
> Current implemented hashing/IR behavior is specified in `docs/vibe.md`.

## Goals

1. Content-addressable modules based on **AST hash** (not text)
2. Path-based syntax for human readability
3. Normalized to hash on save, expanded to path on edit

## Syntax

### Import

Only named imports are supported. No `* as` or default exports.

```vibe
// Named imports
use ./path.vibe { foo, bar }
use ./path.vibe { foo as f, bar }

// Hash reference (normalized form)
use #abc12345 { foo }
```

### Export

```vibe
// Inline export
export let foo = 1
export let add = (x: Int, y: Int) -> Int { x + y }
export type Point = record { x: Int, y: Int }
export enum Color { Red; Green; Blue }

// Re-export
export { foo, bar } from ./other.vibe

// Export list (at end of file)
export { foo, bar, baz }
```

### Module Reference

```
ModuleRef ::= Path | Hash

Path   ::= "./" segment ("/" segment)* ".vibe"
Hash   ::= "#" [a-f0-9]{8,64}
```

## AST Changes

```moonbit
// New types
struct ImportItem {
  name : String
  rename : String?   // None means same as name (for `foo as bar`)
}

struct ImportSpec {
  items : Array[ImportItem]  // { foo, bar as b }
}

enum ModuleRef {
  Path(path~ : String)     // ./foo/bar.vibe
  Hash(hash~ : String)     // #abc12345
}

// Updated Stmt enum
enum Stmt {
  // ... existing variants ...

  // Replace old Import with:
  Import(spec~ : ImportSpec, source~ : ModuleRef, span~ : Span)

  // New export variants:
  ExportLet(rec~ : Bool, name~ : String, expr~ : Expr, span~ : Span)
  ExportEnumDef(...)
  ExportTypeAlias(...)
  Export(names~ : Array[String], span~ : Span)
  ReExport(names~ : Array[String], source~ : ModuleRef, span~ : Span)
}
```

## AST Hashing

### Principle

- Hash the **normalized AST**, not source text
- Comments are excluded
- Formatting differences produce same hash
- Alpha-equivalent code should ideally produce same hash (Phase 2+)

### Normalization Rules (Phase 1)

1. Strip all `Span` fields
2. Strip comments (not in AST anyway)
3. Serialize AST to canonical format (JSON or MessagePack)
4. SHA256 hash

```
Source → Parse → AST → Normalize → Serialize → SHA256
```

### What's Included in Hash

| Included | Excluded |
|----------|----------|
| All expressions | Span/location info |
| Type annotations | Comments |
| Import specs | Formatting |
| Export specs | |

### Alpha-Normalization

Variable names are normalized to positional indices before hashing:

```
(x, y) -> x + y    →  ($0, $1) -> $0 + $1
(a, b) -> a + b    →  ($0, $1) -> $0 + $1
(foo, bar) -> ...  →  ($0, $1) -> ...
```

This ensures semantically equivalent code produces the same hash.

### Normalization Algorithm

```
normalize(ast) -> NormalizedAST:
  1. Walk AST recursively
  2. For each scope (function, block):
     - Collect bound variable names in order
     - Replace with $0, $1, $2, ...
  3. Strip all Span fields
  4. Return normalized AST

serialize(normalized_ast) -> String:
  - Convert to canonical JSON
  - Sort object keys alphabetically
  - No whitespace (compact)

hash(ast) -> String:
  - normalized = normalize(ast)
  - json = serialize(normalized)
  - git_blob_hash(json)
```

### Scope Rules for Alpha-Normalization

```vibe
let add = (x, y) -> x + y
// Scope: [x=$0, y=$1]
// Normalized: ($0, $1) -> $0 + $1

let nested = (a) -> {
  let b = a + 1
  (c) -> b + c
}
// Outer scope: [a=$0]
// Inner let: [b=$1]
// Inner fn scope: [c=$0] (resets for new function)
// Normalized: ($0) -> { let $1 = $0 + 1; ($0) -> $1 + $0 }
```

### Example

```vibe
// These ALL produce the SAME hash:

let add = (x: Int, y: Int) -> Int { x + y }
let add = (a: Int, b: Int) -> Int { a + b }
let add = (x: Int, y: Int) -> Int {
  x + y
}
```

```vibe
// These produce DIFFERENT hashes:

let add = (x: Int, y: Int) -> Int { x + y }
let add = (x: Int, y: Int) -> Int { y + x }  // different semantics
```

### Hash Format

```
#abc12345          // 8 chars (default)
#abc123456789abcd  // extended if collision
```

Git-style: shortest unique prefix within the module database.

## Module Resolution

### Phase 1: File-based

```
project/
├── src/
│   ├── main.vibe
│   └── lib/
│       └── utils.vibe
└── .vibe/
    └── modules.db      # path → hash mapping
```

### Resolution Algorithm

1. Parse source file
2. For each `import ... from ./path.vibe`:
   - Resolve path relative to current file
   - Load and parse target file
   - Compute AST hash
   - Store in module DB
3. Replace `Path(./path.vibe)` with `Hash(#abc...)` in normalized form

### Circular Import Detection

- Build dependency graph during resolution
- Error if cycle detected (Phase 1: no mutual recursion)

## Storage Format: Git Objects

Use git's object storage directly for content-addressed modules.

### Object Types

```
.git/objects/           # or .vibe/objects/
├── ab/
│   └── cdef1234...     # normalized AST blob
└── 12/
    └── 3456789...      # another module
```

### Blob Format

Each module is stored as a git blob containing normalized AST JSON:

```
blob <size>\0<normalized-ast-json>
```

### Git Commands (CLI integration)

```bash
# Write object
echo '<ast-json>' | git hash-object -w --stdin

# Read object
git cat-file blob <hash>

# Verify
git cat-file -t <hash>  # should be "blob"
```

### Path Mapping (.vibe/paths.json)

```json
{
  "./lib/utils.vibe": "abcdef1234567890...",
  "./main.vibe": "1234567890abcdef..."
}
```

### Alternative: Standalone Object Store

If not in a git repo, use `.vibe/objects/` with same format:

```
.vibe/
├── objects/
│   ├── ab/cdef1234...
│   └── 12/3456789...
└── paths.json
```

## CLI Commands

```bash
# Save file (normalize to hash)
vibe save src/main.vibe

# Edit file (expand from hash to path)
vibe edit src/main.vibe

# Show module hash
vibe hash src/main.vibe

# Show dependencies
vibe deps src/main.vibe

# Verify all hashes
vibe verify
```

## Scope & Visibility

### Default: Private

```vibe
let internal_helper = ...   // Not visible outside
export let public_fn = ...  // Visible to importers
```

### Import creates bindings

```vibe
use ./lib.vibe { foo, bar as b }

foo()    // OK
b()      // OK (alias for bar)
bar()    // Error: bar not in scope (must use alias)
```

## Design Decisions

1. **No backward compatibility** - Old `import "path"` syntax is removed
2. **Alpha-normalization** - Variable names are normalized before hashing
3. **Short hash** - Git-style shortest unique prefix (default 8 chars)

## Implementation Plan

### Step 1: AST & Parser
- [ ] Add `ImportSpec`, `ModuleRef` types
- [ ] Update `Stmt::Import`
- [ ] Add `Stmt::Export*` variants
- [ ] Parse new import/export syntax
- [ ] Backward compat for old import

### Step 2: AST Hashing
- [ ] Implement `normalize_ast()`
- [ ] Implement `serialize_ast()`
- [ ] Implement `hash_ast()`

### Step 3: Module Resolution
- [ ] Implement path resolution
- [ ] Implement cycle detection
- [ ] Create module DB schema

### Step 4: Scope & Binding
- [ ] Track exports per module
- [ ] Resolve imports to bindings
- [ ] Type check across modules
