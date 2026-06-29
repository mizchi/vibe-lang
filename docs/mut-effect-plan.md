# Mut Effect Handler 実装計画

ADR: [ADR-0021](adr.md), [ADR-0050](archive/adr/0050-unify-handle-as-generic-effect-handler.md)

## 仕様固定

`handle` の public surface は ADR-0050 で先に固定する。
この文書は、その frozen surface に到達するための staged implementation plan として扱う。

固定済みの前提:

- canonical syntax は `handle { expr } with EffectName { Op(...) => expr; }`
- `Error` は built-in effect の一種として扱う
- 旧 bare-arm 版 `handle` は移行期間なしで廃止する
- arm は `match` 相当の pattern / or-pattern / guard を許可する
- arm 区切りは `;` のみ
- `resume` は one-shot / lexical-scope 限定
- 1 つの `handle` が消す effect は 1 個のみ。複数 effect は nested handle で表現する

## 現状分析

### 現在のエフェクトシステム

- `EHandle(Expr, Array[(Pat, Expr)])` — パターンマッチ付きの汎用 handle 式。
  `Error(_)` だけでなく enum コンストラクタ (`Ask(_)`, `Log(_)` 等) も使用可能
- `EThrow(Expr)` — throw で Error を送出
- `EFn` の第5フィールド `Option[String]` — エフェクト注釈 (`with { Error }` 等)
- エフェクトチェッカー (`checker_effects.vibe`) は `in_effect: Bool` フラグのみで、
  エフェクト名の区別なし
- WASM codegen (`codegen_expr.vibe:1047`) では `EHandle(body, _)` = body をそのまま
  compile（ハンドラ arms 無視）
- eval (`eval.vibe:1326`) では Error catch として実行
- `perform`/`resume` は `examples/perform_handle.vibe` でも canonical syntax
  (`perform Ask::Ask(41)`, `resume(42)`) を使う。旧 `perform(Ask(41))`
  は互換入力に限定する

### 不足している機能

1. ユーザー定義エフェクト宣言 (`effect Mut<T> { ... }`)
2. 旧 `perform(...)` 互換入力の整理（canonical syntax へ移行済み、
   互換入力の扱いは段階的に縮小）
3. エフェクト型の追跡（`Bool` ではなくエフェクトセット）
4. ハンドラによるエフェクト消去の型検査
5. ADR-0050 canonical syntax への移行
   (`handle { ... } with EffectName { ... }`、旧構文廃止、single-effect handle)

### 設計上の注意: `perform`/`resume` の構文選択

現在の `examples/perform_handle.vibe` は `effect Ask { Ask(Int) -> Int }` と
`perform Ask::Ask(41)` の組み合わせに揃えている。関数呼び出し構文の
`perform(Ask(41))` は legacy 互換入力として残すが、仕様・docs・examples では
canonical syntax を使う。

- 互換形式: `perform(Ask(41))` — legacy compatibility only
- canonical: `perform Ask::Ask(41)` — effect と operation を直接指定

---

## Phase 0: 設計の制約と方針

### コンパイル戦略

vibe は WASM ターゲットであり、一般的な delimited continuation の実装（CPS 変換、stack switching）は避ける。
代わりに **tail-resumptive handler のみを Phase 1 でサポート**し、inline 化によりゼロコスト化する。

**tail-resumptive handler** の定義:
ハンドラ節が `resume(expr)` を末尾で 1 回だけ呼ぶパターン。

```
// tail-resumptive (OK)
push(v) -> { buf.push(v); resume(()) }

// NON tail-resumptive (Phase 1 では非サポート)
choose() -> { resume(true); resume(false) }  // multi-shot
get() -> { let v = state; resume(v) }         // OK (これも tail-resumptive)
```

### Scope

- Phase 1: tail-resumptive のみ → inline 化 → ランタイムコストゼロ
- Phase 2: single-shot non-tail-resumptive → CPS or stack switching (ADR-0012)
- Phase 3: multi-shot → 将来検討

