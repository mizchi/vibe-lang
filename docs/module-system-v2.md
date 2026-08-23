# vibe Module System v2 — 契約ファースト・パッケージシステム設計

> **現行の規則の正本は [module-system-oracle.md の「現行モデル」節](module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述)** (#1269)。
> 本ドキュメントは設計記録であり、`index.vibei` を契約ファイルの主役として
> 説明する箇所は現行の綴り (`index.vpkg`) より前の世代の記述である。
>
> Status: **implemented (A–G core, 2026-07-04; owner policy updated
> 2026-07-16)** (ADR-0063 / ADR-0064 / ADR-0070)。
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
fn read(path: String) -> String with Fs { ... }
fn identity[T](x: T) -> T { x }
fn f(x~: Int, y~: Int) -> Int { x + y }        // labeled args
```

- **純粋な sugar**: parse 直後に既存の `let rec name: (T...) -> R with .. =
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
  ([bootstrap.md](bootstrap.md) の手順に従う)。

## 2. 境界規則 — nearest `index.vpkg` owner

> **`index.vpkg` だけが boundary である。各 source は最寄りの祖先
> `index.vpkg` に所有される。**

- nested `index.vpkg` は別 package を開始する。
- owner を持たない source は公開 compatibility space として、owner の有無に
  かかわらず import できる。
- owner を持つ implementation import は importer と target の owner が同一の
  場合だけ許可。親→子・子→親の両方向で、別 owner の内部 source へ直接入れず、
  ownerless importer も owned implementation を bypass できない。
- 別 owner から見える入口は相手の `index.vpkg` facade だけ。
- `index.vibe` と legacy `index.vibei` は boundary ではない。ただし同じ
  directory に複数の index spelling があれば hard error。
- 暗黙 build root は `index.vpkg` 直下の通常 `*.vibe` のみ。subdirectory は
  再帰 discovery せず、direct root の relative import/export で到達させる。
- `_*.vibe` / `*.draft.vibe` は明示到達時だけ graph/hash に入り、最寄り owner の
  `index.vpkg` shared import を継承する。
- 正式な判定と実装対応は [module-system-oracle.md](module-system-oracle.md)。

## 3. 契約ファイル — index のトップレベル = 公開 API

> **index ファイルのトップレベルに並んでいるものが、その境界の公開 API の
> すべてである。**

現在の contract/boundary は `index.vpkg`。旧 spelling は compatibility lane:

| ファイル | 意味 |
|---|---|
| `index.vpkg` | bodyless 公開契約、依存宣言、shared import、package boundary |
| `index.vibei` | legacy bodyless 契約。boundary ではない |
| `index.vibe` | legacy 実装込み index。boundary ではない |

決め打ちの規則 (曖昧さ排除):

1. 同一ディレクトリに複数の index spelling があれば**ハードエラー**。
2. **モード混在禁止**: `index.vibe` 内の body なし `fn` はエラー、
   `index.vibei` 内の body 付き `fn` はエラー。
3. `index.vibe` モードの private ヘルパは兄弟ファイルに書いて import する。
   `priv` 修飾子は導入しない (「トップレベル = 公開」を例外なしに保つ)。
   1 ファイルに私的ヘルパを同居させたくなったら `.vibei` へ移行するサイン。

契約ファイル (`.vibei`) に書けるもの:

- 型定義。公開 struct/enum は定義ごと。実装を隠す場合は **`opaque type Ast`**。
- 関数シグネチャ (body なし `fn`)。**effect row (`with Fs`) は契約の中核
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
- 外部に subpath (`@lib/@vibe/compiler/syntax`) として見せるのは、**ルートの
  index.vibei が明示 re-export したときだけ**:

```vibe
// lib/@lib/@vibe/compiler/index.vibei
export ./syntax as syntax
```

ワイルドカード再 export は引き続き採用しない (#628 と同じ理由)。

## 5. コンテンツアドレス — バージョン = ハッシュ、semver は表示名

- **package_hash**: `index.vpkg`、直下 production roots、そこから relative
  edge で到達する同一 owner source、および自分の `require` 行の merkle tree
  hash。`_*.vibe` / `*.draft.vibe` も明示到達時は含む。`#ab12cd…` (短縮 prefix 可)。パッケージの
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

## 6. `require` — one line = manifest + lock

```vibe
// Same syntax in an index.vibei and at the top of a one-off script
require @vibe/core 1.2.3 = #ab12cd34      // bare triple = exact match
require @vibe/http ^1.2.3 = #77aa02ef     // ^ = compatible range (full triple required)
```

- **semver spelling is strict**: the only operators are "none (exact)" and
  `^`. `^1` / `^1.2` / `~` / `>=` / `1.x` / `*` are parse errors. The
  constraint is never consumed by the build (the hash is the truth), so the
  grammar stays minimal.
- **Only direct dependencies are written.** A dependency's hash is computed
  over its own `require` lines, so pinning the direct dependencies fixes the
  transitive closure (the same way a git commit hash fixes a tree). **Lock
  files are abolished** (`index.lock` is retired).
- **The hash is inserted by fmt / normalize**: write just
  `require @vibe/core 1.2.3` and `vibe fmt` completes the `= #hash`
  (a goimports-style "formatter that completes the code"). **Implemented**
  (#730 D-3): all three fmt entries (single-file `vibe_fmt.sh`, the batch
  lane behind CI's `vibe-fmt-check` and `pkf run fmt`, and the installed
  `vibe fmt`) fill via `fill_require_pins_lenient` (loader). Notes:
  - **fmt is offline.** It fills only when the workspace store
    (`.vibe/store/<name>/`) can answer; a line the store cannot answer is
    left verbatim (the current implementation emits no diagnostic — an
    unpinned require that reaches the build is rejected there; failing
    `--check` over an unanswerable line is not yet implemented).
  - Network access belongs to `vibe add` / `vibe update` / the first
    `vibe run`, never to fmt.
  - **The pinned form is canonical.** An unpinned line the store can answer
    is a DIFF under `--check`. The release-check normalize gate enforces
    "committed sources are always pinned" (this is the effective lock
    verification).
- **Duplicate detection with a unification hint**: the build never resolves
  conflicts. When one package name appears in the closure under multiple
  hashes, the answer is a deterministic error plus a machine-readable
  conflict listing and a suggestion:

```
error: duplicate package @vibe/core
  #ab12cd (1.2.3)  required by @lib/@vibe/compiler
  #cd34ef (1.2.5)  required by @vibe/http
hint: require @vibe/core 1.2.5 = #cd34ef override
```

- `require ... override` (root only) unifies every dependency onto that hash
  (the Nix `inputs.follows` analogue). Post-override consistency is verified
  by the whole-program check.
- `vibe dedupe` picks the highest version satisfying every constraint,
  confirms compatibility via contract diff, and proposes it; `--apply`
  writes it.
- A by-product of content addressing: identical code vendored under
  different names (matching package_hash or file hash) is also detected and
  proposed for unification.

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
- effect row が空なら、述語から semantic effect と Error が escape しないことは
  機械判定できる。ただし divergence、panic、Wasm trap、OOM が別にあるため、
  empty row だけでは totality は証明できない。Phase 3 の SMT 対象では termination
  条件と partial primitive の扱いを追加で定義する。

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

fn main() -> Unit with Stdout + Net { ... }
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

bootstrap 制約 ([bootstrap.md](bootstrap.md)): 新構文は
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
  `lib/@vibe/core/sha1.vibe` を contract import 経由で直接消費する
  (#726/#730 の flattener 刷新後に移行済み)。以前は vendored twin
  `lib/@vibe/compiler/cache/sha1.vibe` を別途持ち、gate step 6e が
  canonical との diff を強制していたが、その twin は #741 で削除され、
  drift-check 自体が不要になった。
- store 配布: `scripts/vibe_core_install.sh`（`.vibe/store/@vibe/core/`
  へ contract + impl をコピーし、VIBE_HASH でハッシュを表示）。
- E2E: `fixtures/vibe_core_pkg_test.vibe` が契約 import 経由で
  sha1 / leb128 / List / StringSet を横断使用する。
