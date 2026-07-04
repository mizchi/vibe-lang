# vibe Module System v2 — 契約ファースト・パッケージシステム設計

> Status: **implemented (A–G core, 2026-07-04)** (ADR-0063 / ADR-0064)。
> 全フェーズの中核が landing 済み: fn / module{} 削除 / .vibei 契約照合 +
> facade + 境界強制 + opaque / content-addressed require + store + fmt pin
> 挿入 + repin / where 契約の常時 runtime check / publish semver 機械検証 /
> seed bump `module-system-v2-2026-07-04` + compiler source の fn 移行開始。
> 後続: ネットワーク add/update、Fs::ReadDir(自動発見・global store)、
> 型封印(opaque の強制)、release strip、全ツリー移行。
>
> 決定の経緯: 2026-07-03 の設計セッション。関連 ADR: 0004 (コンテンツアドレス
> モジュール — 本設計はその具体化), 0005 (stdlib 階層), 0019 (canonical naming),
> 0061 (#cfg — seed 制約の先例), #716 (merge 層の可視性強制 — 本設計の実装基盤)。

## 0. 目標

1. **契約の確定**: パッケージの公開 API を 1 ファイル (契約ファイル) に集約し、
   実装から分離して機械照合する。人間にも AI にも「API 面だけを読む」ことを
   可能にする。
2. **決定的ビルド**: バージョン解決をビルドから追放し、コンテンツハッシュ
   のみでビルド入力を固定する (Nix / Unison 系)。lock ファイルを持たない。
3. **スクリプト性**: 単一ファイルに依存 pin まで書けて、それだけで永続的に
   再現可能なビルドになる。
4. **単純な規則**: 可視性・境界・解決の規則を、再帰適用できる少数の原則に
   畳む。修飾子や例外を増やさない。

## 1. `fn` 構文 (ADR-0064)

トップレベルの名前付き関数に `fn` を導入する。

```vibe
fn add(x: Int, y: Int) -> Int { x + y }
fn read(path: String) -> String with { Fs } { ... }
fn identity[T](x: T) -> T { x }
fn f(x~: Int, y~: Int) -> Int { x + y }        // labeled args
```

- **純粋な sugar**: parse 直後に既存の `let rec name: (T...) -> R with {..} =
  (params) -> { body }` へ脱糖する。checker / codegen は無変更。
- `fn` は常に完全注釈 (パラメータ型・返り値型) を要求する。ADR-0037 の
  前方参照・自己再帰の条件を常に満たすため、`rec` の書き分けが消える。
- `let` は値・計算で作る関数・高階の戻り値にそのまま残す。
  規約: 「トップレベルの名前付き関数は `fn`、それ以外は `let`」。
- 導入理由:
  1. 契約の `where` 節 (§7) が**引数名を参照する**必要があり、位置型
     `(Int, Int) -> Bool` では表現できない。
  2. `let f: (a: Int) -> R = (a) -> ...` の二重宣言の解消。
  3. AI の事前学習分布 (Rust/MoonBit 系 `fn`) との一致による生成誤り減。
- 移行: `vibe fmt` が旧形式を機械変換する (inline-param-type deprecation と
  同じ経路)。コンパイラ自身のソースで使うのは seed bump 後
  ([selfhost-bootstrap.md](selfhost-bootstrap.md) の手順に従う)。

## 2. 境界規則 — index を持つディレクトリは境界

> **index.vibe(i) を持つディレクトリは境界である。その外のファイルは、
> その中身を index 経由でしか import できない。**

- この規則は**再帰的**に適用される。パッケージルートは「一番外側の境界」
  にすぎず、パッケージ内サブディレクトリ (`syntax/`, `codegen/` 等) も
  index を置けば同じ規則で境界になる。
- 境界は**入方向のみ**制約する。境界内のファイルが外 (パッケージルートまで)
  を相対 import するのは合法。
- 相対 import は**パッケージルート (一番外側の index のあるディレクトリ) を
  上に越えられない**。
- 他パッケージの内部ファイルへの直接 import は禁止。外から見えるのは契約に
  書かれた名前だけ。
- 実装基盤: #716 の per-file export rename (`name_exp_<path>`) をパッケージ
  hash 込み (`name_exp_<pkghash>_<path>`) に拡張する。

## 3. 契約ファイル — index のトップレベル = 公開 API

> **index ファイルのトップレベルに並んでいるものが、その境界の公開 API の
> すべてである。**

拡張子が変えるのは「body がインラインか、外部照合か」だけ:

| ファイル | 意味 |
|---|---|
| `index.vibei` | 宣言は **body なし**。実装は同ディレクトリの `.vibe` に書き、契約に照合される |
| `index.vibe` | 宣言が **body を持つ** (実装込み)。小さいパッケージ・スクリプト向け |

決め打ちの規則 (曖昧さ排除):

1. 同一ディレクトリに `index.vibe` と `index.vibei` が両方あったら**ハードエラー**。
2. **モード混在禁止**: `index.vibe` 内の body なし `fn` はエラー、
   `index.vibei` 内の body 付き `fn` はエラー。
3. `index.vibe` モードの private ヘルパは兄弟ファイルに書いて import する。
   `priv` 修飾子は導入しない (「トップレベル = 公開」を例外なしに保つ)。
   1 ファイルに私的ヘルパを同居させたくなったら `.vibei` へ移行するサイン。

契約ファイル (`.vibei`) に書けるもの:

- 型定義。公開 struct/enum は定義ごと。実装を隠す場合は **`opaque type Ast`**。
- 関数シグネチャ (body なし `fn`)。**effect row (`with { Fs }`) は契約の中核
  情報**であり必須で照合される。
- `trait` / `effect` / `suberror` 宣言。
- サブ境界の公開: `export ./syntax as syntax` (§4)。
- パッケージメタデータと依存: `package` / `version` / `require` (§5–6)。
- `where` 契約節 (§7)。

`.vibei` 内では body のない `fn` がそのまま宣言になる。`declare` 等の新
キーワードは導入しない (`.vibe` 内の body なし `fn` はエラー、で曖昧さなし)。

帰結:

- **`export` キーワードは実装ファイルから撤去する** (契約モデル安定後の
  フェーズ)。可視性の唯一の情報源が契約ファイルになる。
- 契約に書かれていないトップレベル定義は自動的に境界内 private。
- `.vibei` の集合だけでワークスペース全体の API 面が読める (AI 文脈効率・
  人間のコードリーディング・LSP の workspace symbols)。
- incremental check の境界: 契約が変わらない実装変更は依存側の再チェック不要。

## 4. subpath の公開

サブ境界の存在 (内部整理) と外部公開は分離する:

- サブ index はデフォルトで **package-private の境界**。
- 外部に subpath (`@vibe/compiler/syntax`) として見せるのは、**ルートの
  index.vibei が明示 re-export したときだけ**:

```vibe
// lib/@vibe/compiler/index.vibei
export ./syntax as syntax
```

ワイルドカード再 export は引き続き採用しない (#628 と同じ理由)。

## 5. コンテンツアドレス — バージョン = ハッシュ、semver は表示名

- **package_hash**: パッケージディレクトリ (正規化ソース + 自分の `require`
  行) 全体の merkle tree hash。`#ab12cd…` (短縮 prefix 可)。パッケージの
  唯一の識別子であり、pin・store キー・依存解決のすべてがこれを使う。
- **contract_hash**: index の宣言部のみ (require pin を除く) の hash。
  API 互換シグナル・依存側再チェックのキャッシュキー・publish 時 semver
  検証 (§8) に使う。
- `version 0.1.0` は**人間向けエイリアス・メタデータ**。registry が
  `name@version → hash` を引くためだけの情報で、ビルドは信頼しない。
- **semver 解決はビルド時ではなく編集時**。`vibe add` / `vibe update` が
  registry を引いて hash を確定しソースに書き込む。**コンパイラは resolver
  を持たない**。ビルド入力は hash のみ → 決定的・オフライン再現可能。
- store: `~/.vibe/store/<hash>/` にコンテンツアドレスで展開。hash 検証する
  ため registry / ミラーは信頼不要 (Go module proxy / Nix substituter と同型)。
- Unison 流の**定義単位**ハッシュは defer。初版はパッケージ単位 merkle。
  contract_hash を宣言ごとに細分化する拡張余地は残す (ADR-0004 の三層 ref
  とはこの点で接続する)。

## 6. `require` — 1 行 = manifest + lock

```vibe
// index.vibei でも、単発スクリプトの先頭でも同じ構文
require @vibe/core 1.2.3 = #ab12cd34      // bare triple = 完全一致
require @vibe/http ^1.2.3 = #77aa02ef     // ^ は互換範囲 (full triple 必須)
```

- **semver 表記は厳密**: 演算子は「なし (完全一致)」と `^` の 2 つだけ。
  `^1` / `^1.2` / `~` / `>=` / `1.x` / `*` は parse error。制約はビルドに
  使われない (真実は hash) ので grammar は最小でよい。
- **直接依存だけ書く**。依存先の hash はその依存先自身の `require` 行を
  含んで計算されるため、直接依存を pin した時点で推移閉包が固定される
  (git commit hash が tree を固定するのと同じ)。**lock ファイルは廃止**
  (`index.lock` は retire)。
- **hash は fmt / normalize が挿入する**: `require @vibe/core 1.2.3` とだけ
  書けば `vibe fmt` が `= #hash` を補完する (goimports 系の「コードを完成
  させる formatter」)。ただし:
  - **fmt はオフライン**。ローカル store / registry キャッシュから引ける
    ときだけ挿入。引けなければ行を残して diagnostics (`--check` では fail)。
  - ネットワークを触るのは `vibe add` / `vibe update` / 初回 `vibe run` 側。
  - **pinned form が正規形**。release-check の normalize gate が「コミット
    されるソースは常に pinned」を強制する (これが実質の lock 検証)。
- **重複検知と統一提案**: ビルドは解決しない。同名パッケージが複数 hash で
  閉包に現れたら決定的エラー + 機械可読な衝突列挙 + 提案:

```
error: duplicate package @vibe/core
  #ab12cd (1.2.3)  required by @vibe/compiler
  #cd34ef (1.2.5)  required by @vibe/http
hint: require @vibe/core 1.2.5 = #cd34ef override
```

- `require ... override` (root のみ) は全依存をその hash に統一する
  (Nix `inputs.follows` 相当)。override 後の整合性は whole-program check が
  検証する。
- `vibe dedupe` が全制約を満たす最大バージョンを選び contract diff で互換を
  確認して提案、`--apply` で書き込み。
- content-addressing の副産物: 別名 vendoring された同一コード (package_hash
  ないしファイル hash の一致) も検知して統一提案できる。

## 7. `where` 契約節 — 段階導入

シグネチャ末尾に不変条件を書ける (MoonBit の `proof_require`/`proof_ensure`
の形を踏襲):

```vibe
fn binary_search(xs: Array[Int], key: Int) -> Option[Int] where {
  requires: sorted(xs),
  ensures: result is Some(i) implies Array::get(xs, i) == key,
}

fn sorted(xs: Array[Int]) -> Bool      // 述語はただの pure 関数
```

- 予約する文法: `where { requires: expr, ensures: expr }`。`ensures` 内で
  `result` が返り値を参照。`implies` は論理含意。
- 段階導入:
  1. **Phase 1**: parse して保持。debug ビルド (`VIBE_CFG=dev` 系) で
     入口/出口の runtime assert に脱糖。release では零コスト。
  2. **Phase 2**: fuzz oracle。fuzz 基盤の「クラッシュしたか」に「契約違反」
     を追加する。
  3. **Phase 3**: SMT (Why3/Z3 系)。
- vibe は pure by default で effect が型に載っているため、「仕様に使える
  述語」= effect row が空の関数、が既に機械判定できる (MoonBit の
  `#proof_pure` 相当のマーカーが不要)。

## 8. publish 時の semver 検証 (Elm 方式)

`vibe publish` は前リリースと契約を diff し、宣言 semver を機械検証する:

- **patch**: contract_hash 不変 (実装のみ変更) でなければ拒否。
- **minor**: 宣言の追加のみ (既存宣言の型・effect row・where 節がすべて同一)
  でなければ拒否。
- **major**: 制限なし。

「semver は守られているはず」ではなく「守られていないと publish できない」。
`^` 制約が信頼できるのはこの検証があってこそ。

## 9. 単一ファイルスクリプト

```vibe
// fetch_report.vibe — この 1 ファイルで永続的に再現可能
require @vibe/http ^1.2.0 = #77aa02
require @vibe/json ^2.0.1 = #31bb9c

import @vibe/http { get }
import @vibe/json { parse }

fn main() -> Unit with { Stdout, Net } { ... }
```

- 任意のエントリ `.vibe` の先頭に `require` を書ける。
- 開発中は pin なしの bare import を許容 (ツールが解決)。`vibe run --freeze`
  (または初回実行時の自動追記) が `require ... = #hash` を書き込む。
- CI / `vibe build --release` は pin 必須。

## 10. 廃止するもの

- **`module Name {}` ブロック**: パッケージ + ファイル境界に一本化。
  `Type::method` / `Effect::Op` の qualified access はモジュールブロックと
  独立の機構なのでそのまま残る。(現状の使用は `examples/` 2 ファイルのみ。)
- **`index.lock`**: §6 のとおり require 行が兼ねる。
- **実装ファイルの `export` キーワード**: 契約モデル安定後に撤去 (§3)。

## 11. WIT との対応

`index.vibei` は事実上「vibe 語彙で書いた WIT」。effect→WIT mapping (#537,
[effect-wit-mapping.md](effect-wit-mapping.md)) と合わせて、パッケージを
wasm component として publish する際に WIT を契約から機械導出する。

## 12. 実装フェーズ

bootstrap 制約 ([selfhost-bootstrap.md](selfhost-bootstrap.md)): 新構文は
seed がそれを理解するまでコンパイラ自身のソースで使えない。各フェーズは
「user 向け実装 → gates → (必要なら) seed bump → compiler source 移行」の順。

| Phase | 内容 | 依存 |
|---|---|---|
| A | `fn` sugar (parser 脱糖のみ)。fixtures + fmt 変換 | なし |
| B | `module {}` ブロック削除 (examples 移行 + parser から撤去) | なし |
| C | `.vibei` 契約照合 + index 境界規則 + opaque type + 可視性 (checker/merge 層。#716 rename 機構の拡張) | A |
| D | `@scope/name` 解決 + store + `require`/hash + fmt pin 挿入 + dedupe/override | C |
| E | `where` 契約 Phase 1 (debug assert 脱糖) + fuzz oracle 接続 | A |
| F | publish + semver 機械検証 (registry は local/git から開始) | D |
| G | 実装ファイルからの `export` 撤去、compiler source の fn/契約移行 (seed bump を伴う) | C, D |

## 13. 最初の実パッケージ: @vibe/core (2026-07-04)

moonbitlang/core の構成を参考に、旧 `vibe/collection/{list,set}` /
`vibe/sha1` / `vibe/leb128` を **`lib/@vibe/core/`** に統合した。
このシステム自身のドッグフーディングであり、契約は
`lib/@vibe/core/index.vibei`（82 fn 宣言 + `type List[T]` / `type StringSet`）。

- **bodyless `type Name[T]` 宣言**: opaque と同じ機構で impl 側の型を
  透過的に re-export する契約文法（この抽出で必要になり追加）。
- **契約照合の any-match 化**: 同名の private 兄弟定義（list/set 間の
  bare alias 衝突回避）があっても、いずれかの exported def が
  シグネチャ一致すれば満たされる。
- **compiler 内部との関係**: build cache の identity hash は
  `vibe/compiler/cache/sha1.vibe`（vendored twin）を使い、canonical
  (`lib/@vibe/core/sha1.vibe`) との同期は selfhost gate step 6e が
  comment 行を除いた diff で強制する。compiler が @vibe/core を
  `require` で消費する形は #726/#730 の flattener 刷新後に移行する。
- store 配布: `scripts/vibe_core_install.sh`（`.vibe/store/@vibe/core/`
  へ contract + impl をコピーし、VIBE_HASH でハッシュを表示）。
- E2E: `fixtures/vibe_core_pkg_test.vibe` が契約 import 経由で
  sha1 / leb128 / List / StringSet を横断使用する。
