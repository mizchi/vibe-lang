# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## vbundle 廃止 (完了)

vbundle 形式を廃止し、`.vibe/cache.json` + `index.lock` に完全移行済み。
ソースコード・テスト・スクリプトから全 vbundle 参照を削除。

## カバレッジ計測

### 現在の計測結果 (2026-03-18)

| 対象 | lines | branches | コマンド |
|------|-------|----------|---------|
| vibe/wasm (純関数のみ) | 100% | 28.63% | `scripts/coverage_wasm_source.sh vibe/wasm/coverage_test.vibe` |
| vibe/compiler (selfhost suite) | 99% | **45.34%** | `just coverage-selfhost-suite` |
| vibe/compiler (checker_parity 単体) | 99% | 28.25% | 120 parity tests |

suite 計測コマンド:
```bash
VIBE_BIN=_build/native/release/build/cmd/vibe/vibe.exe \
VIBE_SELFHOST_SUITE_EXTRA_ENTRIES="vibe/compiler/fixture_test.vibe,vibe/compiler/checker_parity_test.vibe" \
just coverage-selfhost-suite
```

### 目標: branch coverage 70%

#### 足りていないテスト領域

**1. Selfhost checker (checker.vibe, checker_stmt.vibe)**
- [ ] `check_expr` の全 Expr variant カバー (EMap, ESpread, EStringInterp が未テスト)
- [ ] `check_stmts` の全 Stmt variant カバー (SModule, STraitDef, SImpl が未テスト)
- [ ] unify のエッジケース (CtForAll, CtNamed with args, recursive types)
- [ ] generalize / instantiate の境界ケース
- [ ] type_implements_trait の trait hierarchy テスト

**2. Selfhost parser (parser.vibe)**
- [ ] 全 Token 種別のパース (THash, TQuestion, TDotDotDot が未テスト)
- [ ] エラーリカバリパス (throw するケース全種)
- [ ] multiline string, raw string, string interpolation
- [ ] labeled/optional パラメータのパース
- [ ] `impl` 文のパース

**3. Selfhost printer (printer.vibe)**
- [ ] 全 Stmt/Expr variant の print 往復テスト (roundtrip)
- [ ] 特殊文字エスケープ (string, char)
- [ ] nested match/if/while の indent

**4. Selfhost lexer (lexer.vibe)**
- [ ] hex literal, char escape sequences
- [ ] multiline string (`#|`)
- [ ] comment skip
- [ ] edge cases: empty input, single char, max int

**5. Selfhost builtins (builtins.vibe)**
- [ ] 全 builtin 関数の型チェック (92 builtins, ~30 未テスト)
- [ ] Fs/Process/Net/Socket 系 builtin の型

**6. Normalize / DCE (normalize.vibe, dce.vibe)**
- [ ] normalize の各 variant テスト (ユニットテスト追加)
- [ ] DCE: re-export chain の dead code 除去
- [ ] DCE: qualified enum ctor の reachability

**7. Loader (loader/index.vibe)**
- [ ] cross-module import の merge 順序テスト
- [ ] circular import 検出テスト
- [ ] version/symbol ref 解決テスト

#### 追加すべきテストファイル

| ファイル | 内容 | 想定 branch 貢献 |
|---------|------|-----------------|
| `checker_parity_test.vibe` | OK/ERR パリティ追加 | +5% |
| `checker_expr_test.vibe` (新規) | check_expr の全 variant ユニットテスト | +10% |
| `parser_roundtrip_test.vibe` (新規) | parse→print→reparse 一致テスト | +5% |
| `lexer_edge_test.vibe` (新規) | lexer のエッジケーステスト | +3% |
| `builtins_type_test.vibe` (新規) | 全 builtin の型チェック | +5% |
| `normalize_test.vibe` (拡充) | normalize ユニットテスト | +3% |

### 他のカバレッジ改善
- [ ] vibe/wasm: branches 28% → 50% (parse_* のカバレッジ)
- [ ] eval_e2e_test の trap 修正 (coverage suite で collect failed の原因)
- [ ] CI にカバレッジ gate を組み込み (branch 最低率)

## WASM Exceptions 修正 + suberror compiled 対応

WASI P3 HTTP handler の effect-based エラーハンドリングに必要。
詳細: `docs/report/support-wasip3.md`

### WASM Exceptions の string throw/catch 修正

`throw("NotFound")` → `handle { } { Error(err) => }` で `err` が破損する。

- [x] throw は常に tagged string object を投げるように変更 (エラーコード intern 廃止)
- [x] catch 側で tagged string が正しく復元される
- [x] `throw("hello")` → `Error(msg)` → `String::equals(msg, "hello")` = true

### suberror の compiled backend 対応 (完了 2026-03-18)

- [x] suberror constructor → Error 型への自動変換: 動作確認
- [x] suberror payload (`BadInput("invalid")`): 動作確認
- [x] pattern match (`Error(NotFound) => 404`): 動作確認

