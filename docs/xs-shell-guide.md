# XS Shell ユーザーガイド

## 概要
XS Shellは、XS言語のインタラクティブな開発環境（REPL）です。コードの実行、関数の定義、名前空間の管理などが可能です。

## シェルの起動
```bash
cargo run -p xs-tools --bin xs-shell
```

## 基本機能

### 1. 名前空間管理

#### 現在の名前空間を確認
```
xs:scratch> namespace
Current namespace: scratch
```

#### 名前空間の切り替え
```
xs:scratch> namespace myproject
Switched to namespace: myproject
xs:myproject> 
```

デフォルトでは `scratch` 名前空間で開始します。

### 2. 関数の定義と再定義

#### 関数の定義
```
xs:scratch> let double x = x * 2
double : Int -> Int
```

#### 再定義時の動作
- **同じ実装での再定義**: "Definition unchanged (same implementation)" と表示
- **異なる実装での再定義**: "Updated existing definition (previous definition: [hash])" と表示

例：
```
xs:scratch> let double x = x * 2     -- 初回定義
xs:scratch> let double x = x * 2     -- 同じ実装：変更なし
xs:scratch> let double x = 2 * x     -- 異なる実装：更新警告
```

### 3. 型注釈と演算

#### Float型の演算
```
xs:scratch> let celsiusToFahrenheit c = c * 1.8 + 32.0
xs:scratch> celsiusToFahrenheit 0.0
32.0
```

#### モジュロ演算子
```
xs:scratch> let isEven n = n % 2 = 0
xs:scratch> isEven 4
true
```

### 4. useディレクティブ

#### 標準ライブラリの使用
```
xs:scratch> use lib/String
xs:scratch> String.concat "Hello, " "World!"
"Hello, World!"
```

#### エイリアス付きインポート
```
xs:scratch> use lib/String as Str
xs:scratch> Str.length "hello"
5
```

### 5. 文字列操作

#### 複数の文字列連結
```
xs:scratch> String.concat "a" (String.concat "b" "c")
"abc"
```

#### パイプライン演算子の使用
```
xs:scratch> "hello" |> String.length
5
```

## 高度な機能

### コンテンツアドレス
各定義は自動的にハッシュ値が計算され、コンテンツアドレスとして管理されます。

```
xs:scratch> let factorial n = if n = 0 { 1 } else { n * factorial (n - 1) }
factorial : Int -> Int = <closure> [bac2c0f3]
```

### updateコマンド
保留中の変更をコードベースに保存：
```
xs:scratch> update
Updated 3 definitions:
+ double
+ celsiusToFahrenheit
+ isEven
```

### editsコマンド
保留中の編集を表示：
```
xs:scratch> edits
Pending edits:
  + double : Int -> Int
  + isEven : Int -> Bool
```

## プロンプトのカスタマイズ
プロンプトは `xs:名前空間名>` の形式で表示されます。名前空間を切り替えることで、異なるプロジェクトコンテキストで作業できます。

## トラブルシューティング

### 型エラー
型の不一致がある場合、詳細なエラーメッセージが表示されます：
```
xs:scratch> let add x y = x + y
xs:scratch> add "hello" 5
Type error: Cannot unify String with Int
```

### 未定義の変数
定義されていない変数を参照すると：
```
xs:scratch> unknown
Error: Undefined variable: unknown
```

## ベストプラクティス

1. **scratch名前空間の活用**: 実験的なコードは`scratch`で試してから、プロジェクト名前空間に移動
2. **定期的なupdate**: 重要な定義は`update`コマンドで保存
3. **型注釈の活用**: 複雑な関数には型注釈を付けて可読性を向上
4. **名前空間の整理**: 関連する関数は同じ名前空間にグループ化