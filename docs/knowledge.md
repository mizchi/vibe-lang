# Knowledge Base

実装中に得られた設計知見・落とし穴をまとめる。

---

## K-001: Pure cache と effect 関数の相互作用

- 場所: `src/checker/purity.mbt`, `src/runtime/store.mbt`
- 発見: 2026-02

### 背景

vibe ランタイムは pure 関数の結果を content-addressed cache に保存する。旧 evaluator では `eval_user_call` の `pure_cache`、現行 runtime では `Runtime` の `pure_cache` がその保持場所だった。同じ引数で呼ばれた pure 関数は cache から即座に返される。

### 問題

`purity_for_let` が関数の `effects` 宣言を無視していた (`effects=_`)。これにより `with { Fs }` のような effect 付き関数でも、body が pure なら関数全体が pure と判定された。

```vibe
export let exists = (path: String) -> Bool with { Fs } {
  do { Fs::exists(path) }
}
```

旧 evaluator ではこの関数が `fn_val.pure = true` になり、同じ `path` で2回呼ぶと2回目は cache から stale な結果が返った。

```vibe
let before = do { exists(path) }  // true (実行)
do { rm(path) }                   // ファイル削除
let after = do { exists(path) }   // true (cache!) ← 本来 false
```

### 修正

`purity_for_let` で `fn_effects.length() > 0` なら body 分析に関わらず impure とする。

### 教訓

- **pure cache は正確な purity 判定に依存する**。purity 判定ロジックを変更する場合は、effect 付き関数のテスト（特に同じ引数での複数回呼び出し）で cache 挙動を検証すること。
- purity 判定に影響する要素: `let mut`, `do {}`, **effect 宣言**, 外部関数呼び出し。

---

## K-002: `do {}` ブロックの purity の二面性

- 場所: `src/checker/purity.mbt`
- 発見: 2026-02

### 背景

vibe には2つの独立した purity 系統がある:

1. **Effect guard** (`require_effect_guard`): builder 操作に `do {}` を要求する仕組み
2. **Purity analysis** (`check_toplevel_purity`): トップレベル束縛を Pure / StateLocal / Impure に分類する仕組み

### 問題

`Do` ブロックは effect guard のために存在するが、purity analysis では当初 `impure` として扱われていた。これにより `do {}` 内で builder を使う関数が StateLocal/Impure に分類され、不要な診断ノイズが発生していた。

### 修正

`Do` ブロック自体は purity analysis では `pure` とする（impurity を encapsulate する境界として扱う）。ただし K-001 の通り、effect 宣言がある関数は別途 impure にする。

### 教訓

- `do {}` は「ここに副作用がある」というマーカーだが、purity 判定においては「副作用が外部に漏れない」という encapsulation の意味を持つ。
- effect guard と purity analysis は独立した系統。片方の変更がもう片方に波及しないか確認すること。

---

## K-003: 旧 interpreter の loop fuel

- 場所: `src/runtime/eval.mbt` (削除済み), `src/runtime/store.mbt` (当時の補助設定)
- 発見: 2026-02

### 背景

旧 interpreter の `while` / `loop` 実行系に反復上限がなく、`while true {}` で CPU 300% (3スレッド: メイン + MoonBit GC) の暴走が発生。

### 当時の設計

- デフォルト fuel: **100,000** 反復
- 環境変数 `VIBE_LOOP_FUEL` で上書き可能
- fuel 消費は while/loop の body 実行ごとに 1 減算
- fuel 切れで `EvalError::LoopFuelExhausted` を raise

### 実測値

| fuel | 消費時間の目安 |
|------|--------------|
| 100K | 数秒以内 |
| 1M | 30秒前後 |
| 10M | 数分 |

インタプリタの1反復あたりオーバーヘッドが大きいため、重い計算は WASM コンパイル実行を使う方針。

### 現状

- compiled-only execution surface への移行に伴い、interpreter/evaluator 本体と `VIBE_LOOP_FUEL` は active runtime surface から削除済み。
- この項目は「探索用 backend でも runaway guard が必要だった」という履歴として残す。

### 教訓

- exploratory backend でも無限ループ対策は必要。
- 廃止済み runtime knob を public / active surface に残さない。

---

## K-004: Cascading diagnostics (依存モジュールの型エラー伝播)

- 場所: `src/runtime/db_query.mbt`, `src/cmd/vibe/cli.mbt`
- 発見: 2026-02

### 問題

依存モジュールに型エラーがある場合、`type_check_with_env` が catch して空の `TypeEnv` を返す。すると export された名前が importerの型環境に入らず、「unknown function」という misleading なエラーが表示される。

### 修正

import 解決時に `exported_names` (AST レベル) と `imported_env` (型レベル) の不一致を検出し、根本原因を示す diagnostic を emit する。CLI では依存側の diagnostic を先に表示する (root cause priority)。

### 教訓

- **AST レベルの export list** と **型レベルの名前解決** は別物。両者の不一致が cascading error の兆候。
- エラー表示は root cause を先に出す。ユーザーにとって「依存先を直して」が最も有用な情報。

---

## K-005: codebase テストの環境依存

- 場所: `src/codebase/codebase_test.mbt`
- 発見: 2026-02

### 問題

`index.lock` がリポジトリルートに存在すると、codebase の lock root 解決テストがルートの `index.lock` を見つけてしまい、テスト用の `.tmp/` ディレクトリ内の lock ファイルが使われない。

### 影響

10件の codebase テストが環境依存で失敗する。コンパイラ・ランタイムの変更とは無関係。

### 備考

`index.lock` は git status で untracked/modified として表示されるが、テスト実行に影響する。CI では `index.lock` が存在しないため問題にならない。

---

## K-006: Ripple type_query と has_dir_index のハング問題

- 場所: `src/runtime/db_query.mbt` (type_query, simple_type_query)
- 発見: 2026-03

### 背景

`type_query` は ripple 増分計算システムで管理される。ファイルが `vibe/compiler/` のような `index.vibe` を持つディレクトリにある場合、`has_dir_index = true` となり、index.vibe の cross-directory imports をシブリングファイルの型環境にマージする処理が走る。

### 問題

import を持たないファイル（`types.vibe`, `token.vibe` 等）が `has_dir_index = true` の場合に、type_query のフルパスを通すと **ハング（無限再評価ループ）** が発生する。

具体的なハングパターン:
1. `type_query(types.vibe)` → has_dir_index ブロック → `import_query.fetch(rt, index.vibe)` → index の imports を処理
2. index.vibe の imports 先（ast.vibe, lexer.vibe 等）の `type_query` が連鎖的に起動
3. ripple の依存追跡で再評価ループが発生し、テストが無限にハング

`eval_selfhost_module` 内の `compile_module` 呼び出しが、共有された VibeDb 上で ripple query を蓄積するため、特にセルフホストテスト（probe test 等）でハングが顕在化する。

### 回避策

`imports.length() == 0` のファイルは **常に** `simple_type_query` にルーティングする（`has_dir_index` の有無に関わらず）。

```moonbit
if imports.length() == 0 {
  return simple_type_query.fetch(rt, file_path)
}
```

