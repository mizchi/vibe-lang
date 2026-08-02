# doctest ハーネス第一弾 — cheatsheet 検証レポート (2026-07-12)

> **2026-07-13 更新**: 運用化を実施。§4 (運用化の結果)・§5 (#830/#831 再現
> fixture)・§6 (発見した compiler/doc gap 一覧) を追記。対象 docs はすべて
> exit 0 (fail 0)。

0.3.0 ロードマップ「doctest + 実行可能な `*.vibe.md`」の第一弾。
markdown 中の ```vibe fenced block を selfhost stage2 で compile 検証する
ハーネス `scripts/doctest_extract_run.sh` を追加し、`docs/cheatsheet.md` で
試運転した結果と、docs 全体への展開・gate 組み込みの提案をまとめる。

## 1. ハーネスの使い方

```bash
bash scripts/doctest_extract_run.sh docs/cheatsheet.md          # 単一ファイル
bash scripts/doctest_extract_run.sh docs/*.md                   # 複数可
```

- block ごとに `PASS` / `FAIL` / `SKIP` を 1 行ずつ報告 (`<file>:<行番号>` 付き)。
  fail が 1 つでもあれば exit 1。
- compile は moon-free: `run_wasm_vibe_host_runner.sh --invoke cli_main` に
  `VIBE_PREOPEN_DIR=$ROOT VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw` で
  stage2 wasm を食わせる (compiler_gate.sh の 4/4 と同じ経路)。
- compiler は起動時に **一度だけ** 解決して work dir にコピーする
  (最新 `_build/selfhost/generations/*/stage2.wasm` → 無ければ
  `bootstrap/seed/selfhost_compiler.wasm`)。並行の bootstrap build が途中で
  generation を増やしても・消しても run 中の compiler は変わらない。
  `DOCTEST_STAGE2=<wasm>` で明示指定可。
- その他の env: `DOCTEST_WORKDIR` (中間ファイル置き場、default
  `_build/doctest/$$`、終了時に削除)、`DOCTEST_KEEP=1` (残す)、
  `DOCTEST_TIMEOUT` (block ごとの秒数、default 120)。
- 所要時間: cheatsheet 全 29 block で **~3.3 秒** (compile only)。

### block 分類 pragma (fence の info string)

| fence | 意味 |
|---|---|
| ```` ```vibe ```` | **compile check のみ** (entry `__no_entry__`)。default・安全側 |
| ```` ```vibe run ```` | compile (`_start` entry) + `--invoke _start` で実行。非 0 / trap は FAIL |
| ```` ```vibe skip ```` | 検証除外。**block 先頭行に理由コメントを書く運用** |

`vibe run` block は `export let _start` を持つ自己完結プログラムであること。

### 断片への配慮 (実装済みの吸収策)

- **`./lib/...` import**: work dir に `lib` symlink を張るので、block は
  「repo root に置いたファイル」として書けばよい
  (`import ./lib/@vibe/prelude/io.vibe { stdout_write }` が通る)。
- **宣言だけの block** (型 / `suberror` / effect 宣言のみ) は
  "no functions found to compile" で落ちるため、
  `export let __doctest_anchor: () -> Int = () -> { 0 }` を付加して
  一度だけ retry する (parse + typecheck の検証は維持)。
- それ以外の wrap (block を関数 body に包む等) は **不採用**: 式断片は
  救えるが top-level 宣言 (enum/struct/effect) を壊すため万能でなく、
  エラー行番号もずれる。断片は `vibe skip` タグで明示する方針。

## 2. cheatsheet 試運転結果

pinned stage2 = `_build/selfhost/generations/version-directive-2026-07-05_440d871/stage2.wasm`。

- 修正前: **9 / 29 pass**
- docs 修正 (2 block) + anchor retry (1 block) 後: **12 / 29 pass、17 fail**

### 直した docs 箇所 (今回 commit 対象の diff)

1. **`fn` block (旧 L72)** — `fn hello()` が `stdout_write` を import なしで
   使っていて `unknown name` になっていた。block 先頭に
   `import ./lib/@vibe/prelude/io.vibe { stdout_write }` を追加。
