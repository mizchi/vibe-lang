# Vibe Language - AI向け高速静的解析言語

## 概要
Vibe言語は、AIが理解・解析しやすいように設計された静的型付き関数型プログラミング言語です。コンテンツアドレス型のコード管理、純粋関数型設計、そしてAIフレンドリーなエラーメッセージにより、AIによるコード理解と生成を最適化します。

## 言語の特徴

### 1. コンテンツアドレス型コードベース（Unison風）
- すべての式がSHA256ハッシュで一意に識別される
- 同じコードは常に同じハッシュを生成（決定論的）
- 変更の追跡が容易で、AIが差分を効率的に理解できる
- UCM（Unison Codebase Manager）風のedit/update機能

### 2. 純粋関数型プログラミング
- 副作用のない純粋関数のみ
- 自動カリー化による部分適用
- 参照透過性により、AIが関数の振る舞いを確実に予測可能
- Perceus参照カウントによる効率的なメモリ管理

### 3. Haskell風構文とブロックスコープ
- シェルフレンドリーな読みやすい構文
- ブロックスコープとパイプライン演算子のサポート
- Haskellに基づいた型システムと関数型プログラミング

### 4. Hindley-Milner型推論
- 明示的な型注釈を最小限に
- 完全な型推論により、AIが型情報を活用しやすい
- Let多相による柔軟な型システム

### 5. AIフレンドリーなエラーメッセージ
- 構造化されたエラー情報（カテゴリー、提案、メタデータ）
- 型変換の自動提案
- レーベンシュタイン距離による類似変数名の提案
- トークン効率的な英語メッセージ（将来的に多言語化予定）

### 6. 名前空間システム
- 階層的な名前空間（`Math.Utils.fibonacci`）
- コンテンツベースの依存関係管理
- 名前の解決とエイリアス機能
- インクリメンタルな再コンパイル

### 7. 構造的コード変換
- ASTコマンドによる安全な変換操作
- Replace、Rename、Extract、Wrapなどの基本操作
- 型安全性を保証する変換
- AIやツールからの予測可能な操作

### 8. エフェクトシステム（実装中）
- 拡張可能エフェクト（Extensible Effects）
- 関数レベルでのエフェクト推論
- `perform`構文によるエフェクト実行
- `handle/with`構文によるエフェクトハンドラー（実装予定）
- IO、State、Exception、Asyncなどの組み込みエフェクト

### 9. セマンティック解析フェーズ
- パース後の構造検証
- ブロックごとのエフェクト権限管理
- スコープとキャプチャの解析
- 特殊フォーム（match、do、handle）の検証

## アーキテクチャ

詳細なモジュール責務分担については[ARCHITECTURE.md](./ARCHITECTURE.md)を参照してください。

### crateの構成
- **xs-core**: 言語コア（AST定義、型定義、パーサー、プリティプリンタ、エフェクト定義）
- **xs-compiler**: コンパイラ（型チェッカー、エフェクト推論、セマンティック解析、メモリ最適化）
- **xs-runtime**: ランタイム（インタープリター、評価器、エフェクトランタイム）
- **xs-wasm**: WebAssemblyバックエンド（WASMコード生成、WASIサンドボックス）
- **xs-workspace**: ワークスペース管理（コードベース、インクリメンタルコンパイル、ブロック属性管理）
- **vsh**: 統合シェル・REPL（Vibe Shell、コマンドラインツール）
- **xs-test**: テストフレームワーク
- **xs-lsp**: Language Server Protocol実装（エディタ統合）
- **xs-mcp**: Model Context Protocol実装（AI統合）

### メタデータ管理
- ASTとは別にコメントや一時変数ラベルを管理
- NodeIdによる一意な識別
- コード展開時にメタデータを考慮した整形

## 基本構文

### 命名規則
- **lowerCamelCase**: 変数名、関数名はハイフンなしのlowerCamelCaseを使用
- 例: `strConcat`、`intToString`、`foldLeft`（~~`str-concat`~~、~~`int-to-string`~~、~~`fold-left`~~）

