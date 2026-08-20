# repair コーパス — 診断駆動修復の測定

rubric 8軸目 `repair_convergence` の実測基盤。「壊れたプログラムを与えたとき、
**コンパイラの出力だけを読んで**直せるか」を測る。

新しい言語なので初回コンパイルが通らないのは前提。測るのはそこではなく、
**落ちた後に収束できるか** — 診断が編集すべき場所と内容を示しているか。

## ケースの構成

```
repair/NN_name/
  broken.vibe      壊れたプログラム
  fixed.vibe       最小の修復 (診断から導けるはずの編集を1つ適用したもの)
  fixed.expected   fixed.vibe の期待標準出力
  entry            compile entry (省略時 main。test ブロックだけなら __no_entry__)
  diag.grep        診断に必ず含まれる部分文字列 (1行1パターン、全一致必須)
  silent           ↑の代わりに置く。「診断が出ないこと」自体が測定対象のケース
```

`bash eval/lang-review/run_repair.sh` が**二方向ラチェット**で検証する:

- `diag.grep` ケース — broken が compile FAIL し、診断が全パターンを含むこと
- `silent` ケース — broken が compile SUCCEED すること
- 全ケース — fixed が compile+run して `fixed.expected` と一致すること

silent ケースに診断が付くようになった場合も **FAIL する**。改善なので、
`silent` を消して `diag.grep` を書き、スコアを付け直してから通すこと
(`scripts/vibe_fmt_allowlist.txt` と同じラチェット規律)。

## 採点 (1ケース 0–4 点)

診断の**テキストだけ**から採点する。ソースを読み直さない・docs を引かない。

| 指標 | 点 | 定義 |
|---|---|---|
| **L** localization | 0/1 | 1 = 編集すべきトークンを行と列で指している。行だけ合っていて列が構文の先頭 (`1:1` など) を指すものは 0 |
| **A** actionability | 0/1 | 1 = 必要な編集そのもの、または編集を機械的に導ける規則を述べている。内部用語だけなら 0 |
| **C** convergence | 0/2 | 2 = メッセージだけから導いた1編集で緑になる / 1 = 絞り込めるが追加の探索が要る / 0 = 導けない (診断が無い場合を含む) |

**dimension score = 1 + mean(L + A + C)** — 0–4 点の平均に 1 を足して 1–5 に写す。

コーパスは**ラウンド間で固定する** (tasks と同じ扱い: 追加は可、変更は不可)。
スコアはコーパス構成の関数なので、構成を変えると推移が比較不能になる。

## 実測 (r4 / 2026-08-06, stage2 `console-exception-rowvar-2026-08-06_dd5d4e10`)