2. **effects block (旧 L466)** — 2 点:
   - `perform Logger::Log("hello \(name)")` が **0.3.0 で削除済みの
     `\(expr)` 補間**のままだった (compiler も「removed in 0.3.0」と
     診断する)。`\{name}` に修正。
   - top-level の裸の `handle { ... }` 式は handler が持つ `Stdout` effect を
     discharge できずコンパイル不能 (`use of undeclared effect Stdout`)。
     `let main: () -> Unit with { Stdout } = () -> { handle ... }` に包んだ。

### 落ちる 17 block の分類 (すべて「断片ゆえ」— skip 化は pragma 合意後)

行番号は修正後の cheatsheet.md 基準。

**A. 未定義名を参照する式断片 (構文提示が目的)** — 8 block
`:117` (lambda shorthand, `xs`), `:141` (pipe, `x`/`f`), `:171` (combinators,
`f`/`g`), `:188` (control flow, `cond`/`opt`/`arr`), `:257` (`is` expr,
`expr`), `:412` (tap, `x`/`next_stage`), `:563` (I/O builtins, `s`),
`:583` (idioms, `read_config` 等)。

**B. パターン構文の列挙 (そもそもプログラムでない)** — 1 block
`:226` (pattern matching 一覧)。

**C. `...` ellipsis 入り (意図的な省略)** — 2 block
`:355` (Result pipeline の `{ ... }`), `:613` (`#cfg` の `{ ... }`)。

**D. 直前の block の定義に依存** — 2 block
`:379` (`let*` — `parse_id` 等は 1 つ前の block で定義), `:441` (`?` —
`checked`/`half`)。→ 将来 `vibe continue` (前 block と連結して compile)
pragma で救える候補。

**E. top-level `let record { ... } = r` 破壊 (要議論)** — 2 block
`:240` (destructuring let), `:287` (Collections)。
検証で判明: **record destructure は関数 body 内では通るが top-level では
parse error** (`expected = but got {`)。tuple destructure
(`let (a, b) = (1, 2)`) は top-level でも通る。cheatsheet は #760 の機能を
top-level 断片として提示しているため落ちる。docs を関数内例に書き換えるか、
top-level record destructure を parser に足すかは compiler 側の判断
(今回 compiler は凍結のため報告のみ)。

**F. 存在しない import 先 (module system の構文一覧)** — 1 block
`:518` (`import ./lib.vibe { ... }`)。付随の compiler UX 発見:
**import 先ファイル欠落は綺麗な診断でなく
`[crash debug] ... fs_read_file failed ... ENOENT` で落ちる** (報告のみ、
compiler 凍結中)。

**G. effect context なしの直接呼び出し** — 1 block
`:572` (Profiler — `with { Profiler }` を持つ関数に包む必要あり。docs 側を
自己完結例に書き換えれば通せる、次弾候補)。

## 3. 今後の運用提案

### pragma 規約 (docs 全体の合意を取ってから適用)

- 上記 3 種 (`vibe` / `vibe run` / `vibe skip`) を規約化。`skip` は
  block 先頭行の理由コメント必須 (`// skip: 構文列挙のため非プログラム` 等)。
- A/B/C/F は `vibe skip` タグ、D は self-contained 化 (ないし将来の
  `vibe continue`)、E は関数内例への書き換え、G は self-contained 化が妥当。
  全 block をタグ付けすれば cheatsheet は green になり、以後の例の腐敗を
  CI が止める。

### gate への組み込み

1. **第一段階 (すぐ可能)**: `Taskfile.pkl` に `doctest` タスクを追加 —
   `bash scripts/doctest_extract_run.sh docs/cheatsheet.md`。
   cheatsheet の skip タグ付け完了後に有効化 (それまでは exit 1 のまま)。
2. **第二段階**: 対象を allowlist で拡大 (`docs/language-tour/*.md`,
   `docs/spec/syntax.md`, README)。ラチェット方式: green にしたファイルから
   allowlist に足す (adding-modules.md のテスト allowlist と同じ運用)。
3. **release-check への追加**: `compiler_gate.sh` 本体には入れず、
   `release-check` の独立ステップとして追加するのを推奨 (docs の赤で
   selfhost fixpoint 検証を止めない。~3 秒/ファイルなのでコストは無視できる)。