### Algebraic Effect (Model 1: Full Effect)

**設計決定**: Request/Response ともに effect（capability ベース）。
データ受け渡しではなく、handler が必要な capability を `with` で宣言し、`perform` で operation を呼ぶ。
詳細: `docs/report/support-wasip3.md`

**理由**: 最小権限、テスト容易性 (全 operation mock 可)、streaming 自然、WIT 1:1 マッピング

目標の syntax:

```vibe
// Effect 定義 = capability の宣言
effect HttpRequest {
  Method -> String;
  Url -> String;
  Header(String) -> Option[String];
  Body -> String
}

effect HttpResponse {
  Status(Int) -> Unit;
  Header(String, String) -> Unit;
  Write(String) -> Unit
}

effect HttpClient {
  Fetch(String, String, String) -> (Int, String)
}

// Handler = 必要な capability を宣言
let handler = () -> Unit with { HttpRequest, HttpResponse } {
  let url = perform HttpRequest::Url
  if String::equals(url, "/health") {
    perform HttpResponse::Status(200)
    perform HttpResponse::Header("content-type", "application/json")
    perform HttpResponse::Write("{\"ok\":true}")
  } else {
    perform HttpResponse::Status(404)
    perform HttpResponse::Write("Not Found")
  }
}

// Middleware = 一部の capability だけ要求 (最小権限)
let auth = [A](inner: () -> A with { HttpRequest, HttpResponse })
  -> A with { HttpRequest, HttpResponse, Error } {
  match perform HttpRequest::Header("authorization") {
    None => { perform HttpResponse::Status(401); throw("Unauthorized") }
    Some(_) => inner()
  }
}

// Test = effect handler で mock
handle { handler() } {
  HttpRequest::Method => resume("GET"),
  HttpRequest::Url => resume("/health"),
  HttpRequest::Header(_) => resume(None),
  HttpRequest::Body => resume(""),
  HttpResponse::Status(code) => ...,
  HttpResponse::Write(body) => ...
}
```

WIT マッピング: `effect HttpRequest` → `interface http-request`, `effect HttpResponse` → `interface http-response`

Phase 2 タスク:
- [x] `effect Name { Op(Args) -> Ret; ... }` 宣言 — AST / parser / checker (host + selfhost)
- [x] `perform Effect::Op(args)` 式 — AST / parser / checker / codegen (WASM import)
- [x] `handle { body } { Effect::Op(args) => resume(value) }` tail-resumptive inline
- [x] `resume(value)` — inline expansion (body 直下の perform のみ、関数越えは Phase 3)
- [x] handle body の effect scope を自動有効化
- [x] `with { Effect }` — 名前付き effect set 追跡 (`with { Console }` で `State` は使えない)
- [ ] 関数呼び出しを跨ぐ perform の handler dispatch (CPS or stack switching)

### builtin effect の統合計画

**設計決定**: `Error` と `Net` を user-defined effect framework に統合する。

#### Error → suberror ベース統合

現状: `throw(x)` / `handle { } { Error(msg) => }` が特別構文。
目標: `Error` を通常の effect として扱う。`throw` は `perform Error::Throw` の sugar。

```vibe
// Error は言語組み込みだが、意味的には以下と等価:
// effect Error { Throw(String) -> Never }
//
// throw("msg")  →  perform Error::Throw("msg")
// handle { body } { Error(msg) => expr }  →  既存構文を維持

// suberror は Error の sub-type:
suberror AppError { NotFound; BadInput(String) }
// throw(NotFound) → perform Error::Throw(NotFound)
```

タスク:
- [ ] `throw(x)` を内部的に `Perform("Error", "Throw", [x])` に desugar (逆方向は完了)
- [x] `Error` effect を暗黙定義として TypeEnv に登録 (Throw(String) -> Never)
- [x] `perform Error::Throw(msg)` → `Raise(msg)` desugar
- [x] `handle { } { Error(msg) => }` 既存構文を維持（後方互換）
- [ ] suberror の throw は Error effect 経由に統一

#### Net → fine-grained capability effects

現状: `with { Net }` で Http/Socket/Process 全 builtin を許可（粗い粒度）。
目標: capability ごとに独立した effect に分解。

```vibe
// 現在
let f = () -> Int with { Net } {
  Http::listen(8080)  // Net で全許可
}

// 将来
let f = () -> Int with { HttpServer } {
  perform HttpServer::Listen(8080)  // 明示的な capability
}
```

マッピング:
| 現在の builtin | 目標 effect | operations |
|--------------|------------|-----------|
| `Http::listen/accept/respond` | `effect HttpServer` | Listen, Accept, Respond |
| `Http::request/response_*` | `effect HttpClient` | Request, ResponseStatus, ... |
| `Socket::tcp_*` | `effect Socket` | Connect, Read, Write, Close |
| `Fs::*` | `effect Fs` | ReadFile, WriteFile, Stat |
| `sh` | `effect Process` | Exec |
| `stdout_write_char` | `effect Stdout` | WriteChar |
| `stdin_read_char` | `effect Stdin` | ReadChar |

