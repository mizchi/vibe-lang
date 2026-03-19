# TODO

Spec-locked decisions are tracked in `docs/spec/decisions.md`.
Completed items are archived in `docs/DONE.md`.

## vbundle 廃止 (完了)

vbundle 形式を廃止し、`.vibe/cache.json` + `index.lock` に完全移行済み。
ソースコード・テスト・スクリプトから全 vbundle 参照を削除。

## テスト高速化

### プロファイル結果 (2026-03-19)

#### `just test` ステップ別

| ステップ | 時間 | テスト数 | 備考 |
|---------|------|---------|------|
| check_lock_clean ×2 | 0.4s | - | |
| moon test --target js | 33s | 957 | VIBE_SKIP_FIXTURES=1 で fixture スキップ済み |
| moon test lib wasm-gc | 2.4s | 9 | |
| cli_e2e native | 39s | 78 | 0.5s/test |
| check_wasi wasm | 3.5s | 17 | |
| ensure_native_cli | 0~24s | - | キャッシュ時 20ms |
| parallel_cleanup_e2e | 3.6s | - | |
| vibe.exe test (wasm除く) | ~30s | - | |

#### vibe/wasm/* — `just test-wasm-heavy` で分離済み

| モジュール | 時間 | テスト数 | 備考 |
|-----------|------|---------|------|
| wasm_parser | 2s | 148 | |
| wat_parser | 10s | 82 | |
| component_parser | 1s | 48 | |
| **wasm_runtime** | **68s** | 64 | prelude 再コンパイル問題 |
| **wasm_opt (minify_zlib)** | **248s** | 6 | 171KB fixture + prelude 再コンパイル |
| wasm_opt (他) | 10s | 69 | |
| wat_encoder | 2s | 10 | |

### 根本原因: compiled test runner の prelude 再コンパイル

各テストケースで prelude (helper 関数 + import) をフルでパース → 型チェック → WASM 生成している。
個別テスト実行は ~200ms なのに、バッチ実行は ~1s/test (wasm_runtime) や ~41s/test (minify_zlib)。

該当コード: `src/cmd/vibe/cli.mbt` L2790 `run_compiled_test_case` → L2804 `load_compiled_test_case_db`

### 改善タスク

- [x] ~~P1: db キャッシュ導入~~ — 検証済み: `load_db_for_test_into` / `set_source` いずれも効果なし。import 解決は ripple が既にキャッシュしている。ボトルネックは型チェック + codegen 自体 (0.6s/test) と wasmtime プロセス起動 (0.5s/test)
- [x] **P2: テストバッチ化** — 実装済み。全テストを 1 WASM にバッチコンパイル + 1 wasmtime 実行。結果: wasm_runtime 68→63s (-7%), minify_zlib 248→222s (-10%)。改善限定的 — 主因はテスト実行自体の計算コスト
- [ ] **P3: minify_zlib 個別対策** — 6 テストで ~222s。各テストで 171KB zlib.wasm を WASM interpreter で処理する計算コストが支配的。native テスト実行やテスト粒度の見直しが有効

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

## ビルドパイプライン最適化 (per-package .wasm + ランタイムリンク検討)

### 背景

各パッケージ (index.vibe 単位) を独立に .wasm へコンパイルしておき、実行時に結合する構成を検討した。
目的はインクリメンタルビルドの高速化: 変更パッケージだけ再コンパイルし、他はキャッシュ済み .wasm を再利用する。

### 結合方式の比較 (wasmtime, 100M iterations, i32 add)

| 構成 | 実行時間 | 倍率 |
|------|---------|------|
| Monolithic (単一 module, 直接 call) | 0.17s | 1x |
| **Core module linking** (wasm import/export) | **0.16s** | **~1x** |
| Component Model (canonical ABI lift/lower) | 27.7s | **163x** |

- **Component Model 分離は不採用**: canonical ABI のオーバーヘッドが 163x。string/list はメモリコピーが加わりさらに劣化
- **Core module linking はオーバーヘッドゼロ**: wasmtime が import を直接 call として解決するため monolithic と同等

### prelude 事前コンパイル (core module linking)

prelude (153KB, 18 modules) を core module として事前ビルドし、user code が wasm import で参照する構成は有効。

```
[事前ビルド] prelude/*.vibe → prelude.wasm (core module, export functions)
[都度ビルド] user.vibe → user.wasm (core module, import prelude functions)
[実行] wasmtime --preload prelude=prelude.wasm user.wasm
```

### production と incremental の結果同一性