4. **`*.vibe.md` (literate)**: 本ハーネスがそのまま基盤になる。literate
   モードでは「全 block を 1 モジュールに連結して compile + `vibe run` 相当で
   実行」(D 類の依存も自然に解決) を `vibe run file.vibe.md` として
   compiler CLI に載せるのが最終形。それまでの繋ぎとして
   `doctest_extract_run.sh --literate` の追加も小さい。
5. **将来の出力アサーション**: `vibe run` block の直後の ` ```output `
   block を期待 stdout として照合する拡張 (rust doctest の `//=>` 相当) を
   次弾候補にする。

### 既知の制約

- 実行 (`vibe run`) は linear backend の `_start` 直接 invoke のみ。
  `vibe test` 相当 (`test { }` block) の doctest 化は未対応。
- compile check は「その block が単体プログラムとして valid」の検証であり、
  文中コードとの整合 (例: 表内のシグネチャ) までは見ない。

## 4. 運用化の結果 (2026-07-13)

pinned stage2 = `_build/selfhost/generations/version-directive-2026-07-05_fc45db4/stage2.wasm`
(scratchpad にコピーして run 中固定)。skip 理由は各 block 直前の
`<!-- doctest-skip: 理由 -->` コメントに記載する規約で統一した。

### PASS/SKIP 内訳 (before → after)

| file | before | after |
|---|---|---|
| docs/cheatsheet.md | 12 pass / 17 fail (29) | **14 pass / 16 skip / 0 fail (30)** |
| docs/vibe.md | 5 pass / 9 fail (14) | **6 pass / 8 skip / 0 fail (14)** |
| docs/language-tour/basics.md | 22 pass / 7 fail | **27 pass / 2 skip** |
| docs/language-tour/collections.md | 3 pass / 4 fail | **7 pass / 0 skip** |
| docs/language-tour/effects.md | 7 pass / 3 fail | **9 pass / 1 skip** |
| docs/language-tour/modules.md | 2 pass / 8 fail | **2 pass / 8 skip** |
| docs/language-tour/quick-start.md | 4 pass / 3 fail | **7 pass / 0 skip** |
| docs/language-tour/shell.md | 0 pass / 5 fail | **4 pass / 1 skip** |
| docs/language-tour/syntax-reference.md | 10 pass / 18 fail | **13 pass / 15 skip** |
| docs/language-tour/index.md | 2 pass / 0 fail | 2 pass (変更なし) |
| **計** | **67 pass / 74 fail (141)** | **91 pass / 51 skip / 0 fail (142)** |