ADR-0050 の stable contract は one-shot handler 全体を対象とするが、
実装は tail-resumptive から段階導入する。

### 継続呼び出し規約: `resume` (canonical) vs 明示 `k` (#627)

fixtures 上、ハンドラ arm の継続呼び出しに 2 つの表記が存在する。両者は
**競合する別規約ではなく、同一の one-shot 継続の 2 つの書き方**であり、
canonical は `resume` である (ADR-0050)。

1. **暗黙 `resume(v)` — canonical。** `perform` 地点の継続を暗黙に指す。
   実装は **replay-based handler**: `handle` body を再実行し、各 `perform` に
   対し resume-memo slot から記憶済みの値を返す (`compile_call.vibe` の
   `resume` magic + `linked_compile.vibe` の resume-memo 配列、ストライド
   `131072`)。tail position で 1 回だけ呼ぶ tail-resumptive 形は inline 化で
   ゼロコスト。これが仕様・docs・examples の既定形。

   ```
   Log(msg) => { stdout_write(msg); resume(()) }   // tail-resumptive
   ```

2. **明示 `Op(args..., k)` — 一般形 (defunctionalized)。** arm が
   operation の宣言 arity より 1 つ多い末尾パラメータを束縛すると、それが
   継続 `k` になる。`resume` が末尾でしか呼べない (tail-only) のに対し、
   `k` は **non-tail position で結果を使える** (`v + k(0)` のように畳み込める)。
   `fixtures/effect_cps_*.vibe` / `effect_defunc_*.vibe` / `effect_generic_writer.vibe`
   がこの形を使う。これらは defunctionalized 継続として実装され、現状は
   `resume` と同じく **one-shot** (継続を 1 回呼ぶ) に限る。

   ```
   Emit(v, k) => v + k(0)    // k を non-tail で 1 回呼ぶ — resume では書けない
   ```

**線引き (現状の規約):**
- canonical な継続呼び出しは `resume`。新規コード・docs・examples は `resume` を使う。
- 明示 `k` は「継続の結果を non-tail で使いたい」場合の一般形として残すが、
  どちらも one-shot。**multi-shot (`k` を複数回呼ぶ) は未サポート** (Phase 3 将来検討)。
  replay-based handler は unbounded perform でストライドを溢れさせるため、
  真の first-class / multi-shot continuation はこの軸では扱わない。
- tail-resumptive 検出 (Step 4) の対象は `resume` 末尾 1 回呼びパターン。

### 領域つき書き込み capability モデル (ADR-0060 / #629)

可変性は「領域 (region) でパラメータ化した書き込みエフェクト」`Write[r]` の
一機構で統一説明する（採否判断は ADR-0060）。脱糖規則:

```
// 局所 mut は「新しい領域 r0 を導入し、Write[r0] を束縛点で即設置・即 discharge」
// する糖衣とみなす。Write[r0] はブロック内で完全に消化されるため、
// 関数の公開エフェクト行には現れない（= 局所 mut は capability 不要に見える）。
let mut x = e0; <body>
  ≡  handle {
       // x への書き込み x = v は perform Write[r0]::set(x, v) として解釈
       <body>
     } with Write[r0] { set(cell, v) => /* in-place 更新 */ resume(()) }
```

- **局所性 = 領域の閉包**: ADR-0017 の「escape 不可」は「region `r0` が束縛点を
  scope-out すると無効」という region 規律で正当化される。`Write[r0]` ハンドラは
  束縛点で即設置・即 discharge されるため、`r0` を参照する書き込み権限は
  ブロックの外へ持ち出せない。
- **跨スコープ書き込み**: 外側 mut を書き換える関数は領域権限を公開行
  `... with { Write[router] }` に宣言し、その mut を所有しハンドラを設置した側
  だけが grant する。権限を持たない関数は行に `Write[r]` が無く型レベルで書込不能。
