# ADR-0088: capability authorization surface — `allows` 句・optional capability・`perform?`・preflight authorization

Status: proposed

Date: 2026-07-31

Related: #1218, ADR-0043(`--allow`/`--deny`/capability DCE), ADR-0071(effectset),
ADR-0075(`.vibex` runtime contract), ADR-0084(effect taxonomy / entry row 規則),
ADR-0085(`Exception[E]`)。背景・選択肢の比較は
[effect-taxonomy-review.md](effect-taxonomy-review.md) を参照。

## Context

ADR-0084 は effect operation を capability effect(resource kind を持ち host/provider
が解決する)、algebraic effect(in-process handler で discharge する)、core ambient
effect(言語予約の `Exception[E]`、移行中は `Error`)の三分類にすることを決めたが、
**表面構文は意図的に未決のまま残していた**。現状の単一 `with ...` 行では、
シグネチャを読んだだけでは「環境から解決される権限」と「プログラム内で handler が
解決する抽象」が区別できず、監査面(どの関数がどの外部権限を要求するか)が
構文上見えない。

また、effect システムと Deno 風権限認可には解決不能性の非対称がある。algebraic
effect は handler が無ければ実行できない(型エラー)のに対し、権限としての
capability は「権限が無いときのフォールバック」をプログラム側に書きたい。
[effect-taxonomy-review.md](effect-taxonomy-review.md) は Optional capability
(`Fs::Read[CacheDir]?`)+ 3値 `Attempt` を返す `perform?` を提案し、Deno の
mid-run permission prompt は ADR-0075 の「authority は run 中不変」の原則と衝突する
ため不採用とした。一方で「認可の束縛時期」は一つではない:

1. 型レベルで表現できない動的引数(computed key、動的 path)
2. ビルド時の静的分岐(SST 型 — grant を build 入力で確定し、分岐ごと消す)
3. 実行前(instantiate)の preflight 認可
4. TUI での対話的な認可

ADR-0043(`--allow-*`/`--deny-*`/`--profile`、未実装)はこのうち (2) を単独機能と
して提案していたが、review 文書が指摘した通り retrofit 後は ADR-0075 の
`Entry.requires ⊆ ComposedHost.provides` に吸収できる。本 ADR は、この4つの
タイミングを **単一の表面(Optional capability + `perform?`)と単一の解決ラダー**
に載せ、表面構文(`allows` 句)とあわせて確定する。

## Decision

### 1. `with A allows C` — 検査付き糖衣

関数シグネチャと関数型の effect row を、2つの句に分けて書けるようにする。

- 意味論は**単一 row のまま**とする。`with A allows C` は正規化 row `A ∪ C`
  へ脱糖し、ADR-0071 の正規化・`Rreq ⊆ Rdecl` 包含・contract hash・WIT projection
  は句の綴りに一切依存しない。同じ集合を裸 `with`、分割形、effectset 経由で
  綴った関数は byte-identical な contract hash / WIT を生成する。
- 分割述語は ADR-0084 の三分類に従う: **`allows` 句には capability effect のみ**、
  **`with` 句には algebraic effect・core ambient effect(`Error`/`Exception[E]`)・
  row 変数のみ**を書ける。違反(`allows Logger` 等)は分類根拠を示す型エラー。
- `.vibex` の `main` は追加規則を持つ: `with` 句は core ambient のみ、`allows` 句は
  capability のみ。これは ADR-0084 の entry row 規則の句ごとの再表現である。
- 糖衣は**型位置でも一様に使える**(高階関数パラメータ、型 alias、trait method
  シグネチャ、closure 注釈)。row 文法は1つであり、第二の row 表現は導入しない。
- **混在 effectset**: effectset の定義は ADR-0071 のまま透明・閉集合であり、
  カテゴリ制約を課さない。分類は常に**完全展開後の row** に対して行う。展開後に
  カテゴリが混在する effectset は裸 `with` からのみ参照でき、`allows` 句・分割形の
  `with` 句から参照すると、ADR-0071 様式の展開差分付き型エラーになる
  (`effectset X expands to { ... }; Fs::read_file is a capability effect and must
  appear in allows`)。fix-it は effectset の分割を提案するだけで、自動分割・
  自動移動はしない(ADR-0071 の「複数 consumer の権限を広げる fix-it を出さない」
  方針と一貫)。
