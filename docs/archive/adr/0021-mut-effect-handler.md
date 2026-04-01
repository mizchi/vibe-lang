# ADR-0021: ミュータビリティを Effect Handler で表現する

- Date: 2026-03-10
- Updated: 2026-03-18 (P3 HTTP effect 具体例追加)
- Status: proposed
- Supersedes: ADR-0017 の Ref[T] 部分 (abandoned。Effect Handler で代替)
- Extends: ADR-0003 (エフェクトセット検証を `Bool` → 名前付きエフェクトセットに拡張)
- Related: ADR-0003 (エフェクトシステム), ADR-0016 (handle 統一構文), ADR-0010 (Component Model)

**詳細実装計画**: [mut-effect-plan.md](../mut-effect-plan.md)

## Context

### 現在の実装状況

- `let mut` は実装済み（ADR-0017 の項目 1）
- `Ref[T]` は ADR-0017 で当初 accepted だったが **abandoned** (本 ADR の Effect Handler で代替)
- `EHandle(Expr, Array[(Pat, Expr)])` は実装済みだが、エフェクト名の区別はなく
  `in_effect: Bool` フラグでの二値チェックのみ
- `perform`/`resume` は `examples/perform_handle.vibe` に関数呼び出し形式の
  サンプルがあるが、**キーワードとしては未実装**（通常の識別子として扱われる）
- `handle` ブロックは `Error(_)` だけでなく enum コンストラクタ (`Ask(_)`,
  `Log(_)` 等) でのパターンマッチが既に動作する

### 課題

`ArrayBuilder` のようなミュータブル参照を外部に渡すと参照透過性が崩れる
懸念がある。ADR-0017 の `Ref[T]` はこれを型レベルで防ぐ意図だったが未実装。

この問題の防止策として検討した選択肢:

1. **rank-2 多相型 + `run_mut` 特殊形式** — Koka/Haskell ST monad 方式。
   スコープパラメータ `forall<h>` で参照の脱出を型レベルで防ぐ。
   汎用 rank-2 推論は決定不能であり、`run_mut` 専用の特殊ルールとして
   型チェッカーに組み込む必要がある。

2. **Effect Handler でミュータブル操作を抽象化** — ミュータブルな状態を
   ハンドラ内部に閉じ込め、ユーザーコードには `perform` のみ公開する。
   参照そのものがユーザーコードに露出しないため、脱出が構造的に不可能。
   既存のエフェクト型消去の仕組みで安全性を保証でき、型システム拡張が不要。

3. **線形型 / 所有権** — Rust 的アプローチ。実装コスト・学習コストともに高い。

## Decision

**選択肢 2: Effect Handler によるミュータビリティ表現を採用する。**

### 設計

ミュータブルな操作を effect として宣言し、`handle` ブロックで状態を閉じ込める:

```
effect Mut<T> {
  push(value: T) -> Unit
  build() -> Array<T>
}

let xs: Array<Int> = handle {
  perform push(1)
  perform push(2)
  perform build()
} with Mut<Int> {
  let buf = @array.new()
  push(v) -> { buf.push(v); resume(()) }
  build() -> { resume(buf.to_array()) }
}
```

### 安全性の保証

ハンドラ境界で `Mut` エフェクトが消去されるため、`Mut` を含む型は外に出られない:

```
// 型エラー: Mut<Int> エフェクトがハンドラ外に脱出
let bad = handle {
  let f = () -> Unit with { Mut<Int> } { perform push(1) }
  f  // ERROR: unhandled effect Mut<Int> in return type
} with Mut<Int> { ... }
```

これは rank-2 型のスコープ制約と同等の保証を、既存のエフェクト型システムだけで
達成する。ミュータブルな状態（`buf`）はハンドラ実装の内部にのみ存在し、
ユーザーコードからは `perform` 経由でしかアクセスできない。

### `let mut` との関係

`let mut` は ADR-0017 の通り局所可変状態として引き続き許可する。
Effect Handler は `let mut` では表現しにくい以下のケースで使用する:

- ビルダーパターン（状態の蓄積と最終値の生成）
- 複数の協調するミュータブル状態
- ライブラリが提供する抽象的なミュータブル操作

### WASM ターゲットでの最適化: tail-resumptive inline 化

Effect Handler の perform/resume はオーバーヘッドが懸念されるが、
vibe のターゲットは WASM であり、以下の最適化を適用する:

**tail-resumptive handler の検出と inline 化**:
ハンドラ節が `resume(expr)` で即座に返すパターン（tail-resumptive）を検出し、
perform/resume のペアをダイレクトコールに変換する。

```
// 最適化前: perform → handler dispatch → resume → continuation
push(v) -> { buf.push(v); resume(()) }

// 最適化後: inline 化されたダイレクトコール
buf.push(v)  // perform push(v) が直接この呼び出しに置換される
```

上記の `Mut` ハンドラの例では、`push` と `build` の両方が tail-resumptive
であるため、ハンドラ全体がダイレクトコールに最適化される。
結果として、手書きのミュータブルコードと同等の WASM コードが生成される。

この最適化は Koka で実証済みの手法であり、WASM の線形実行モデルと親和性が高い。

### Component Model 統合: エフェクトと WASM Import の統一

