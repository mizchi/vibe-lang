# AST Binary ABI v1

Stable binary encoding for `@core.Module` shared by the MoonBit host
implementation (`src/core/serialize_binary.mbt`,
`src/core/deserialize_binary.mbt`) and the selfhost vibe compiler
(`vibe/compiler/ast_binary.vibe`).

The format is the source of truth for the on-disk prelude AST cache
(`~/.cache/vibe/prelude-<sha>.ast.bin`) and any other place where an
AST has to cross a process boundary. Both implementations MUST agree
byte-for-byte on roundtrips.

## Goals

- 5-10× smaller than JSON serialization (~5KB vs ~56KB for the prelude).
- Single-pass deserialize, no intermediate tree.
- Forward-compatible: new variants get new tag numbers; existing
  consumers raise `UnknownTag(...)` rather than misinterpreting.
- Endianness-independent (varints, no raw multi-byte ints).

## File layout

```
+----------------+------------------+----------------+
| magic (4B)     | version (varint) | module body    |
| "vAST"         | = 1              |                |
+----------------+------------------+----------------+
```

Magic: ASCII `'v' 'A' 'S' 'T'` (`0x76 0x41 0x53 0x54`). Followed by a
varint version number; this document defines **version 1**. The
deserializer rejects any other magic or any version it doesn't
recognize.

## Primitives

| Name       | Encoding |
|------------|----------|
| `varint`   | LEB128 unsigned, max 10 bytes (i.e. fits u64). |
| `svarint`  | Standard signed LEB128 (sleb128), max 10 bytes (i.e. fits i64). Chosen to align with wasm/DWARF conventions and reuse selfhost's existing `leb128_encode_s64`. |
| `bool`     | One byte: `0x00` = false, `0x01` = true. Any other value is malformed. |
| `string`   | `varint` length N in bytes, followed by N bytes UTF-8. |
| `optstr`   | One byte present flag (`0x00`=None, `0x01`=Some) + `string` if Some. |
| `array<T>` | `varint` count N, followed by N `T` items. |
| `map<K,V>` | `varint` count N, followed by N pairs (`K` then `V`). Order is implementation-defined; deserializers MUST NOT depend on it for equality. |
| `f32`      | IEEE-754 binary32, little-endian, 4 bytes. |
| `f64`      | IEEE-754 binary64, little-endian, 8 bytes. |
| `char`     | `varint` of the Unicode code point. |

## Span

```
span : svarint(start) svarint(end)
```

Encoded relative to the file. There's no dedicated empty-span sentinel;
`Span { start: 0, end: 0 }` encodes as the two-byte sequence `0x00
0x00`.

## Module

```
module : array<stmt>
```

## Tag numbers

Tags are single bytes (0..255). Once a tag is assigned to a variant
it is **frozen** — adding new variants takes new unused tag numbers,
never re-uses old ones, and never reorders fields.

### Stmt tags (variant → tag)

| Tag  | Variant |
|------|---------|
| 0x01 | `Let { rec, name, expr, span }` |
| 0x02 | `EnumDef { name, params, ctors, span }` |
| 0x03 | `TypeAlias { name, params, target, span }` |
| 0x04 | `TraitDef { name, supertraits, methods, open_impl, exported, span }` |
| 0x05 | `TraitImpl { type_params, type_bounds, trait_name, target, methods, span }` |
| 0x06 | `Expr { expr, span }` |
| 0x07 | `Import { spec, source, span }` |
| 0x08 | `Test { name?, body, span }` |
| 0x09 | `Bench { name?, body, span }` |
| 0x0A | `LetMut { name, expr, span }` |
| 0x0B | `ExternLet { name, ty, span }` |
| 0x0C | `Assign { name, expr, span }` |
| 0x0D | `IndexAssign { target, index, value, span }` |
| 0x0E | `LetPat { pat, expr, span }` |
| 0x0F | `LetPatElse { pat, expr, else_body, span }` |
| 0x10 | `ExportLet { rec, name, expr, span }` |
| 0x11 | `InternalExportLet { rec, name, expr, span }` |
| 0x12 | `ExportEnumDef { name, params, ctors, span }` |
| 0x13 | `InternalExportEnumDef { name, params, ctors, span }` |
| 0x14 | `ExportTypeAlias { name, params, target, span }` |
| 0x15 | `InternalExportTypeAlias { name, params, target, span }` |
| 0x16 | `InternalTraitDef { name, supertraits, methods, open_impl, span }` |
| 0x17 | `Export { names, span }` |
| 0x18 | `ReExport { spec, source, span }` |
| 0x19 | `AliasDecl { alias_name, source, span }` |
| 0x1A | `StructDef { name, params, fields, span }` |
| 0x1B | `ExportStructDef { name, params, fields, span }` |
| 0x1C | `InternalExportStructDef { name, params, fields, span }` |
| 0x1D | `EffectDef { name, params, ops, import_path?, span }` |
| 0x1E | `ExportEffectDef { name, params, ops, import_path?, span }` |