### 副作用と対処

`simple_type_query` にルーティングすると、その diagnostics が `db.diagnostics(path)` で収集されない問題が発生した（`db.diagnostics()` が `type_query` の diagnostics のみ収集していたため）。

**修正**: `VibeDbQueries` に `simple_type_query` フィールドを追加し、`db.diagnostics()` で `simple_type_query` の diagnostics も収集するようにした。

### 教訓

- ripple の type_query 内で `import_query.fetch` を呼ぶと依存グラフが複雑化し、ハングの原因になりうる。import のないファイルは軽量パスを通すべき。
- diagnostics の収集元 query を追加する際は、`db.diagnostics()` の `get_for_query` リストも更新すること。

---

## K-007: enum コンストラクタの import 失敗（set_ctor vs set_scheme）

- 場所: `src/checker/typecheck_stmts.mbt` (register_enum_def), `src/runtime/db_query.mbt` (import_symbol)
- 発見: 2026-03

### 背景

vibe の型チェッカーは enum 定義を登録する際に `set_ctor` でコンストラクタ情報を登録するが、`set_scheme` でコンストラクタの型スキームを登録しない。

### 問題

モジュール間 import では `get_scheme(name)` で値を解決する。enum コンストラクタ（例: `EnvEmpty`）は `set_ctor` でのみ登録されているため、`get_scheme("EnvEmpty")` が `None` を返し、import が失敗する。

```vibe
// types.vibe
export enum TypeEnv { EnvEmpty; EnvBind(String, Type, TypeEnv) }

// type_db.vibe
import ./types.vibe { EnvEmpty }  // ← 失敗: "dependency export unavailable"
```

### 修正

`import_symbol` 関数に ctor fallback を追加: `get_scheme` が `None` の場合、`get_ctor` を試行し、見つかれば `set_ctor` で import 先の env に登録する。

```moonbit
None =>
  match imported_env.get_ctor(source_name) {
    Some(ctor_info) => {
      if can_bind_import_value(target_name, span) {
        env.set_ctor(target_name, ctor_info)
      }
      imported_any = true
    }
    None => ()
  }
```

### 教訓

- **型スキーム（scheme）とコンストラクタ情報（ctor）は独立した名前空間**。enum コンストラクタは両方に登録すべきだが、現状は ctor のみ。import 側で fallback が必要。
- セルフホストコンパイラのソースを `compile_module` でコンパイルすることで、この種の型システムの不整合を検出できる。

---

## K-008: import_query の path_obj.normalized による二重プレフィックス

- 場所: `src/runtime/db_query.mbt` (type_query の has_dir_index ブロック)
- 発見: 2026-03

### 問題

index.vibe の cross-directory import を処理する際、`imp.path_obj.normalized` を使って import のディレクトリを判定していた。しかし `path_obj.normalized` はパス正規化時に `base_dir` を二重に含めることがあり、例えば `vibe/compiler/vibe/compiler/ast.vibe` のような不正なパスが生成される。

### 修正

`path_obj.normalized` の代わりに `imp.path`（最終解決済みパス）を使用する。

```moonbit
// Before (buggy):
let imp_dir = match imp.path_obj {
  Some(obj) => @path.Path(obj.normalized).dirname().to_string()
  None => continue
}

// After (fixed):
let imp_dir = @path.Path(imp.path).dirname().to_string()
```

### 教訓

- `PathObj` の `normalized` フィールドは `base_dir + raw_path` の正規化結果だが、`base_dir` 自体が既にパスに含まれている場合に二重プレフィックスが起きる。
- import 解決後の最終パス（`imp.path`）が最も信頼できる。

---

## K-009: セルフホストコンパイラの native compile テスト

- 場所: `src/tests/vibe_wasm_eval_test.mbt (旧 vibe_integration_test.mbt)`
- 発見: 2026-03
- 状態: **完了**

### 目的

18個のセルフホストコンパイラソース（`vibe/compiler/*.vibe`）全てが host MoonBit の `compile_module` パイプライン（parse → type-check → desugar → monoify）を通過することを検証する。

### 構成

```
vibe/compiler/
├── token.vibe          # トークン定義
├── ast.vibe            # AST 定義
├── lexer.vibe          # 字句解析
├── parser.vibe         # 構文解析
├── printer.vibe        # AST → ソース
├── builtins.vibe       # 組み込み関数
├── types.vibe          # 型定義（import なし）
├── checker_resolve.vibe # 名前解決
├── checker.vibe        # 型チェッカー
├── checker_stmt.vibe   # 文の型チェック
├── codegen.vibe        # コード生成
├── compiler.vibe       # コンパイルパイプライン
├── type_db.vibe        # 増分型チェック DB
├── dce.vibe            # Dead Code Elimination
└── index.vibe          # パッケージ re-export
```

### 既知の課題

- `index.vibe` は同ディレクトリの re-export のみ含む。cross-dir import がないため K-006 のハング問題には該当しない。
- `type_db.vibe` は `./ripple` ディレクトリを import する。`fixture_test.mbt` にディレクトリ import 解決（`./dir` → `./dir/index.vibe`）を追加して対応済み。
- `types.vibe` は import なし。K-007 の ctor fallback がないと、types.vibe から enum コンストラクタを import する type_db.vibe 等が失敗する。

### 進捗

- 18/18 ファイルが `compile_module` を通過（K-007, K-008 の修正後）
- `native compile: all compiler sources pass compile_module` テストを再有効化し、`type_db.vibe` / `index.vibe` を含む 18 ファイルを検証対象に復帰

---

## K-010: simple_type_query diagnostics の可視化と副作用

- 場所: `src/runtime/db.mbt` (diagnostics), `src/runtime_compile/compile.mbt` (compile_module)
- 発見: 2026-03

### 背景

`compile_module` は `db.types(path)` で型環境を取得した後、`db.diagnostics(path)` で diagnostics を収集し、type/import ステージの diagnostic があれば `CompileError::TypeDiag` を raise する。

### 問題

K-006 の修正で `simple_type_query` の diagnostics を `db.diagnostics()` に追加した。これにより、以前は不可視だった型エラーが `compile_module` に到達するようになった。

影響を受けたテスト（3件）:
1. **resume multi-layer perform** — nested handle での `resume(perform(Ask(32)))` で誤検知
2. **resume rejects mismatched resumed value type** — 型不一致を runtime error として期待していたが compile-time error に
3. **resume rejects prior effects before perform** — effect 付き関数での resume 誤検知

### 分析

```
compile_module(db, path)
  → db.types(path)           // type_query → simple_type_query (no imports)
  → db.diagnostics(path)     // 以前: type_query のみ収集 → 0件
                              // 今回: + simple_type_query も収集 → resume 誤検知が浮上
  → diag.stage == "type" → raise CompileError::TypeDiag  // ← 以前は到達しなかった
```

### 根本原因の分類

