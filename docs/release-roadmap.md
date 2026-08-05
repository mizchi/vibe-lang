# vibe リリースロードマップ

> 作成: 2026-06-25 / 対象: 0.1.0 sign-off 済みのコンパイラを
> 「外部ユーザーが実利用できる公開リリース」まで持っていくための工程表。
>
> 言語コア（parser / checker / codegen / bootstrap）は 0.1.0 sign-off
> （`docs/archive/report/0-1-0-usability-signoff.md`, `docs/archive/TODO.md`「0.1.0 release sign-off」）で
> 一定の完成度に達している。本ロードマップは **プロダクトとしての配布・利用・
> 開発体験** に残る 4 テーマを「リリース blocker」として整理する:
>
> 1. install 配布方法の確定
> 2. モジュール配布方法の確定
> 3. debugger の実装
> 4. LSP の実装

各テーマは GitHub Issue（一次管理）と本ファイル（ロードマップ概要）で追う。
設計判断は `docs/adr.md` に記録する。

---

## 方針転換 (2026-07-10)

> **1.0 GA タグは見送り、次のリリースは `0.2.0` とする**（ADR-0066）。実装側の
> content gate 達成（M1–M4）は 2026-06-26 時点の記録として残すが、「1.0 として
> 外部公開してよいか」は別判断であり、現時点ではまだその段階にないと判断した。
> `docs/spec/1.0-freeze.md` の stable surface 定義自体は 1.0 到達時にそのまま
> 使う想定で無効化しない。**#647 は 1.0 GA タグの issue として保留**し、直近の
> リリース作業は 0.2.0（0.1.0 からの継続的バグ修正・小機能追加）として進める。
>
> **追記 (2026-07-12, ADR-0067)**: GA のバージョン番号自体を **1.0 → 0.3 に
> renumber** した。旧 1.0 GA タグ issue #647 は close 済みで、タグ運用を含む
> tracking は **#805 (0.3.0 GA) / #806 (0.4.0)**。下の「バージョンロードマップ」
> 参照。

---

## バージョンロードマップ (2026-07-12)

> **GA = 0.3.0**（旧 1.0 GA を renumber、ADR-0067）。1.0 は GA の同義語では
> なくなり、GA 後の成熟版番号として空ける。`spec/1.0-freeze.md` の stable
> surface 定義は GA (= 0.3) 到達時に適用するものと読み替える（ADR-0057/0066 の
> 「1.0 到達時に使う」を継承）。

| version | 位置づけ | 内容 |
| --- | --- | --- |
| **0.2.0** | 現在地 | 既知バグが一通り吐き出せている段階。0.1.0 からの継続的バグ修正・小機能追加（ADR-0066 のリリース） |
| **0.3.0** | **GA** | 下記 10 項目 + タグ運用。tracking: **#805** |
| **0.4.0** | post-GA | 下記 3 項目。tracking: **#806** |

### 0.3.0 (GA) の内容

1. **パッケージレジストリの完成** — ADR-0065 の registry / 供給網要件
   （transparency log、scope 所有権・署名、version→hash 不変 mapping、
   yank 不変、provenance）を実装し、`vibe add`/`publish` の導線を閉じる。
   Module System v2（ADR-0063/0064）の後続作業（ネットワーク add/update）を含む。
2. **冗長な文法の削除** — 同じことを書く方法が複数ある箇所を 1 つに絞る
   （`module {}` 削除 #728 の路線を継続）。
3. **トップレベル副作用の制限 + `fn main {}` エントリポイント特殊化** —
   現状 `_start` / `main` / `cli_main` 等のエントリ規約が混在している。
   MoonBit と同様に `fn main {}` を言語レベルで特殊化し、トップレベルは
   宣言のみ・副作用（実行）は main に限定する方向で設計する。