### Expr tags

| Tag  | Variant |
|------|---------|
| 0x01 | `Int { value: i64, span }` |
| 0x02 | `Float { value: f32, span }` |
| 0x03 | `Double { value: f64, span }` |
| 0x04 | `Bool { value, span }` |
| 0x05 | `Char { value, span }` |
| 0x06 | `String { value, span }` |
| 0x07 | `StringInterp { parts, span }` |
| 0x08 | `Ident { name, span }` |
| 0x09 | `Placeholder { index, span }` |
| 0x0A | `Call { name, type_args, args, span }` |
| 0x0B | `Tuple { items, span }` |
| 0x0C | `TupleIndex { expr, index, span }` |
| 0x0D | `Record { fields, span }` |
| 0x0E | `Array { items, span }` |
| 0x0F | `Map { fields, span }` |
| 0x10 | `If { cond, then_body, else_body, span }` |
| 0x11 | `Block { body, span }` |
| 0x12 | `Match { scrutinee, arms, span }` |
| 0x13 | `ForIn { value_name, index_name?, iterable, body, span }` |
| 0x14 | `Fn { type_params, type_bounds, params, ret?, effects, body, span }` |
| 0x15 | `While { cond, body, span }` |
| 0x16 | `Loop { params, body, span }` |
| 0x17 | `Break { value?, span }` |
| 0x18 | `Continue { args, span }` |
| 0x19 | `Return { value?, span }` |
| 0x1A | `Yield { expr, span }` |
| 0x1B | `Handle { body, arms, span }` |
| 0x1C | `StructLit { name, type_args, fields, span }` |
| 0x1D | `Spread { expr, span }` |
| 0x1E | `Perform { effect_name, op_name, args, span }` |

### Pat tags

| Tag  | Variant |
|------|---------|
| 0x01 | `Wildcard { span }` |
| 0x02 | `Bind { name, span }` |
| 0x03 | `Ctor { name, args, span }` |
| 0x04 | `Tuple { items, span }` |
| 0x05 | `Record { fields, span }` |
| 0x06 | `Struct { name, fields, span }` |
| 0x07 | `Int { value: i64, span }` |
| 0x08 | `Float { value: f32, span }` |
| 0x09 | `Double { value: f64, span }` |
| 0x0A | `Bool { value, span }` |
| 0x0B | `Char { value, span }` |
| 0x0C | `String { value, span }` |
| 0x0D | `Or { pats, span }` |

### Type tags

| Tag  | Variant |
|------|---------|
| 0x01 | `Int` |
| 0x02 | `Float` |
| 0x03 | `Double` |
| 0x04 | `Bool` |
| 0x05 | `Char` |
| 0x06 | `String` |
| 0x07 | `Path` |
| 0x08 | `PromptText` |
| 0x09 | `Unit` |
| 0x0A | `Infer` |
| 0x0B | `Tuple { items }` |
| 0x0C | `Record { fields: map<string,type> }` |
| 0x0D | `Array { elem }` |
| 0x0E | `Map { key, value }` |
| 0x0F | `Set { elem }` |
| 0x10 | `ArrayBuilder { elem }` |
| 0x11 | `MapBuilder { key, value }` |
| 0x12 | `StringBuilder` |
| 0x13 | `Bytes` |
| 0x14 | `V128` |
| 0x15 | `Variant { fields: map<string,type> }` |
| 0x16 | `Named { name, args }` |
| 0x17 | `Param { name }` |
| 0x18 | `Var { id }` |
| 0x19 | `Func { params, ret, effects }` |
| 0x1A | `Never` |