- **アンビエント状態**: host/global の真にアンビエントな状態は `#import` 付き
  外部エフェクト（Phase 2）としてビルトインが grant する。これが issue の言う
  「ビルトインとして与える権限」に対応。
- **#418 escape ↔ region 対応**: ADR-0052 `mut` field を持つ struct への参照が
  関数戻り値 / クロージャ捕捉 / async・spawn 越しに保持される escape 検査は、
  「領域 `r` が所有スコープを脱出していないこと」の検査として再定式化する。
  Effekt の second-class capability（値は first-class、capability は領域外へ
  持ち出せない）が参照実装で、#418 の escape analysis をこの規律として
  読み替えられる。
- 実装は後続。前提 #626（effect 変数の真の単一化・effect row 正規化）は
  解決済み (closed 2026-06-27) なので、領域 `r` を row 変数の一種として
  単一化に載せる足場はある。本節は採用モデルと脱糖・escape 対応の記録で、
  `Write[r]` lowering / region 推論の実装は別作業。

---

## Phase 1: Tail-Resumptive Effect Handler

### Step 1: AST 拡張

```
// ast.vibe に追加

// エフェクト宣言（トップレベル）
SEffect(Bool, String, Array[TypeExpr], Array[EffectOp])
//       pub   name   type_params      operations

// エフェクト操作
EffectOp(String, Array[(String, TypeExpr)], TypeExpr)
//       name    params                     return_type

// 式の追加
EPerform(String, Array[Expr])   // perform push(1)
EResume(Expr)                   // resume(value)  — ハンドラ節内のみ

// EHandle の拡張
// 現在: EHandle(Expr, Array[(Pat, Expr)])
// 拡張: EHandleEffect(Expr, String, Array[(String, Array[String], Expr)])
//                      body  effect_name  [(op_name, param_names, handler_body)]
```

### Step 2: 構文

```
// エフェクト宣言
effect Mut<T> {
  push(value: T) -> Unit
  build() -> Array<T>
}

// ハンドラ付き handle（ADR-0050 canonical syntax）
let xs = handle {
  perform push(1)
  perform push(2)
  perform build()
} with Mut<Int> {
  let buf = @array.new()
  push(v) => { buf.push(v); resume(()) };
  build() => { resume(buf.to_array()) };
}

// Error も通常 effect として扱う
handle { throw("err") } with Error {
  Throw(msg) => msg;
}
```

**パーサー変更点**:
- `effect` キーワードをトップレベル宣言として追加
- `perform` キーワードを式として追加
- `handle { ... } with EffectName { ... }` を canonical syntax として実装
- 旧 bare-arm 版 `handle` は parser error にする

### Step 3: 型チェック

`checker_effects.vibe` を拡張:

```
// 現在
in_effect: Bool

// 拡張: エフェクトセット
EffectSet = Array[String]  // ["Error", "Mut", "IO"]

// チェックルール:
// 1. perform op(args) → op が属するエフェクト E を解決
//    → 現在のコンテキストに E が含まれるか検査
// 2. handle { body } with E { ... }
//    → body は E をエフェクトセットに追加して検査
//    → handle 全体の型からは E を除去
// 3. resume(v) はハンドラ節の中でのみ使用可能
// 4. with E の arm は exhaustive である必要がある
// 5. resume は one-shot / lexical scope 限定
```

**エフェクト脱出検査** (ADR-0021 の核心):
```
// handle の戻り値型に E が残っていたらエラー
// → クロージャの型が with { Mut } を含むなら、handle の外に返せない
handle {
  let f: () -> Unit with { Mut } = () -> { perform push(1) }
  f  // ERROR: unhandled effect Mut in return type
} with Mut { ... }
```

### Step 4: Tail-Resumptive 検出

コンパイラパスとして `detect_tail_resumptive` を追加:

