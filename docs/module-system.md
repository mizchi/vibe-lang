# vibe Module System (歴史的記述 — v1)

> **現行の規則はここではない** (#1269): パッケージ境界・可視性・pin/update の
> 正本は [module-system-oracle.md の「現行モデル」節](module-system-oracle.md#現行モデル-canonical--ここが唯一の現行記述)。
> 本ドキュメントは v1 の設計経緯として残しており、以下に出てくる
> `module {}` ブロック・`vibe.deps`/`vibe.lock` を唯一の依存モデルとする記述・
> `index.vibe(i)` を境界とする記述は現行ではない。
>
> **v2 設計が確定しています** (ADR-0063/0064/0070, 2026-07-16):
> [module-system-v2.md](module-system-v2.md)。契約・唯一の境界 `index.vpkg` /
> nearest-owner 規則 / content-addressed `require` / `fn` 構文 / `module {}`
> ブロック廃止。本ドキュメントは実装フェーズの進行に合わせて置き換えられる。
> 実行可能な正本は [module-system-oracle.md](module-system-oracle.md)。
>
> **実装済み (2026-07-03)**: `fn` 構文 (#727, Phase A)。`module Name {}`
> ブロックと `export module` は **削除済み** (#728, Phase B) — 以下の
> 「モジュール定義」「モジュール import」節は歴史的記述。`Type::method` の
> qualified access と file import/export は不変。

## 目的
- ユーザー向けには `::` で統一された名前空間アクセスを提供する。
- 実装内部の解決/再配置は parser lower で吸収し、利用側 API はシンプルに保つ。

## 構文

### モジュール定義
```vibe
module math {
  let private_inc: (Int) -> Int = (x) -> { add(x, 1) }
  export let inc = private_inc
}
```

```vibe
export module math {
  export let inc: (Int) -> Int = (x) -> { add(x, 1) }
}
```

### モジュール import
```vibe
import ./lib.xm { module math }
math::inc(41)
```

```vibe
import ./lib.xm { module math as m }
m::inc(41)
```

```vibe
import /lib/@vibe/prelude/string { from_char_code }
from_char_code(65)
```

## 意味論
- `module foo { ... }` は内部的に `foo::name` 形式へ lower される。
- `export module foo { ... }` は `foo::...` を export する。
- `import <path> { ... }` は source 先行で import する。
- `/vibe/...` の場合は `/vibe/` を落とした名前空間を使う（例: `/lib/@vibe/prelude/string` -> `prelude/string::...`）。
- `import { ... } from ...` は廃止され、parse error になる。
- `module` import は `.xm` ソースのみ対応し、`foo::...` 形式 export を取り込む。
- アクセス子は `::` を正規とする。
- ディレクトリ import は `index.vibe` エンドポイントへ正規化される。
- 再 export は `export ./mod.vibe { A, B }` のように **名前を明示列挙する**。
  ワイルドカード再 export（`export ./mod.vibe { * }`）は **採用しない**（#628）。
  TypeScript の `export *` のように「どの名前がどこから来たか」が追えなくなる
  のを避け、明示的な公開境界（AI-friendly / コンテンツアドレスと整合）を保つため。
  取り込んだ名前を `export { ... }` で再列挙する冗長は、この明示性の代償として許容する。

### 旧 import 記法の移行

- 旧記法:
  ```vibe
  import { add } from "./lib.vibe"
  ```
- 新記法:
  ```vibe
  import ./lib.vibe { add }
  ```
- 現行 parser は旧記法に対して `import <module-ref> { ... }` 形式の migration error を返す。

## import kind
- `import <path> { x }`: `value`
- `import <path> { type T }`: `type`
- `import <path> { trait Eq }`: `trait`
- `import <path> { module foo }`: `module` (namespace import)

## trait / impl の import 意味論 (#1549)

- **trait は名前で import する**と、依存側の trait 定義 (メソッド行・supertrait・
  header binder) が consumer の環境に流れる。alias (`Greet as Salute`) は
  定義をエイリアス名で束縛し、その trait の impl 行もエイリアス名で複製する。
- **impl は名前を持たないので import 文そのものに随伴して流れる**。依存の
  checked 環境は自身の依存の impl も含むため、可視性は推移的 (merge された
  build lane と同じ答えになる)。
- これにより FS/import path でも user-trait bound が single-module と同じ
  規則で検査される (`no impl \`T\` for \`X\``)。
- struct / enum / type alias / effect 宣言はまだ環境 transport に乗らない
  (#1550 の module typing artifact で閉じる予定)。cross-module のこれらの
  誤用は現状 check を素通りし codegen 以降で落ちる。

## 制約 (現行)
- `import <path> { module foo::bar }` は未対応 (parse error)。
- `module` 本体は現状、以下の文のみを想定:
  - `let` / `export let` / `let mut`
  - 代入、式文、`import`
  - `test` / `bench`
- 空モジュールは parse error。

## 例
```vibe
// lib.xm
export module math {
  export let inc: (Int) -> Int = (x) -> { add(x, 1) }
}

// main.vibe
import ./lib.xm { module math }
let v = math::inc(1)
```

## 今後の拡張候補
- module 本体で許可する statement の拡張
- module import の wasm import 連携方針の整理

---

## 配布とパッケージ管理 (git/URL 分散)

vibe のモジュール配布は **git/URL 分散モデル**（Deno/Go 風）。中央 registry は
持たず、依存は git/URL を直接指し、取得物は content hash で lock する
（`docs/release-roadmap.md` テーマ2 の決定）。

### マニフェスト: `vibe.deps`

プロジェクト直下の `vibe.deps` に `<name> <url>` を 1 行ずつ書く（`#` 始まりは
コメント）。url は次の形式に対応:

| 形式 | 例 | vendor 先 |
| --- | --- | --- |
| 単一ファイル (`file://`) | `mathlib file:///abs/path/lib.vibe` | `deps/<name>.vibe` |
| 単一ファイル (`http(s)://`) | `mathlib https://example.com/lib.vibe` | `deps/<name>.vibe` |
| git リポジトリ | `mathgit git+https://host/repo#v1.2.0` | `deps/<name>/`（ディレクトリ） |

git url は `git+<remote>[#<ref>]`。`#<ref>` は tag/branch/commit、または
**semver 制約**。制約はリモートの tag 一覧から最高の満たすものを解決する:

| 制約 | 意味 |
| --- | --- |
| `^1.2.3` | `>=1.2.3 <2.0.0`（major 固定。`^0.2.3` は `>=0.2.3 <0.3.0`） |
| `~1.2.3` | `>=1.2.3 <1.3.0`（minor 固定） |
| `>=1.2`, `>1.2`, `<=2.0`, `<2.0`, `=1.2.3` | 比較演算子 |
| `1.2` | partial（`>=1.2.0 <1.3.0`） |
| `1` | partial（`>=1.0.0 <2.0.0`） |
| `*` / 省略 | 任意（最高 tag） |

完全な `1.2.3`（演算子なし）・branch 名・commit sha・`v` 付き tag は
**そのまま literal** に扱う（制約と解釈しない）。tag は `v` prefix の有無
どちらも可。解決した具体 tag/commit が `vibe.lock` に固定される。

### 取得: `vibe fetch [--frozen] [dir]`

`vibe.deps` を読み、依存を `deps/` 配下に vendor し、`vibe.lock` を書く。

- **単一ファイル** → sha256 で content-addressed cache + `deps/<name>.vibe`、
  lock に `sha256:<hash>`。
- **git** → clone + ref checkout → `deps/<name>/` に vendor、lock に解決した
  commit `git:<sha>` と content tree digest `tree:<sha>`。
- **transitive 解決** — vendor した git dep 自身が `vibe.deps` を宣言していれば、
  その dep の `deps/` に再帰 vendor する（相対 import がネストする）。
  `VIBE_FETCH_MAX_DEPTH=16` で cycle guard、`VIBE_NO_TRANSITIVE=1` で無効化。
- **`--frozen`** — 既存 `vibe.lock` に記録した commit に git dep を pin する
  （再現ビルド）。upstream HEAD が進んでも lock の sha を維持。lock に該当
  エントリが無ければエラー。transitive にも伝播する。

### 追加: `vibe add <name> <url> [dir]`

`vibe.deps` に 1 行追記して即 `fetch` する糖衣。

### 検証: `vibe verify [dir]`

vendor 済みの実体を `vibe.lock` に照合し、改竄・欠落を検出する（供給網整合性）。

- 単一ファイル dep → sha256 を再計算して比較。
- git dep → tree digest を再計算して比較（vendor 物の `deps/`・lock は除外
  するので transitive 解決の影響を受けない）。ネストした dep は各自の lock へ
  再帰して検証。
- いずれかが不一致/欠落なら非ゼロ終了。

### import 側

vendor された依存は相対 import で参照する:

```vibe
import ./deps/mathlib.vibe { add }       // 単一ファイル dep
import ./deps/mathgit/index.vibe { triple } // git dep（ディレクトリ）
```

### lock 形式 (`vibe.lock`)

タブ区切り。後方互換のため git dep の `tree:` は 4 列目に付与する。

```
mathlib   file:///abs/lib.vibe        sha256:<64hex>
mathgit   git+https://host/repo#v1    git:<40hex>      tree:<64hex>
```

### `vibe publish`

専用 registry は建てない。公開は **git push + tag** で代替する。利用側は
`git+<remote>#<tag>` で参照し、`vibe fetch` が tag を解決して commit を lock
する。発見性（検索）が要れば、後付けで軽量 index を足す余地は残す。