```haskell
# 変数定義
let x = 42
let y : Int = 10  # 型注釈（オプション）

# 関数定義（自動カリー化）
let add = fn x y -> x + y
let inc = add 1  # 部分適用

# letIn構文（ローカルバインディング）
let x = 10 in x + 5  # 結果: 15
let x = 5 in
  let y = 10 in
    x * y  # 結果: 50

# 再帰関数
rec factorial n =
  if (eq n 0) {
    1
  } else {
    n * (factorial (n - 1))
  }

# rec内でletIn使用（内部ヘルパー関数）
rec quicksort lst =
  match lst {
    [] -> []
    pivot :: rest ->
      let smaller = filter (fn x -> x < pivot) rest in
      let larger = filter (fn x -> x >= pivot) rest in
        append (quicksort smaller) (cons pivot (quicksort larger))
  }

# letRec（相互再帰対応）
letRec even n = if (eq n 0) { true } else { odd (n - 1) }
letRec odd n = if (eq n 0) { false } else { even (n - 1) }

# パターンマッチング（ofキーワード不要）
match xs {
  [] -> 0                        # 空リスト
  [h] -> h                       # 単一要素
  h :: t -> 1 + (length t)       # head/tailパターン
}

# 複数要素と残りのパターン
match lst {
  [a, b, c, ...rest] -> a + b + c  # 最初の3要素を取得
  [x, y] -> x + y                   # 2要素のみ
  _ -> 0                            # その他
}

# 代数的データ型
type Option a =
  | None
  | Some a

type Result e a =
  | Error e
  | Ok a

# モジュール
module Math {
  export add, multiply, factorial
  let add = fn x y -> x + y
  ...
}

# インポート
import Math
import List as L

# 名前空間での定義
namespace Math.Utils {
  let fibonacci = rec fib n ->
    if n < 2 {
      n
    } else {
      (fib (n - 1)) + (fib (n - 2))
    }
}

# 完全修飾名でのアクセス
Math.Utils.fibonacci 10

# レコード（オブジェクトリテラル）
let person = { name: "Alice", age: 30 }

# フィールドアクセス
let name = person.name
let age = person.age

# ネストしたレコード
let company = {
  name: "TechCorp",
  address: { city: "Tokyo", zip: "100-0001" }
}

# ネストしたフィールドアクセス
let city = company.address.city

# 関数的な更新（新しいレコードを作成）
let updatedPerson = { name: "Bob", age: person.age }

# エフェクトの使用例
# perform構文でエフェクトを実行
let greet = fn name -> perform IO ("Hello, " ++ name)

# handle構文でエフェクトを処理（実装予定）
handle {
  x <- perform State.get;
  perform State.put (x + 1);
  perform State.get
} {
  State.get () k -> k 0 0    # 初期状態0を返す
  State.put s k -> k () s    # 状態を更新
}
```

## 標準ライブラリ

### core.vibe
- 基本的な関数合成、恒等関数、定数関数
- Maybe/Either型と関連関数
- ブーリアン演算、数値ヘルパー

### list.vibe
- リスト操作: map, filter, foldLeft, foldRight
- リスト生成: range, replicate
- リスト検索: find, elem, all, any

### math.vibe
- 数学関数: pow, factorial, gcd, lcm
- 数値述語: even, odd, positive, negative
- 統計関数: sum, product, average

### string.vibe
- 文字列操作: concat, join, repeat
- 文字列比較: strEq, strNeq
- 文字列変換: intToString, stringToInt

## Vibe Shell (vsh)

### 基本コマンド
- `help` - ヘルプ表示
- `history [n]` - 評価履歴表示
- `ls [pattern]` - 名前付き式の一覧（パターンフィルタ対応）
- `search <query>` - 型・AST・依存関係による検索
- `find <pattern>` - 名前パターンによる検索
- `add <name> = <expr>` - 式に名前を付けて追加
- `view <name|hash>` - 定義の表示

### 検索機能
- `search type:Int->Int` - 型による検索
- `search ast:match` - AST構造による検索
- `search dependsOn:foo` - 依存関係による検索

### 使用例
```
xs> let double = fn x -> x * 2
double : Int -> Int

xs> double 21
42

xs> add double_fn = fn x -> x * 2
Added double_fn

xs> search type:Int->Int
Found 3 definitions:
double : Int -> Int [bac2c0f3]
double_fn : Int -> Int [bac2c0f3]
inc : Int -> Int [def456ab]

xs> search ast:match
Found 2 definitions:
quicksort : List a -> List a [abc123de]
findFirst : (a -> Bool) -> List a -> Option a [fed987cb]
```

## エラーメッセージの設計

### エラーカテゴリー
- **SYNTAX**: 構文エラー
- **TYPE**: 型エラー
- **SCOPE**: スコープエラー（未定義変数など）
- **PATTERN**: パターンマッチエラー
- **MODULE**: モジュール関連エラー
- **RUNTIME**: 実行時エラー