```
is_tail_resumptive(handler_body: Expr) -> Bool {
  // handler_body の末尾が EResume(expr) であること
  // handler_body 内に EResume が 1 箇所のみであること
  match handler_body {
    EResume(_) => true,
    ESeq(_, EResume(_)) => true,
    ELet(_, _, EResume(_)) => true,
    ELet(_, _, ESeq(_, EResume(_))) => true,
    _ => false
  }
}
```

Phase 1 では非 tail-resumptive を検出したらコンパイルエラー:
```
error: non-tail-resumptive handler is not supported yet
  --> file.vibe:10:3
   | choose() -> { resume(true); resume(false) }
   |              ^^^^^^^^^^^^^^ second resume not allowed
```

### Step 5: WASM Codegen — Inline 化

**核心の最適化**: tail-resumptive handler を通常の関数呼び出しに変換する。

変換前 (AST):
```
handle {
  perform push(1)
  perform push(2)
  perform build()
} with Mut<Int> {
  let buf = @array.new()
  push(v) -> { buf.push(v); resume(()) }
  build() -> { resume(buf.to_array()) }
}
```

変換後 (脱糖 AST, codegen 直前):
```
// ハンドラの状態初期化をブロック先頭に展開
let buf = @array.new()
// perform push(1) → handler body を inline 展開 (resume を除去)
let v$0 = 1
buf.push(v$0)    // resume(()) の () が継続の結果
// perform push(2) → 同様に inline 展開
let v$1 = 2
buf.push(v$1)
// perform build() → 同様に inline 展開
buf.to_array()   // resume(buf.to_array()) の buf.to_array() が最終結果
```

**codegen_expr.vibe での実装**:

```
EHandleEffect(body, effect_name, handlers) => {
  // 1. 全 handler が tail-resumptive か検証（Step 4 で済み）
  // 2. handler の初期化コード（let buf = ... 等）をコンパイル
  //    → 通常の let として local_names に追加
  // 3. body 内の EPerform を走査し、対応する handler body で置換
  //    → EResume(v) は v の値そのものに置換（継続 = 次の式）
  // 4. 置換後の body を compile_expr で通常コンパイル
  compile_expr(buf, inlined_body, local_names, next_local, ctx, ld)
}
```

具体的な WASM 出力:
```wasm
;; handle { perform push(1); perform push(2); perform build() }
;; with Mut<Int> { let buf = ...; push(v) -> ...; build() -> ... }

;; ハンドラ状態初期化
call $array_new          ;; buf = @array.new()
local.set $buf

;; perform push(1) → inline
i64.const 1              ;; v = 1
local.set $v
local.get $buf
local.get $v
call $array_push         ;; buf.push(v)
drop                     ;; resume(()) → Unit を消費

;; perform push(2) → inline
i64.const 2
local.set $v
local.get $buf
local.get $v
call $array_push
drop

;; perform build() → inline
local.get $buf
call $array_to_array     ;; resume(buf.to_array()) → 最終値
```

### Step 6: Eval インタプリタ

```
// eval.vibe の EHandleEffect
EHandleEffect(body, effect_name, handlers) => {
  // ハンドラ環境を構築
  let handler_env = eval_handler_init(handlers, env)
  // body を評価（perform 時に handler を呼び出す）
  eval_with_handlers(body, handler_env, handlers)
}

// perform の評価
EPerform(op_name, args) => {
  // 現在のハンドラスタックから op_name を探す
  // handler body を評価（resume = 継続に値を返す）
  let handler = find_handler(op_name, handler_stack)
  eval_handler_op(handler, args, continuation)
}
```

---

## Phase 2: Component Model 統合

### 概要

エフェクト宣言に `#import` ディレクティブを付与し、Component Model の名前空間にバインドする。
WASI に限定せず、任意の Component Model インターフェースに対応する。

### Step 1: `#import` ディレクティブ構文