| テスト | 型チェッカーの挙動 | 正誤 |
|--------|-------------------|------|
| multi-layer perform | nested handle の resume で "no matching perform" | **誤検知**（false positive） |
| mismatched type | resume の型不一致を検出 | **正検知**（テスト期待値の方が古い） |
| prior effects | effect 付き関数の resume で "no matching perform" | **誤検知**（false positive） |

### 修正 (2026-03-02)

- `typecheck_expr.mbt` の `Handle` 型検査で、arm 内で新規に発生した resume type 情報を外側スコープに伝播するようにした（nested handle の false positive 対策）。
- `type_resume_expr` の `"resume has no matching perform"` を必須エラーにせず、期待型が推論済みの場合のみ型一致を強制するようにした（inter-procedural な false positive 対策）。
- テスト 921（`resume rejects mismatched resumed value type`）は compile-time `TypeDiag` を期待するように更新した。

### 教訓

- **diagnostics の可視範囲を広げると、以前は不可視だった型チェッカーのバグが顕在化する**。ripple query ごとに独立した accumulator があるため、どの query の diagnostic を collect するかで compile_module の挙動が変わる。
- 型チェッカーの `resume` / `perform` 処理は nested handle や effect 付き関数で不完全。これらのテストが通っていたのは、型エラーが simple_type_query に閉じ込められて不可視だったため。
- テスト 921（型不一致）は compile-time 検出が正しい挙動。テスト期待値を更新すべき。

---

## K-011: selfhost probe テストの長時間化ボトルネック

- 場所: `src/tests/vibe_wasm_eval_test.mbt (旧 vibe_integration_test.mbt)` (`probe: selfhost roundtrip all compiler sources`)
- 発見: 2026-03

### 問題

`probe` テストが JS バックエンドで長時間化し、`--index 44` 単体でも数分スケールで完了しないケースがあった。  
主因は次の 2 点:

1. **重い selfhost roundtrip（lex → parse → print → lex → parse → print）を多数ファイルに対して実行**
2. **フル検証を常時実行していた**

### 追加で判明した落とし穴

driver 返り値を配列で作る際、`[roundtrip(...), ...]` 形式が parser 側で `UnexpectedToken(expected="]", got=",")` を起こすケースがあった（`[` の曖昧性による解釈経路の問題）。  
回避として driver 返り値を tuple に変更した。

### 修正

- `probe` を **デフォルト smoke モード**に変更（`token.vibe`, `ast.vibe` 等の少数ファイル）
- 環境変数 `VIBE_SELFHOST_PROBE_FULL=1` のときのみ full モード（16 ファイル）を実行
- 環境変数 `VIBE_SELFHOST_PROBE_STRICT=1` のときのみ strict roundtrip（2-pass）を有効化（デフォルトは 1-pass）
- 環境変数 `VIBE_SELFHOST_PROBE_FILES` で対象ファイルをオーバーライド可能にし、1ファイル単位の実測を可能化
- driver の集約結果は array ではなく tuple で返す
- 追加の高速化（2026-03-02）:
  - `vibe/compiler/printer.vibe`: `join` / `escape_string` を builder ベースに変更
  - 旧 interpreter runtime: `String::length` / `String::char_code_at` / `String::substring` / `String::concat` / `Array::length` / `Array::get` にホットパス追加
  - `vibe/compiler/lexer.vibe`: `keyword_lookup` を length + 先頭文字ディスパッチに変更

### 効果

- `moon test src/tests/vibe_wasm_eval_test.mbt (旧 vibe_integration_test.mbt) --target js --serial --index 44`
  - smoke: **7.48s → 6.52s**（約 12.8% 改善）
  - full (`VIBE_SELFHOST_PROBE_FULL=1`): **199.1s → 201.6s**（誤差レベルで改善なし）

### 追加計測: full のファイル別所要時間（1ファイルずつ）

`VIBE_SELFHOST_PROBE_FILES=<file>` で計測した結果（秒）:

> 注: eval_*.vibe, values.vibe は eval 廃止に伴い削除済み。計測データは当時の記録。

- 52.28: `vibe/compiler/types.vibe`
- 43.34: `vibe/compiler/lexer.vibe`
- 35.13: `vibe/compiler/printer.vibe`
- 19.95: `vibe/compiler/checker.vibe`
- 16.61: `vibe/compiler/eval_builtins.vibe`
- 11.24: `vibe/compiler/builtins.vibe`
- 11.12: `vibe/compiler/type_db.vibe`
- 5.88: `vibe/compiler/eval_stmt.vibe`
- 4.66: `vibe/compiler/checker_stmt.vibe`
- 4.29: `vibe/compiler/values.vibe`
- 2.15: `vibe/compiler/token.vibe`
- 2.11: `vibe/compiler/eval_loader.vibe`
- 1.28: `vibe/compiler/ast.vibe`
- 1.26: `vibe/compiler/checker_resolve.vibe`
- 0.73: `vibe/compiler/index.vibe`
- 0.48: `vibe/compiler/eval_e2e_helpers.vibe`

上位3ファイル（types/lexer/printer）だけで **61.5%**、上位5ファイルで **78.7%** を占める。

### 教訓

- 当時の interpreter 上の selfhost 系 probe は、CI の常時実行では **smoke/full を分離**すべきだった。
- parser の曖昧構文（特に `[` 起点）に触れる生成コードは、最小ケースでも parse check を先に行うと切り分けが速い。
- full 高速化は「MoonBit 側 typechecker の equality 畳み込み」より、**vibe selfhost 側の lexer/printer/types の実行コスト削減**が支配的。

---

## K-012: wasm backend の `for-in` は `iter_*` fallback が必要

- 場所: `src/codegen/wasm_codegen_call_builtin_pre_user.mbt`, `src/tests/vibe_wasm_test.mbt`
- 発見: 2026-03

### 問題

`for-in` は core desugar で `iter_require` / `iter_length` / `iter_get` 呼び出しになる。  
wasm backend に同名 call ハンドラがないと `BackendLimit(call: iter_require)` で落ちる。

### 修正

- `iter_require` を identity として実装
- `iter_length` / `iter_get` を `Array::length` / `Array::get` 相当の fallback として実装
- 回帰テスト: `vibe wasm compiles for-in expressions`

### 教訓

- prelude 経由の関数でも、wasm codegen 側で未解決 call になり得る。desugar 後の call 名を backend で必ず確認すること。

---

## K-013: DCE は pattern ctor 参照を依存として拾う必要がある

- 場所: `src/core/ast_walker.mbt`, `src/runtime_compile/dce_test.mbt`
- 発見: 2026-03

### 問題

`match p { PWild => ... }` のように **式側では ctor を生成せず pattern だけで ctor を使う**ケースで、DCE が ctor 参照を拾えず enum 定義が落ちる。  
結果として wasm codegen で `unknown ctor: PWild` が発生する。

### 修正

- AST walker に `walk_pattern_refs` を追加
- `Match` / `Handle` / `LetPat` / `LetPatElse` で pattern ctor 名を参照収集
- 回帰テスト: `dce: keeps enum definitions referenced only by match patterns`

### 教訓

- 依存解析は式参照だけでは不十分。**pattern の名前解決（Ctor/Struct）も参照グラフに含める**こと。

