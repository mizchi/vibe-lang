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

**05 / 08 は据え置き** — こちらは「位置が一切付かない」C カテゴリで、原因が別。
効果パス側のエラーは `EffectError` が offset を持たず、compile 経路の
`emit_compile_diag` が `locate_type_error` を呼ばない。後者を配線するには
offset がどのソース基準かを決める必要があり、merged 複数ファイルコンパイルでは
一意でない。誤った位置は位置無しより悪いので、別スライスとして #1514 に残す。

**ラチェットは位置の改善では落ちない** (`diag.grep` は文言だけを見る)。この表の
更新は手動 — 位置は「文言が変わっていないのに質が上がる」唯一の軸なので、
自動検出の対象外にしてある。

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