エフェクトシステムを Component Model の import/export と統合する。
外部依存（WASI やカスタムコンポーネント）をエフェクトとして宣言し、
`#import` ディレクティブで Component Model の名前空間にバインドする:

```
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

// カスタムコンポーネントも同様
#import("myorg:auth/session@1.0.0")
effect Auth {
  verify_token(token: String) -> Bool
  get_user_id() -> String
}
```

これにより:

1. **型チェック時**: `perform read_file(p)` には `Fs` エフェクトが必要
   → 関数シグネチャの `with { Fs }` で追跡
2. **WASM codegen 時**: `#import` の名前空間から import section を自動生成
3. **Component Model 時**: export 関数のエフェクトセットを集約し、
   world の import を自動導出（ADR-0010 の WIT 自動生成と統合）
4. **テスト時**: `handle ... with Fs { ... }` でモックハンドラを注入可能
   → 外部依存なしでユニットテストが書ける

`#import` を持たないエフェクト（`Mut`, `State` 等）はローカルエフェクトとして
ハンドラで消化される。`#import` を持つエフェクトは最終的に WASM import に
解決されるか、テスト用にハンドラで差し替えられる。

### WASI P3 HTTP の具体例 (2026-03-18)

WASI P3 HTTP を effect + `#import` で表現する設計決定 (Model 1: Full Algebraic Effect)。
Request/Response ともに effect (capability) として扱い、最小権限・テスト容易性・streaming を実現する。

```
// P3 incoming request の読み取り capability
#import("wasi:http/types@0.3.0-rc-2026-02-09")
effect HttpRequest {
  Method -> String;
  Url -> String;
  Header(String) -> Option[String];
  Body -> String
}

// P3 response の書き込み capability
#import("wasi:http/types@0.3.0-rc-2026-02-09")
effect HttpResponse {
  Status(Int) -> Unit;
  Header(String, String) -> Unit;
  Write(String) -> Unit
}

// P3 outbound HTTP client capability
#import("wasi:http/client@0.3.0-rc-2026-02-09")
effect HttpClient {
  Fetch(String, String, String) -> (Int, String)
}
```

**Handler**: 必要な capability を `with` で宣言:
```
// read + write capability
let handler = () -> Unit with { HttpRequest, HttpResponse } {
  let url = perform HttpRequest::Url
  perform HttpResponse::Status(200)
  perform HttpResponse::Write("hello")
}

// middleware: read-only (最小権限)
let logger = [A](inner: () -> A with { HttpRequest, HttpResponse })
  -> A with { HttpRequest, HttpResponse } {
  let url = perform HttpRequest::Url
  // log(url)
  inner()
}
```

**WIT マッピング**:

| vibe effect | WIT interface | direction |
|---|---|---|
| `effect HttpRequest` | `wasi:http/types` (request accessors) | handler が runtime に問い合わせ (import) |
| `effect HttpResponse` | `wasi:http/types` (response builder) | handler が runtime に指示 (import) |
| `effect HttpClient` | `wasi:http/client` | handler が runtime に要求 (import) |
| handler function | `wasi:http/handler.handle` | runtime が handler を呼ぶ (export) |

**codegen パス** (`vibe compile --compose-p3`):
1. effect operation (`perform HttpRequest::Url`) → WASM import call
2. handler function → WASM export (`wasi:http/handler.handle`)
3. P3 adapter (Rust) が WASM import を実装: `HttpRequest::Url` → `request.get_path_with_query()`
4. P3 adapter が WASM export を呼ぶ: `handle(request)` → vibe handler 実行

**テスト** (effect handler で mock, 外部依存なし):
```
handle { handler() } {
  HttpRequest::Method => resume("GET"),
  HttpRequest::Url => resume("/test"),
  HttpRequest::Header(_) => resume(None),
  HttpRequest::Body => resume(""),
  HttpResponse::Status(code) => assert(code == 200),
  HttpResponse::Write(body) => assert(body == "hello")
}
```

**Capability DCE との連携**: `--profile edge` で `HttpClient` が利用不可なら、
`with { HttpClient }` を使う関数が DCE される (see ADR-0043)。

## Consequences

良い面:
- rank-2 型や線形型を導入せずに、参照脱出の安全性を構造的に保証できる
- 既存のエフェクトシステム（ADR-0003）と `handle` 構文（ADR-0016）の自然な拡張
- tail-resumptive inline 化により、ミュータブルコードと同等の実行効率
- ビルダーパターン等の抽象化が型安全に提供可能
- Component Model の import 依存が型レベルで表現され、リンク要件がコンパイル時に確定
- `#import` ディレクティブにより WASI に限らず任意のコンポーネントに対応可能
- テスト時にエフェクトハンドラでモック注入でき、外部依存なしのユニットテストが書ける

悪い面/トレードオフ:
- tail-resumptive 検出と inline 化のコンパイラ実装が必要
- 非 tail-resumptive なハンドラ（delimited continuation が必要なケース）は
  WASM での実装コストが高い（stack switching 等が必要、ADR-0012 参照）
- `let mut` との使い分けガイドラインが必要（単純な局所変数は `let mut`、
  抽象化が必要なら Effect Handler）
- `perform` の構文的オーバーヘッド（`buf.push(v)` より `perform push(v)` は冗長）
- `#import` ディレクティブと Component Model のバージョニング・型マッピングの設計が必要