---

## K-014: wasm `handle` で arm bind をローカル束縛しないと `UnknownName`

- 場所: `src/codegen/wasm_codegen_expr_effect.mbt`, `src/tests/vibe_wasm_test.mbt`
- 発見: 2026-03

### 問題

`handle { ... } with Error { Throw(msg) => ... }` の catch payload を arm 側に束縛していなかったため、arm body で `msg` 参照時に `UnknownName("msg")` が発生した。

### 修正

- `compile_expr_handle` で catch payload をローカルに受ける
- `Throw(msg)` / `Bind(msg)` を検出して arm body の前に束縛ローカルを注入
- 回帰テスト: `vibe wasm compiles handle arm bind patterns`

### 教訓

- effect handler の codegen では、`catch` 本体生成だけでなく **pattern bind のスコープ注入**が必須。

---

## K-015: top-level 関数 capture は「env が必要な関数」だけ残す

- 場所: `src/codegen/wasm_codegen_ctx.mbt`
- 発見: 2026-03

### 問題

top-level 関数が他の top-level 関数を機械的に capture すると、不要に env-backed になり、`missing closure env for direct call` が発生する（例: `print_type_expr`）。

一方で、`_no_tp` のような top-level 非関数値を capture する関数（例: `parse_impl`）は env が必要で、これに依存する top-level 関数の capture は残す必要がある。

### 修正

- `collect_func_defs` 後に top-level 関数 capture を fixed-point で正規化
- 非関数 capture を持つ top-level 関数を seed として env 必須集合を計算
- top-level 関数 capture は「env 必須集合に入る関数」だけ保持

### 教訓

- capture 削減は一律削除では壊れる。**非関数 capture を起点にした伝播計算**で最小化するのが安全。

---

## K-016: `vibe/*` モノレポでは import root を `vibe` ルートへ引き上げる

- 場所: `src/codebase/lib.mbt` (`resolve_index_root_with_fs`)
- 発見: 2026-03

### 問題

`vibe/compiler/*.vibe` の root が `vibe/compiler` だと、`../module/path.vibe` が `outside root` で失敗する。

### 修正

- `resolve_index_root_with_fs` で、祖先に `vibe` ディレクトリがあり
  `prelude/json/base64/sha1` の `index.lock` を持つ場合は、その `vibe` ルートを root として採用
- これにより `vibe/compiler` から `vibe/module` への import が許可される
- 追加テスト: `codebase resolve_index_root uses shared vibe root for repo subtree`

### 教訓

- package 単位 root と monorepo 共通 root は目的が異なる。  
  selfhost のような横断 import では **repo-aware root 解決**が必要。

---

## K-017: MoonBit wasm import の FFI 制約（HTTP builtin 実装時のブロッカー）

- 場所: `src/backend/http_wasm.mbt` 周辺、MoonBit wasm backend
- 発見: 2026-03

### 事実

- wasm import 自体は `fn f(...) = "module" "name"` で定義できる（`extern "C"` は wasm backend で不可）。
- ただし import stub の型制約が強く、`String`/`Bytes` を直接引数・戻り値にできない（`Invalid stub type`）。
- 現行 `vibe:http/*` host import（vibe の wasm codegen 側）は tagged value (`i64`) ABI を前提にしている。

### 影響

- `http_wasm.mbt` を単純に host import へ差し替えるだけでは、文字列を伴う API（`Http::request`, `Http::response_body`, `Http::request_url` など）を安全に往復できない。
- そのまま差し替えると、wasm instantiation 時に必須 import が増え、既存の non-HTTP 実行パスを壊すリスクがある。

### 必要な前提

- host から guest へ文字列を返すための ABI を定義する（guest allocator/export 契約を含む）。
- compiled 実行系（`vibe run/test`）で `vibe:http` host runtime を提供し、interpreter と同等の capability ルールを適用する。

### 進捗 (2026-03-03)

- wasm codegen に `vibe_http_host_string_new(i32)->i64` export を追加（`--http-host-imports` かつ HTTP builtin 使用時）。
- host import e2e で、helper で確保した文字列に `memory` 経由で UTF-8 を書き込み、`Http::request_method/url/header/body` の戻り値として消費できることを固定化。
- compiled 実行系（`vibe run/test`）で HTTP builtin を検出した場合、`--http-host-imports` 付き wasm を生成し、`scripts/wasm_http_host_runner.js` を自動起動して `vibe:http` import を解決する経路を追加（`scripts/test_compiled_backend_http_policy.sh` で auto/forced compiled を検証）。
- compiled host runner に capability allowlist を統合（`VIBE_HTTP_ALLOW_CONNECT`, `VIBE_HTTP_ALLOW_LISTEN`）。
  - `VIBE_HTTP_ALLOW_CONNECT`:
    - 省略時は `*`（developer preset 相当）
    - 空文字は deny-all
    - 例: `example.com:443,*.example.org,*`
  - `VIBE_HTTP_ALLOW_LISTEN`:
    - 省略時は `*`（developer preset 相当）
    - 空文字は deny-all
    - 例: `8080,3000,*`
- `can_connect_any` / `can_listen_any` は旧 runtime 契約に合わせて「該当 capability が1件でもあれば true」。
- `moon run --target native src/cmd/vibe -- ...` 経路では、`die()` が内部で使う `exit(1)` の終了コードが script から安定して観測できないケースがある。
  - policy gate（`scripts/test_compiled_backend_http_policy.sh`）は `vibe.exe` 直実行に切り替えて終了コード判定を安定化。

---

## K-018: WASI HTTP P3 async component の compose ツールチェーン不整合

- 場所: `scripts/build_wasi_http_p3_adapter.sh`, 外部 toolchain (`cargo-component`, `wac`, `mwac`, `wasm-tools compose`)
- 発見: 2026-03

### 問題

`wasi:http@0.3` の `handler.handle` は async であり、component 側に async-lift/lower の型情報が入る。  
この形式に対して、現行 compose ツールが揃って同時に対応していない。

### 事実

- `cargo-component 0.21.1`（内部 `wit-bindgen 0.41`）は async export 名として `#[async]handle` を使い、`wasm-tools validate` / `wasmtime` で reject される。
- `wit-bindgen 0.51` + `wasm-tools component new` では validate 可能な P3 async component は生成できる。
- ただし compose 側で以下が発生する:
  - `wac-cli 0.8.1`: `invalid leading byte (0x43) for component defined type`
  - `wac-cli 0.9.0`: `plug + validate` は通るが、`wasmtime serve` で `wasi:http/types` の resource 実装不一致により起動失敗（`resource implementation is missing`）
  - `mwac/wite compose`: `unknown type ... type index out of bounds`（invalid component 出力）
  - `wasm-tools compose`: function import 経路で panic（`should not have an instance import ref to a non-instance import`）
- さらに、compose を介さない service-only component（`include wasi:http/service` のみ）でも `wasmtime serve` で同じ `resource implementation is missing` が出る。
  - つまり `wac compose` 固有ではなく、現状の `wit-bindgen 0.51` 生成物と `wasmtime serve` の resource 型照合にもギャップがある。