- cheatsheet の E 類 (top-level record destructure, #830) は関数/ test body 内の
  例に書き換えて PASS 化 (Int64Array 部分は selfhost 未移植のため skip block に分離)。
- 直した主な doc バグ: 0.3.0 で削除済みの `\(expr)` 補間 (basics)、`Err` パターン
  arity、bare `to_string`、`sh`/`sh_lines` の効果を `{Stdout}` → `{Process}` に修正
  (+ String 戻り値の discard)、`Map::get_or`/`Map::map`/`Map::filter` →
  builtin + `lib/@vibe/core` の `get_or` に整理、JSON 例を
  `json_convenience.vibe` (`Json::field`) に合わせ、`Lines::parse` の import 追加、
  `(x) { ... }` (arrow なし block lambda、parse 不可) を `(x) -> { ... }` に修正、
  Result pipeline 例を stub 付き self-contained 化。
- skip 分類は §2 の A〜G をそのまま踏襲 (A: 未定義名断片 / B: 構文列挙 /
  C: ellipsis / D: 前 block・対ファイル依存 / F: 存在しない import 先 /
  G: effect context なし) + 「削除済み機能の歴史的記載」(modules.md の
  module block, #728) と「spec と実装の gap」(下記 §6)。

### ADR-0069 (top-level 式禁止) との併走について

検証中に並行 bootstrap が生成した新しい stage2 (gen `089474fe`) は
**ADR-0069: top-level 式文の禁止** (`top-level expressions are not allowed;
move it into fn main`) を実装していた。cheatsheet の該当 3 block は let 束縛 /
block 式に書き換え、**cheatsheet + vibe.md は旧 (pinned fc45db4)・新 (089474fe)
両方の stage2 で exit 0** を確認済み。

**ADR-0069 Phase 1 commit (811673d8) 後の追対応 (同日)**: language-tour で
fail していた 19 block を新仕様に合わせて書き換え、**全対象 142 blocks が
ADR-0069 実装済み stage2 で 91 pass / 0 fail / 51 skip (exit 0)**。

- **`fn main { ... }` 化 (4 block)**: index.md の Hello World / Entry Point、
  quick-start.md の Entry Point (いずれも `fn main with { Stdout }` +
  `stdout_write`)。Entry Point / CLI 節の文章も「entry は `fn main`、top-level
  は宣言限定、`let main: () -> Int` は従来形 (Int を print) として存続」に更新。
- **let 束縛 / block 式化 (15 block)**: 値例の裸式 (basics の Float/Double・
  for-in・loop・match・pipe・struct・derive・Option、collections の record match・
  tuple、effects の apply、syntax-reference の labeled call・struct・block・
  tuple index) は `let name = expr   // => 値` 形に変換 (fn main で包むより
  値例としての可読性が高く、旧 stage2 でも通る)。
- 注意: `fn main {}` sugar は新 parser のみ受理するため、fn main を含む
  index.md / quick-start.md の 3 block は **旧 stage2 (fc45db4 以前) では
  parse できない**。doctest gate は最新 stage2 を解決するので問題にならない。

### release-check への配線状況

- `Taskfile.pkl` に `doctest` タスクを追加済み:
  `bash scripts/doctest_extract_run.sh docs/cheatsheet.md docs/vibe.md docs/language-tour/*.md`
  (`cache = false` — stage2 解決が `_build` の状態に依存するため)。
- `release-check` の deps への追加は **保留**: 作業環境で pkfire package の
  取得が 403 になり `pkf run release-check` のグラフ評価を検証できなかった
  (releaseCheck 定義内の NOTE コメント参照)。`pkf run doctest` 単体 /
  CI 独立 step で green を確認してから deps へ昇格する。
- CI 独立 step 案 (ci.yml の selfhost-only-gate job、stage2 staging の後):

  ```yaml
  - name: Docs doctest (compile-check ```vibe blocks)
    run: |
      gen="$(ls -dt _build/selfhost/generations/*/ 2>/dev/null | head -1)"
      DOCTEST_STAGE2="${gen}stage2.wasm" \
        bash scripts/doctest_extract_run.sh \
          docs/cheatsheet.md docs/vibe.md docs/language-tour/*.md
  ```

## 5. #830 / #831 再現 fixture

### #830 — top-level `let record { ... } = r` が parse error

> **2026-08-01 更新 (#1281)**: この制限は解消した。top-level の irrefutable
> pattern `let` (tuple / record / named-struct) は parser が「値を保持する
> hidden binding + 名前ごとの射影」へ展開して動く。以下は当時の再現記録。

```vibe skip
// repro-830.vibe — top-level だと `expected = but got {`
let r = record { name: "vibe", ver: 1 }
let record { name: n, ver: v } = r
```

関数 body / block 式 / `test { }` body 内では同じ 2 行が通る (検証済み):

```vibe
let r = record { name: "vibe", ver: 1 }
let nv = {
  let record { name: n, ver: v } = r
  (n, v)
}
```

再現コマンド: 上の skip block を `repro.vibe` に保存して
`VIBE_PREOPEN_DIR=$PWD VIBE_FS_COMPILE=1 VIBE_IMPORT_ABI=raw \
bash scripts/run_wasm_vibe_host_runner.sh --invoke cli_main <stage2.wasm> repro.vibe out.wasm __no_entry__`
(doctest ハーネスの compile 経路そのもの)。

### #831 — import 先ファイル欠落が raw crash (ENOENT)

```vibe skip
// repro-831.vibe — located diagnostic でなく
// `[crash debug] ... fs_read_file failed for 'missing.vibe': ENOENT ...` になる
import ./missing.vibe { helper }
```

同経路の diagnostics: cheatsheet の Module System block (`./lib.vibe`)、
vibe.md の import 構文一覧 (`./std/stringify.vibe`)、language-tour の
2 ファイル例 (`./math.vibe`)。すべて `vibe skip` タグ + 理由コメントで
doctest からは除外済み — #831 修正後は「missing import の located error」を
期待する fixture に昇格できる。

## 6. 今回新たに見つけた compiler / spec gap (報告のみ、compiler 凍結中)

1. **`Int64Array::*` builtin が selfhost checker に未移植** — cheatsheet に
   記載があるが `unknown name: Int64Array::make`。
   docs/archive/moonbit-retirement.md の「要確認」項目そのもの (要ポート判断)。
2. **struct literal の明示型引数 `Pair[Int]::{ ... }` が parse error**
   (`unexpected token: ::`) — docs/vibe.md の "Struct and enum details" が
   spec として明記する形。実装との gap。
3. **struct literal の field shorthand `Pair::{ left, right }` が parse error**
   (`expected : but got ,`) — 同上 (record literal の shorthand は通る)。
4. **`Result::and_then` 連鎖で成功型が途中で変わると推論できない**
   (`(Int)->Result[String,E]` を最終段に置くと
   `return type mismatch: got Result[Int, ...]`)。`let*` 版も同様。
   docs の railway 例は同型 stage に揃えて回避した。
5. **`(x) { ... }` (arrow なし block-body lambda) は parse 不可** —
   syntax-reference が記載していた (docs は `(x) -> { ... }` に修正済み)。
6. **`import ./dep.vibe#hash` (PinnedPath suffix) が parse 不可**
   (`unknown # directive`) — modules.md が記載 (skip + 注記済み)。
7. **`where` (Array filter の prelude 関数) が現 prelude に存在しない** —
   shell.md が記載 (skip + 注記済み)。
8. **effect polymorphism の「wrapper が `{ e }` 未宣言ならエラー」の例が
   実際にはコンパイルが通る** (vibe.md / effects.md の `// error:` 例) —
   checker がこの違反を検出していない可能性。要確認。
   **調査結果 (#838, 2026-07-13)**: 実 gap と確認。#626 (transitive effect
   enforcement, 2026-06-28) で `check_perform_effects_expr_tx`
   (`checker_effects.vibe`) が effect ROW VARIABLE を transitive check から
   明示的に除外している (`label_is_effect_var` ガード、コメント
   "Effect-variable rows (polymorphic) impose nothing")。加えて `fn_names`/
   `fn_effs` の呼び出しグラフは top-level named binding のみを追跡するため、
   doc の例のようにラムダ引数 (`f`) 経由で呼ぶケースはそもそも追跡対象外。
   健全な修正には呼び出し箇所ごとの effect-row 単一化が要る (現状の
   label 文字列一致ベースの独立 pass では不可)。素朴に row-variable 除外を
   外すと `fixtures/typecheck/generic_effect_matrix_ok_passthrough_pure.vibe`
   のような正当な pure-instantiation ケースまで reject する false positive
   を確認したため、checker 修正は見送り、vibe.md / effects.md 側を
   「意図した設計だが未実装」と明記する docs-only fix に留めた
   (該当 block は `vibe skip` 化)。checker 側の是正は別 issue でトラック。
9. **`sh` / `sh_lines` の必要 effect は `{Process}`** (checker_effects.vibe)。
   docs の複数箇所が `{Stdout}` と記載していた (今回修正済み)。`sh` は
   captured output (String) を返すため `Unit` 関数では discard が必要。
10. **modules.md は削除済み機能 (`module` block #728、`.xm`、`module` import
    kind) を現行機能として記載** — セクション書き換えの別タスクを推奨。
11. **匿名 record の dot access (`r.name`) は bare な top-level 式文の位置で
    しか lower されない** — `let rn = r.name` や関数/test body 内では
    `unknown struct field: name` (#760 の部分実装)。ADR-0069 (top-level 式禁止)
    が入ると実質使えなくなるため、#760 側の lowering を式位置全般に広げるか
    docs から dot access を落とすかの判断が必要 (cheatsheet は destructure
    ベースに書き換え + 状態注記済み)。
