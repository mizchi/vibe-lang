# ADR-0022: ディレクティブ構文

- Date: 2026-03-10
- Status: proposed
- Related: ADR-0021 (Effect Handler の `#import` で使用)

## Context

`#import("wasi:filesystem/read@0.2.0")` のようなコンパイラへの指示を
宣言の前に記述する必要が出てきた（ADR-0021）。
これを汎用的なディレクティブ構文として定義し、`#import` 以外にも
`#cfg`, `#name`, `#deprecated` 等の静的指示を統一的に扱えるようにする。

ディレクティブは実行時の関数呼び出しではなく、静的解析（パース時・コンパイル時）
でのみ処理される。

## Decision

### 単行ディレクティブ

行頭の `#` で始まる関数呼び出しスタイルの式をディレクティブとして認識する:

```
#directive_name(arg1, arg2, ...)
```

ディレクティブは直後の宣言（`let`, `effect`, `export`, `fn` 等）に付与される。

```
// import ディレクティブ — 外部エフェクトの CM 名前空間バインド
#import("wasi:filesystem/read@0.2.0")
effect Fs {
  read_file(path: String) -> String
}

// 条件コンパイル
#cfg(target = "wasi")
let platform_init = () -> Unit { ... }

// 操作名の明示的マッピング
#import("wasi:filesystem/types@0.2.0")
effect FsTypes {
  #name("read-directory-entry")
  read_dir_entry(fd: Int) -> Option<DirEntry>
}

// 非推奨マーク
#deprecated("use new_api instead")
let old_api = (x: Int) -> Int { x }
```

### 複数行ディレクティブ

`###directive_name` で開始し `###` で終了するブロックを複数行ディレクティブとして
認識する。ブロックの内容は最後の引数として `prompt("...")` に変換される:

```
###prompt
You are a helpful assistant.
Respond in JSON format.
###
let my_agent = (input: String) -> String with { AI } {
  perform complete(input)
}
```

上記は以下と等価:

```
#prompt("You are a helpful assistant.\nRespond in JSON format.")
let my_agent = (input: String) -> String with { AI } {
  perform complete(input)
}
```

複数行ディレクティブの用途:

```
// AI プロンプト（主要ユースケース）
###prompt
Given a file path, analyze the code and return a summary.
Output format: { "summary": string, "complexity": number }
###
let analyze = (path: String) -> AnalysisResult with { AI, Fs } { ... }

// ドキュメンテーション（将来）
###doc
This module provides filesystem utilities.
All operations require the Fs effect.
###
```

### 構文規則

1. 単行ディレクティブは `#name(args)` の形式。行頭でのみ有効
2. 複数行ディレクティブは `###name` で開始、`###` のみの行で終了
3. ディレクティブは直後の宣言に付与される。宣言なしのディレクティブはエラー
4. 複数のディレクティブを連続して記述可能（順序は宣言順に適用）:
   ```
   #cfg(target = "wasi")
   #import("wasi:filesystem/read@0.2.0")
   effect Fs { ... }
   ```
5. ディレクティブは実行時に評価されない。パーサーが AST に付与情報として保持し、
   コンパイラの各パスが静的に処理する

### AST 表現

```
// ディレクティブ値
enum DirectiveArg {
  DStr(String);           // "wasi:filesystem/read@0.2.0"
  DIdent(String);         // wasi
  DKeyVal(String, String) // target = "wasi"
}

enum Directive {
  DCall(String, Array[DirectiveArg])  // #import("..."), #cfg(target = "wasi")
}

// 宣言に付与
SEffect(Bool, String, Array[TypeExpr], Array[EffectOp], Array[Directive])
//                                                       ^^^ directives
SLet(Bool, Bool, String, Option[TypeExpr], Expr, Array[Directive])
//                                                ^^^ directives
```

### 初期サポートするディレクティブ

| ディレクティブ | 用途 | Phase |
|---|---|---|
| `#import("ns:pkg/iface@ver")` | CM 名前空間バインド | P2 (ADR-0021) |
| `#name("kebab-name")` | CM 関数名マッピング | P2 (ADR-0021) |
| `#cfg(key = "value")` | 条件コンパイル | 将来 |
| `#deprecated("message")` | 非推奨警告 | 将来 |
| `###prompt` | AI プロンプト付与 | 将来 |

## Consequences

良い面:
- 静的指示を統一構文で表現でき、言語拡張が容易
- `#import` が汎用ディレクティブの一例として自然に収まる
- 複数行ディレクティブにより、プロンプト等の長文テキストを自然に記述可能
- 実行時のセマンティクスに影響しないため、既存コードとの互換性を保てる

悪い面/トレードオフ:
- パーサーにディレクティブ解析のパスが追加される
- `#` が行頭でのみ特殊扱いされる規則をユーザーが理解する必要がある
- 不明なディレクティブの扱い（警告 vs エラー）のポリシー決定が必要
