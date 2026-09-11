# AST Binary ABI v1

Stable binary encoding for the vibe surface-syntax AST — `Array[Stmt]` and
the `Stmt` / `Expr` / `Pat` / `TypeExpr` trees underneath it, as declared
in `lib/@vibe/ast/index.vpkg`. Implemented in
`lib/@vibe/compiler/ast_binary.vibe`.

The format is the source of truth for the on-disk per-file AST cache
(`~/.cache/vibe/prelude-<sha>.ast.bin`, #2510) and any other place where
an AST has to cross a process boundary. Roundtrips MUST be byte-for-byte
stable across compiler versions.

There is one implementation and one AST. The tag tables below were
rewritten against that AST in #2510, replacing tables that still described
the host retired in #594 — they named `Int` / `Float` / `Record` / `Map` /
`Set` / `ArrayBuilder`, and whole enums (`ModuleRef`, `ParamLabel`,
`EffectAtom`) this compiler has never had. `scripts/check_ast_binary_tags.sh`
now holds every table to `lib/@vibe/ast/index.vpkg`, so a variant cannot be
added, removed or renamed without this document following it.

## Goals

- 5-10× smaller than JSON serialization.
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

| Name          | Encoding |
|---------------|----------|
| `varint`      | LEB128 unsigned, max 10 bytes (i.e. fits u64). |
| `svarint`     | Standard signed LEB128 (sleb128), max 10 bytes (i.e. fits i64). Chosen to align with wasm/DWARF conventions. |
| `bool`        | One byte: `0x00` = false, `0x01` = true. Any other value is malformed. |
| `string`      | `varint` length N in bytes, followed by N bytes UTF-8. |
| `optstr`      | One byte present flag (`0x00`=None, `0x01`=Some) + `string` if Some. |
| `array<T>`    | `varint` count N, followed by N `T` items. |
| `opt<T>`      | One byte present flag (`0x00`=None, `0x01`=Some) + `T` if Some. |
| `f64`         | `varint` lo + `varint` hi: the IEEE-754 binary64 bit pattern split into two UNSIGNED 32-bit halves, low half first. See below. |
| `(A, B)`      | `A` then `B`, no tag — the field's declared type says which. Likewise for wider tuples. |
| `span`        | `svarint(start) svarint(end)`. Implemented and tested, but **no node in this AST uses it**: vibe's AST carries bare byte offsets in named `Int` slots (`EIdent`, `ELet`, `ELetMut`, `ECall`, `EBinOp`, `EDot`) rather than start/end pairs, so those encode as plain `svarint`. Retained because it predates the vibe AST and costs nothing. |

There is no `f32`, `char`, or `map<K,V>` primitive: nothing in this AST is
a `Float`, a `Char`, or a `Map`. `EMap` is an `Array[(String, Expr)]`, so
it encodes as `array<(string, Expr)>` and its order is significant.

### Why `f64` is a lo/hi pair and not text

`EFloat` and `PFloat` carry a `Double`, and the encoding has to be exact
— an AST cache that returns a slightly different literal is silently
wrong, which is the worst failure mode this project recognizes.

The obvious cheap route, `Double::to_string` on write and `Double::parse`
on read, is **lossy**. Measured 2026-09-11 against the committed seed
(the `to_string` defect is filed on its own as #2652):

| value | `Double::to_string` | exact? |
|---|---|---|
| `2.2250738585072014` | `2.225073858507201` | no — last digit dropped |
| `1e300` (computed) | `0` | no |
| `1e-300` (computed) | `0` | no |
| `0.1`, `-1.5`, `pi` | round-trips | yes |

`Double::to_i64_bits_lo` / `Double::to_i64_bits_hi` are exact for every
value tested, and each half is `0 .. 2^32-1`, so each fits vibe's 63-bit
`Int` — unlike the full 64-bit pattern, which does not (ADR-0055
Blocker-2). This is the same split `emit_f64_const_lohi` already uses to
put an `f64.const` into the wasm output.

**The read side needs a primitive that does not exist yet.**
`Double::from_i64_bits(Int) -> Double` takes the whole pattern in one
`Int`, so it cannot receive any value whose bit pattern exceeds 63 bits —
which includes every negative double (`-1.5` is `0xBFF8000000000000`).
Encoding `f64` therefore waits on a `lohi` counterpart to
`Double::to_i64_bits_lo/_hi`, tracked in #2651. `TypeExpr` has no
`Double` anywhere in it, so it is unaffected and is implemented today.

## Module

```
module : array<Stmt>
```

## Tag numbers

Tags are single bytes (0..255), assigned in **declaration order** within
each enum as declared in `lib/@vibe/ast/index.vpkg`. Once a tag is
assigned to a variant it is **frozen** — adding new variants takes new
unused tag numbers, never re-uses old ones, and never reorders fields.
A new variant appended to an enum's declaration therefore takes the next
free tag, NOT the tag its new declaration position would imply.

Field names below are descriptive; the AST's constructors are positional,
so the **order** is what the format fixes.

### TypeExpr tags (5 variants)

| Tag  | Variant | Payload |
|------|---------|---------|
| 0x01 | `TyName(String)` | `string(name)` |
| 0x02 | `TyApp(String, Array[TypeExpr])` | `string(name) array<TypeExpr>(args)` |
| 0x03 | `TyFn(Array[TypeExpr], TypeExpr, Option[String])` | `array<TypeExpr>(params) TypeExpr(ret) optstr(effect_row)` |
| 0x04 | `TyTuple(Array[TypeExpr])` | `array<TypeExpr>(items)` |
| 0x05 | `TyUnit` | — |

### Pat tags (10 variants)

| Tag  | Variant | Payload |
|------|---------|---------|
| 0x01 | `PWild` | — |
| 0x02 | `PBind(String)` | `string(name)` |
| 0x03 | `PInt(Int)` | `svarint(value)` |
| 0x04 | `PFloat(Double)` | `f64(value)` |
| 0x05 | `PString(String)` | `string(value)` |
| 0x06 | `PBool(Bool)` | `bool(value)` |
| 0x07 | `PCtor(String, Array[Pat])` | `string(name) array<Pat>(args)` |
| 0x08 | `PTuple(Array[Pat])` | `array<Pat>(items)` |
| 0x09 | `POr(Pat, Pat)` | `Pat(left) Pat(right)` |
| 0x0A | `PStruct(String, Array[(String, Pat)])` | `string(name) array<(string, Pat)>(fields)` |

### ImportKind tags (5 variants)

| Tag  | Variant |
|------|---------|
| 0x01 | `ImportType` |
| 0x02 | `ImportStruct` |
| 0x03 | `ImportEnum` |
| 0x04 | `ImportEffect` |
| 0x05 | `ImportTrait` |

`ImportItem` is a struct, not an enum, so it carries no tag of its own:

```
ImportItem : opt<ImportKind>(kind) string(name) optstr(alias)
```

### Expr tags (33 variants)

| Tag  | Variant | Payload |
|------|---------|---------|
| 0x01 | `EInt(Int)` | `svarint(value)` |
| 0x02 | `EFloat(Double)` | `f64(value)` |
| 0x03 | `EString(String)` | `string(value)` |
| 0x04 | `EBool(Bool)` | `bool(value)` |
| 0x05 | `EIdent(String, Int)` | `string(name) svarint(byte_offset)` |
| 0x06 | `ETuple(Array[Expr])` | `array<Expr>(items)` |
| 0x07 | `EArray(Array[Expr])` | `array<Expr>(items)` |
| 0x08 | `ERecord(String, Array[(String, Expr)], Array[TypeExpr])` | `string(name) array<(string, Expr)>(fields) array<TypeExpr>(type_args)` |
| 0x09 | `EIf(Expr, Expr, Expr)` | `Expr(cond) Expr(then) Expr(else)` |
| 0x0A | `ELet(String, Expr, Expr, Int)` | `string(name) Expr(value) Expr(body) svarint(byte_offset)` |
| 0x0B | `ELetRec(String, Expr, Expr)` | `string(name) Expr(value) Expr(body)` |
| 0x0C | `ELetMut(String, Expr, Expr, Int)` | `string(name) Expr(value) Expr(body) svarint(byte_offset)` |
| 0x0D | `EAssign(String, Expr, Expr)` | `string(name) Expr(value) Expr(body)` |
| 0x0E | `EAssignOp(String, String, Expr, Expr)` | `string(target) string(op) Expr(value) Expr(body)` |
| 0x0F | `ESeq(Expr, Expr)` | `Expr(first) Expr(second)` |
| 0x10 | `EMatch(Expr, Array[(Pat, Expr)])` | `Expr(scrutinee) array<(Pat, Expr)>(arms)` |
| 0x11 | `EHandle(Expr, Array[(Pat, Expr)])` | `Expr(body) array<(Pat, Expr)>(arms)` |
| 0x12 | `EWhile(Expr, Expr)` | `Expr(cond) Expr(body)` |
| 0x13 | `ELoop(Array[(String, Expr)], Expr)` | `array<(string, Expr)>(params) Expr(body)` |
| 0x14 | `EForIn(String, Option[String], Expr, Expr)` | `string(value_name) optstr(index_name) Expr(iterable) Expr(body)` |
| 0x15 | `ECall(Expr, Array[Expr], Int)` | `Expr(callee) array<Expr>(args) svarint(byte_offset)` |
| 0x16 | `EBinOp(String, Expr, Expr, Int)` | `string(op) Expr(lhs) Expr(rhs) svarint(operator_byte_offset)` |
| 0x17 | `EUnaryOp(String, Expr)` | `string(op) Expr(operand)` |
| 0x18 | `EFn(Array[String], Array[(String, Array[String])], Array[(String, Option[TypeExpr])], Option[TypeExpr], Option[String], Expr)` | `array<string>(type_params) array<(string, array<string>)>(bounds) array<(string, opt<TypeExpr>)>(params) opt<TypeExpr>(ret) optstr(effect_row) Expr(body)` |
| 0x19 | `EDot(Expr, String, Int, Int)` | `Expr(receiver) string(field) svarint(byte_offset) svarint(field_byte_offset)` |
| 0x1A | `ELabeledArg(String, String, Expr)` | `string(label) string(param) Expr(value)` |
| 0x1B | `EReturn(Expr)` | `Expr(value)` |
| 0x1C | `EBreak(Option[Expr])` | `opt<Expr>(value)` |
| 0x1D | `EContinue(Array[Expr])` | `array<Expr>(args)` |
| 0x1E | `EMap(Array[(String, Expr)])` | `array<(string, Expr)>(entries)` |
| 0x1F | `ESpread(Expr)` | `Expr(value)` |
| 0x20 | `EStringInterp(Array[String])` | `array<string>(parts)` |
| 0x21 | `EUnit` | — |

### Stmt tags (26 variants)

| Tag  | Variant | Payload |
|------|---------|---------|
| 0x01 | `SLet(Bool, Bool, String, Option[TypeExpr], Expr)` | `bool(exported) bool(rec) string(name) opt<TypeExpr>(ty) Expr(value)` |
| 0x02 | `SLetMut(String, Option[TypeExpr], Expr)` | `string(name) opt<TypeExpr>(ty) Expr(value)` |
| 0x03 | `SEnum(Bool, String, Array[String], Array[(String, Array[TypeExpr])], Array[String])` | `bool(exported) string(name) array<string>(type_params) array<(string, array<TypeExpr>)>(ctors) array<string>(derives)` |
| 0x04 | `SSuberror(Bool, String, Array[(String, Array[TypeExpr])])` | `bool(exported) string(name) array<(string, array<TypeExpr>)>(ctors)` |
| 0x05 | `SStruct(Bool, String, Array[(String, TypeExpr)], Array[String], Array[String], Array[String])` | `bool(exported) string(name) array<(string, TypeExpr)>(fields) array<string>(derives) array<string>(mut_fields) array<string>(type_params)` |
| 0x06 | `STypeAlias(Bool, String, Array[String], TypeExpr)` | `bool(exported) string(name) array<string>(type_params) TypeExpr(target)` |
| 0x07 | `STrait(Bool, String, Array[String], Array[(String, Array[TypeExpr], TypeExpr)], Array[(String, Array[String], Array[(String, Array[String])])], Array[String])` | `bool(exported) string(name) array<string>(supers) array<(string, array<TypeExpr>, TypeExpr)>(methods) array<(string, array<string>, array<(string, array<string>)>)>(method_generics) array<string>(header_params)` |
| 0x08 | `SImpl(Array[String], Array[(String, Array[String])], String, TypeExpr)` | `array<string>(type_params) array<(string, array<string>)>(bounds) string(trait_name) TypeExpr(target)` |
| 0x09 | `SExternLet(String, TypeExpr)` | `string(name) TypeExpr(ty)` |
| 0x0A | `SImport(String, Array[ImportItem])` | `string(source) array<ImportItem>(items)` |
| 0x0B | `STest(String, Expr)` | `string(name) Expr(body)` |
| 0x0C | `SBench(String, Expr)` | `string(name) Expr(body)` |
| 0x0D | `SExample(String, Expr)` | `string(name) Expr(body)` |
| 0x0E | `SExpr(Expr)` | `Expr(value)` |
| 0x0F | `SExport(Array[String])` | `array<string>(names)` |
| 0x10 | `SReExport(String, Array[ImportItem])` | `string(source) array<ImportItem>(items)` |
| 0x11 | `SAliasDecl(String, String)` | `string(alias) string(source)` |
| 0x12 | `SReExportSourceBoundary(Array[String], Array[String])` | `array<string>(local_spellings) array<string>(publication_only)` |
| 0x13 | `SQualifiedPatternRefs(Array[(String, String)])` | `array<(string, string)>(qualifier_variant_pairs)` |
| 0x14 | `STestEffectRows(Array[(String, String)])` | `array<(string, string)>(test_name_row_pairs)` |
| 0x15 | `SLetPat(Pat, Expr)` | `Pat(pat) Expr(value)` |
| 0x16 | `SModule(Bool, String, Array[Stmt])` | `bool(exported) string(name) array<Stmt>(body)` |
| 0x17 | `SEffectDef(Bool, String, Array[String], Array[(String, Array[TypeExpr], TypeExpr)])` | `bool(exported) string(name) array<string>(type_params) array<(string, array<TypeExpr>, TypeExpr)>(ops)` |
| 0x18 | `SEffectSet(Bool, String, Array[String])` | `bool(exported) string(name) array<string>(members)` |
| 0x19 | `SResource(String, String)` | `string(name) string(kind_path)` |
| 0x1A | `SFnDecl(Bool, String, Expr, Array[Expr], Array[Expr])` | `bool(exported) string(name) Expr(fn_value) array<Expr>(requires) array<Expr>(ensures)` |

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

## Conformance

`lib/@vibe/compiler/tests/ast_binary_test.vibe` covers the primitive
encodings (`varint`, `svarint`, `bool`, `string`, `optstr`, `span`,
`header`) with canonical-byte and roundtrip checks, plus a canonical
byte sequence for the empty module (header + `array_count varint(0)`).

`lib/@vibe/compiler/tests/ast_binary_type_expr_test.vibe` covers
`TypeExpr`: canonical bytes for each of the five tags, roundtrips
through nesting, and the unknown-tag / truncated-input rejections.

The `Pat` / `Expr` / `Stmt` encoders are not written yet; `Pat` and
`Expr` additionally wait on the `f64` read primitive (#2651). Coverage
for them lands with them.

Whenever a new variant is added:

1. Pick the next unused tag in the relevant table above and update
   this document **first**.
2. Extend the matching test file to cover it.
3. Update the writer and the reader in lock-step.
4. Bump the file version (`+1`) only if existing payloads change
   shape; pure additions don't require a version bump (the unknown-tag
   error already protects older readers).
