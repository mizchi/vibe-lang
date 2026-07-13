# doctest ハーネス第一弾 — cheatsheet 検証レポート (2026-07-12)

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
  `VIBE_PREOPEN_DIR=$ROOT VIBE_FS_COMPILE=1 VIBE_SELFHOST_IMPORT_ABI=raw` で
  stage2 wasm を食わせる (selfhost_only_gate.sh の 4/4 と同じ経路)。
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
3. **release-check への追加**: `selfhost_only_gate.sh` 本体には入れず、
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