```
// 構文: #import("<namespace>:<package>/<interface>@<version>")
// version は省略可能

#import("wasi:filesystem/read@0.2.0")
effect Fs {
  read_file(path: String) -> String
  write_file(path: String, content: String) -> Unit
}

#import("wasi:cli/stdio@0.2.0")
effect Console {
  print(msg: String) -> Unit
  read_line() -> String
}

#import("wasi:clocks/wall-clock@0.2.0")
effect Clock {
  now() -> Int
}

#import("wasi:sockets/tcp@0.2.0")
effect Tcp {
  connect(host: String, port: Int) -> Int
  send(fd: Int, data: String) -> Unit
  recv(fd: Int) -> String
}

// WASI 以外のカスタムコンポーネント
#import("myorg:auth/session@1.0.0")
effect Auth {
  verify_token(token: String) -> Bool
  get_user_id() -> String
}

#import("myorg:storage/kv@2.0.0")
effect KV {
  get(key: String) -> Option<String>
  set(key: String, value: String) -> Unit
  delete(key: String) -> Unit
}
```

**パーサー変更**:
- `#import("...")` を attribute/directive としてパース
- `SEffect` ノードにオプショナルな `import_path: Option[String]` を追加
- `#import` は `effect` 宣言の直前にのみ出現可能

### Step 2: エフェクトの分類

`#import` の有無でエフェクトを 2 種類に分類:

| 種類 | `#import` | ハンドラ | WASM 出力 |
|------|-----------|---------|-----------|
| **ローカルエフェクト** | なし | 必須（ユーザーが `handle...with` で消化） | inline 化 |
| **外部エフェクト** | あり | オプショナル（テスト用モック） | WASM import |

```
// ローカルエフェクト — ハンドラで消化される
effect Mut<T> { push(value: T) -> Unit }

// 外部エフェクト — WASM import にコンパイルされる
#import("wasi:filesystem/read@0.2.0")
effect Fs { read_file(path: String) -> String }
```

### Step 3: WASM Import 生成

外部エフェクトの `perform` は WASM import 呼び出しにコンパイルされる:

```
// ソース
#import("wasi:filesystem/read@0.2.0")
effect Fs {
  read_file(path: String) -> String
}

let main: () -> Unit with { Fs } = () -> {
  let content = perform read_file("hello.txt")
  print(content)
}
```

```wasm
;; WASM 出力
(module
  ;; #import から生成される import section
  (import "wasi:filesystem/read@0.2.0" "read-file"
    (func $fs_read_file (param i64) (result i64)))

  ;; perform read_file("hello.txt") → 直接 import 呼び出し
  (func $main
    i64.const ...        ;; "hello.txt"
    call $fs_read_file   ;; perform → direct import call
    call $print
  )
)
```

**tail-resumptive inline 化との関係**:
外部エフェクトの `perform` は、ハンドラ不要で直接 import 呼び出しにコンパイルされる。
これは tail-resumptive inline 化の特殊ケース（ハンドラ本体 = import 関数呼び出し）と
見なせるため、同じコンパイルパイプラインで処理できる。

### Step 4: World 自動導出

export 関数のエフェクトセットを集約し、Component Model の world を自動導出する:

```
// ソース
#import("wasi:filesystem/read@0.2.0")
effect Fs { ... }

#import("wasi:cli/stdio@0.2.0")
effect Console { ... }

export let main: () -> Unit with { Fs, Console } = () -> { ... }
```

コンパイラが以下の WIT world 相当を自動導出:

```wit
// 自動生成される world
world my-app {
  import wasi:filesystem/read@0.2.0
  import wasi:cli/stdio@0.2.0
  export run: func()
}
```

これにより:
- `vibe compile --component` 時に WIT ファイルの手書きが不要
- エフェクトの追加/削除が world 定義に自動反映
- リンク時に不足する import があればコンパイルエラー

### Step 5: テスト時のモックハンドラ

外部エフェクトもハンドラで差し替え可能:

```
// テスト: Fs エフェクトをモックで差し替え
test "read file" {
  let result = handle {
    process_file("config.json")
  } with Fs {
    read_file(path) -> {
      resume("{\"key\": \"value\"}")
    }
    write_file(path, content) -> {
      // 書き込みは何もしない
      resume(())
    }
  }
  assert(String::equals(result, "value"))
}
```