**動作 (observable behavior): 保証可能。** core module linking は wasm 仕様上、直接 call と同一のセマンティクスを持つ。
関数呼び出し・ミュータブル global・共有メモリ・data セグメントすべてで monolithic と同一結果を確認済み。

**バイナリ同一性: 不可能。** 以下の差異がある:

| | production (monolithic) | debug (linked) |
|---|---|---|
| DCE | 全体最適化（使用関数だけ残る） | prelude は全 export を含む |
| インライン化 | wite -Oz がクロス関数インライン | モジュール境界で不可 |
| バイナリサイズ | 最小 | prelude 分の未使用コードを含む |
| 性能 | 最大 | ~同等（core linking のオーバーヘッドゼロ） |

つまり: **debug linked で正しく動くコードは production monolithic でも正しく動く（逆も同様）。**
性能差は最適化の有無のみで、論理的な動作は同一。

### 共有が必要な wasm 状態 (codegen 調査)

現在の codegen が生成する shared state:

| 状態 | 種別 | 共有方法 |
|------|------|---------|
| linear memory | memory | prelude が export, user が import |
| `__heap_ptr` | mutable global | prelude が export, user が import |
| funcref table | table | **要検討**: クロージャの table slot を両モジュールで共有する必要あり |
| data segments (文字列定数) | data | prelude 側で配置、user 側は heap_ptr 以降を使用 |
| `__stack_switching` global | mutable global | 必要に応じて共有 |
| `__fs_root_descriptor` | mutable global | 必要に応じて共有 |

**最大の課題は funcref table の共有。** vibe はクロージャ/高階関数を `call_indirect` + funcref table で実装している。
prelude の関数が table slot 0..N を使い、user code が N+1..M を使う場合、user code のコンパイル時に N を知る必要がある。

対策案:
1. **prelude が table を export + table slot count を export** → user code は offset 付きで table.set
2. **table.grow + table.set** で初期化時に動的追加 → 初期化コストのみ、per-call オーバーヘッドなし
3. **prelude にクロージャがなければ不要** → prelude 関数は基本的に直接 call で呼ばれるので table 不要の可能性あり

### 検証結果 (2026-03-19)

PoC で core module linking の E2E を確認:
- `vibe compile --wasm --no-dce prelude.vibe` → prelude.wasm (export 関数群 + memory + heap_ptr)
- 手動 WAT で user module を作成 (import prelude functions)
- `wasmtime --preload prelude=prelude.wasm user.wasm` → **正常動作確認**

**計測結果:**
- import 込み compile: 290ms、import なし compile: 18ms → 差 270ms がimport解決+型チェック+bundleコスト
- wasm_runtime 64テスト: バッチコンパイル済みで63秒 → 大部分はテスト実行自体の計算コスト（WASM interpreter E2E）
- core module linking の効果はテストランナーでは限定的。**通常の `vibe run` での高速化に有効**

**実装済み:**
- [x] `vibe compile --library` — `_start` を emit せず export のみの .wasm を生成
- [x] codegen: linked imports — import した関数を wasm import として emit
- [x] `bundle_for_wasm_linked` — import 先を inline せず linked imports リストを返す
- [x] `vibe build --debug` — import 先を `.vibe/debug/` にキャッシュ、linked compile
- [x] `vibe build --release` — 従来通り monolithic bundle
- [x] lazy heap init — `require_heap` で遅延初期化 (library compile の heap 問題を解消)
- [x] E2E 動作確認 (簡単なケース)

**追加実装済み:**
- [x] multivalue return 対応 — tuple 返り値の関数で linked import のシグネチャが正しく生成される
- [x] lazy heap init — `require_heap` で遅延初期化 (library compile の heap 未初期化を解消)
- [x] E2E 動作確認 — pure function (fib, factorial), multivalue return ともに正常

**動作確認:**
- `vibe build --debug` → linked .wasm + library .wasm → `wasmtime --preload` → 正常実行
- pure functions: fib(10)+factorial(5) = 175 → tagged 700 ✅
- multivalue return: exec_body の型一致 ✅ (ただし memory 共有問題で実行時エラー)

**計測 (wasm_runtime import):**
- release (monolithic): 241ms
- debug (初回 lib compile): 354ms
- debug (キャッシュ): **194ms** (20% 改善)

