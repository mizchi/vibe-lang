## xsh module/import design (draft)

### 目的
- Nix 的な「入力固定 + 純粋な出力 + 再現性」を、xsh の import を中心に表現する。
- 実行時ではなく **解決時(ビルド時)** に依存を固定し、結果は内容アドレスで参照する。
- 既存の xsh 文法を大きく崩さず、module system として自然に扱う。

### 非目的 / 先送り
- 具体的な **リテラル表現(ソース指定の文字列表現)** は後回し。
- CLI/lock ファイルの具体形式は後で決める。
- 実行時の外部アクセス(ネットワーク)は設計外。

---

## コア設計 (案)

### 1) import を module system の軸にする
import は「モジュールの評価結果(名前空間)」を返す純粋式として扱う。

```
import "path/to/mod.xsh" as mod
let x = mod.add(1, 2)
```

### 2) 依存の固定は SourceSpec + lock で行う
import は **SourceSpec** を参照するだけで、実体解決はロックを通す。

- SourceSpec は abstract な構造(後で文字列表現を決める)
  - 例: `{ kind: "git", locator: "github:owner/repo", rev: "...", hash: "...", subpath: "src/mod.xsh" }`
- lock が無い import は **コンパイルエラー**
- `xsh fetch` のような別コマンドで lock を生成/更新

### 3) module は「エクスポート可能な名前空間」
モジュールは **名前空間レコード** を返す。
export 方式はどれかを採用:

**A. 明示 export 文を追加 (推奨)**
```
let add = fn (x: Int, y: Int) -> Int { x + y }
let sub = fn (x: Int, y: Int) -> Int { x - y }
export { add, sub }
```

**B. 暗黙 export (全 top-level let/type/enum を公開)**
- シンプルだが、不要な公開が起きやすい

**C. exports レコードを慣習として扱う**
```
let exports = record { add, sub }
```
- 文法追加なし。import は `exports` だけを見る規約にする

### 4) import の構文案 (最小限)
- 現行: `import "path"` / `import name`
- 拡張案:
```
import "path/to/mod.xsh" as mod
import { add, sub } from "path/to/mod.xsh"
import mod from "path/to/mod.xsh"
```

### 5) 参照の正規化と内容アドレス
- 依存解決後は **内容アドレス**(hash)で参照。
- これは xsh の関数アドレス設計と整合。
- import で得た namespace の各シンボルは
  - `name#hash` を内部的に保持
  - 人間可読名は別で保持

### 6) 純粋性と Effect
import は **純粋式** として扱う。

- 依存解決・ダウンロードは **コンパイル時の別フェーズ**
- 実行時は lock で固定済みの内容しか参照しない
- これにより import は `with {}` なしで使える

---

## 例 (将来像)

```
import "git:github:NixOS/nixpkgs@rev#hash//pkgs.xsh" as pkgs

let dev_shell = pkgs.mk_shell {
  packages = [ pkgs.wasm, pkgs.nodejs ]
}

export { dev_shell }
```

---

## 未決事項

- SourceSpec の具体的な記法
  - 文字列 (`"git:...@rev#hash//path"`)
  - record (`record { kind: "git", ... }`)
  - dedicated literal (例: `git("github:...", rev="...", hash="...")`)
- export の文法 (新規キーワード `export` を導入するか)
- lock ファイルの形式と配置 (例: `index.lock`)
- import の失敗時のエラー設計

---

## 次のステップ (設計)

1. export の方式を確定 (A/B/C のどれか)
2. import 構文の最小追加点を決定
3. SourceSpec の記法を決定
4. lock の運用フロー(生成/更新/検証)を決定