- **row 変数**は `with` 句のみに書ける。`allows e` はエラーとする — `allows` は
  「全要素が静的に既知の capability OperationRef である」という約束であり、変数は
  それを満たせない。row 変数が混在集合へ実体化されることは従来どおり許す
  (意味論は単一 row であり、実体化先の具体 operation は呼び出し側の宣言 row で
  検査される)。`.vibex` main は closed row 必須(ADR-0075)なので row 変数が
  entry に到達することはない。
- `allows` は**文脈キーワード**とする(シグネチャ/型位置の row 直後でのみ認識)。
  予約語にはしない — repo 内に識別子としての使用はゼロだが、ユーザーコードを
  壊さないため。
- **通常関数の裸 `with`(混在可)は恒久的に合法**。分割形は監査面を見せたい場所で
  使うオプトインであり、既存コードの一括移行は要求しない。

### 2. Optional capability — `?` grade

capability の「無ければフォールバックする」要求を、row item の後置 `?` で表す。

- `?` を付けられるのは capability operation item(`Fs::read_file?`)、capability
  effect 全体(`Fs?`)、展開後 capability-only の effectset 参照(`Fs::Read?`)。
  後2者では `?` は展開後の**全 OperationRef に分配**される。
- 正規化 row の要素を `(OperationRef, Required | Optional)` に拡張する。grade は
  alias ではなく OperationRef 単位で持つ。同一 OperationRef が Required と Optional
  の両方で現れたら join = Required(強い方)に正規化する。
- **graded subset**: `Rreq ⊆ Rdecl` の各要素照合で `grade_decl ⊒ grade_req` を要求
  する。Required 宣言は Optional 要求を満たすが、Optional 宣言は Required 要求を
  満たさない(review 文書の 2 点束をそのまま採用)。
- `?` は**裸 `with` でも合法**。裸/分割は同じ row の綴り違いであり、片方でしか
  `?` を書けないと hash 不変性(Decision 1)が壊れる。
- algebraic / core ambient への `?` はエラー。optionality は grant の概念であり、
  handler で discharge する effect には「権限が無い」状態が存在しない。
- **hash 安定性**: Required をエンコード上のデフォルト(不在)とし、`?` を使わない
  既存 row の contract hash は本 ADR の前後で不変とする(fixture で固定)。

### 3. `perform?` と `Attempt[T, E]`

- `perform? Fs[CacheDir]::read_file(p)` は
  `Attempt[T, E] = NotGranted | Errored(E) | Granted(T)` を返す。`T` は operation
  の宣言結果型。`Attempt` は `lib/@vibe/core` の**通常の閉じた enum** であり、
  compiler magic は「`perform?` がこれを返す」ことだけ。