コンパイラの処理:
- `handle ... with Fs { ... }` が存在する → WASM import ではなくハンドラを使用
- ハンドラが tail-resumptive → inline 化
- テストバイナリは `wasi:filesystem` import なしでも動作可能

### Step 6: 操作名と Component Model 関数名のマッピング

Component Model の関数名は kebab-case (`read-file`)、vibe は snake_case (`read_file`)。
デフォルトで snake_case → kebab-case 変換を適用し、明示指定も可能にする:

```
#import("wasi:filesystem/read@0.2.0")
effect Fs {
  read_file(path: String) -> String           // → "read-file"
  #name("directory-list")
  list_dir(path: String) -> Array<String>     // → "directory-list" (明示)
}
```

---

## Phase 3: 標準ライブラリのエフェクト定義

### 組み込みエフェクト

```
// 既存の Error は暗黙的エフェクトとして維持
// 新規エフェクトを std として提供

effect State<T> {
  get() -> T
  set(value: T) -> Unit
}

effect Collect<T> {
  emit(value: T) -> Unit
}

// Console は #import 付きの外部エフェクト
#import("wasi:cli/stdio@0.2.0")
effect Console {
  print(msg: String) -> Unit
  read_line() -> String
}
```

### WASI エフェクトの標準バンドル

```
// std/wasi.vibe — WASI Preview 2 のエフェクト定義集

#import("wasi:filesystem/preopens@0.2.0")
effect FsPreopens {
  get_directories() -> Array<(Int, String)>
}

#import("wasi:filesystem/types@0.2.0")
effect FsTypes {
  read_file(path: String) -> String
  write_file(path: String, content: String) -> Unit
  stat(path: String) -> FileStat
}

#import("wasi:cli/environment@0.2.0")
effect Env {
  get(key: String) -> Option<String>
  args() -> Array<String>
}

#import("wasi:http/outgoing-handler@0.2.0")
effect Http {
  request(method: String, url: String, body: String) -> HttpResponse
}

#import("wasi:clocks/monotonic-clock@0.2.0")
effect MonotonicClock {
  now() -> Int
  resolution() -> Int
}
```

### ビルダーパターンのライブラリ化

```
// std/builder.vibe — ローカルエフェクト（#import なし）
effect ArrayBuild<T> {
  push(value: T) -> Unit
}

let build_array = <T>(f: () -> Unit with { ArrayBuild<T> }) -> Array<T> {
  handle { f(); [] } with ArrayBuild<T> {
    let buf = @array.new()
    push(v) -> { buf.push(v); resume(()) }
  }
}

let xs = build_array<Int>(() -> Unit with { ArrayBuild<Int> } {
  perform push(1)
  perform push(2)
  perform push(3)
})
// xs = [1, 2, 3]
```

---

## Phase 4: Non-Tail-Resumptive (将来)

WASM stack switching (ADR-0012) が利用可能になった段階で:

- single-shot delimited continuation
- `Async` エフェクト (`await`/`yield`)
- Generator パターン

---

## 実装順序