| # | ケース | 診断 (要約) | L | A | C | 計 |
|---|---|---|---|---|---|---|
| 01 | braced effect row (#1429) | `line 1:1: the braced effect row ... was removed in #1429 -- write` `with A + B` | 0 | 1 | 2 | 3 |
| 02 | retired `Error` label (#1461) | `line 6:1: ` `Error` ` was retired ... -- write ` `Exception` | 0 | 1 | 2 | 3 |
| 03 | top-level bare expr (ADR-0069) | `line 4:1: top-level expressions are not allowed; move it into fn main` | 1 | 1 | 2 | 4 |
| 04 | `test` 名が裸の識別子 | `line 1:1: expected test name string` | 0 | 1 | 2 | 3 |
| 05 | effect row 宣言漏れ | `effect row mismatch for 'helper': missing { Stdout::write_stream } ... hint: declare ...` | 0 | 1 | 2 | 3 |
| 06 | ユーザー関数の arity | `line 4:11-14: function arity mismatch for add: expected 2 args, got 3` | 1 | 1 | 2 | 4 |
| 07 | builtin の引数型 | `line 2:24-38: argument type mismatch for String::concat (arg 1): Int` | 1 | 1 | 2 | 4 |
| 08 | `handle` 適格性 (#1511) | `handle of effect 'Ask' cannot be compiled: ... (ADR-0076) ... 追記34 V2 ...` | 0 | 1 | 1 | 2 |
| 09 | `Stdout::write_stream()` (0引数) | **なし** — compile 成功、生成 wasm が不正で load 時に host が拒否 | 0 | 0 | 0 | 0 |
| 10 | `Stdout::write_stream(42)` | **なし** — compile も実行も成功し、garbage を出力 | 0 | 0 | 0 | 0 |

mean = 26/10 = 2.6 → **repair_convergence = 3.6**

### 採点の根拠 (個別)

- **01/02/04** — 文言は完璧 (必要な編集を名指しし、`vibe fmt` で直ることまで
  言う) が、位置が構文の先頭を指す。02 は `Error` が 6行目24列にあるのに
  `6:1` (= `fn` の位置)。行が合うので実用上は追える → L=0, A=1, C=2
- **03** — `4:1` が式そのものの位置。L=1
- **05** — **位置情報が一切無い** (`line:col` が付かない)。ただし `hint:` が
  書くべき宣言をそのまま出すので収束は1編集 → L=0, A=1, C=2
- **06/07** — `line:col-col` のスパンで該当の呼び出しを囲む。この2つが
  現状のベストプラクティス
- **08** — 位置なし。文言は適格な形 (直接 perform / トップレベル関数呼び出し /
  row 注釈付きクロージャリテラル) を列挙しているので**何に直すか**は分かるが、
  **body 内のどの呼び出しが問題か**を言わないので、呼び出しが複数ある body では
  二分探索が要る → C=1
- **09/10** — 診断が無い。09 は不正な wasm を吐き、host の load エラー
  (`expected 1 elements on the stack for fallthru`) がソース位置なしで出る。
  10 は**成功して間違った出力を出す** (silent miscompile)。→ 全項目 0

## 更新: #1513 を塞いだ (09 が silent → 診断あり)

ラチェットが設計どおりこの改善を検出して FAIL し、採点し直しを要求した。上の r4
表は**そのラウンドの記録として残す**。現行の値は:

| # | ケース | 診断 | L | A | C | 計 |
|---|---|---|---|---|---|---|
| 09 | `Stdout::write_stream()` (0引数) | `line 2:3-23: function arity mismatch for Stdout::write_stream: expected 1 args, got 0` | **1** | **1** | **2** | **4** (was 0) |

`line:col-col` のスパン付きで出るので、06/07 と同じ最良の段。

mean = 30/10 = 3.0 → **repair_convergence = 4.0** (r4 の 3.6 から)。
`type_soundness` の 3.0 も、silent miscompile が1種類消えたので次ラウンドで
見直す対象になる (スコアの更新はラウンドの仕事なので `scores/` は触っていない)。

**ケース 10 は silent のまま据え置き** — 直したのは arity であって引数の型では
ない。`Stdout::write_stream(42)` は今も compile も実行も通り garbage を出す。
ディレクトリ名 `09_silent_builtin_arity` は当初この2つが同じ穴だった経緯の記録
なので、名前は変えていない。

## 更新: #1514 の B カテゴリ (構文の先頭を指していた3件)

01/02/04 は文言が完璧なのに位置が構文の先頭を指していた。パーサには
` at #<token index>` という側チャネルが既にあり (`parse_program_located` が
line:col に解決して文言からは剥がす)、対象の3つの throw がそれを付けていな
かっただけだった。ソース基準の曖昧さが無いので、これは確実に直せる部類。

| # | 位置 (before → after) | L | 計 |
|---|---|---|---|
| 01 | `1:1` (`fn`) → **`1:14`** (`with {` の `{`) | 0 → **1** | 3 → **4** |
| 02 | `6:1` (`fn`) → **`6:24`** (`Error` そのもの) | 0 → **1** | 3 → **4** |
| 04 | `1:1` (`test`) → **`1:6`** (名前になるべきトークン) | 0 → **1** | 3 → **4** |

mean = 33/10 = 3.3 → **repair_convergence = 4.3** (r4 3.6 → #1513 で 4.0 → 4.3)。

## 更新: #1514 の C カテゴリ (05 — 位置が一切付かなかった)

当初「merged 複数ファイルでは offset の基準ソースが一意でない」と判断して降りたが、
**実装を読んだらそうではなかった**。`compile_source_wasi_only(source, entry)` は
ソース文字列そのものを受け取り、`check_program` はそれを lex した AST を見る —
つまり offset の基準は呼び出し側が持っている `source` で確定している。

塞いだのは2つ:

1. `EEEffectRowMismatch` に**呼び出しサイトの offset** を持たせた。walker の
   `ECall(callee, args, _)` arm がその場で offset を捨てていただけ
2. `emit_compile_diag_located` を足し、compile 経路で ` [@off=N]` を解決する

2 は**マーカーを持つメッセージだけ**に適用する。マーカーが無ければ
`locate_type_error` の first-occurrence ヒューリスティックに落ちて、もっともらしい
別の行を指しうる — 既存の全メッセージを黙って変える危険があるので、
「自分がどこから来たか述べている診断」だけが位置を得る。

| # | 位置 (before → after) | L | 計 |
|---|---|---|---|
| 05 | なし → **`line 2:3`** (effect を要求している呼び出しそのもの) | 0 → **1** | 3 → **4** |

mean = 34/10 = 3.4 → **repair_convergence = 4.4**。

**08 は据え置き** — こちらは codegen (`inline_direct_perform.vibe`) が投げる
ADR-0076 のエラーで、位置の出どころが `EHandle(body, arms)`。この AST ノードは
**offset フィールドを持たない**ので、付けるには EHandle を構築/分解している
全箇所に触る必要がある。別スライスとして #1514 に残す。

**ラチェットは位置の改善では落ちない** (`diag.grep` は文言だけを見る)。この表の
更新は手動 — 位置は「文言が変わっていないのに質が上がる」唯一の軸なので、
自動検出の対象外にしてある。

## 更新: #1513 の後半 (10 が silent → 診断あり)

arity に続いて**引数の型**も塞いだ。`builtin_first_arg_head` /
`builtin_arg_head_rest` という手書きの表 (Array / String / Bytes / FixedArray
しかカバーしていない) を、中央レジストリのパラメータ型へフォールバックさせた。
手書きの表は entry がある位置で勝つので、既に検査されていたものは verdict が
変わらない。

| # | ケース | 診断 | L | A | C | 計 |
|---|---|---|---|---|---|---|
| 10 | `Stdout::write_stream(42)` | `line 2:3-23: argument type mismatch for Stdout::write_stream: receiver type Int` | **1** | **1** | **2** | **4** (was 0) |

mean = 38/10 = 3.8 → **repair_convergence = 4.8**。

レジストリの型を head-kind 比較に落とすとき、`CtChar` は `CtInt` に畳む。
`Char` はこの言語では `Int` の別名 (lexer が char リテラルを `TInt` で出すので
`'A' == 65`、`core/types.vibe` の `char_int_compatible` が両方向に unify を許す)
であり、head 比較が `unify` の作らない区別を作ってはいけない。畳まないと
レジストリで `CtChar` と書かれた `Char::to_int` が `Char::to_int('A')` を弾き、
逆に `CtChar` の値 (`Char::from_int(65)`) が `CtInt` と書かれた
`Stdout::write_char` に渡せなくなる (実際に prelude の `char.vibe` が落ちた)。

**コーパスから silent ケースが無くなった。** 09/10 は「診断が出ないこと」を測る
ために置いた2件で、どちらも塞がった。今後 silent 種別が見つかったら**新しい
ケースとして追加する**(既存の変更は不可) — この2件は「かつて診断が無かった」
記録として、診断ありのケースのまま残る。

`type_soundness` を 4.0 → 3.0 に下げた理由 (rubric 4 の定義そのままの silent
miscompile) はこれで解消したので、次ラウンドの見直し対象。

## r5 として記録済み (2026-08-07)

上の4つの更新節 (#1513 arity → #1514 B → #1514 C → #1513 引数型) の到達点を
**r5 ラウンドのスコアとして確定した** (`scores/2026-08-07-r5.json`,
`findings/2026-08-07-r5.md`)。

| 指標 | r4 | r5 |
|---|---|---|
| L (位置) | 3/10 | **9/10** |
| A (実行可能性) | 8/10 | **10/10** |
| C (収束) | 15/20 | **19/20** |
| 合計 / repair_convergence | 26/40 = 3.6 | **38/40 = 4.8** |

残る減点は **08 (`handle` 適格性、L=0 C=1) の1件だけ**。ここから先は
コーパスを増やさないとスコアが動かない — 新しい silent 種別・位置なし種別を
見つける作業そのものが次の仕事になる。

### 09/10 の範囲 (実測) — #1513

`direct_call_return` の fast path (`checker.vibe`、#626 の seed ヒープ制約で
`lookup_builtin` を呼ばない) に載る builtin は arity が検査されない。引数型は
`builtin_first_arg_head` / `builtin_arg_head_rest` という**手書きの表**に載って
いるものだけが検査される。

| builtin | arity 検査 |
|---|---|
| `Stdout::write_char` / `Stdout::write_stream` | なし |
| `Env::get` / `Env::args_len` / `Env::args_get` | なし |
| `Stdin::read_char` / `Stdin::read_stream` | なし |
| `Fs::read_file` | なし |
| `Profiler::now_us` | あり |
| `Array::length` / `String::concat` | あり (引数型も) |

capability かどうかでは分かれない (`Profiler::now_us` は capability だが検査
される)。分かれ目は fast path に載っているかどうか。

## 更新: #1511 の (c) — 08 の文言を書き直した

08 は残る唯一の減点で、内訳は L=0 (位置なし) / A=1 / C=1。この更新で触ったのは
**A の中身**であって点ではない — 旧文言も「何に直すか」は述べていたので A は
元から 1 だった。

旧文言は `the site is not eligible for evidence-passing migration (ADR-0076)`
`and the replay engine was removed (追記34 V2)` と、**コンパイラ内部の語彙を
2節ぶん読ませてから**、実際に効く助言に到達していた。#1511 の指摘2
(「エラーが行動可能でない」) はここを指している。書き直しで:

- 効く文を先頭に出した (handled body に許される3つの形 → 直し方)
- **拒否される形を名指しした** — 「ローカル束縛やクロージャ引数越しの呼び出しが
  perform を隠す」。旧文言は許される形しか挙げておらず、読み手は自分の
  コードがどれに当たらないかを消去法で当てる必要があった
  (**この名指しは誤りだった — 末尾の「更新: #2137」節を見ること**)
- ADR 参照は末尾に残した (設計記録を追いたい読み手のため)

| # | L | A | C | 計 |
|---|---|---|---|---|
| 08 | 0 | 1 | 1 | 2 (据え置き) |

**スコアは動かない。** 点が動くのは (a) 位置を付ける (L) か
(b) body 内のどの呼び出しが不適格かを名指しする (C) の2つで、どちらも
別スライス:

- **L**: 出どころが `EHandle(body, arms)` で、この AST ノードは offset を
  持たない (#1514 に残置)
- **C**: `edp_body_has_opaque_call` (Bool) の隣に「最初の不適格な callee の
  名前と offset」を返す walker を足し、生き残った handle の body に対して
  走らせる。`edp_first_live_replay_handle` が effect 名しか返していないので、
  body も返すようにする必要がある。**C=2 と L=1 を同時に取れるのはこちら** —
  EHandle 自体の位置より「どの呼び出しか」のほうが編集位置として正しい

つまり 08 の残り2点は**同じ1つの作業**で取れる。#1511 / #1514 のどちらに
置くかは、その作業を始めるときに決める。

## 追加候補: #1525 (ローカル `enum` の silent miscompile)

r5 の申し送り「新しい silent 種別を見つけてケースを追加する作業そのものが次の
仕事」に対して、1件見つけて塞いだ。**ただしコーパスには足していない。**

見つかった形 (`examples/syntax.vibe` が type-check を通るようになって初めて
実行され、そこで露見した):

```
enum を fn/test の中で宣言すると constructor が作られず、
match が黙って `_` arm に落ちる (catch-all が無ければ trap)
```

塞ぎ方は「ローカル `enum` を located error で拒否する」。回帰は
`fixtures/typecheck/local_enum_rejected.vibe` (expected.tsv) がロックしている。

**コーパスに足さなかった理由**: 今足すと 4/4 のケースが1つ増えて
**分母が 10 → 11 になり、平均が言語の改善なしに上がる**。r5 (3.8/4 平均) と
r6 が直接比較できなくなる。

足す場合は r6 の仕事として、**10ケース版と11ケース版の両方を報告する**こと。
コーパスの「追加は可」規則はそのままだが、追加したラウンドは推移が
二重になる、という運用上の注記。

## 更新: #1514 C の残り — 08 が位置と名指しを得た (r5 内更新)

「08 の残り2点は同じ1つの作業で取れる」(上の #1511 (c) 節) を実施した。
`edp_body_has_opaque_call` (Bool) の隣に、同じ判定で**最初の不適格な呼び出し**を
`(callee 名, source offset)` で返す walker を足し
(`edp_first_opaque_call_info` / `edp_live_handle_opaque_info`,
`inline_direct_perform.vibe`)、エラー文に `(here: the call to 'bump')` と
` [@off=N:M]` marker を付けた。EHandle 自体は offset を持たないが、**編集位置と
して正しいのは handle ではなく犯人の呼び出し**なので、AST に手を入れずに済む。

位置の解決は「基準ソースを知っているレーンだけ」が行う:

- **`vibe check`** (`check_linked_file`): entry ソースに対して解決。ただし
  merged stmts には依存モジュール由来の offset も流れてくるので、
  `verify_culprit_off_marker` (cli_support.vibe) が **span がその位置に犯人名を
  実際に綴っているか**を検証してから解決する。不一致 (依存側の offset) は
  marker を剥がして位置なしに降りる — もっともらしく間違った行を指すのは
  位置なしより悪い (#1445 の教訓)
- **FS-compile レーン** (`vibe build/run/test`, この repair ハーネス):
  compile API が診断を生成した source snapshot を返さないため、offset の所有元を
  証明できない。`emit_compile_diag_fs_located` は犯人名を残して marker を剥がし、
  **位置なしへ fail closed** する (#1596)。snapshot を輸送できるようになるまで、
  entry の現在内容を読み直して位置を推測してはならない
- **single-source レーン** (self-build 用): desugar 後の AST で offset が
  失われるため名指しのみ・位置なし (marker は `emit_compile_diag` が常に
  剥がすので生の `[@off=` は漏れない)

| # | 位置 (before → after) | 名指し | L | C | 計 |
|---|---|---|---|---|---|
| 08 | `vibe check` は snapshot 証明付きで犯人位置、FS repair lane は安全のため位置なし (#1596) | **`(here: the call to 'bump')`** | **0** | 1 → **2** | 2 → **3** |

mean = 39/10 = 3.9 → **repair_convergence = 4.9**。FS compile API が consumed
source snapshot を診断側へ輸送できるまでは、誤った位置を出すより L=0 を選ぶ。
残る減点はケース08の位置情報1点。以降スコアを動かす場合も、上の
「追加候補」節の運用に従う。

## 更新: #2137 — 08 の文言が嘘をついていた

`#1511 の (c)` 節の「**拒否される形を名指しした**」が**誤りだった**。
2026-08-20 に stage2 で実測すると、名指しされた形のうち次はすべて
**コンパイルできる**:

| handled body が呼ぶもの | 実測 |
|---|---|
| row を持つクロージャ**引数** (`f: () -> Int with Ask`) | ok |
| row を持つローカル**束縛** | ok |
| handled body の**中で**定義した row 無しクロージャ | ok |
| performing な top-level `fn` の**別名** (`let alias = ask_once`) | ok |
| first-order builtin (`println` など、#2109) | ok |

実際に落ちるのは「この pass が中を見られない呼び出し」の一形だけで、しかも
08 のように**その呼び出しが handled body に無い**ケース (needing 関数の中の
row 無し引数経由) もある。旧文言はそこで「handled body に許されるのは…」と
述べており、**08 のプログラムが既に満たしている形**を助言していた。

書き直しは 3 分岐にした — 犯人を名指しできるとき / 呼び出しが名前でないとき
(即時適用ラムダ、`(t.0)(x)`) / 犯人が handled body に無いとき。どの分岐も、
実測して通ることを確認した編集だけを挙げる。`diag.grep` は新しい文言に更新
した。**`(here: the call to 'bump')` は据え置き** — これは装飾ではなく
`verify_culprit_off_marker` が犯人名を取り出す綴りで、変えると `[@off=N:M]`
が未検証のまま流れて #1596 の「依存モジュール由来の offset を entry の行に
解決してしまう」が復活する。

**スコアは動かない** (08 は L=0 / A=1 / C=2 = 3 のまま、mean 3.9 →
repair_convergence 4.9)。rubric の A が測るのは「編集を述べているか」なので、
嘘の編集を正しい編集に替えても点にはならない。L の残り 1 点も従来どおり
FS compile レーンの snapshot 輸送待ち。

accept/reject と文言の対は
`lib/@vibe/compiler/tests/handle_eligibility_diagnostic_test.vibe` が押さえて
おり、受理される形の実測表は `docs/cheatsheet.md` にある。

`08_handle_ineligible/diag.grep` は**次の bootstrap bump まで**、旧文言 (seed)
と新文言 (stage2) の両方に含まれる部分文字列だけを needle にしている —
`run_repair.sh` は generation の stage2 が無い環境 (CI の late shard) では
seed に fallback し、seed は旧文言を出すため、新文言専用の needle は
コンパイラの選ばれ方でスコアが変わる嘘の検証になる。bump 後は
`handle_eligibility_diagnostic_test.vibe` が押さえている新文言へ戻すこと。