- **綴りの訂正 (#1345 実装時, 2026-08-05)**: 本 ADR は当初この型を
  `NotGranted | Failed(E) | Ok(T)` と定めていたが、`Ok` と `Failed` は**どちらも
  既に別 enum の constructor** だった — `Ok` は `@vibe/wit_runtime` の
  `Result[T, E]`(WIT `result<T,E>` への射影。#1324 が残した唯一の綴り)、`Failed`
  は `@vibex/concurrent` の `TaskError`。constructor は merge 済みプログラム全体で
  グローバルなので、名前を再利用すると1ファイル内で静かに隠れるのではなく、
  **両方を import するすべてのプログラムでもう一方の constructor を別型に
  すり替える**。実測: `Result` を import した状態で `Ok(T)` を宣言すると
  `fn r() -> Result[Int, String] { Ok(7) }` が
  `expected Result[Int, String], got Attempt[Int, ?t3]` で落ちる。`@vibe/core` は
  それらとの併用を避けられる package ではないため、成功 arm を `Granted`、失敗
  arm を `Errored` へ改名した。`NotGranted` は衝突が無くそのまま。
  (この「診断なしにすり替わる」挙動自体は #1078 の ctor 衝突ゲートが同一ファイル内
  しか見ていない取りこぼしで、別途追跡する価値がある。)
- v1 は `E = String`(現 `Error = Exception[String]` の payload)に固定する。
  ADR-0085 の typed `Exception[E]` が row の実表現に入った後、operation が宣言する
  exception kind へ一般化する。この結合は移行順序の制約として明記する。
- **strict grade-match** を採用する: `perform?` は enclosing row で **Optional と
  宣言された operation にのみ**使える。Required 宣言の operation への `perform?` は
  型エラー(fix-it: plain `perform` にするか、宣言へ `?` を付ける)。対称に、
  Optional 宣言の operation への plain `perform` も型エラー(NotGranted で起動した
  run では authority が無く、直呼びは成立しない)。これにより grade 推論は構文主導
  (`perform` → Required 要求、`perform?` → Optional 要求)になり、`Attempt` の
  `NotGranted` arm が静的に死んでいる型を作らない。warning 止まりの緩い変種は
  「型が到達可能性について嘘をつく」ため不採用。
- 文法: `?` は `perform` 直後(operation path の前)。既存の後置 `expr?`
  (`__try_op`)との曖昧性は「`perform` の直後に `?` + operation path が続く場合は
  `perform?` として読む」という lookahead で解決する(`perform` は soft keyword の
  ため規則を明文化する)。
- 注記(実装現実): builtin operation(`Fs::read_file` 等)は host import 直呼びに
  lower され、`handle ... with Fs { ... }` の arm は**実行されない**(vacuous-handle
  elimination)。capability の in-process mock は `perform` wrapper 層
  (`lib/@vibe/fs/fs.vibe`)か、plan フェーズの provider 差し替え(ADR-0075)で
  行う。handler は capability の傍受機構ではない。

### 4. 解決ラダー — build → apply → instantiate(mid-run 無し)

Optional capability の Granted/NotGranted は、**利用可能な最も早いフェーズで
ちょうど一回**確定し、run 中は不変とする(ADR-0075 の原則を維持)。

- **L1 build**: ADR-0043 の `--allow-*`/`--deny-*`/`--profile` を compile 入力として
  受け、確定した grant は build fact として記録する。codegen は該当 `perform?` の
  結果への match を const-fold し、死んだ arm を DCE する。operation の全使用が
  消えれば demand-driven import emission(既存)が import を落とし、
  SemanticContract から entry が消える(deny)/ resolved-Granted と記録される
  (allow)。**`@build.allows(...)` のような新しい式は導入しない** — `perform?` +
  const-fold で同じ表現力が得られ、表面が1つ減る。`@build.*` 定数は capability と
  無関係の build 設定にのみ残す。これにより ADR-0043 は本ラダーの L1 入力として
  吸収され、独立機能ではなくなる。
- **L2 apply**: build で未確定の Optional entry は、BindingLock の
  `optional_resolution: Map[OperationRef, Granted | NotGranted]` として apply 時に
  一回だけ確定する(review 文書の提案を採用)。`perform?` は実行中この固定
  テーブルを引くだけの純粋参照である。
- **L3 instantiate — preflight TUI prompt**: **`main` の1命令目より前に**、
  未解決の grant を一括で対話的に質問する。ただし prompt が扱えるのは
  **「認可」だけ**であり、対象は「composed host が provide できる(型の合う
  adapter/binding が存在する)が、まだ許可されていない」operation に限る —
  未確定の Optional は Granted/NotGranted、認可待ちの Required は
  grant-or-abort。**provider/binding 自体が `ComposedHost.provides` に無い
  Required は prompt の対象にしない**: instantiate 時点では provider 選択・
  residual import・binding・hash が確定済み(ADR-0075)であり、「grant」と
  答えても operation を呼べるようにはならないため、これは従来どおり
  非対話の preflight 失敗(構造化診断)として abort する。非 TTY の
  デフォルトは Optional → NotGranted、認可待ち Required → abort(不足 grant
  の一覧と、それを許可する `--allow-*` flag の正確な綴りを診断に含める)。
- prompt の結果は **per-run ephemeral** とする(どこにも永続化しない)。スクリプト
  用途は L1 の flag、環境固定は L2 の BindingLock が担う。grant 記録ファイルは
  将来の別 ADR とする — 導入するなら BindingLock 隣接のレビュー可能 artifact で
  あって隠し dotfile ではない、という制約だけ先に記す。
- **mid-run prompt は導入しない**。review 文書の「authority は run 中不変、
  instantiate 前に一括検査」の決定を維持する。「対話的」なのは確定の手段であって
  タイミングではない — L3 の prompt は preflight の一部であり、`main` 開始後に
  authority が変わることはない。

型で表現できない動的引数(computed key、動的 path)は本ラダーに乗らず、従来どおり
provider 側の実行時検証に委ねる(失敗は `NotGranted` ではなく `Failed(E)` /
checked failure として観測される)。静的にはリソース単位、動的には provider 保証と
いう二段構えは review 文書・ADR-0075 のままである。

### 5. `main` の段階的ゲート

- ADR-0084 Phase 3(entry 分類の有効化)の時点で: `.vibex` main の row に capability
  が裸 `with` のまま残っていたら **warning + 分割形への fix-it**。
- builtin retrofit Phase 5(ADR-0043 統合フェーズ)の時点で: capability を含む
  `main` は**分割形を必須**とする。
- row が core ambient のみの `main`(`fn main with Exception`)は書くものが無いので
  裸 `with` のままで恒久的に合法。通常関数はゲートの対象外(Decision 1)。

## Grammar sketch

```vibe skip
// 分割シグネチャ: with = algebraic/core-ambient, allows = capability
fn load_config() -> Config with Logger + Exception[IoError] allows Fs::Read[Cfg] {
  perform Logger::Log("loading")
  parse(perform Fs[Cfg]::read_file("config.json"))
}

// 型位置でも一様
fn with_retry(op: () -> Bytes with Logger allows Fs::read_file) -> Bytes { ... }

// Optional capability ('?' は capability item のみ、effectset 参照にも分配される)
effectset Fs::Read = { Fs::read_file, Fs::read_bytes }

fn maybe_use_cache() -> String allows Fs::Read[CacheDir]? {
  match perform? Fs[CacheDir]::read_file("cache.json") {
    Ok(bytes)  => Bytes::to_string(bytes)
    Failed(_)  => compute_fresh()   // 権限はあったが操作自体が失敗
    NotGranted => compute_fresh()   // そもそも権限が無い
  }
}

// Attempt は lib/@vibe/core の通常の閉じた enum
enum Attempt[T, E] { NotGranted, Failed(E), Ok(T) }

// .vibex main: with 句は core ambient のみ、allows 句は capability のみ
fn main with Exception[IoError] allows Fs::Read[CacheDir]? + Stdout {
  Stdout::write_stream(maybe_use_cache())
}
```

(`Fs[Cfg]` 等の resource kind パラメータの正式構文は ADR-0084 の未決点のままで
あり、上記は review 文書と同じ便宜表記である。)

## Consequences

- 関数シグネチャの `allows` 句が**そのまま監査面**になる: 環境権限を要求する
  関数は句を見れば分かり、`.vibex` main の `allows` 句は起動 preflight の契約
  そのものになる。
- contract hash / WIT は綴り(裸/分割/effectset)に不変なので、既存 package の
  contract 互換性を壊さずに導入できる。`?` を使わない row の hash も不変。
- ADR-0043 は独立機能としては消滅し、本ラダーの L1 入力(compile 時 flag)+
  const-fold DCE として実装される。「capability DCE」と「host satisfaction 検査」
  が `Entry.requires ⊆ ComposedHost.provides` に統合されるという review 文書の
  見立てを確定させる。
- ランナー(viberun / node runner)は現在**無条件に全 host import を注入**して
  いる。Optional の NotGranted lowering と preflight を実装するには、contract 駆動
  の import 注入(BindingLock / grant table を読んで register する)への移行が
  前提作業になる。
- `test {}` / `bench {}` ブロックは従来どおり ambient full authority(全 Optional
  = Granted 相当)を維持する。テストの権限を絞る話は本 ADR の対象外。

## Non-goals

- resource kind パラメータの表面構文(`effect Fs[R: Fs::Root]` の正式文法)。
  ADR-0084 の未決点のまま残す。
- mid-run の動的 grant / revoke / 再 prompt(ADR-0075 の据え置き領域のまま)。
- grant 永続化ファイル(将来 ADR)。
- Required/Optional の2点より細かい grant 格子。
- handler / discharge 意味論の変更(ADR-0050/0071/0076 のまま)。
- `region` / ADR-0060(review 文書の別トピック)。

## Implementation sequence

表面は本 ADR で確定するが、実装は builtin retrofit(review 文書 Phase 0–5)と
足並みを揃えた段階導入とする。各段で fixture 先行(TDD ロック)、
`stage2 == stage3` fixpoint 確認は bootstrap.md の運用に従う。

1. **parser/printer**: `allows` 文脈キーワード、`?` row item、`perform?`。
   round-trip fixture を先に書く。compiler 自身のソースは新構文を使わないため
   **bootstrap bump は不要**(seed が新構文を理解する tag を作るのは、compiler
   source が使い始めたくなった時点でよい)。
2. **checker**: 分割述語の検証(ADR-0084 の taxonomy metadata が前提)、正規化 row
   への grade 追加、graded subset。3綴り hash 同一 fixture、`?` 無し hash 不変
   fixture。
3. **`Attempt` + `perform?` 型付け**: strict grade-match。builtin operation への
   適用は retrofit Phase 1(暗黙 `Fs[Process::Root]`)が前提。
4. **BindingLock `optional_resolution` + instantiate preflight**: ランナー作業
   (`runtime/vibe` launcher、viberun / node runner の contract 駆動 import 注入、
   TTY prompt、非 TTY デフォルト)。
5. **main gating warning**(ADR-0084 Phase 3 と同時、fixture:
   `main with Fs` → warning + fix-it)。
6. **分割形必須化 + ADR-0043 flag 配線 + const-fold DCE**(retrofit Phase 5)。
   linear / wasm-gc 両 backend で DCE 挙動が一致することを differential gate で固定。

## Formal contract

ADR-0084 の Lean 層(`formal/VibeFormal/Effect/Taxonomy*.lean`、
`Capability/TaxonomyBridge.lean`)を grade 付き row へ拡張する。

- grade 格子(`Optional ⊑ Required`、join = Required)が effectset 展開・正規化で
  保存されること(monotonicity)。
- **Required-only 射影の健全性**: `Entry.requires` を Required エントリに限定して
  も ADR-0075 preflight の受理が保存されること(TaxonomyBridge の一方向 refinement
  の拡張)。これが「Optional が無くても main が起動できる」の形式的実体。
- **deny 単調性**: L1 で Optional を NotGranted に確定する操作は contract の
  requires 集合を縮めるだけで、authority を広げないこと。
- 反例の固定: plain `perform` が Optional 宣言に乗ることを許す壊れた checker が、
  authority 無しの実行を accept してしまうこと(strict grade-match の根拠)。
- oracle corpus(`formal/oracle/effect-taxonomy.tsv`)に grade 列を追加し、
  Optional 充足の両方向・混在 effectset の `allows` 参照 reject・row 変数の
  `allows` reject・main 分割 accept/reject・algebraic への `?` reject の 6–8 ケース
  を追加する。

## Reconciliation ledger

| 項目 | 根拠 / 観測 | 結論 |
| --- | --- | --- |
| 期待する契約 | 監査面(環境権限)がシグネチャで見えない | `allows` 句 = capability 専用の監査面。意味論は単一 row |
| 実装観測 | effect row は `Option[String]`(カンマ結合文字列)で grade も OperationRef も無い | 正規化 row への `(OperationRef, grade)` 導入が checker 前提条件 |
| 実装観測 | `handle ... with Fs` は builtin を傍受できない(host import 直呼び、arm は erased) | capability の mock は perform-wrapper 層 / plan 時 provider 差し替え。ADR に明記 |
| 実装観測 | ランナーは全 host import を無条件注入(viberun `register_imports` / node runner の fallback Proxy) | contract 駆動 import 注入が L3 preflight の前提作業 |
| 実装観測 | import emission は demand-driven(used builtin のみ)、`--allow-*` は完全未実装 | L1 const-fold DCE は既存機構の小さな拡張。ADR-0043 は L1 入力に吸収 |
| 回帰ガード候補 | 3綴り(裸/分割/effectset)hash 同一、`perform?`-on-Required reject、`perform`-on-Optional reject、main 分割 fixture | 実装 Phase 1–3 の compiler gate に固定する |
| 形式モデル | grade 格子・Required-only 射影・deny 単調性・strict grade-match の反例 | Lean + oracle TSV を実装に先行させる(ADR-0084 と同じ運用) |

## Risks

- **`perform?` と後置 `expr?`(`__try_op`)の曖昧性**: `perform` は soft keyword で
  あり、`perform?` は今日のパーサでは identifier + try-op に読める。lookahead 規則
  (`perform` 直後の `?` + operation path)を parser fixture で固定する。
- **row item の `?` と型の `T?`(Option 糖衣)**: row 文法と型文法は非交差だが、
  generic row item(`Exception[IoError]`、`Fs[CacheDir]?`)の printer round-trip を
  fixture でロックする。
- **`Attempt` の `E` が ADR-0085 待ち**: v1 `E = String` は意図した移行結合であり、
  typed Exception 着地時に一般化する(broken change にしない encode を検討)。
- **wasm-gc lane**: const-fold DCE による import 削減が linear / gc 両 backend で
  同一に働くことを differential gate で固定する(ADR-0039 dual-track)。
- **`allows` の文脈キーワード化**: 予約語にしないため、既存コードへの影響は無い
  見込みだが、シグネチャ位置の識別子 `allows` を使う既存 fixture が無いことを
  導入時に再確認する。