| Step | Phase | 内容 | 変更ファイル | 依存 |
|------|-------|------|-------------|------|
| 1 | P1 | AST ノード追加 | `ast.vibe` | - |
| 2 | P1 | パーサー: `effect` 宣言 | `parser.vibe`, `cst.vibe`, `lower.vibe` | Step 1 |
| 3 | P1 | パーサー: `perform`, `handle...with` | `parser.vibe`, `cst.vibe`, `lower.vibe` | Step 1 |
| 4 | P1 | Printer: 新ノードの出力 | `printer.vibe` | Step 1 |
| 5 | P1 | Eval: インタプリタ対応 | `eval.vibe` | Step 1-3 |
| 6 | P1 | Checker: エフェクトセット拡張 | `checker_effects.vibe` | Step 1-3 |
| 7 | P1 | Tail-resumptive 検出 | `checker_effects.vibe` (新) | Step 1 |
| 8 | P1 | Codegen: inline 化変換 | `codegen_expr.vibe` | Step 1-7 |
| 9 | P1 | Codegen: WASM 出力 | `codegen_expr.vibe`, `codegen_wasi.vibe` | Step 8 |
| 10 | P1 | E2E テスト | `*_test.vibe` | Step 5 or 9 |
| 11 | P2 | パーサー: `#import` ディレクティブ | `parser.vibe`, `cst.vibe` | Step 2 |
| 12 | P2 | エフェクト分類（ローカル/外部） | `checker_effects.vibe` | Step 6, 11 |
| 13 | P2 | Codegen: 外部エフェクト → WASM import | `codegen_wasi.vibe`, `component_codegen.vibe` | Step 9, 12 |
| 14 | P2 | World 自動導出 | `component_codegen.vibe` | Step 13 |
| 15 | P2 | テスト: モックハンドラ E2E | `*_test.vibe` | Step 13 |
| 16 | P3 | 標準 WASI エフェクト定義 | `std/wasi.vibe` | Step 13 |
| 17 | P3 | ビルダーライブラリ | `std/builder.vibe` | Step 8 |

### マイルストーン

- **M1**: `effect` 宣言が parse → print できる
- **M2**: `perform`/`handle...with` が parse → eval で動作する
- **M3**: エフェクトチェッカーが Mut 脱出を検出する
- **M4**: tail-resumptive handler が WASM にコンパイルされる
- **M5**: `#import` 付きエフェクトが WASM import にコンパイルされる
- **M6**: export 関数から world が自動導出される
- **M7**: テストでモックハンドラが外部エフェクトを差し替えられる
- **M8**: 標準 WASI エフェクト + ビルダーライブラリが使える

---

## リスクと未決事項

1. **`perform` の構文**: `perform push(1)` vs `Mut.push(1)` vs `push(1)` (暗黙 perform)
   - 暗黙 perform はスコープ解決が複雑になる → Phase 1 は明示 `perform` で
2. **ハンドラ初期化コードの表現**: `let buf = ...` をハンドラ本体のどこに書くか
   - 案 A: ハンドラブロックの先頭に自由に書ける
   - 案 B: 専用の `init { ... }` ブロック
   - → Phase 1 は案 A（シンプル）
3. **エフェクトの型パラメータ**: `Mut<T>` の T をどう解決するか
   - Phase 1 は単相（`Mut<Int>` 等、具体型のみ）で開始
4. **旧構文からの移行**: bare-arm 版 `handle` をどう壊すか
   - ADR-0050 に従い、互換期間なしで parser error + migration hint
5. **複数エフェクトの合成**: `handle { } with (Mut<Int>, State<String>) { ... }`
   - ADR-0050 では単一エフェクトのみ。複数は nested handle で表現
6. **`#import` の名前空間解決**:
   - Component Model の interface 名と effect 操作名のマッピング
   - snake_case (vibe) → kebab-case (CM) の自動変換をデフォルトに
   - `#name("explicit-name")` で個別オーバーライド可能
7. **`#import` のバージョン管理**:
   - `@0.2.0` 等のバージョンは Component Model のセマンティクスに準拠
   - 同一 interface の複数バージョンは Phase 2 では非サポート
8. **外部エフェクトの型マッピング**:
   - Component Model の型 (string, list, record 等) と vibe 型の対応
   - Phase 2 は String, Int, Bool, Array, Option のプリミティブのみ
   - record/variant は Phase 3 以降で struct/enum マッピング
9. **外部エフェクトの未ハンドル検出**:
   - `#import` 付きエフェクトが handle されずに export 関数まで伝播 → WASM import 生成（正常）
   - `#import` なしエフェクトが export 関数まで伝播 → コンパイルエラー（ハンドラ不足）