### ImportKind tags

| Tag  | Variant |
|------|---------|
| 0x01 | `Value` |
| 0x02 | `Type` |
| 0x03 | `Struct` |
| 0x04 | `Trait` |
| 0x05 | `Effect` |
| 0x06 | `Suberror` |
| 0x07 | `Module` |

### ModuleRef tags

| Tag  | Variant |
|------|---------|
| 0x01 | `Path { path }` |
| 0x02 | `Hash { hash }` |
| 0x03 | `Version { name }` |
| 0x04 | `Symbol { name }` |
| 0x05 | `Alias { name }` |
| 0x06 | `PinnedPath { path, hash }` |

### ParamLabel tags

| Tag  | Variant |
|------|---------|
| 0x01 | `Positional` |
| 0x02 | `Variadic` |
| 0x03 | `Required` |
| 0x04 | `Optional` |

### EffectAtom tags

| Tag  | Variant |
|------|---------|
| 0x01 | `Const { name }` |
| 0x02 | `Var { name }` |

### StringInterpPart tags

| Tag  | Variant |
|------|---------|
| 0x01 | `Lit { text }` |
| 0x02 | `Expr { expr }` |

## Auxiliary structs

These are inlined (no leading tag — the context disambiguates).

```
FuncParam        : string(name)
                   ParamLabel
                   Type(ty)
                   array<string>(bounds)

CallArg          : optstr(label) Expr(expr) Span(span)

RecordFieldExpr  : string(name) Expr(expr) Span(span)
MapFieldExpr     : string(key)  Expr(expr) Span(span)
RecordFieldPat   : string(name) Pat(pat)   Span(span)

LoopParam        : string(name) Expr(init) Span(span)

MatchArm         : Pat(pat) optExpr(cond) Expr(expr) Span(span)
  where optExpr  : 0x00 / 0x01 <Expr>

TypeCtor         : string(name) array<Type>(args) Span(span)
StructField      : string(name) Type(ty) bool(is_mut) Span(span)

EffectOp         : string(name) array<Type>(params) Type(ret) Span(span)

TraitMethodSig   : string(name) array<FuncParam>(params) Type(ret) Span(span)
ImplMethodDef    : string(name) Expr(expr) Span(span)

ImportItem       : ImportKind string(name) optstr(rename)
ImportSpec       : array<ImportItem>
```

## Error handling

Deserializers MUST raise (or return an error) — never panic — on any
of:

- Wrong magic.
- Unsupported version.
- Unknown tag byte (for any tagged enum).
- Unexpected EOF mid-record.
- String length that exceeds remaining bytes.
- `bool` byte that is neither `0x00` nor `0x01`.

The on-disk cache MUST treat any of these as a cache miss and fall
back to parsing the source string.

## Cross-implementation conformance

`vibe/compiler/ast_binary_test.vibe` and
`src/core/serialize_binary_wbtest.mbt` each contain a small fixture
("the smoke module") that exercises every tagged variant at least
once. Both implementations must produce byte-identical output when
serializing the smoke module, and both must deserialize the smoke
fixture file (`docs/fixtures/ast_binary_smoke.bin`) back to an equal
`Module`.

Whenever a new variant is added:

1. Pick the next unused tag in the relevant table above and update
   this document **first**.
2. Extend the smoke module to cover it.
3. Update both serializers in lock-step.
4. Bump the file version (`+1`) only if existing payloads change
   shape; pure additions don't require a version bump (the unknown-tag
   error already protects older readers).
