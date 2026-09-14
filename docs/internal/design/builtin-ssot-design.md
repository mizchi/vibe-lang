# Builtin Single Source of Truth (SSoT) Design

## 問題

ビルトイン関数の型シグネチャが以下の場所に散在・重複している:

| 場所 | 役割 | 形式 |
|------|------|------|
| `src/checker/typecheck_call_builtin_handler_*.mbt` | Host checker | MoonBit match arm |
| `src/checker/prelude.mbt` | Host prelude source | vibe source 文字列 |
| `src/checker/builtin_modules.mbt` | Host module builtins | vibe source 文字列 |
| `src/codegen/wasm_codegen_call_builtin_pre_user.mbt` | Host codegen | WASM emit |
| `lib/@vibe/compiler/checker/builtins_*.vibe` | Selfhost checker | vibe 関数 |
| `lib/@vibe/compiler/codegen/*/builtin_bodies*.vibe` | Selfhost codegen | vibe 関数 |

host と selfhost で同じシグネチャを別々に管理しており、不一致が頻発。

## 設計: コンパイル時生成 + バイナリ中間表現

### 原則

1. **declarations.vibe が SSoT** (人間が編集する唯一の場所)
2. **ビルド時にバイナリテーブルに変換** (ランタイムでテキストパースしない)
3. **バイナリテーブルは WASM data section に埋め込み可能** なコンパクトさ

### パイプライン

```
declarations.vibe  (SSoT, 人間が編集)
       │
       ▼ ビルド時 (moon build / vibe build)
  builtin_table.bin  (バイナリ中間表現)
       │
       ├──▶ Host checker: MoonBit が Bytes として読み込み
       ├──▶ Selfhost checker: vibe が Bytes として読み込み
       └──▶ CI: 契約検証 (host == selfhost == declarations)
```

### declarations.vibe 構文

```vibe skip
// doctest-skip: design sketch: the syntax below is not implemented
// lib/@vibe/compiler/builtins/declarations.vibe

//# Array
declare Array::new() -> Array[T]
declare Array::get(Array[T], Int) -> T
declare Array::push(Array[T], T) -> Array[T]
declare Array::map(Array[T], (T) -> U) -> Array[U]
declare Array::find_index(Array[T], (T) -> Bool) -> Option[Int]

//# String
declare String::length(String) -> Int
declare String::split(String, String) -> Array[String]
declare String::equals(String, String) -> Bool

//# Set
declare Set::new() -> Set[T]
declare Set::add(Set[T], T) -> Set[T]
declare Set::contains(Set[T], T) -> Bool
```

### バイナリテーブル形式

コンパクトで WASM 上でも高速にデコードできるフラットバイナリ:

```
Header:
  magic: "VBLT" (4 bytes)
  version: u8
  count: LEB128  (エントリ数)

Entry (繰り返し):
  name_len: LEB128
  name: UTF-8 bytes  (例: "Array::get")
  param_count: LEB128
  params: [TypeTag]  (各 1 byte)
  ret: TypeTag       (1 byte)
  flags: u8          (has_effects, is_generic, ...)

TypeTag (1 byte):
  0x00 = Unit
  0x01 = Int
  0x02 = Bool
  0x03 = String
  0x04 = Double
  0x05 = Float
  0x06 = Bytes
  0x07 = Char
  0x08 = Path
  0x10 = Array[T]    (次の1バイトが要素型)
  0x11 = Map[K,V]    (次の2バイト)
  0x12 = Set[T]      (次の1バイト)
  0x13 = Option[T]   (次の1バイト)
  0x14 = Result[T,E] (次の2バイト)
  0x20 = Fn(...)     (param_count + params + ret)
  0xF0 = T (generic type var 0)
  0xF1 = U (generic type var 1)
  0xF2 = V (generic type var 2)
  0xFF = Unknown
```

### サイズ見積もり

典型的なエントリ: `Array::get(Array[T], Int) -> T`
- name: 10 bytes + 1 (len)
- params: 1 (count) + 2 (Array[T]) + 1 (Int) = 4
- ret: 1 (T)
- flags: 1
- total: ~17 bytes

100 builtins × ~20 bytes = **~2KB** (data section に余裕で収まる)

### デコーダー (vibe 実装, ~50行)