### エラー構造
```
ERROR[TYPE]: Type mismatch: expected type 'Int', but found type 'String'
Location: line 3, column 5
Code: x + y
Type mismatch: expected Int, found String
Suggestions:
  1. Convert string to integer using 'int_of_string'
     Replace with: intOfString y
```

## 実装状況

### 完了済み機能
- ✅ Haskell風パーサー（ブロックスコープ、パイプライン演算子、lowerCamelCase対応）
- ✅ HM型推論（完全な型推論サポート）
- ✅ 基本的なインタープリター
- ✅ 統合CLIツール (vsh: parse/check/run/test/bench/shell)
- ✅ 高機能REPL (Vibe Shell with 検索機能)
- ✅ コンテンツアドレス型コードベース
- ✅ 自動カリー化と部分適用
- ✅ 標準ライブラリ（core, list, math, string）
- ✅ パターンマッチング（`::` 演算子、リストパターン）
- ✅ レコード型（オブジェクトリテラル）
- ✅ 代数的データ型
- ✅ モジュールシステム（基本実装）
- ✅ ASTメタデータ管理
- ✅ AIフレンドリーなエラーメッセージ
- ✅ 階層的な名前空間システム
- ✅ 関数単位の依存関係追跡（型定義含む）
- ✅ ASTコマンドによる構造的変換
- ✅ インクリメンタル型チェック
- ✅ 差分テスト実行システム
- ✅ match構文の統一化（case/ofキーワード廃止）
- ✅ ==演算子のサポート
- ✅ エフェクトシステム（基本実装）
- ✅ セマンティック解析フェーズ
- ✅ AST/型による構造化検索
- ✅ ハッシュ参照（`#abc123`）
- ✅ バージョン指定インポート（`import Math@abc123`）
- ✅ 型推論結果の自動埋め込み
- ✅ 省略可能なパラメータ（`param?:Type?`）
- ✅ 新しい関数定義構文（`let func x:Int y:Int -> Int = x + y`）
- ✅ Option型の糖衣構文（`String?`）

### 開発中/計画中
- 📋 do記法の完全実装
- 📋 handle/with構文の完全実装
- 📋 エフェクト多相性
- 📋 統一文法の完全実装（keyword_form）
- 📋 構造化シェルのパイプライン処理
- 📋 実行権限システム（エフェクトベース）
- 📋 WASIサンドボックス
- 📋 並列実行サポート
- 📋 より高度な型システム（GADTs、型クラスなど）

## パフォーマンス
- インクリメンタルコンパイル（Salsa使用）
- Perceus参照カウントによる効率的なGC
- WebAssembly GCターゲット
- 型チェッカーベンチマーク実装済み

## テストカバレッジ
現在のテストカバレッジ: 76.63%

## 開発方針
1. **AIファースト**: すべての設計判断はAIによる理解・生成を優先
2. **純粋性**: 副作用を排除し、予測可能な動作を保証
3. **効率性**: 静的解析の高速化を重視
4. **拡張性**: 将来の機能追加を考慮したモジュラー設計

## 開発プラクティス

### テスト駆動開発
各ステップでは以下のテストを実行することを推奨します：

1. **型チェックとコンパイル**
   ```bash
   cargo check --all
   cargo build --all
   ```

2. **ユニットテスト**
   ```bash
   cargo test --all
   ```

3. **XSコード（セルフホスティング部分）のテスト**
   ```bash
   # vshを使用したテスト実行
   cargo run -p vsh --bin vsh -- test
   
   # 特定のファイルのテスト
   cargo run -p vsh --bin vsh -- test tests/xs_tests/
   
   # または Makefile を使用
   make test-xs
   ```

### コード品質管理
リファクタリング時には以下のツールを使用してコード品質を維持：

1. **Clippy（Rustの静的解析ツール）**
   ```bash
   cargo clippy --all -- -D warnings
   ```

2. **similarity-rs（重複コード検出）**
   ```bash
   # 重複コードの検出と除去
   cargo install similarity
   similarity check src/
   ```

### 推奨される開発フロー
1. 機能の追加・修正前に既存のテストが通ることを確認
2. 新機能のテストを先に書く（TDD）
3. 実装後、すべてのテストが通ることを確認
4. Clippyでコード品質をチェック
5. 重複コードがないか確認
6. ドキュメントを更新

## 今後の展望
- マルチコアCPUでの並列実行
- より高度な型システム（依存型、線形型など）
- ビジュアルプログラミング対応
- AIによる自動最適化
- 分散コードベース対応