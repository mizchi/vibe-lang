# ADR-0041: _start エントリポイントの型制約と副作用宣言

- Date: 2026-03-31
- Status: proposed

## Context

### エントリポイントの現状

eb9e94b2 で `export let run` 特例を廃止し、core WASM のエントリポイントを `export let _start` に統一した。しかし以下の問題が残っている:

1. **戻り値型が不定**: `_start` の型に制約がなく、`() -> Int`、`() -> String`、`() -> Unit` など任意の型が許される
2. **WASI 非準拠**: WASI の `_start` は `() -> ()` だが、現在は tagged Int (i64) を返す
3. **副作用が暗黙的**: プログラムが使う WASI capability は AST スキャンで自動検出されるが、ユーザーが意図的に宣言する手段がない

### エフェクトシステムとの接続

vibe は既に完全なエフェクトシステムを持つ:

- `with { Stdout, Fs, Error }` で関数の副作用を宣言
- checker が宣言と実際の使用を照合し、不一致をエラーにする
- component codegen が副作用から WASI import を自動導出

`_start` のエフェクト宣言を義務化すれば、プログラム全体の capability が型レベルで明示される。

## Decision

### 1. `_start` の戻り値型を `Unit` に制限する

```
// OK
export let _start = () -> Unit with { Stdout } {
  Stdout::write_stream("hello\n")
}

// OK (pure)
export let _start = () -> Unit {
  ()
}

// Error: _start must return Unit
export let _start = () -> Int { 42 }
```

**理由**: 
- WASI `_start` は `() -> ()` であり、標準に準拠する
- exit code は戻り値ではなく `proc_exit` (panic / 明示 exit) で制御する
- 戻り値で exit code を返す設計は、エフェクトシステムと相性が悪い（Int を返すだけでは副作用が見えない）

### 2. exit code は panic または明示 exit で制御

```
// 正常終了 (exit code 0)
export let _start = () -> Unit { () }

// エラー終了 (panic → exit code 1)
export let _start = () -> Unit with { Error } {
  panic("something went wrong")
}

// 明示的 exit code (将来: Process::Exit effect)
export let _start = () -> Unit with { Process } {
  Process::exit(42)
}
```

### 3. `_start` のエフェクト宣言がプログラムの capability を定義する

`_start` の `with { ... }` 句がプログラム全体の必要な WASI import のセットとなる:

```
// このプログラムは Stdout と Fs のみ使用
export let _start = () -> Unit with { Stdout, Fs } {
  let content = Fs::read_file("input.txt")
  Stdout::write_stream(content)
}
```

コンパイラの各段階での活用:

| 段階 | 活用 |
|------|------|
| checker | `_start` の with 句に含まれないエフェクトの使用をエラーにする（既存の仕組みで動作） |
| codegen | `_start` の with 句から WASI import を導出（現在の AST スキャンを置き換えまたは検証に使う） |
| component WIT | `_start` の with 句から `import wasi:...` を生成 |
| security audit | `_start` のシグネチャだけでプログラムの capability が判明 |

### 4. REPL / eval モードは例外

REPL や `vibe eval` は `_start` を定義しない単一式評価モード。このモードでは:
- 最後のトップレベル式の値を返す（従来の動作を維持）
- 戻り値型は任意（Int, String, etc.）
- エフェクトチェックは行わない（全 capability が暗黙許可）

### 5. component ABI との対応

| 層 | 変更 |
|---|---|
| source | `export let _start = () -> Unit with { Effects }` |
| core WASM | `_start: () -> ()` (void) |
| component | `run: func()` (return なし) |
| WIT | effects から import を導出、`export run: func();` |

現在の `export run: func() -> s64;` は `export run: func();` に変更。

## Implementation Plan

### Phase 1: 戻り値型の制約 (checker)

- checker で `_start` の戻り値型が `Unit` でなければ `TypeError` を出す
- `ensure_run_ast_result` を修正: `_start()` 呼び出しの戻り値を捨てる
- core WASM の `_start` シグネチャを `() -> ()` に変更

### Phase 2: component ABI の更新

- component WIT の `export run: func() -> s64;` → `export run: func();`
- trampoline module の return 処理を削除
- component codegen の lift/lower を更新

### Phase 3: エフェクト駆動の import 導出 (optional)

- 現在の AST スキャンによる自動検出を、`_start` のエフェクト宣言と照合
- 宣言と検出の不一致を warning → 将来的に error
- `Process::exit(code)` effect の追加

## Consequences

### Good

- **WASI 標準準拠**: `_start: () -> ()` は WASI 仕様そのもの
- **Capability の可視化**: `_start` のシグネチャだけでプログラムの副作用が判明
- **型安全性**: 意図しない副作用はコンパイルエラーになる
- **Security**: effect 宣言が capability-based security のベースになる

### Bad

- **REPL との非対称性**: REPL は暗黙許可、`_start` は明示宣言。二つのモードが存在する
- **既存コードの破壊**: `export let _start = () -> Int { ... }` を使う既存コードが壊れる
- **exit code の間接化**: `return 1` ではなく `Process::exit(1)` が必要（やや冗長）

### Neutral

- component codegen の import 自動検出は当面残す（エフェクト宣言と二重になるが、移行期間として必要）