タスク:
- [ ] 各 capability を effect として定義（prelude or std）
- [ ] builtin 関数呼び出しを `perform Effect::Op` に desugar
- [ ] `with { Net }` を `with { HttpServer, HttpClient, Socket, ... }` の sugar として維持
- [ ] codegen: effect op → 既存の WASM builtin import にマッピング
- [ ] ADR-0027 capability-based DCE との統合

Phase 3 タスク (Http P3 実装):
- [ ] `effect HttpRequest`, `effect HttpResponse`, `effect HttpClient` を P3 WIT にマッピング
- [ ] P3 adapter が effect handler として resume を提供する codegen パス
- [ ] `vibe serve handler.vibe` コマンド
- [ ] streaming response (`HttpResponse::Write` 複数回呼び出し)

## Packed Bytes (obj_bytes) 残作業

`Bytes` の WASM メモリレイアウトを `obj_array` (4byte/elem) から `obj_bytes` (1byte/elem) に変更済み。
codegen のみの変更で型システムには影響なし。

### 残タスク
- GC backend: Bytes ハンドラが元々未実装（packed bytes scope 外）。別途対応時に packed 前提で実装
- ベンチ: WASM バイナリサイズ 694→673 bytes (-3%)。ランタイム計測は vibe CLI 再ビルド後

## vibe/wasm ツールチェーン
- [ ] wasm_opt: directize (call_indirect → call 変換)
- [ ] wasm_opt: call forwarding propagation
- [ ] wasm_opt: signature pruning (未使用パラメータ削除)
- [ ] wasm_opt: duckdb-mvp.wasm 対応 (39MB — Bytes bulk copy 高速化)
- [ ] wasm_runtime: nested block+loop+br のさらなるテスト
- [ ] wat_encoder: S 式 `(if (then (if ...)))` 完全対応

## vibe/x 準公式ライブラリ

- [ ] x/url — compiled test で `../regexp` import がルート外エラー
- [ ] x/template — 簡易テンプレートエンジン
- [ ] x/diff — テキスト差分 (Myers diff)

## Vibe 言語仕様の整合性

- [ ] function type / effect 表現を AST・型・parser・printer・checker で統一する
- [ ] selfhost evaluator の AST codec を full-fidelity にする
- [ ] method syntax を nominal sugar と trait dispatch のどちらにするか仕様として固定する
- [ ] import surface の kind 情報を AST に残す
- [ ] 演算子の型規則を checker と evaluator で一致させる
- [ ] 文字列補間を raw source 再 parse ではなく typed AST にする
- [ ] `loop` / `continue` の状態受け渡しを positional から named へ寄せる
- [ ] generic `impl` を AST だけ先行させる状態を解消する

## モジュール分離 (ルート制約ブロッカー)

- [ ] ルート制約の緩和: `vibe test` のルート判定を緩和し、兄弟ディレクトリからの import を許可
  - 現状: `vibe test vibe/parser/test.vibe` のルート = `vibe/parser/`、`../types/` はルート外エラー
  - 必要: `vibe/` 全体をルートとして認識するか、明示的なルート指定 (`--root vibe/`)
- [ ] ルート制約解消後: `vibe/types/` (ast.vibe, types.vibe) を分離
- [ ] ルート制約解消後: `vibe/parser/` (token, lexer, parser, printer) を分離
- [ ] 現状の論理分離 (`vibe/compiler/core/`, `vibe/compiler/syntax/`) は維持

## Self-Host Compiler

- [ ] MoonBit host CLI を bootstrap 専用へ縮退する
- [ ] selfhost perf gap を cutover 可能な水準まで詰める
- [ ] GC backend セルフコンパイルで ~350KB 配布形を実現する
- [ ] `vibe/compiler` の論理分割を manifest `group` 列に合わせて進める

## ユーザビリティ改善

- [ ] 軽量 struct リテラル sugar `Type { ... }`
- [ ] `String` を `for-in` 対象にする
- [ ] トレイトにメソッド定義を許可
- [ ] `?` 演算子または `try` 式

## 現在の .vibe 言語の制約

| 制約 | 回避策 |
|------|--------|
| `~` (bit_not) 非対応 | `x ^ 0x7FFFFFFFFFFFFFFF` で代用 |
| mutable closure 制限 | レコード + 関数引数で明示受け渡し |
| `[]` が常に `Array[Unit]` | `Array::slice([(sentinel)], 0, 0)` で型付き空配列 |
| 大文字始まり変数名は enum constructor | snake_case 必須 |
| `let (x, mut y)` 非対応 | `let (x, y0) = ...; let mut y = y0` |