**残課題:**
- [x] memory/heap_ptr 共有 — user module が library の memory と __heap_ptr を import。exec_body E2E 動作確認済み
- [x] multivalue return — tuple pack をlinked import呼び出し後に自動生成
- [x] 型チェック + import I/O スキップ — fast path: キャッシュ済み linked imports + user code のみ parse/codegen。**485ms → 10ms (48x 高速化)**
- [ ] funcref table 共有 — 高階関数 (クロージャ) を cross-module で渡すケース。実用上はほぼ不要 (prelude の map/filter 等はインライン展開される)。将来的には user 関数を wasm export → library が import する方式で解決可能
- [x] ソース hash ベースのキャッシュ判定 — content_address_hash でソース変更検出、変更時に library 自動再コンパイル
- [x] data section のオフセット調整 — user module の string を 64KB offset に配置（衝突回避）。ただし cross-module string 受け渡しで concat 結果が不正になるケースあり（要調査: heap_ptr 初期値と allocate 位置の関係）

### 補足: wac compose のビルド時間

| 操作 | 時間 |
|------|------|
| wac compose (複数コンポーネント結合) | ~20ms |
| wite optimize -Oz (個別コンポーネント) | 7-10s |
| compose 後の optimize | 効果なし (コンポーネント境界を越えた最適化不可) |

### 現在のコンパイルプロファイル

| ステージ | 時間 | 割合 |
|---------|------|------|
| load | 11-16ms | 25% |
| typecheck | 24-33ms | **50%** |
| compile (bundle+emit) | 10-13ms | 22% |
| total | 46-62ms | |

ボトルネックは load + typecheck (75%) であり、compile/emit ではない。

### WIT/CM 境界での generics と effect の欠落問題

#### 問題

WIT (WebAssembly Interface Types) は generics と effect を表現できない:

- **generics**: `map<T>(list<T>, func(T) -> T) -> list<T>` のようなパラメトリック多相が書けない
- **effect**: `with { Console, Error }` のような effect 追跡情報を WIT に載せられない

これは **外部境界** (vibe component ↔ 他言語 component) を Component Model で公開する場合に問題になる。

#### 内部境界 (prelude ↔ user code) では問題にならない理由

core module linking は WIT を経由しない。wasm の raw function signature (i32, i64, ...) で直接リンクするため:

- **generics**: vibe は tagged i64 ユニフォーム値表現 (`(value << 2) | tag`) を使用。generic 関数は全て `(i64, ...) -> i64` のシグネチャになり、型パラメータは不要。monoify パス (frontend/monoify.mbt) による特殊化も monolithic と同じタイミングで適用される
- **effect**: effect operation は wasm import (`"EffectName" "OpName"`) として emit される。core module linking でも同じ import/export メカニズムで handler を渡せる

つまり vibe が両側のコードを制御する限り、tagged value + wasm import/export で generics も effect も完全に表現できる。

#### 外部境界 (CM export) での対策

vibe の関数を WIT interface として他言語に公開する場合の対策:

| 手法 | 概要 | 適用場面 |
|------|------|---------|
| **monomorphization** | 使用される具体型ごとに WIT 関数を生成 (`map_i32`, `map_string`) | export する generic 関数が少ない場合 |
| **variant boxing** | `variant value { i(s64), s(string), l(list<value>), ... }` で汎用型を定義 | JSON-like なデータ交換 |
| **resource handle** | generic コンテナを opaque resource として公開、accessor を型別に用意 | コレクション API の公開 |
| **動的コード生成** | 呼び出し元の型情報から specialized WIT + wasm を toolchain が生成 | プラグイン SDK 等 |

effect については:

| 手法 | 概要 |
|------|------|
| **WIT interface へのマッピング** | `effect Console { Print(String) -> Unit }` → `interface console { print: func(s: string) }` (既に codegen で実装済み) |
| **effect metadata を custom section に格納** | WIT には載らないが、vibe ツールチェーン間で effect 情報を共有できる |
| **capability pattern** | effect set を WIT の import group として表現 (`with { Console }` → `import console`) |

**結論**: 内部境界では問題なし。外部境界は monomorphization + WIT interface mapping で対応可能（vibe が既にやっている effect → wasm import のパターンを拡張）。

### 最適化方針

- [ ] **debug: prelude を core module として事前コンパイル** — prelude 変更時のみ再ビルド
- [ ] **debug: user code を prelude import 付き core module として emit** — codegen に分離ビルドモード追加
- [ ] **debug: funcref table 共有方式の決定** — prelude 関数が直接 call のみなら table 共有不要
- [ ] **debug: -O0 で出力** — wite optimize をスキップ
- [ ] **prod: AST インライン → 単一 module → -Oz** — 従来通り（最大性能）
- [ ] **typecheck のインクリメンタル化** — 変更モジュールだけ再 typecheck（最大ボトルネック）
- [ ] **bundle の差分更新** — 依存が変わってなければ AST キャッシュを再利用

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