- 外部 issue を作成して追跡中:
  - wasmtime: https://github.com/bytecodealliance/wasmtime/issues/12714
  - wit-bindgen: https://github.com/bytecodealliance/wit-bindgen/issues/1554

### 実務上の扱い

- 「P3 adapter の build」までは再現可能にし、`scripts/build_wasi_http_p3_adapter.sh` に固定。
- `wac` 経路の再現は `scripts/probe_wasi_http_p3_compose.sh` に固定（`plug` / `validate` / `serve smoke`）。
- compose 非依存の再現は `scripts/probe_wasi_http_p3_service_only.sh` に固定（service-only build + `serve smoke`）。
- CI は `scripts/test_wasi_http_p3_blocked_gate.sh` を monitor-only で実行し、既知ブロッカーは fail させない。
  - `VIBE_WASI_HTTP_P3_REQUIRE_READY=0`（default）: known blocker を許容
  - `VIBE_WASI_HTTP_P3_REQUIRE_READY=1`: ready でない場合は fail（昇格用）
- 「adapter + vibe run の compose/serve」は toolchain 側の async resource 対応待ち（または compose 実装更新）を blocker として管理。

### 教訓

- P3 async を扱う場合、**guest 生成（bindgen）と compose 実装の対応レベルを必ずセットで検証**すること。  
  どちらか一方だけ更新しても end-to-end は成立しない。

---

## K-019: selfhost bootstrap の真のボトルネックは `module_loader_test` / `file_compile_mode_test`

- 場所: `scripts/test_selfhost_bootstrap_gate.sh`, `src/cmd/vibe/cli.mbt`, `vibe/compiler/loader/index.vibe`, `vibe/compiler/entry/compiler/file_compile/index.vibe`
- 発見: 2026-03

### 背景

compiled selfhost bootstrap は当初「parallel batch が細かすぎて child process が増えすぎている」ことが疑われた。  
実際に root-affinity を入れて batch 数を減らすと、`shard 2/4` は次まで改善した。

- files: `28`
- batches: `10`
- tests: `281/281`
- wall time: `101.67s`

しかし `shard 1/4` を同じ条件で再計測すると、他の batch が先に抜けた後も次の 2 本だけが高 CPU のまま残り続けた。

- `vibe/compiler/module_loader_test.vibe`
- `vibe/compiler/file_compile_mode_test.vibe`

### 観測

- heavy test を singleton batch に分離した後でも、`12m+` 時点で上の 2 本だけが継続
- つまり scheduler / batch 数 / report 集約は **一次ボトルネックではない**
- 支配コストは test 本体が踏む FS import 閉包収集と file-compile 準備経路にある

### 真因

#### 1. `stat token` だけで persistent cache を捨てていた

`loader/index.vibe` の cache validation は `stat_token` が変わると即 miss 扱いだった。  
そのため temp file を同じ内容で書き直す `file_compile_mode_test` のようなケースでも、content-addressed cache が刺さらない。

```vibe
// 旧挙動の要点
if stat_token_text != "" {
  Fs::stat_token(path) == stat_token_text
} else {
  compact_string_fingerprint(Fs::read_file(path)) == source_fingerprint
}
```

同一 content rewrite では `stat_token` は変わるが `source_fingerprint` は変わらない。  
ここで fingerprint fallback しないと、artifact hit 前の source-group cache が毎回 cold になる。

#### 2. manifest list / group cache が片側 miss だと閉包収集をやり直していた

`collect_all_sources_fs` と `collect_source_groups_fs` は別 cache を持つが、片側だけ cache が残っていても再利用せず、

- manifest 読み直し
- full source 読み込み
- `collect_needed_paths_rec`

をもう一度やっていた。  
`module_loader_test` はこの両方を同じファイル内で繰り返し叩くため、二重コストが効く。

### 修正

- `matches_cached_file_spec` は `stat_token` mismatch 時に `source_fingerprint` fallback する
- `load_source_if_cached_file_spec_matches` を追加して、valid 判定と source 読み出しを一体化
- `collect_all_sources_fs` は valid な group cache から list cache を再構築できるようにした
- `collect_source_groups_fs` は valid な list cache から group cache を再構築できるようにした

### 教訓

- content-addressed cache で本当に効かせたいなら、**mtime/stat 由来の invalidate を content hash より優先しすぎない**こと
- persistent cache は artifact だけでなく、**dependency closure の表現（list/group/header/interface）を相互変換できる粒度**で持つと効く
- bootstrap のような重い系では、batch 数の改善で child explosion を止めたあとに、**最後まで残る singleton test** を見て真因を切り分けるのが早い

---

## K-020: ADR を一周まわして実装する作業ループ

- 場所: `docs/adr.md`, `src/checker/`, `vibe/compiler/`
- 発見: 2026-05 (ADR-0051 / 0046 / 0047 / 0050 / 0023-selfhost を順に処理)

### 背景

ADR-0051 (trait 解決 3 層化) を起点に、`docs/adr.md` の `proposed` 列を順に潰していった。実装作業として ADR-0046, 0047, 0050 は「すでに実装済みだが status が更新されていない」状態、ADR-0023 は「host 実装済み・selfhost 未追従」状態という違うパターンに当たり、ADR ごとにアプローチが変わるのが分かった。

### よくあるパターンと処理ループ

各 ADR を以下のフローでさばくと事故が少ない。

1. **status と実装の照合**
   - `docs/adr.md` 表で proposed のものを取り、関連実装場所を grep で探す。
   - 簡単な end-to-end コードで動作確認 (`vibe run /tmp/foo.vibe`)。
   - 動けば「実装済み・doc だけ古い」パターンなので、status 更新 + 補強 wbtest 1〜2 件の小 PR で済む。