4. **エフェクトシステムの精緻化** — effect 診断の fix-it (#639)、`Error` の
   algebraic effect 化 (#640)、mut の region capability 統一
   (#418/#629, ADR-0060) 系の残タスク。
5. **REPL** — compiled session backend の `vibe shell` を対話開発の一級導線に
   引き上げる（interpreter は撤去済みのため compiled REPL として）。
6. **doctest + 実行可能な `*.vibe.md`** — docs 中のコード例を検証対象にする
   （cheatsheet ↔ examples の同期切れを構造的に防ぐ）。
7. **inline wasm (WAT S 式) の直接記述** — 最適化のために WAT の S 式を
   vibe ソース内に直接書けるようにする。既存資産: `lib/@vibex/wasm` の
   wat_encoder（S 式完全対応）、SIMD codegen 計画（0xFD prefix emit）。
   ホットパスの手書き最適化・SIMD intrinsic の足場。
8. **`@vibe/core` コアライブラリの拡充** — moonbitlang/core を参考に契約
   パッケージとしての stdlib 面を広げる（#766 で統合した base64/math/diff/
   uuid/list/set の路線を継続）。
9. **`let` → `fn` 移行の完遂** — ADR-0064。compiler source を含む全ツリーで
   トップレベル名前付き関数を `fn` に統一する（cache/sha1.vibe から着手済み）。
10. **WASI p3 動作保証** (#821) — wasmtime の WASI p3 (wasmtime_wasi p3
    bindings) で動くことを CI で保証する。async-component gate の復旧、
    guarantee gate 新設（wasmtime 45/46 matrix、ツール欠如 = FAIL）、
    ratified 0.3.0 / wasmtime 46 への cutover。パイプライン自体は wasmtime
    45 で動作確認済み — 欠けているのは検証側のみ。

### 0.4.0 の内容

1. **shared-nothing structured concurrency** — generative nursery に束縛した
   `Task` と typed channel、`Send`、cooperative cancel を公開モデルにする
   （[ADR-0068 詳細仕様](concurrency.md)）。JSPI + Worker、WASI Component
   Model、shared-everything-threads はこの意味論の交換可能な lowering とする。
   JSPI の全 browser 出荷と #488 shared-everything の upstream 実装完了は
   0.4.0 blocker にしない。#488 は opt-in probe を維持し、intrinsic/type gap と
   backend differential gate が解消してから高速化 backend として昇格する。
   0.3.0 までの全設計も ADR-0068 の制約（新しい mutable global を増やさない、
   handler/continuation を task-local に保つ）に従う。
2. **形式化を念頭に置いた型システムの設計** — checker 健全化
   （ADR「型健全性」系列）の先にある、仕様の形式化・機械検証を見据えた
   型システムの再設計。
3. **専用のエージェントハーネス** — AI エージェントが vibe を書く・検証する
   ための専用ハーネス（diagnostics/editor query primitives の路線の先）。
   前身として言語評価ループ `eval/lang-review/`（AI レビュアーが文法・
   意味論・型健全性をスコアリングし、所見を issue 化して改善を回す）が
   稼働済み。

---

## 実装進捗 (2026-06-25 セッション)

> **マイルストーン**: M1（配布確定）+ M2（開発体験 MVP）+ M3（開発体験フル）+
> M4（GA）content gate 達成 → 実装側 **GA-ready**（[GA readiness](archive/report/1-0-ga-readiness.md)）。
> ADR 決定事項を全確定（install/module/LSP host/仕様 freeze =
> [spec/1.0-freeze.md](spec/1.0-freeze.md)）。PR #642 を main に merge 済み。
> 以降の DAP P3 step/P4 named-local / `vibe binding-at` / rename 配線 /
> CI wasmtime 修正 / 仕様 freeze / span-arc step2–5 / docs は branch
> `claude/kind-fermat-lxtjov` に在り（main は authoritative compiler gate green、
> cli-install は wasmtime CLI 未導入で一時 red — branch の修正で解消）。
> テーマ3 debugger は P0-P4 + 3-D + 行 breakpoint 完了。span-arc は
> step1（診断 offset）/ step2（ECall+EDot offset）/ step3（typed hover）/
> step4（call/field hover + `vibe symbols` + 厳密診断 range）着地、
> step5 は**関数内任意行 breakpoint + 行 step（multi-file 対応）**まで着地。
> PR #643 で branch `claude/kind-fermat-lxtjov` を main へ land。
>
> **進捗メモ（2026-06-26、PR #643 マージ時点）— tracked issues**:
> 実装側の roadmap は出し切り。残りは GitHub issue で追跡する。
> - 残（リリース運用、2026-07-10 時点で保留・0.2.0 を優先 — 上記「方針転換」参照）:
>   1.0 GA タグ / version bump → **#647**
> - 残（post-GA, debugger）: `vibe.linemap` 命令オフセット粒度化 + 裸リテラル文の
>   break 対応 → **#644**（裸リテラル文の break 対応は着地済み — ELet/ELetMut に
>   文の source offset を追加し、値式が offset を持たない場合のフォールバックに
>   使用。`vibe.linemap` custom section も着地（後述の 2026-07-30 メモ）:
>   引き続き残るのは真の命令オフセット粒度 pause/step — 全 Expr への span 付与が
>   前提で未着手）
> - ✅（post-GA, debugger, 2026-07-30）: `vibe.linemap` custom section 着地 → **#644**
>   の前半。CompileCtx に `LineMapState`（cov_state と同型の cur_fn セル + 4本の
>   append-only ログ）を追加し、既存の `emit_dbg_line_stmt` probe サイトごとに
>   （所有 top-level 関数 index, body_buf 相対 offset, file id, line）を記録。
>   linked_compile.vibe が code section 組み立て時に各関数の locals ヘッダ長を
>   足し込み（wasmtime `FrameInfo::func_offset()` の計測基点と実測で一致確認済み
>   — 手製 wat + `WasmBacktrace` で検証）、`vibe.linemap`（16-byte LE レコード×N）
>   を発行。runner (`viberun`) が起動時にパースし、`--dump-linemap` で単体検査可能。
>   実利用: `--break` build が **未捕捉 trap** で停止したとき、各バックトレース
>   フレームを `frame: <fn> (<file>:<line>)` で **実際のトラップ行**に注釈（従来は
>   関数宣言行のみ）。ラベルは意図的に `  at ` ではなく `frame: ` — launcher
>   (`runtime/vibe`) の funcmap ベース stderr 注釈フィルタが `  at <name>` 行を
>   二重注釈してしまうのを回避。lambda/closure 本体の probe は linemap 対象外
>   （既知のスコープ外 — ライブな `--break`/`dbg_line` 自体は影響なし）。
>   `scripts/test_vibe_linemap.sh` 9/9、既存 break/step/trace/alloc-site 全 green、
>   compiler gate green、fixpoint 確認済み。**残**: 真の命令オフセット粒度
>   pause/step は全 Expr への span 付与が前提でここでは未着手。
> - ✅（post-GA, LSP）: field-access 診断 end offset を compiler 由来に（EDot field
>   offset）→ **#645**（2026-07-12 着地: `EDot(Expr, String, Int, Int)` の第4引数に
>   field token offset、checker が `[@off=N:M]` で厳密 range 発行、LSP の dot-hop
>   heuristic 撤去、field 位置 hover も解決）
> - 残（test-infra）: hosted CI runner の compiler error-path（vibe-eh-ci）→ **#646**
> - 残（post-GA, 任意式 watch）: debugger の arbitrary expression evaluation（未着手）
>
> **CI 根本原因メモ（vibe-eh-ci, RESOLVED）**: fresh compiler build は standalone
> `wasmtime` CLI を要するが CI 未導入 → seed fallback で diagnostics/type-at が機能せず。
> wasm-EH のバグではない。`cli-install.yml` に wasmtime 導入 step を追加して解消。
> 詳細 `docs/known-issues.md`。

完了・検証済み（compiler gate green、`scripts/test_vibe_cli_install.sh` 34/34）:

- **テーマ1 (install) ほぼ完了** — `viberun` に compiler CLI 用 raw-ABI host
  import を実装、`vibe` launcher（run/compile/build/check/test/fetch/version/
  self-update/help）、`scripts/install.sh`（install 時 `.cwasm` AOT）、
  `scripts/build_cli_wasm.sh`、`docs/install.md`、CI（`cli-install.yml`）。
- **診断表面化 (UX/LSP 基盤)** — コンパイルエラーを `<output>.diag` に書き
  launcher が `error: <file>: <message>` 表示（trap/backtrace を置換）。
- **テーマ2 (modules) ほぼ完了** — `vibe fetch`（file/http/git+、content-addressed
  vendor + `vibe.lock`）、transitive 自動解決、semver バージョン制約解決、
  `--frozen` 再現ビルド、`vibe add`、`vibe verify`（tree digest で改竄検出）、
  配布 docs。残: seamless `import "<url>"`（codegen 脆弱性 block）。
  M1「配布凍結」に到達。

- **テーマ3 (debugger) P0 着手** — wasm name section を実装し、trap backtrace が
  user 関数名を表示するようになった（`<wasm function N>` → `main`/`boom`）。
  DAP 本体（P1-P4）と source-line map は source span が前提で未着手。

残テーマ (3/4/土台) は**共通基盤の不足**がボトルネック。スコープを明確化:

### source span 基盤 — 着手・進行中（2026-06-25）

ユーザー選択に従い着手。**最初の可視スライス（located parse 診断）まで到達。**

完了:

- ✅ **NUL codegen バグ修正** — FS-compile の parse エラー診断が 175 byte の NUL
  garbage になっていた。根因は `loader/header_cache.vibe` が `+` 演算子で
  文字列連結していたこと（`+`-string-concat が compiler codegen で NUL 化）。
  `String::concat` 化で解消。これが located 診断の前提ブロッカーだった。
- ✅ **token-level span インフラ活用** — 既存の `lex_with_offsets`（トークン
  start/end offset）に `offset_to_line_col` helper を追加。
- ✅ **located parse 診断** — `parse_program_located`（文単位で `line:col` を
  付与）を追加し、FS-compile の header-load parse に配線。`vibe check`/`run` が
  `foo.vibe: line 2:1: unexpected token ...` を表示。LSP は `line N:col M:`
  プレフィックスから正確な range を生成。
- ✅ **located 型エラー（common case）** — FS typecheck の error handler で
  `unknown name:` / `function arity mismatch for` / `unknown field` /
  `unknown constructor` のシンボルを source から探し `line:col` を付与
  （`offset_to_line_col`）。`foo.vibe: line 3:31: unknown name: zzz` のように
  正確な列まで出る。LSP は range を識別子に絞る（`test_vibe_lsp.js` 11/11）。

- ✅ **EIdent への位置フィールド（構造 foundation 着地）** — `EIdent(String)` →
  `EIdent(String, Int)`（char offset）を全コンパイラ（~62 source / 375 sites）+
  legacy tree に適用。worktree agent が実施し cherry-pick で本セッションの作業
  （located 診断・name section・NUL 修正）とクリーンに統合、compiler gate
  green（fixpoint 維持）。**現状 offset は全て -1**（構造のみ）。

- ✅ **offset の実値化（着地）** — `lex_with_offsets` の `starts` を statement /
  expression parser に通し、ユーザ識別子 EIdent に実 char offset を入れた。
  `parse_recur` クロージャ型は不変（`parse_impl` のクロージャが `starts` を
  capture）、直接 helper シグネチャにのみ `starts: Array[Int]` を追加。合成識別子
  （`__lt`/`perform`/`String::concat` 等）は -1 のまま。located path
  （`parse_program_located`/`parse_program_spans`）に実 starts が流れ、非 located
  entry（`parse`/`parse_expr`/`parse_program`）は `[]` で従来通り -1。
  compiler gate green（stage2==stage3 fixpoint）、located 診断 4/4。
  worktree agent 実施 → cherry-pick 統合。

### 次の実装ステップ（span 消費 → hover/DAP）— 順序付き

> **重要**: EIdent の offset は構造的に通ったが、**まだ consumer が無い**
> （located 診断は `locate_by_marker` の first-occurrence text heuristic を使い、
> AST offset を読んでいない）。foundation を「実際に効かせる」のが次の最小段。
> 各段は compiler source 変更 → compiler fixpoint gate を要するので worktree
> agent + cherry-pick で隔離する。

1. ✅ **【最小 payoff】診断を AST offset 消費に切替（着地）** — checker が各 EIdent の
   実 offset を `[@off=N]` 除去可能マーカーでエラー文字列に乗せ、
   `locate_type_error` が正確な `line:col` に変換（マーカーは表示前に必ず除去、
   無い時は従来 first-occurrence heuristic に fallback）。**併せて FS typecheck の
   parse を `parse_program` → `lex_with_offsets`+`parse_program_located` に切替**
   （これが無いと FS 経路の starts が空で offset が全て -1 のまま＝土台が効かない
   発見）。これで arity mismatch が「関数の定義行」ではなく「実際の呼び出し行」を
   指すようになった（pipeline を end-to-end で実証）。compiler gate green、
   located 診断 7/7（call-site 精度の回帰 + marker leak guard 含む）。
   worktree agent → cherry-pick 統合。
2. ✅ **ECall へ offset 付与（着地）** — `ECall(Expr, Array[Expr])` →
   `ECall(Expr, Array[Expr], Int)`（EIdent と同じ構造 refactor: variant に Int
   field 追加 → 全 construct/match site 更新 → bundle 再生成）。parser は callee
   start offset を `callee_offset(expr)` で thread、AST 保存パス（desugar /
   normalize / perceus / import_alias_rewrite / expand_interp / eval_loader）は
   offset を pass-through、synthetic site（index/slice/len sugar、interp、spread
   等）は `-1`。**consumer 配線**: checker の arity 診断が ECall offset を
   `off_marker(call_off)` 経由で消費し、arity mismatch が**呼び出し位置**を指す
   （`s.length(99)` が定義行でなく `line 6:3` を報告）。compiler gate green
   （stage2==stage3 fixpoint、bootstrap bump 不要）、`test_located_diagnostics.sh`
   8/8。
   - ✅ **EDot offset（着地）** — `EDot(Expr, String)` → `EDot(Expr, String, Int)`。
     parser は base 式の start offset を `callee_offset` で thread、AST 保存パスは
     pass-through、synthetic（record-pattern projection / CST lowering）は `-1`。
     **consumer 配線**: checker の standalone EDot arm が、base が既知 struct で
     field が無い場合に `unknown field '<f>' on struct <S>` を `off_marker(dot_off)`
     付きで報告（`find_field` を `CtUnknown` 返却から `Option[Type]` へ変更し
     「missing field」を区別）。`p.z` が `line 3:3` を指す。gate green、
     `test_located_diagnostics.sh` 10/10。**step 2 完了**（ECall + EDot）。
3. **型付き hover** —
   - ✅ **3a env-visible MVP（着地）** — `vibe type-at` + `type_at_source`
     （位置の EIdent → `check_program` → `env_lookup` + `type_to_string`）を実装し
     LSP hover に配線。トップレベル/import 名の推論型が editor で出る。
     compiler gate green、`test_vibe_type_at.sh` 3/3 / `test_vibe_lsp.js` 14/14。
   - ✅ **3b per-node 型テーブル（着地）** — `check_expr`/`check_stmts` に
     `errors` と並走する `(Int, Type)` レコーダーを通し、推論中に各 EIdent の型を
     記録。`check_program_type_table` が「テーブル + 最終 subst」を返し
     （`check_program` の公開シグネチャは不変）、`type_at_source` が
     `subst_apply` で解決して offset で引く。**ローカル変数・パラメータの use も
     hover で型が出る**（`test_vibe_type_at.sh` 5/5: param `n`→Int, local `g`→Int）。
     compiler gate green。残: 束縛**定義**位置（EIdent でない）と式ノードの型は
     未記録（use サイトは解決）。scope 精度の高い補完・rename もこの上に乗せられる。
4. **span 露出 CLI / LSP 連携（大部分着地）** — `vibe type-at` で offset→型を露出済み。
   - ✅ **call-site / field-access hover（着地）** — step 2 の ECall/EDot offset を
     LSP 側の consumer として配線。checker の per-node 型テーブル（3b）を ECall arm
     （call の**結果型**を `tab_call_ty` で direct/method/general/no-name 各 callee
     path にタグ、`call_off >= 0` のみ）と EDot arm（field 型を `(dot_off, field_ty)`、
     `dot_off >= 0`）へ拡張。`vibe type-at` がカーソル位置の**呼び出し**・
     **フィールドアクセス**でも型を返す（`is_pos(5)`→`Bool`、`p.x`→`Int`）。
     `test_vibe_type_at.sh` 7/7、compiler gate green（fixpoint 維持）。
     **seed 制約メモ**: 巨大 `match callee {...}` を `let`/block/arg で一段ネスト
     すると seed parser が trap するため、結果型タグは match を tail position の
     flat なまま内側 result 式に付与する方式に留めた。
   - ✅ **診断 range の精度化（field access、JS LSP 層）** — checker の `@off`
     アンカーは EDot では**ベース式**（`p.x` の `p`）を指すため、LSP の素朴な
     word-scan は field error で base 識別子を誤ハイライトしていた。`locate()` を
     「メッセージが名指しするトークンをアンカー以降（field error は `.` の後）で
     ハイライト」する方式へ変更し、`unknown field 'x'` の squiggle が field を
     正確に指すよう修正（compiler 不変 = fixpoint 影響なし）。`test_vibe_lsp.js`
     に field-range 回帰を追加。
   - ✅ **シンボル span の JSON 露出（着地）** — 新 CLI `vibe symbols <file>` が
     parse 済み AST を歩き、宣言ごとに `NAME KIND START END`（KIND = LSP
     SymbolKind、START/END = 名前の char offset）を出力。新 compiler module
     `runtime/symbol_spans.vibe`（`parse_program_spans` の文単位 span 内で
     名前を whole-word 復元）+ adapter 配線 + launcher subcommand。LSP の
     document-outline / go-to-definition を行 regex から AST 正確版へ置換
     （multi-line 宣言・module ネスト対応、string/comment 誤マッチなし、
     function/value/struct/enum/trait/alias/effect の kind 区別）。regex は
     fallback として保持。`test_vibe_symbols.sh` 6/6 + `test_vibe_lsp.js`
     20/20（AST-outline 3 件追加）、compiler gate green（stage2==stage3
     fixpoint 維持、13 regression）。
   - ✅ **診断の完全 AST range 化（着地）** — checker が名前付きトークンの
     **end offset** を `[@off=N:M]` で発行（`off_marker_len(off, len)`、unknown
     name / arity mismatch の 4 サイト）。`locate_type_error` が `N:M` を
     decode し prefix を `line L:colC-E:`（同一行のみ range、後方互換: `line
     N:` が先頭）へ拡張。LSP `locate()` が end column を消費して厳密 range を
     返す（word-scan が `.` で切ってしまう qualified name `Mod.foo` も正確）。
     field error は base アンカーのため start-only 維持（JS named-token が
     担当）。`test_located_diagnostics.sh` 11/11（range 形式 + marker 非リーク
     回帰）、`test_vibe_lsp.js` 20/20、compiler gate green（fixpoint a899368、
     13 regression）。
   残（post-GA）: field error の end も compiler 由来にする（EDot への field
   offset 追加が前提）— 現状 JS named-token で実用上は解決済み。
5. ✅ **行ベース breakpoint（関数行 + 関数内任意行、着地）** —
   `vibe run --break <file>:<line>`（bare `<line>` も可）。
   - **関数宣言行**（既着地）: runner が `VIBE_BREAK` を関数名集合と行集合に分割、
     `.funcmap` sidecar（`VIBE_FUNCMAP`）と entry basename（`VIBE_BREAK_FILE`）から
     entering 関数の宣言行を解決し行一致で pause。
   - ✅ **関数内任意行 + 行 step（multi-file 含め着地）** — break-mode codegen が
     各文境界（ELet/ELetMut/ESeq）で `call vibe::dbg_line(<file_id>, <line>)` を
     発行し、runner の `vibe_dbg_line` hook がその (file, line) を line-break-set と
     照合 / step 判定で pause。行は codegen 側で算出: 文の値部分式の leftmost
     offset（`first_offset`、EIdent/ECall/EDot の char-offset）を、その関数の
     **自ファイル**の newline-index（`offset_to_line`）で 1-based 行へ変換。
     **multi-file**: merge は各文の出所ファイルを `DbgProv`（file 一覧 + 各ファイルの
     newline 表 + 文→file_id）として記録（append の length delta で alignment）。
     codegen は per-function に file_id + その file の newline 表を `CompileCtx`
     （`dbg_line_idx`/`dbg_line_nl`/`dbg_line_file_id`）へ載せ、`vibe.dbgfiles`
     custom section（basename 一覧）を発行。runner は file_id→basename を解決し
     `--break <file>:<line>` の file と照合するので、`helper.vibe:3`（import 先）と
     `main.vibex:3`（entry）を正しく区別する。
     **完全 gate**: `debug_break && DbgProv に file あり` のときだけ発行するため
     既定 codegen は byte-identical（fixpoint d21309a 維持）。FS-compile path を
     `parse_program_located` 化して offset を供給（codegen は offset を読まないので
     既定出力は不変）。値が裸リテラルの文（`let a = 1`）は offset を持たず個別
     break 不可。`test_vibe_break_interior.sh` 8/8（単一/multi-file の行 hit・
     行 step・file 区別・既定不変・非マッチ）、既存 break/break_line/step/dap 全
     green、compiler gate green。
   **残（post-GA）**: 真の命令オフセット粒度 pause/step（現状は文境界粒度）。
   `vibe.linemap` custom section 自体は #644 で着地済み（2026-07-30 メモ参照）—
   静的な (func index, code offset) → (file, line) 解決と、`--break` build の
   未捕捉 trap バックトレースへの実行行注釈に使われている。文境界を超えた
   pause/step には全 Expr への span 付与が前提でこちらは未着手。

- **codegen の関数 index↔name 対応** — ✅ wasm name section（土台B / debugger P0）
  は実装済み（`func_offset + i` で user 関数を正確に命名）。

## 全体方針とリリースの段階

リリースは一括ではなく、テーマ単位のマイルストーンを刻んで段階的にタグを打つ。

| マイルストーン | 内容 | 主テーマ | 状態 |
| --- | --- | --- | --- |
| **M1: 配布確定** | install + module の配布方法を凍結し、外部の人が「入れて使える」 | (1)(2) | ✅ 達成（install 配布物確定 + module fetch/lock/transitive/semver/frozen/verify） |
| **M2: 開発体験 MVP** | LSP MVP（診断/シンボル/hover）+ debugger P0（source-mapped trace） | (3)(4) | ✅ 達成（型付き hover、parser error recovery で全診断、trap→source-line） |
| **M3: 開発体験フル** | LSP 補完/リファクタ + DAP step 実行 | (3)(4) | ✅ 達成（DAP P1-P4 = breakpoint/名前付き変数検査/step 実行 + 3-D VS Code debug adapter、rename/references は scope 精度の `vibe binding-at` で AST 精度化）。テーマ3 debugger は P0-P4 + 3-D 完了 |
| **M4: GA (1.0)** | 上記を統合し、言語仕様 freeze + docs 完備で一般公開 | 全部 | ✅ content gate 達成（仕様 freeze = [spec/1.0-freeze.md](spec/1.0-freeze.md)、docs = install/module/editor+debug、span-arc step1–4 + step5 関数行 breakpoint、[GA readiness](archive/report/1-0-ga-readiness.md)）。**2026-07-10: 1.0 タグ自体は見送り**（ADR-0066）。直近の実リリースは **0.2.0** として進める。post-GA 課題（任意行 debug・LSP span JSON）は引き続き有効 |

### 横断的な前提（どのテーマにも効く 2 つの土台）

先に潰すと 4 テーマ全部のコストが下がる共有基盤。**優先度高**。

- **A. parser のエラー回復 (error recovery)** — 現状 `vibe/parser/parser.vibe` は
  最初の `expect_tk` 失敗で `with Error` throw して停止する。これは
  LSP（編集中の壊れたソースで診断/補完を出す）と UX 両方の天井になっている。
  recovery point（`;` / `}` / トップレベル宣言境界で再同期）を入れる。
- **B. source location / wasm name section** — 現状 codegen は name section も
  source map も出さない（`grep source.?map lib/@vibe/compiler/codegen` → 0 件）。
  ランタイム trap / panic がソース行を指せない。ADR-0035 P0 の
  `vibe.func_map` + wasm name section を入れると、debugger だけでなく
  実行時エラーの可読性も上がる。

---

## テーマ 1: install 配布方法の確定

### 現状

- `pkf run install`（`Taskfile.pkl`）が native CLI を `~/.local/bin/vibe` に
  コピーする。これは開発者向けで、外部ユーザー向けの導線ではない。
- `scripts/build_release_assets.sh` が GitHub Release 用 asset を生成する
  (selfhost-only 化済み — 旧 `vibe-<tag>.wasm` = MoonBit host lib は #594 で廃止):
  - `vibe-compiler-<tag>.wasm`（stage0 seed compiler、stock wasmtime で実行可）
  - `vibe-compiler-module-source-<tag>.vibe` / `-seed-<tag>.json` / `SHA256SUMS.txt`
  - `v*` tag push で `.github/workflows/release.yml` が公開。
- 実行基盤は `runtime/viberun`（Rust, `viberun`）。compiler は
  compiler wasm + wasmtime runner で動く（ADR-0056 cutover）。

### ギャップ（未確定）

- **正規の配布物が未定**。「native binary」「compiler wasm + runner」「npm」の
  どれを *外部ユーザー向けの canonical artifact* にするか決まっていない。
- npm / Homebrew / `cargo install` / `curl | sh` のいずれも未整備。
- README に一般ユーザー向けの「インストール手順」セクションがない。
- wasm を実行するための wasmtime / runner の同梱・前提が未定義。

### ゴール

「3 つの代表 OS（Linux/macOS/Windows）で 1 コマンドで入り、`vibe run hello.vibex`
が通る」状態を、再現可能な CI ジョブで保証する。

### 決定（2026-06-25）

**canonical = 独自ビルドの wasmtime runner + vibe コンパイラ wasm の分離配布。
インストール時に各環境で `.cwasm`（AOT precompile）をビルドする。**

- 実行基盤は `runtime/viberun`（`viberun`）を「独自ビルドの wasmtime
  runner」として配布する。runner は portable wasm を受け取り、インストール時に
  ホスト固有の `.cwasm` へ AOT コンパイルしてキャッシュする
  （既存の `.cwasm` cache 機構 / ADR-0050・ADR-0056 を install フローに昇格）。
- **runner 層と compiler wasm 層を分離**する（`docs/archive/TODO.md`「Cutover work」と一致）。
  vibe コンパイラ本体は wasm artifact として runner とは独立に更新できる
  （runner を入れ替えずに `vibe` 自身を bump 可能）。
- これにより DWARF 的なネイティブ依存を増やさず、stock でない wasmtime 拡張も
  自前 runner に閉じ込められる。

> 補足: npm / 単一ネイティブバイナリは canonical からは外す。必要になれば
> 補助配布として後付け検討（JS 埋め込み用途は `clients/js/` を維持）。

### マイルストーン

- [x] **1-1 runner/compiler 分離の確定** — `viberun` に compiler CLI が使う
      raw-ABI host import (`vibe::env-get`/`args-get`/`fs_*`) を実装し、runner が
      compiler wasm を実行基盤として動かせるようにした。compiler wasm は
      差し替え可能 artifact として分離（`runtime/viberun/src/main.rs`）。
- [x] **1-2 install-time `.cwasm` ビルド** — `scripts/install.sh` が runner 取得後に
      `viberun --precompile` で compiler wasm を host 固有 `.cwasm` へ AOT。
      launcher は runner より古い `.cwasm` を検出すると portable wasm に fallback。
- [x] **1-3 マルチプラットフォーム CI** — `.github/workflows/cli-install.yml` が
      ubuntu/macos で runner build + `scripts/test_vibe_cli_install.sh` smoke test。
      （Windows は launcher が bash 依存のため対象外。残: arch matrix 拡張）
- [x] **1-4 ワンライナー installer** — `scripts/install.sh` が runner build +
      compiler wasm 配置 + `.cwasm` 生成 + `vibe` launcher 配置 + PATH link。
      `--prefix`/`--runner`/`--cli-wasm`/`--bin-dir`/`--no-link` 対応。
- [x] **1-5 compiler-only update 導線** — `vibe self update --cli-wasm <path>` が
      runner 据え置きで compiler wasm を差し替え `.cwasm` を再生成。
- [x] **1-6 docs** — README「Install」節 + `docs/install.md`（layout/options/
      update 手順）。

> 実装メモ: launcher (`runtime/vibe`) が `run`/`compile`/`build`/`check`/
> `test`/`version`/`self update`/`help` を提供。`run`/`test` は compile→別プロセス
> 実行の 2 段（compiler CLI は compile 専用のため orchestration は launcher 側）。
> 検証済み: 単一/マルチファイル `vibe run` → 42、`vibe check` の成功/失敗、
> `vibe test` の pass/fail 集約、`.cwasm` 経路の利用。installer は
> `scripts/build_cli_wasm.sh` で最新 source からコンパイラ wasm を build（seed
> fallback あり）。残: `vibe fmt` の launcher 統合。
>
> **診断表面化 (UX/LSP 前提)**: コンパイルエラー時、compiler CLI が整形済み
> 診断 String を `<output>.diag` サイドカーに書き、launcher が `error: <file>:
> <message>` として表示するようにした（`cli_adapter.vibe` cli_main を
> `handle ... with Error { Throw(msg) => ... }` で包む）。trap/バックトレースの
> 代わりに `unknown name: zzz` / `type mismatch ...` が出る。compiler gate
> （bundle/module-source sync + stage2==stage3 fixpoint）green。

---

## テーマ 2: モジュール配布方法の確定

### 現状（想定より進んでいる）

- 相対パス import/export（`import ./lib.vibe { f }`、`export use`）は実装済み
  （`docs/module-system.md`, `lib/@vibe/compiler/module_*.vibe`）。
- **lock workflow 実装済み**（`docs/spec/decisions.md`）:
  `vibe fetch` / `vibe update-lock` が `index.lock`
  （`path`/`version`/`symbol`/`module`/`annotation` マップ）を維持。
  path import は lock entry に対して検証され、import 診断は compile-fatal。
- **semver の足場あり**: `index.vibe` ルートレジストリは
  `export let version = "x.y.z"` を要求。
- **content-addressed store あり**: `.vdb` が `hash:<sha1>` を指せる。
  alias は `VIBE_LIB_DIR`（fallback `$HOME/.vibe/lib`）から解決。
- **分散 ref PoC**: advanced graph の snapshot/delta を git/bit object として
  `refs/bit/index/<scope>/graph/...` で addressing（実験段階）。
- pinned path import（`import ./dep.vibe#hash`）で content lock 可能。

### ギャップ（未確定）

- **`@pkg` / `@lib/path` 構文は spec 記載のみで未実装**（ADR discussion）。
- **リモートからの third-party 取得が無い**: registry も `vibe publish` も
  URL/git import の解決も未実装。`vibe fetch` はローカル lock 維持に閉じる。
- transitive dependency の自動解決・バージョン整合（SAT/semver resolver）が無い。
- 「公開された vibe ライブラリを 1 行で使う」体験が存在しない。

### ゴール

「第三者のライブラリを宣言 → `vibe fetch` で取得・lock → import して使う」が
content-addressed に再現可能で動く。中央 registry の有無を含め配布モデルを凍結。

### 決定（2026-06-25）

**git/URL 分散モデル（Deno/Go 風）。中央 registry は持たない。**

- import は git/URL を直接指し、取得物は content hash で `index.lock` に固定する。
- 既存資産（content-addressed `.vdb` の `hash:<sha1>`、pinned hash import
  `import ./dep.vibe#hash`、`refs/bit/index/...` 分散 ref、`$HOME/.vibe/lib`
  キャッシュ）の上に最短で接続する。
- `vibe publish` は「git push + tag」で代替し、専用 registry サーバーは建てない。
- 発見性（検索）が必要になれば、後付けで軽量 index（tap 風）を足す余地は残す。

### マイルストーン

- [x] **2-1a fetch + lock MVP（launcher）** — `vibe fetch` が `vibe.deps`
      (`<name> <url>` 行) を読んで vendor + `vibe.lock` を書く:
      - 単一ファイル（`file://`/`http(s)://`/ローカル）→ sha256 で content-addressed
        cache + `./deps/<name>.vibe`、lock に `sha256:<hash>`。
      - **git（`git+<remote>[#<ref>]`）** → clone + ref checkout → `./deps/<name>/`
        ディレクトリに vendor、lock に解決した commit `git:<sha>` を固定。
      検証済み（`scripts/test_vibe_cli_install.sh`、git+/transitive/frozen 含め 28/28）。
- [ ] **2-1b seamless `import "<url>"` 構文** — string-literal import を parser で
      受け、resolver で `.vibe/deps/` ミラーに写像する案を試作したが、
      **compiler codegen の既知の脆さ**（`collect_import_path` の string 補間 /
      import 解決ホットパスでの String 操作が NUL garbage を生む。
      `compiler_gate.sh` step4 のコメント参照）に当たり revert。
      seed 互換な codegen 修正を先に固めてから再導入する。
- [ ] **2-1 リモート import 解決（完全版）** — git/URL から外部ソースを取得し
      `$HOME/.vibe/lib` / content store にキャッシュ。`index.lock` に hash を固定。
- [x] **2-2 依存解決器** — transitive 依存の自動解決を実装（git dep が自身の
      `vibe.deps` を宣言していれば、その dep の `deps/` に再帰 vendor。
      `VIBE_FETCH_MAX_DEPTH=16` で cycle guard、`VIBE_NO_TRANSITIVE=1` で無効化）。
      **`vibe fetch --frozen`** で再現ビルド（既存 `vibe.lock` の commit に git dep を
      pin、upstream HEAD が進んでも lock の sha を維持。transitive にも伝播）。
      **semver バージョン制約解決** — git ref が `^1.2`/`~1.2.3`/`>=1.0`/`1.x`/`*`
      等なら、リモートの tag 一覧から最高の満たすものを解決して clone・lock する
      （完全な `1.2.3`・branch・commit・`v` tag は literal 扱い）。
      検証済み（`scripts/test_vibe_cli_install.sh` transitive/frozen/semver ケース、
      semver comparator の unit 検証含む）。
- [ ] **2-3 `vibe add` / `vibe publish`（または equivalent）** — 依存追加と
      公開の CLI 導線。2-0 の選択次第で publish は「git push + tag」かもしれない。
- [x] **2-4 整合性・供給網** — `vibe.lock` に content hash を固定（単一ファイルは
      `sha256:`、git dep は commit `git:` に加え content tree digest `tree:`）。
      **`vibe verify`** で vendored 物を lock に照合（改竄/欠落を検出、transitive
      lock へ再帰）。git dep の tree digest は vendor 物の `deps/`・lock を除外し、
      ネストした dep は各自の lock で別途検証。署名は将来課題。
      検証済み（`scripts/test_vibe_cli_install.sh` verify clean/tamper/transitive）。
- [x] **2-5 docs** — `docs/module-system.md` に「配布とパッケージ管理（git/URL
      分散）」節を追加（`vibe.deps`/`fetch`/`--frozen`/`add`/`verify`/lock 形式/
      import 規約/publish=git push+tag）。

### 決めるべきこと（2-0 の選択肢）

| 案 | 内容 | 長所 | 短所 |
| --- | --- | --- | --- |
| **A. git/URL 分散（Deno/Go 風）** | `import "git+https://…#tag"`、content hash で lock | 中央サーバ不要、既存の `.vdb`/hash/分散 ref 資産と整合 | 名前空間衝突、検索性が低い |
| **B. 中央 registry（npm/crates 風）** | `vibe publish` → registry、`vibe add name` | 検索/発見性、versioning が綺麗 | サーバ運用・ホスティング・モデレーションコスト |
| **C. git + 軽量 index** | 実体は git、index だけ集約（Homebrew tap 風） | 運用軽量、移行容易 | 二段構えの複雑さ |

> 推奨たたき台: 既存実装（content-addressed `.vdb`, 分散 ref, pinned hash import,
> `index.lock`）は **A（git/URL + content-addressed lock）** に最短で接続できる。
> A を MVP として凍結し、発見性が要れば後付けで C の index を足す。

---

## テーマ 3: debugger の実装

### 現状

- **方針は ADR-0035（proposed）で確定済み**
  （`docs/archive/adr/0035-debug-adapter-protocol.md`）:
  - DWARF は不採用（vibe の i64 tagged 値 + closure ABI が C 的メモリモデルと
    impedance mismatch）。
  - 既存の **coverage instrumentation 基盤**（`--coverage`, span/coverage point,
    `.wasm.cov.json` サイドカー）を再利用して独自 DAP サーバーを建てる。
- フェーズ P0–P4 が定義済み。いずれも **未実装**、0.1.0 対象外。
- 関連: `vibe build --debug` は「linked debug build（高速 incremental compile）」で
  あって *対話デバッガではない*（用語の衝突に注意）。

### ギャップ

- name section / `vibe.func_map` / `vibe.debug_map` custom section が未出力（横断土台 B）。
- DAP サーバー本体（breakpoint / variables / step / watch）が未実装。

### ゴール

VS Code（DAP クライアント）から breakpoint を張り、停止・変数検査・step 実行が
できる。最低でも「panic/trap がソース行を指す」を M2 で達成。

### マイルストーン（ADR-0035 のフェーズに対応）

- [x] **3-P0 source map 基盤**（= 横断土台 B、M2）— **wasm name section を実装**
      （`emit_function_name_section`）。trap backtrace が `<wasm function N>` →
      `boom` 等の関数名表示に。**さらに trap がソース行を指すように**: FS-compile が
      `<output>.funcmap` サイドカー（エントリファイルのトップレベル関数名→ソース行、
      `build_funcmap_from_source` = `parse_program_spans` + `offset_to_line_col`）を
      best-effort 出力し、`vibe run` が runner の backtrace を捕捉して named frame に
      `(file:line)` を付与する。trap が `<unknown>!boom (prog.vibex:1)` と表示される。
      codegen/runner 変更不要。検証済み（`scripts/test_vibe_trace.sh`、
      `test_name_section.sh`、cli-install 34/0、compiler gate fixpoint green）。
      残: imported-module 関数の行（現状エントリファイルのみ）。命令オフセットの
      静的行マップ自体（`vibe.linemap` custom section）は #644 で着地（2026-07-30
      メモ）— `--break` build の未捕捉 trap バックトレースを実行行で注釈するのに
      使われている。DAP step 実行で任意の命令オフセットに pause する用途には
      source span の全 Expr 化が前提でこちらは未着手。
- [x] **3-P1 breakpoint DAP**（M3）— **live breakpoint 着地**: `vibe run --break <fn>[,<fn>]`
      が指定関数の入口で停止し、**コールスタック**（各フレーム `(file:line)` 注釈）を
      表示して継続（TTY は stdin 待ち、非対話は auto-continue、`q` で中断）。opt-in の
      debug-break codegen が各ユーザー関数入口に `call vibe::dbg_break` host hook を出す
      （条件付き import、func_offset が整合シフト、type idx 2 = `()->()`）。runner が
      wasm backtrace + name section で入口関数を特定し `VIBE_BREAK` 集合と照合して停止。
      既定（非 break）codegen は不変で compiler fixpoint 維持。検証済み
      （`scripts/test_vibe_break.sh` 5/5: `breakpoint hit: helper` + main フレーム + 継続で 42、
      plain run / `--trace` 非回帰、cli-install 34/0、gate green）。
      残: stop/continue を超えた step 実行・変数検査（P2/P3）と DAP プロトコル化。
      実行例:
      ```
      breakpoint hit: helper
        at helper (prog.vibex:1)
        at main (prog.vibex:2)
      ```
- [x] **3-P1 groundwork** — `vibe run --trace` = function-call 実行トレース。opt-in の
      debug codegen（`VIBE_DEBUG`）が各ユーザー関数入口で user-index を in-memory
      trace log に追記（coverage hit 領域と同方式、wasm import 追加なし＝関数
      index 不変）。`vibe.trace` カスタムセクションが log 配置 + 関数名を記録、runner
      が入口列を dump、launcher が funcmap で `(file:line)` 注釈。既定（非 debug）の
      codegen は不変で compiler fixpoint 維持。検証済み（`scripts/test_vibe_trace_calls.sh`
      6/6: `main`/`helper×2` を行付きでトレース、plain run 非回帰、cli-install 34/0、
      gate green）。残: 関数入口での**停止**（runner pause loop + breakpoint 集合）と
      DAP プロトコル化（次段）。
- [x] **3-P2 変数検査（引数）着地**（M3）— break モードの codegen が各ユーザー
      関数入口で i64 パラメータを予約メモリ（`dbgargs` 領域）に spill し、`vibe.dbgargs`
      custom section にアドレス + tag mode を記録。runner が breakpoint hit 時に読み出し
      tagged 値を decode して `args: [...]` 表示（`vibe run --break`）。
      検証済み（`scripts/test_vibe_break_args.sh`）。残: 全 locals + local-name map
      （任意の名前付きローカルの検査）は将来拡張。
- [x] **3-P3 step 実行 着地**（M3）— 停止フレームで `s`(step into)/`n`(step over)/
      `o`(finish)/`c`(continue)/`q`(quit) を stdin で受け、runner の pause loop が
      backtrace のコール深さで step を判定（関数粒度）。`stopped at: <fn>` 表示。
      検証済み（`scripts/test_vibe_step.sh` 14/14）。残: 行粒度 step（per-statement
      span が前提）。
- [x] **3-P4 名前付きローカル検査 着地**（M4）— codegen が `vibe.dbgnames`
      custom section（関数ごとに param 名を `\t` 区切りで記録、最大16）を埋め、
      runner が `vibe.dbgargs` の値と突き合わせて停止フレームの引数を
      `name=value` 形式（例 `args: [x=20]`）で表示。count 不一致時は positional に
      fallback。DAP `variables` も名前付きで返す。検証済み
      （`scripts/test_vibe_break_args.sh` 6/6、`scripts/test_vibe_dap.js` 25/25）。
      残: 任意の式評価（watch）。
- [x] **3-D editor 統合（着地）** — `clients/js/dap_server.js`（stdio DAP server: 行→関数 breakpoint、step s/n/o/c、stack/args を `vibe run --break` から翻訳）+ `integrations/vscode-vibe`（debuggers contribution + adapter factory）。launcher は `--break`/`--trace` の stderr を FIFO で live stream（対話/DAP 用）。`scripts/test_vibe_dap.js` 25/25（純関数）。E2E は VS Code 必要。

> **DAP P1-P4 の実装設計（2026-06-25 調査）** — これは LSP サーバ構築に匹敵する
> 多コンポーネントの大型機能で、専用の focused 作業が必要:
>
> 1. **codegen: debug-line instrumentation** — coverage（`vibe_cov` bitmap）は
>    点ごとの**ソース span を発見済み**だが、実行機構が memory bitmap への store
>    なので「停止」には使えない。新たに「文ごとに host import `vibe::dbg_line(line, fp)`
>    を call する」debug 計装モードを足す（coverage の span 発見ロジックを再利用して
>    行番号を得る）。`VIBE_DEBUG=1` 系の codegen variant。
> 2. **runner: pause loop** — `viberun` に `vibe::dbg_line` host import を実装し、
>    breakpoint 集合と照合 → hit なら停止して DAP セッション（stdio JSON）を駆動。
>    変数検査は host ABI 経由で linear memory / locals を読み tagged 値を decode。
> 3. **DAP プロトコルサーバ** — `clients/js/`（LSP と同様の transport 抽象を再利用）
>    または runner 内に DAP（initialize/setBreakpoints/stackTrace/scopes/variables/
>    continue/next/stepIn）を実装。`integrations/vscode-vibe` に debug adapter 配線。
>
> P0（trap→source-line）は着地済みで M2 の体感価値は確保。P1-P4 は M3 の中核として
> 上記設計で別途着手する。命令オフセット粒度の行マップが要るため、source span の
> 全 Expr variant への拡張（span-arc step2）も前提に含む。

---

## テーマ 4: LSP の実装

### 現状

- **transport 層は実装済み**: `clients/js/lsp.js`
  （`bindLspTransport` / `createLspBridge` / `createWebSocketTransport`、
  stdio/ws 非依存）。`tests/integration-deno/vibe_lsp_transport_test.ts` あり。
- **シンボル index バックエンドは存在**（ただし MoonBit host `src/` 側）:
  `vibe ide`（outline / peek-def / search）と `vibe lsif` が
  共有 symbol index（`src/frontend/symbol_index.mbt`）を消費。
  `clients/js/index.js` が `createVibeService`（`check`/`ideOutline`/`idePeekDef`/
  `ideSearch`/`checkProject`）を wasm 経由で公開。
- **エディタ拡張は実装済み**（syntax のみ、language server 機能なし）:
  - `integrations/vscode-vibe/`（tmLanguage, language-configuration）
  - `integrations/treesitter-vibe/`（grammar + highlights/tags queries、corpus tests）
  - `integrations/zed-vibe/`（tree-sitter 参照、outline/brackets/indents queries）

### ギャップ

- **LSP サーバー本体が無い**: `vibe lsp` コマンドは docs 記載のみ。
  diagnostics / hover / go-to-def / completion / document symbols / formatting を
  LSP メソッドとして話す層が未実装。
- **バックエンドが host (`src/`) 依存**: selfhost-only 方針に対し、
  symbol index が MoonBit 側にある。コンパイラ側 `lib/@vibe/compiler/` への移植が要る。
- **parser に error recovery が無い**（横断土台 A）— 編集中ソースで診断/補完が
  破綻する。LSP 品質の最大ボトルネック。
- 型チェッカが部分的な型情報（hover 用の式の型、補完候補）を返す API を持たない。

### ゴール

VS Code / Neovim / Zed で「保存時診断 + hover で型 + 定義ジャンプ + 文書シンボル +
フォーマット」が動く LSP を、コンパイラをバックエンドに提供する。

### 決定（2026-06-25）

**LSP サーバーは native runner + compiler wasm で動かす（node 非依存）。**
install/​debugger と runtime 前提を一本化する。`vibe lsp` を
コンパイラをバックエンドにした language server として実装し、
`clients/js/lsp.js` の transport 抽象はブラウザ/embedding 用途の補助に留める。

### マイルストーン

- [x] **4-A parser error recovery**（= 横断土台 A、M2 前提）— `parse_program_recovering`
      （throw せずトップレベル文境界で再同期し、**全構文エラー** + 部分 AST を収集）を
      新設。厳格パス（`parse_program`/`parse_program_located`、コンパイラ self-compile
      用）は不変。`collect_all_diagnostics` → `vibe diagnostics <file>` で全診断を出力し、
      LSP（`runCheck`）が全件 publish（取れない時のみ `vibe check` 単発に fallback）。
      検証済み（`scripts/test_vibe_diagnostics.sh` 3/3、`test_vibe_lsp.js` 15/15:
      2行に跨る同時診断、compiler gate fixpoint green、located-diagnostics 7/7 非回帰）。
      残: 単一文**内**の複数エラー（現状は文単位で最初の1つ）。
- [~] **4-1 LSP MVP**（M2）— `clients/js/lsp_server.js`（stdio JSON-RPC）+ launcher
      `vibe lsp` を実装。`textDocument/publishDiagnostics` を提供（didOpen/
      didChange/didSave で native `vibe check` を駆動 → 診断を publish）。source
      span 未実装のため、診断メッセージ中のシンボルを文書テキストから探して範囲を
      近似。**documentSymbol / definition / hover** をトップレベル宣言のテキスト走査で
      提供（go-to-definition は宣言行へジャンプ、hover は宣言テキストを表示）。
      **型付き hover も着地**（下記 4-3）: hover は `vibe type-at` で推論型を
      表示し、取れない時のみ宣言テキストに fallback。診断範囲も source span
      着地で正確化（`[@off=N]` → 実 line:col）。検証済み（`scripts/test_vibe_lsp.js`
      14/14、型付き hover assertion 含む）。
- [ ] **4-2 compiler への index 移植**（M2–M3）— `src/frontend/symbol_index.mbt`
      相当を `lib/@vibe/compiler/` 側に持ち、host 依存を外す。
- [~] **4-3 definition / hover / completion / references / rename**（M3）—
      definition / completion はテキスト走査ベース。**references / rename は AST 精度化**:
      `vibe binding-at <file> <line> <col>`（compiler の `binding_occurrences`: 位置の
      識別子の binding を特定し、その occurrence の char-span を返す）を LSP rename/
      references が消費し、文字列/コメント/部分語の誤マッチを排除（テキスト走査に
      fallback）。検証済み（`scripts/test_vibe_binding_at.sh`、`test_vibe_lsp.js` 16/16）。
      **scope/shadowing 精度も着地**: `binding_occurrences` が scope-stack walk で
      カーソル識別子を最近接の binding（let/param/for/match binder）に解決し、その
      binding の occurrence のみ返す（f の `x` と g の `x` を区別、トップレベルは
      file-wide）。`test_vibe_binding_at.sh` 7/7。
      **hover は型付きに昇格**: `vibe type-at <file> <line> <col>`（compiler の
      `type_at_source`: 位置の EIdent を実オフセットで特定 → `check_program` →
      `env_lookup` + `type_to_string`）で推論型を返し、LSP hover が表示する
      （`clients/js/lsp_server.js`、`scripts/test_vibe_type_at.sh` 3/3 +
      `test_vibe_lsp.js` 16/16）。**signatureHelp も追加**: 呼び出し `foo(│)` の
      中で callee の推論シグネチャ `foo: (Int) -> Int` を表示（`vibe type-at`
      再利用、enclosingCall でバランス括弧を遡り activeParameter も算出）。
      **MVP スコープ**: トップレベル / import された
      value 名のみ解決。ローカル変数・パラメータは未対応（per-node 型テーブル＝
      span-arc step3b が前提）。スコープ精度の高い補完・rename も同 step が前提。
- [x] **4-5 editor 配線** — `integrations/vscode-vibe` に LSP client
      （`extension.js`、vscode-languageclient）を追加し `vibe lsp` を起動。
      `vibe.serverPath` 設定対応。tree-sitter/zed は grammar 済み（LSP 配線は今後）。
- [ ] **4-4 incremental**（M4, 任意）— 大規模プロジェクト向けに incremental
      parse/check。まずは module 単位キャッシュ（実装済み）で十分か評価。


---

## 依存関係と推奨順序

```
横断土台 A (parser error recovery) ──┬─→ 4 LSP (診断/補完の品質)
横断土台 B (name section/source map) ─┼─→ 3 debugger P0→P4
                                      └─→ 実行時エラーの可読性 (UX 全般)

1 install ──→ 外部ユーザーが触れる前提（最優先で着手可、他テーマと独立）
2 module  ──→ 実プロジェクトで使える前提（install と並行可）
```

- **すぐ着手**: テーマ 1（install）と土台 A/B は他に依存せず並行できる。
- **M2 の核**: 土台 A → LSP MVP、土台 B → debugger P0。この 2 つで
  「実用的な開発体験」の最低ラインに乗る。
- **M1 の核**: install + module の配布凍結。ここが無いと誰も試せない。

## 決定事項・未決事項（ADR 化対象）

決定済み（2026-06-25）:

1. ✅ **install canonical artifact** — 独自ビルドの wasmtime runner +
   compiler wasm の分離配布、install 時に各環境で `.cwasm` AOT ビルド。
   compiler は runner と独立に更新（テーマ 1）。
2. ✅ **module 配布モデル** — git/URL 分散（Deno/Go 風）、中央 registry なし、
   content hash で lock（テーマ 2）。
3. ✅ **LSP ホスト** — **native runner + compiler wasm に寄せる（node 非依存）**。
   install を独自 wasmtime runner に決めたのと整合させ、runtime 前提を 1 本化する。
   `vibe lsp` は同 runner 上で動く LSP サーバーとして提供し、
   `clients/js/lsp.js` の transport 抽象はブラウザ/embedding 用途の補助に留める
   （テーマ 4）。

4. ✅ **言語仕様 freeze の範囲**（M4, ADR-0057）— 1.0 で SemVer 2.0.0 保証する
   stable surface（言語コア / prelude / CLI / フォーマット）と、対象外の
   unstable surface（async / component model / capability / SIMD / span-arc /
   incremental / wasm-gc gap）を [spec/1.0-freeze.md](spec/1.0-freeze.md) に確定。

> runtime 前提は install・LSP・debugger すべて「独自 wasmtime runner +
> compiler wasm」に一本化された。node は補助（`clients/js/`、ブラウザ playground）
> に限定する。ADR 決定事項はすべて確定（install/module/LSP host/仕様 freeze）。