```vibe skip
// doctest-skip: design sketch: the syntax below is not implemented
let decode_builtin_table = (bytes: Bytes) -> Array[BuiltinDecl] {
  let pos = [4]  // skip magic
  let version = Bytes::get(bytes, Array::get(pos, 0))
  pos[0] = pos[0] + 1
  let count = decode_leb128(bytes, pos)
  let result = Array::new()
  let mut i = 0
  while i < count {
    let name_len = decode_leb128(bytes, pos)
    let name = Bytes::to_string(bytes, Array::get(pos, 0), name_len)
    pos[0] = pos[0] + name_len
    let param_count = decode_leb128(bytes, pos)
    let params = Array::new()
    let mut j = 0
    while j < param_count {
      Array::push(params, decode_type_tag(bytes, pos))
      j = j + 1
    }
    let ret = decode_type_tag(bytes, pos)
    let flags = Bytes::get(bytes, Array::get(pos, 0))
    pos[0] = pos[0] + 1
    Array::push(result, { name, params, ret, flags })
    i = i + 1
  }
  result
}
```

### Host 側のデコーダー (MoonBit, ~50行)

同じバイナリ形式を MoonBit の `Bytes` で読む。
host checker の起動時に1回デコードし、`Map[String, BuiltinDecl]` をキャッシュ。

### Codegen との関係

codegen (WASM emit) はシグネチャに依存しない — name → emit handler のマッピングだけ。
ただし **シグネチャ検証** として:
- CI で `codegen handler の name set ⊇ declarations の name set` を検証
- 新しい declare を追加したら codegen handler が必要 (テストで検出)

### 段階的移行

| Phase | 内容 | オーバーヘッド |
|-------|------|---------------|
| Phase 0 | declarations.vibe + バイナリエンコーダー | ビルド時のみ |
| Phase 1 | Host checker が bin から読み込み | 起動時 ~2KB decode (< 1ms) |
| Phase 2 | Selfhost checker が同じ bin から読み込み | 同上 |
| Phase 3 | 既存の手書き builtins_*.vibe を自動生成に置換 | ゼロ |
| Phase 4 | CI で host/selfhost/declarations の契約検証 | CI のみ |

### ランタイムオーバーヘッド

- **テーブルサイズ**: ~2KB (100 builtins)
- **デコード**: LEB128 + 固定バイト読み取り、O(n) で n = builtin 数
- **lookup**: デコード後は `Map[String, BuiltinDecl]` で O(1)
- **WASM data section**: 2KB は WASM バイナリの 0.01% 以下
- **ゼロコピー可能**: data section pointer から直接読む場合、alloc 不要

### 契約検証: 未注入ビルトインの検出

#### コンパイル時検証 (checker)

checker が builtin_table をロードした時点で、codegen が提供する handler set と
突合し、**宣言されているが handler がない** builtin を警告する:

```
warning: builtin 'Set::from_array' declared but no codegen handler registered
  → compiled backend では呼び出し時に runtime error になります
```

これにより「型チェックは通るが実行時に落ちる」パターンを防ぐ。

#### 実装

```vibe skip
// doctest-skip: design sketch: the syntax below is not implemented
// checker 起動時
let declared = decode_builtin_table(builtin_table_bytes)
let registered = codegen_handler_names()  // codegen が提供する name set

for decl in declared {
  if not(Set::contains(registered, decl.name)) {
    emit_warning("builtin '" + decl.name + "' declared but no codegen handler")
  }
}
```

#### 3段階の厳格度

| レベル | 動作 | 用途 |
|--------|------|------|
| `warn` (default) | 警告を出すが型チェックは通す | 開発中、段階的追加 |
| `error` | 型チェックエラーにする | CI / release build |
| `ignore` | 何もしない | テスト / 実験 |

`vibe check --builtin-contract=error` で CI gate として使用。

#### ランタイムフォールバック

codegen handler がない builtin が実際に呼ばれた場合:

1. **compiled backend**: WASM import `vibe.builtin_missing` を生成
   → runner が trap message で builtin 名を報告
2. **eval backend**: `raise EvalError::MissingBuiltin(name)` で明確なエラー

```
runtime error: builtin 'Set::from_array' called but not implemented
  in compiled backend. Add codegen handler or use eval backend.
```

#### CI gate

```bash
# justfile
check-builtin-contract:
    vibe check --builtin-contract=error examples/basics.vibe
```

declarations の全 builtin が codegen handler を持つことを保証。
新しい `declare` を追加したら、handler 追加まで CI が fail。

### 代替案: なぜテキストパースではないか

| | テキスト (.vibe) | バイナリ (.bin) |
|---|---|---|
| パースコスト | 文字列分割 + 型パーサー | LEB128 + 固定 offset |
| サイズ | ~5KB | ~2KB |
| エラー耐性 | パースエラーの可能性 | 形式が固定、壊れにくい |
| WASM 互換 | String 操作が重い | Bytes 操作で完結 |
| 依存 | vibe parser が必要 | 50行のデコーダーのみ |