2. **動かない or 部分実装の場合**
   - host (MoonBit 実装) と selfhost (vibe 実装) のどちらが対応済みか確認。
   - `host ok / selfhost 未対応`のパターンが多い。selfhost 側に追加するときは:
     - `vibe/compiler/syntax/token.vibe` に新 Token variant を追加すると、`tk_name` (`parser_base.vibe`) や `token_to_string` (`token.vibe`) など exhaustive match の一致を必ず壊すので一括で揃える。
     - lexer の keyword_lookup は文字数バケットで分かれているので、追加先のバケットに入れる。
     - parser の precedence ladder に新規 trailing-構文を入れる場合、**if-cond などで先食いされない位置**に置く必要がある。`expr is pat` を入れたとき `if x is pat { ... }` の if-form と衝突したので、`parse_infix_no_is` を切り出して mode_if 側ではそちらを使うようにした (#374 参照)。
3. **新 AST variant が必要なケース**
   - `let-else` のように `Stmt::SLetPatElse` が要るタイプは、selfhost のあらゆる Stmt 走査箇所 (parser, checker, codegen, walker, normalize) を横断する。本格的な機能追加で、ADR 1 件あたり中規模 PR になる。「既存の variant を Option で拡張」は変更面積が爆発するので、新 variant を追加する方が結局少ない。

### PR 粒度

ADR 横断の作業は PR を分けると merge と review が回しやすい。今回の例:

| PR | 内容 | コミット規模 |
|---|---|---|
| #371 | ADR-0051 layered trait solver (本体) | 7 commits |
| #372 | bootstrap gate を unblock (parity skip) | 1 commit |
| #373 | ADR-0046/0047/0050 を accepted へ更新 + wbtest | 1 commit |
| #374 | selfhost に `is` キーワード追加 (ADR-0023 parity) | 1 commit |

ADR doc 更新と新規 wbtest だけの PR (#373) は CI も短く、レビューも軽い。逆に bootstrap gate のような「触ると 10 分かかる」テストは、その PR に閉じ込めて他の作業を巻き込まないようにする。

### bootstrap-gate が落ちたときの分け方

`selfhost-bootstrap-gate` は CI 上 `continue-on-error: true` の informational job なので、`ci-required` には影響しない。ただし pre-existing bug を放置していると判別できなくなるので:

1. `vibe test vibe/compiler/<failing>_test.vibe` をローカルで再現 (`flaker` でなく直叩き)。
2. wasmtime 必須なので `bash scripts/install_wasmtime_release.sh` で 42.0.1 を入れる。
3. exit code 24 = `assert(...)` 失敗。テストが通ろうとしている場面が selfhost compiler のどの構文/型機能を要求しているかを切り分ける。
4. 「テストソース自体が host も受理しない」「auto-generated bundle のシェイプが変わったのに assert が古い」など、テストが先走っていることが多い。skip + 再有効化条件を残すコメントだけで unblock 可 (#372)。

### Trait 解決リファクタの教訓 (ADR-0051)

- **read-path 先行 + storage 切り出しは別 PR にする**: `TypeEnv` から `traits` / `trait_impls` Map を切り出して `TraitState` 構造体に集約するのは clone/fork 全バリエーションに影響するため、(a) 互換アダプタを置く read-path → (b) 書き込み API → (c) storage 切り出し、と段階的に進めると衝撃を抑えられる。
- **診断強化は「失敗理由の構造化」から始める**: `ObligationSolver::satisfies(...) -> Bool` を `witness(...) -> TraitWitness` に置き換えるだけで、bound 不一致のエラーが「impl Show for Array[T] requires T: Hash, but Int does not satisfy it」に化ける。Bool API は thin wrapper として残す。
- **メモ化は per-call**: `is_subtrait` は session 内で単調なので `TraitGraph` インスタンスにメモを持たせれば十分。invalidate を考えなくていい場所を選ぶ。
- **import 経路の cycle ガードは defence-in-depth**: `register_def` は self-ref と未知 supertrait を弾けば cycle は構造的に起きない。一方 `import_def` は既存 entry の supertraits を上書きするので、install→`has_cycle`→roll back の三段で守る。

### 教訓

- ADR は実装と doc の乖離が起きやすい。proposed のままになっているものは「実装済みで doc 更新だけ」が混ざるのでまず end-to-end で確認する。
- selfhost は host の機能を追走する。新 Token を入れるときは exhaustive match 全箇所を一気通貫で更新する。
- precedence ladder に trailing-構文を入れるときは、cond 的に他 form が trailing 部分を奪い合う場合があるので「消費しない版」を切り出す。
- bootstrap-gate のような重い informational job は、PR を分けて閉じ込めるとレビューと再実行が独立に回せる。

---

## K-021: `vibe bench` の per-iter overhead を消すための calibration 設計

- 場所: `src/cmd/vibe/cli_bench.mbt`, `scripts/wasm_vibe_host_runner.js`, `bench/selfhost_perf/README.md`
- 発見: 2026-05 (commits `f907dc7`, `95f77af`)

### 背景

`vibe bench --runs N` の statistical mode (non-setup) は long-running な計測。
当初 `selfhost_lexer_bench` / `selfhost_checker_bench` の per-iter が **19-26ms** で
ファイルサイズに無関係に flat だったため、「workload 自体は noise floor 以下」と誤判断
してしまった。実は **bench harness の per-iter overhead** が支配していた。

### 問題

`vibe bench` 内部の per-case 流れ:

1. `compile_bench_script_to_wasm(...)` で 1 サンプル分の wasm 生成。元コードは
   `build_bench_case_loop_script(iter_body, batch_size)` で wasm 内 vibe-`while` ループ
   を生成し、batch_size 回まわしてから返る。
2. Calibration: `trial=1, 2, 4, …` で wasm を再生成しつつ measure。
   - node runner では `run_bench_module(...)` がそのつど **node を fresh spawn**。
   - wasmtime backend でも **wasmtime プロセスを fresh spawn**。
3. `elapsed > 100ms` (threshold) で break、`batch_size = ceil(threshold / single_us)`。
4. Sampling: `for _ in 0..<runs { run_bench_module(...) }` で **runs 回 spawn**、各回の
   wallclock を `batch_size` で割って per-iter を出す。

破綻ポイント:

- Node spawn cold-start: **~100ms** (V8 startup + WASI shim ロード + wasm 1 回 instantiate)。
- Wasmtime spawn cold-start: 530KB selfhost wasm で **~25ms** (cranelift JIT)。
- Calibration `trial=1` が常に threshold を踏むので `single_us ≈ cold-start cost`、
  `batch_size = 1` に張り付く。以降の sampling も毎 spawn cold start を払い、per-iter は
  「workload cost」ではなく「spawn cost」を測る。

結果: lex_lexer_vibe (681 LOC) と lex_host_parser_vibe (2596 LOC) が **同じ ~20ms** に
見えてしまい、誤った「サイズ無関係」結論を導いた。

### 切り分けプロセスでハマったこと

probe 側に `if String::length(content) < 1000 { abort("short") }` を入れて Fs::ReadFile が
empty を返しているかを確認したが、`abort` は vibe builtin にない (`String::abort` で
type error)。compile error が harness の `PanicError` として表面化して「Fs::ReadFile が
silent fail している」と早合点した。Fs は正常で、cold-start オーバーヘッドだけが問題だった。

教訓: bench probe で人為的に fail させる時は `abort` ではなく `throw "msg"` を使う
(`with { Error }` で受ける)。compile error と runtime error を bench harness の同一の
失敗モードに集約されると切り分けがつかない。

### 修正方針

calibration が cold-start を per-iter cost と混同しないよう、measurement 経路を 2 つに
分割した:

| backend | 修正 |
|---|---|
| node host runner (Fs 系) | wasm は `iterations=1` で生成し、`run_http_host_bench_measure(...)` で `--bench-count batch_size --bench-warmup warmup+1` を渡す。host runner (`scripts/wasm_vibe_host_runner.js:1428-`) が **1 spawn の中で `_start` を loop**。calibration も `--bench-warmup=1` を必ず付け、cold first iter を warmup に逃がす。 |
| wasmtime (Fs-free) | 内部 vibe ループ方式を維持。calibration の break 条件を `trial >= 2` に上げ、`(elapsed_last - elapsed_first) / (trial_last - trial_first)` で startup cost を構造的に subtract。 |

### 実測効果 (`vibe bench --runs 5 --warmup 2`)

| bench | LOC | before | after | speedup |
|---|---|---|---|---|
| `lex_parser_vibe` (node) | 351 | 19,854μs | 987μs | **20×** |
| `lex_host_parser_vibe` (node) | 2596 | 23,873μs | 5,648μs | 4× |
| `check_chained_lets_64` (wasmtime) | — | 22,960μs | 772μs | **30×** |
| `check_cached_env_lookups_n64` (wasmtime) | — | 23,615μs | 1,721μs | 14× |
| `check_cached_env_lookups_n2048` (wasmtime) | — | 26,355μs | 3,153μs | 8× |

修正後は per-iter が LOC に比例 (lex ~2μs/LOC) し、cached_env も N に対して
1.83× / 32× で **僅かな workload signal が見える**ようになった。修正前は spawn cost
20-25ms の中に workload が埋没していた。

### Calibration の cold-start 補正 (一般則)

「(プロセス spawn を伴う) bench harness の calibration は trial=1 を信用するな」。
最低限 trial=2 の measurement を取って線形外挿:

```
iter_cost ≈ (elapsed[N] - elapsed[1]) / (N - 1)
batch_size = ceil(threshold / iter_cost)
```

`elapsed[1]` には startup + 1 iter、`elapsed[N]` には startup + N iter が含まれる
ので、差を取ると startup が消える。`iter_cost = elapsed/trial` で割るだけだと startup
が iter cost に混ざる。

### 教訓

- **bench harness の per-iter overhead は、calibration を疑うところから**。`batch_size=1` が
  全 case に pin している = 「workload は noise 以下」ではなく「spawn cost が threshold
  を勝手に踏んでいる」を疑う。
- **measurement path を backend ごとに分ける**。node host runner は JS-side で `_start` を
  loop できる (`--bench-count`)。wasmtime は無理なので wasm 内 vibe ループに頼る。
  同一 calibration ロジックは使えない。
- **per-iter cost が flat = workload signal なしと早合点しない**。bench harness の
  spawn overhead が支配しているケースは「workload に対する hash 化 / O(N) → O(1) などの
  algorithmic 改善は ROI ゼロ」という誤った結論を導きうる (issue #395 でやらかしかけた)。
- **probe で人為的 fail を作るときは `throw "msg"`、`abort` は使わない**。`abort` は vibe
  builtin ではなく、compile error が harness の runtime panic と同じ stderr に出るため
  切り分け不能になる。

---

## K-022: bench で「flat measurement」を見たら結論を出す前に harness を疑う

- 場所: `bench/selfhost_perf/README.md`, `docs/knowledge.md#K-021`
- 発見: 2026-05 (issue #395 の measurement 反復)

### 経緯

issue #395 (selfhost runtime `Map::has_key`/`Map::get` を hash-backed に上げるべきか) を
検証するため、`vibe/compiler/checker_hotspot_probe.vibe` に `cached_env_lookups` の
N-sweep probe を追加し N=64/256/512/2048 で計測した。1 回目の結果:

| N | per-iter |
|---|---|
| 64 | 9.72ms |
| 256 | 9.38ms |
| 512 | 9.42ms |
| 2048 | 9.98ms |

「32× の N に対して 1.03×、完全に flat → linear-Map cost は noise 以下、#395 着手は
ROI ゼロ」と結論して issue を not-planned で close。

実は K-021 のとおり **bench harness の cold-start が ~9.5ms 程度を全 case で取っており、
workload は実際には 1-3ms** だった。harness 修正後に再計測:

| N | per-iter (fixed) | ratio |
|---|---|---|
| 64 | 1.72ms | 1.00× |
| 256 | 1.81ms | 1.05× |
| 512 | 2.27ms | 1.32× |
| 2048 | 3.15ms | **1.83×** |

依然として 32× N → 1.83× の sublinear scaling で、#395 の結論 (not-planned) は変わらない。
ただし **理由が変わった**: 「noise 以下」ではなく「実測 1.4ms ヘッドルームしかなく、
hash 化しても ~1ms / call 削れるかどうか」。

### 教訓

「benchmark で flat に見える」には 2 通りある:

1. workload 自体が小さく noise 以下 (= 介入の ROI 低い、結論は正しい)
2. harness overhead が workload を埋没させている (= 介入の ROI を測れていない、結論は不正)

両者は計測結果上は区別できないので、結論を出す前に **harness の bare overhead を
独立に測る** こと。具体的には:

- `node host_runner.js --bench-count 1 / --bench-count 100` を直接叩いて
  per-iter cost を比較する (`--bench-count` 増で per-iter が急減 → harness overhead が
  支配)。
- バックエンドが wasmtime なら `wasmtime --invoke` を 1 / 10 / 100 回ループしてみる。
- bench harness の `batch_size=1` が全 case に pin している = ほぼ確実に harness 律速。

なお bench README (`bench/selfhost_perf/README.md`) の「Cached-env lookup scaling」
表は修正後数値で書き換え済 (commit `fbf181e`)。同じ轍を踏まないように、過去の
flat-measurement 結論を読むときも一度 harness 版を疑うのが安全。

### 関連

- K-021 — calibration 設計の根本問題
- issue #395 (closed) — Map → hash-backed: not-planned (理由は更新済)
- `bench/selfhost_perf/README.md` — methodology 詳細

---

## K-023: cutover ratio 計測の "fair compare" 設計

- 場所: `scripts/bench_selfhost_perf.sh`, `bench/selfhost_perf/kpi_heavy_cases.txt`, `docs/selfhost-cutover-kpi.md`
- 発見: 2026-05 (commits `288793e`, `b9b95fc`)

### 背景

メインライン実装を host CLI (MoonBit native binary) から selfhost wasm に切り替える
判断のため `pkf run bench-selfhost-stage2-kpi` を導入。初回実行で「**selfhost の check
が host より 6× 速い** (ratio=0.16×)」という直感に反する結果が出た。実は計測バイアス
2 件が乗っていた。

### 問題 (A): host check が session-http daemon を auto-spawn

`vibe check foo.vibe` は LSP/persistent session 用に session-http daemon を
auto-spawn する。短時間 call (cold-start = 1.5s 程度) に対し、典型的な typecheck
本体は数十 ms。bench harness が cold-start の `vibe check` を毎回 spawn するので、
**全 wallclock のうち ~90% が daemon spawn**。selfhost (moonrun 経由) は daemon を
一切使わないので、比較が極端に不公平になる。

実測 (`vibe/x/regexp/regexp.vibe`, 1302 LOC):

| invocation | wallclock |
|---|---|
| `vibe check ...` (default, daemon spawn) | 1565 ms |
| `VIBE_USE_SESSION_HTTP=0 vibe check ...` | 226 ms |
| `moonrun selfhost.wasm --check ...` | 314 ms |

session-http なしで比較すると host 226ms vs selfhost 314ms = **1.39× (selfhost が
1.39× 遅い)** が真の値。bench harness が daemon-ありで host を測ると selfhost が
不当に有利に見える。

**修正**: `scripts/bench_selfhost_perf.sh` の host check 呼び出しに
`VIBE_USE_SESSION_HTTP=0` を追加 (selfhost 側は moonrun 経由で対称性が取れている)。

### 問題 (B): 小ファイル case では typecheck cost が startup cost に埋もれる

`bench/selfhost_perf/kpi_cases.txt` は `examples/basics.vibe` (145 LOC) や
`bench/compiler_size/cases/*.vibe` (≤71 LOC) で構成。これらは:

- host check の typecheck 自体は数 ms
- host CLI の native binary cold-start は 150-200ms
- 同じく moonrun startup も数十 ms

つまり wallclock のほとんどが startup 由来で、本来の typecheck speed の比較になっていない。

**修正**: `bench/selfhost_perf/kpi_heavy_cases.txt` を追加 (`vibe/x/regexp/regexp.vibe`
1302 LOC + `vibe/wasm/wat_encoder/wat_encoder.vibe` 2700 LOC)。これらは
typecheck/codegen cost が startup を 3-10 倍上回るサイズなので、真の比率が出る。
`bench-selfhost-stage2-kpi` のデフォルト cases を heavy に切替。

### 結果の劇的変化

同じ HEAD で計測:

| measurement | session-http=on, 小 cases | session-http=off, heavy cases (現状) |
|---|---|---|
| compile ratio | 2.93× | 3.64× |
| check ratio | **0.16× (selfhost が速い)** | **2.23× (selfhost が遅い)** |
| 結論 | check は cutover 可能?? | 正しい cutover gap が見える |

修正前は「check は OK」と誤った楽観をしてしまうところだった。

### 教訓

cutover 判断のための比較計測では:

- **比較の両側でランタイム前提を揃える**。host だけ daemon spawn / selfhost だけ
  cold-start interpreter のような非対称があると、wallclock 比較は無意味。可能なら
  両者を同じ runtime profile (両方 warm / 両方 cold / 両方 daemon あり) に揃える。
  揃えられないなら fixed cost を引き算する。
- **典型的な workload サイズで測る**。tiny case (< 200 LOC) では startup cost が
  wallclock を支配する。realistic な workload サイズ (1K+ LOC) を heavy cases に
  指定。tiny と heavy は別の質問に答える (前者: CLI startup latency、後者: typecheck
  throughput)。混同しない。
- **直感に反する結果が出たら計測バイアスを疑う**。本件の「selfhost が host より
  6× 速い」は明らかに変なので踏みとどまれた。微妙な差 (例: 1.05× vs 1.15×) なら
  バイアスを見落としやすい。

### 関連

- `docs/selfhost-cutover-kpi.md` — cutover 基準 + ロードマップ
- `bench/selfhost_perf/stage2_kpi_history.tsv` — 計測履歴 (修正前後の差が見える)
- K-021 / K-022 — bench harness overhead に関する関連知見

---

## K-024: selfhost compiler の "fixed-point" 用語の罠

- 場所: `scripts/bench_selfhost_stage2_kpi.sh`, `docs/selfhost-cutover-kpi.md`, `scripts/test_selfhost_bootstrap_gate.sh`
- 発見: 2026-05 (commit `288793e`)

### 背景

`bench-selfhost-stage2-kpi` の初版で「**bootstrap fixed-point = `sha256(stage-1) ==
sha256(stage-2)`** を verify する」と書いた。これは間違い。

### 用語の正確な切り分け

vibe の bootstrap には複数の段階がある:

| 段階 | 生成過程 |
|---|---|
| **stage-1** wasm | host CLI (MoonBit) が `src/cmd/vibe_compile_wasi/` (MoonBit source) を wasm にビルド |
| **stage-2** wasm | stage-1 wasm が `vibe/compiler/index.vibe` (vibe source) を wasm にコンパイル |
| **stage-3** wasm | stage-2 wasm が同じ `vibe/compiler/index.vibe` を **自分自身のコードジェネレータで** コンパイル |

「fixed-point」と呼ぶに値するのは **stage-2 == stage-3** (selfhost codegen が自分を
再生産できる = 決定論的)。stage-1 と stage-2 はそれぞれ MoonBit codegen と vibe codegen
の **出力 wasm** で、bit-level shape が違って当然 (機能等価性は別 gate で担保)。

| 比較 | 期待 | 何を測れるか |
|---|---|---|
| `stage1 == stage1`-rerun | OK (host codegen の決定性) | host CLI の同一性 |
| `stage1 == stage2` | ❌ 期待しない | (codegen 実装が違うので bit 一致しない、無意味な比較) |
| `stage2 == stage3` | OK (selfhost codegen の決定性) | **cutover 安全性の核心** |

`test-selfhost-bootstrap-gate` は **同じ compiler で同じ source を 2 回コンパイル**
して bit 一致を見る (`VIBE_SELFHOST_CUTOVER=0` で host、`=1` で selfhost を使う)。
これは「compiler 決定性 (determinism)」テストで、`stage-N == stage-N-rerun` を
verify している。selfhost が再生産できるかは `=1` モードで verify される。

### 実装上の罠

stage-2 → stage-3 を script 内で自前に測ろうとすると:

- moonrun で stage-2 wasm を走らせる → `vibe::*` imports (selfhost codegen pattern)
  を resolve できず instantiation 失敗
- wasmtime で `unknown-imports-default=y` を使う → instantiation OK だが、stage-2
  は出力先を CLI args 経由で受け取る I/O 規約を持つので、単純な `--invoke _start`
  では使えない (selfbuild_cli_args_entry 等の特定 export を invoke する必要)

→ stage-3 emit を自前でやろうとせず、既存 `test-selfhost-bootstrap-gate` (cutover
mode で stage-2 == stage-3 を verify する仕組みを既に持っている) に委任するのが正解。
KPI script では `fixed_point=delegated` として記録する。

### 教訓

- **「fixed-point」「determinism」「bit-equivalence」を混同しない**。何を verify
  したいのか言語化してから命名する。bootstrap-gate の test 名は「determinism gate」が
  正確で、「fixed-point」と呼ぶと別概念に滑る。
- **既存 gate に任せられるなら任せる**。selfhost bootstrap や cutover 関連の不変条件は
  既に複数の test で別々に担保されている (`test-selfhost-bootstrap-gate` /
  `test-selfhost-check-parity` / `test-selfhost-cutover-compare`)。新 script で同じ
  ことを再実装すると、(a) 維持コストが二重になる、(b) 微妙に違うチェックを書いてしまって
  食い違いが起きる、(c) 失敗時にどちらを信じるか曖昧になる。
- **selfhost wasm の自己呼び出しは imports と I/O 規約で詰まる**。`vibe::*` 系
  imports は moonrun に存在せず wasmtime でも stub 化が必要、output path 受け渡し
  も export 名と引数経路に依存。selfhost コードを single-shot script から扱うのは
  避け、専用 entry export 経由で叩くか、既存ドライバを呼ぶ。

### 関連

- `docs/selfhost-cutover-kpi.md#用語` — stage 定義
- K-023 — cutover 計測の fair compare


