# Knowledge Base

実装中に得られた設計知見・落とし穴をまとめる。

---

## K-001: Pure cache と effect 関数の相互作用

- 場所: `src/checker/purity.mbt`, `src/runtime/store.mbt`
- 発見: 2026-02

### 背景

vibe ランタイムは pure 関数の結果を content-addressed cache に保存する。旧 evaluator では `eval_user_call` の `pure_cache`、現行 runtime では `Runtime` の `pure_cache` がその保持場所だった。同じ引数で呼ばれた pure 関数は cache から即座に返される。

### 問題

`purity_for_let` が関数の `effects` 宣言を無視していた (`effects=_`)。これにより `with Fs` のような effect 付き関数でも、body が pure なら関数全体が pure と判定された。

```vibe
export let exists: (String) -> Bool with Fs = (path) -> {
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

`type_query` は ripple 増分計算システムで管理される。ファイルが `lib/@vibe/compiler/` のような `index.vibe` を持つディレクトリにある場合、`has_dir_index = true` となり、index.vibe の cross-directory imports をシブリングファイルの型環境にマージする処理が走る。

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

index.vibe の cross-directory import を処理する際、`imp.path_obj.normalized` を使って import のディレクトリを判定していた。しかし `path_obj.normalized` はパス正規化時に `base_dir` を二重に含めることがあり、例えば `lib/@vibe/compiler/lib/@vibe/compiler/ast.vibe` のような不正なパスが生成される。

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

18個のセルフホストコンパイラソース（`lib/@vibe/compiler/*.vibe`）全てが host MoonBit の `compile_module` パイプライン（parse → type-check → desugar → monoify）を通過することを検証する。

### 構成

```
lib/@vibe/compiler/
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
1. **resume multi-layer perform** — nested handle での `resume(perform Ask::Ask(32))` で誤検知
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
  - `lib/@vibe/compiler/printer.vibe`: `join` / `escape_string` を builder ベースに変更
  - 旧 interpreter runtime: `String::length` / `String::char_code_at` / `String::substring` / `String::concat` / `Array::length` / `Array::get` にホットパス追加
  - `lib/@vibe/compiler/lexer.vibe`: `keyword_lookup` を length + 先頭文字ディスパッチに変更

### 効果

- `moon test src/tests/vibe_wasm_eval_test.mbt (旧 vibe_integration_test.mbt) --target js --serial --index 44`
  - smoke: **7.48s → 6.52s**（約 12.8% 改善）
  - full (`VIBE_SELFHOST_PROBE_FULL=1`): **199.1s → 201.6s**（誤差レベルで改善なし）

### 追加計測: full のファイル別所要時間（1ファイルずつ）

`VIBE_SELFHOST_PROBE_FILES=<file>` で計測した結果（秒）:

> 注: eval_*.vibe, values.vibe は eval 廃止に伴い削除済み。計測データは当時の記録。

- 52.28: `lib/@vibe/compiler/types.vibe`
- 43.34: `lib/@vibe/compiler/lexer.vibe`
- 35.13: `lib/@vibe/compiler/printer.vibe`
- 19.95: `lib/@vibe/compiler/checker.vibe`
- 16.61: `lib/@vibe/compiler/eval_builtins.vibe`
- 11.24: `lib/@vibe/compiler/builtins.vibe`
- 11.12: `lib/@vibe/compiler/type_db.vibe`
- 5.88: `lib/@vibe/compiler/eval_stmt.vibe`
- 4.66: `lib/@vibe/compiler/checker_stmt.vibe`
- 4.29: `lib/@vibe/compiler/values.vibe`
- 2.15: `lib/@vibe/compiler/token.vibe`
- 2.11: `lib/@vibe/compiler/eval_loader.vibe`
- 1.28: `lib/@vibe/compiler/ast.vibe`
- 1.26: `lib/@vibe/compiler/checker_resolve.vibe`
- 0.73: `lib/@vibe/compiler/index.vibe`
- 0.48: `lib/@vibe/compiler/eval_e2e_helpers.vibe`

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

`lib/@vibe/compiler/*.vibe` の root が `lib/@vibe/compiler` だと、`../module/path.vibe` が `outside root` で失敗する。

### 修正

- `resolve_index_root_with_fs` で、祖先に `vibe` ディレクトリがあり
  `prelude/json/base64/sha1` の `index.lock` を持つ場合は、その `vibe` ルートを root として採用
- これにより `lib/@vibe/compiler` から `vibe/module` への import が許可される
- 追加テスト: `codebase resolve_index_root uses shared vibe root for repo subtree`

### 教訓

- package 単位 root と monorepo 共通 root は目的が異なる。  
  コンパイラのような横断 import では **repo-aware root 解決**が必要。

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
- **2026-07-12 実測更新 (#821)**: 現行 pipeline (wit-bindgen **0.54.0** +
  vendored WIT `lib/@vibe/wasi/wit/p3`) では **upstream `wac-cli 0.10.1`
  (crates.io) で plug → validate → wasmtime 45.0.2 serve → 200/401 まで
  green**。上記 0.8.1 (leading-byte crash) / 0.9.0 (resource implementation
  is missing) は 0.10.1 で解消しており、この形については fork 不要。
  **wasmtime 46.0.1 re-probe**: async component (phase A) は RC flag のまま
  PASS、http serve (phase B) は 46 が ratified `wasi:http@0.3.0` を提供する
  ため RC world (`@0.3.0-rc-2026-03-15`) の component を link できず fail
  (`resource implementation is missing`) — ratified-WIT cutover (#821) が必要。

### 実務上の扱い

> 注（2026-06-18 更新）: 下記の旧 P3 adapter/probe 群は wasmtime 45 で動く
> `scripts/build_wasi_http_p3_full_adapter.sh` + gate
> `scripts/test_wasi_http_p3_full_gate.sh` に集約して削除した。serve は
> `-Sp3 -Shttp -W exceptions=y -W concurrency-support=y -W component-model-async=y
> -W component-model-async-stackful=y` で実動する。詳細は
> [docs/spec/wasi-p3-async.md](spec/wasi-p3-async.md) §4.1。以下は当時の経緯。

- 「P3 adapter の build」までは再現可能にし、`scripts/build_wasi_http_p3_adapter.sh` に固定。（削除済 → full adapter）
- `wac` 経路の再現は `scripts/probe_wasi_http_p3_compose.sh` に固定（`plug` / `validate` / `serve smoke`）。（削除済）
- compose 非依存の再現は `scripts/probe_wasi_http_p3_service_only.sh` に固定（service-only build + `serve smoke`）。（削除済）
- CI は `scripts/test_wasi_http_p3_blocked_gate.sh` を monitor-only で実行し、既知ブロッカーは fail させない。（削除済 → full gate）
- 「adapter + vibe run の compose/serve」は toolchain 側の async resource 対応待ち（または compose 実装更新）を blocker として管理。

### 教訓

- P3 async を扱う場合、**guest 生成（bindgen）と compose 実装の対応レベルを必ずセットで検証**すること。  
  どちらか一方だけ更新しても end-to-end は成立しない。

---

## K-019: selfhost bootstrap の真のボトルネックは `module_loader_test` / `file_compile_mode_test`

- 場所: `scripts/test_selfhost_bootstrap_gate.sh`, `src/cmd/vibe/cli.mbt`, `lib/@vibe/compiler/loader/index.vibe`, `lib/@vibe/compiler/entry/compiler/file_compile/file_compile.vibe`
- 発見: 2026-03

### 背景

compiled selfhost bootstrap は当初「parallel batch が細かすぎて child process が増えすぎている」ことが疑われた。  
実際に root-affinity を入れて batch 数を減らすと、`shard 2/4` は次まで改善した。

- files: `28`
- batches: `10`
- tests: `281/281`
- wall time: `101.67s`

しかし `shard 1/4` を同じ条件で再計測すると、他の batch が先に抜けた後も次の 2 本だけが高 CPU のまま残り続けた。

- `lib/@vibe/compiler/module_loader_test.vibe`
- `lib/@vibe/compiler/file_compile_mode_test.vibe`

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

- 場所: `docs/adr.md`, `src/checker/`, `lib/@vibe/compiler/`
- 発見: 2026-05 (ADR-0051 / 0046 / 0047 / 0050 / 0023-selfhost を順に処理)

### 背景

ADR-0051 (trait 解決 3 層化) を起点に、`docs/adr.md` の `proposed` 列を順に潰していった。実装作業として ADR-0046, 0047, 0050 は「すでに実装済みだが status が更新されていない」状態、ADR-0023 は「host 実装済み・selfhost 未追従」状態という違うパターンに当たり、ADR ごとにアプローチが変わるのが分かった。

### よくあるパターンと処理ループ

各 ADR を以下のフローでさばくと事故が少ない。

1. **status と実装の照合**
   - `docs/adr.md` 表で proposed のものを取り、関連実装場所を grep で探す。
   - 簡単な end-to-end コードで動作確認 (`vibe run /tmp/foo.vibex`)。
   - 動けば「実装済み・doc だけ古い」パターンなので、status 更新 + 補強 wbtest 1〜2 件の小 PR で済む。
2. **動かない or 部分実装の場合**
   - host (MoonBit 実装) と selfhost (vibe 実装) のどちらが対応済みか確認。
   - `host ok / selfhost 未対応`のパターンが多い。selfhost 側に追加するときは:
     - `lib/@vibe/parser/token.vibe` に新 Token variant を追加すると、`tk_name` (`parser_base.vibe`) や `token_to_string` (`token.vibe`) など exhaustive match の一致を必ず壊すので一括で揃える。
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

1. `vibe test lib/@vibe/compiler/<failing>_test.vibe` をローカルで再現 (`flaker` でなく直叩き)。
2. wasmtime 必須なので `bash scripts/install_wasmtime_release.sh` で repo 既定バージョンを入れる。
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
