# Vibe Language - 統一構文提案

## 設計原則

1. **すべては式** - 文と式の区別をなくし、すべてを式として扱う
2. **統一されたバインディング** - `let`による一貫したバインディング構文
3. **パイプライン指向** - データフローを明確にする演算子
4. **最小限のキーワード** - 構文の複雑さを減らす
5. **一貫したブロック構造** - `{}`の使い方を統一

## 基本構文

### 1. バインディング（すべて`let`で統一）

```vibe
# 値のバインディング
let x = 42

# 関数のバインディング（引数は`=`の前に）
let add x y = x + y

# 型注釈付き
let add (x: Int) (y: Int) -> Int = x + y

# 再帰関数（recキーワードを廃止、自己参照を自動検出）
let factorial n = 
  if n <= 1 then 1
  else n * factorial (n - 1)

# 相互再帰（andで連結）
let even n = if n == 0 then true else odd (n - 1)
and odd n = if n == 0 then false else even (n - 1)

# ローカルバインディング（in式）
let result = 
  let x = 10
  let y = 20
  in x + y
```

### 2. 条件分岐（`if-then-else`で統一）

```vibe
# 基本的なif式
let abs x = if x < 0 then -x else x

# ネストしたif式
let sign x = 
  if x > 0 then 1
  else if x < 0 then -1
  else 0

# ブロック内での複数の式
let process x =
  if x > 0 then {
    let doubled = x * 2
    let squared = x * x
    doubled + squared
  } else {
    0
  }
```

### 3. パターンマッチング（`case`式で統一）

```vibe
# 基本的なパターンマッチ
let describe_list xs = case xs of
  | [] -> "empty"
  | [x] -> "singleton"
  | [x, y] -> "pair"
  | x :: xs -> "multiple elements"

# ガード付きパターン
let describe_number n = case n of
  | n when n > 0 -> "positive"
  | n when n < 0 -> "negative"
  | _ -> "zero"

# ネストしたパターン
let process_option opt = case opt of
  | Some (x, y) -> x + y
  | None -> 0
```

### 4. 型定義（統一された構文）

```vibe
# 型エイリアス
type UserId = Int
type Email = String

# 代数的データ型（パラメータは型名の後）
type Option a = 
  | None
  | Some a

type Result e a = 
  | Error e
  | Ok a

# レコード型（構造的型付け）
type Person = {
  name: String,
  age: Int,
  email: Option String
}

# 型クラス（trait風）
type class Eq a where
  eq : a -> a -> Bool
  neq : a -> a -> Bool = \x y -> not (eq x y)

# インスタンス定義
instance Eq Int where
  eq = intEq
```

### 5. 演算子（優先順位を明確化）

```vibe
# パイプライン演算子（左から右へのデータフロー）
let result = 
  [1, 2, 3, 4, 5]
  |> map (\x -> x * 2)
  |> filter (\x -> x > 5)
  |> fold (+) 0

# 関数合成
let processData = 
  parseJson >> validate >> transform >> save

# 適用演算子（括弧を減らす）
print $ "Result: " ++ toString result

# レコード更新演算子
let updatedPerson = person with { age = 31 }
```

### 6. モジュールシステム（階層的構造）

```vibe
# モジュール定義
module Data.List exposing (map, filter, fold) where
  
  let map f xs = case xs of
    | [] -> []
    | x :: xs -> f x :: map f xs
  
  let filter p xs = case xs of
    | [] -> []
    | x :: xs -> 
      if p x then x :: filter p xs
      else filter p xs
  
  let fold f init xs = case xs of
    | [] -> init
    | x :: xs -> fold f (f init x) xs

# インポート
import Data.List (map, filter)
import Data.Maybe as Maybe
import Prelude exposing (..)  # すべてをインポート
```

### 7. エフェクトシステム（代数的エフェクト）

```vibe
# エフェクトの定義
effect State s where
  get : () -> s
  put : s -> ()

effect IO where
  print : String -> ()
  read : () -> String

# エフェクトの使用（do記法）
let increment = do {
  x <- State.get ()
  State.put (x + 1)
  return x
}

# ハンドラー定義
let runState initial action = 
  handle action with
    | return x -> \s -> (x, s)
    | get () resume -> \s -> resume s s
    | put s' resume -> \_ -> resume () s'
  end initial

# 複数エフェクトの組み合わせ
let program = do {
  name <- IO.read ()
  count <- State.get ()
  IO.print $ "Hello " ++ name ++ " (visit #" ++ toString count ++ ")"
  State.put (count + 1)
}
```

### 8. ブロック構造の統一

```vibe
# ブロックは常に最後の式を返す
let compute x = {
  let a = x * 2
  let b = x + 10
  a + b  # これが返り値
}

# do記法でのブロック
let action = do {
  x <- readInt
  y <- readInt
  return (x + y)
}

# where節（定義を後置）
let solve x = quadratic a b c where
  a = 1
  b = -x
  c = x * x - 4
```

## 構文糖衣

```vibe
# リスト内包表記
let evens = [ x * 2 | x <- [1..10], x mod 2 == 0 ]

# 匿名関数の短縮記法
let add = (+)
let double = (* 2)
let getName = (.name)  # レコードフィールドアクセス

# 部分適用の明示
let add5 = add 5 _

# Optional chaining
let city = person?.address?.city ?? "Unknown"
```

## 優先順位表

| 優先順位 | 演算子 | 結合性 |
|---------|--------|--------|
| 10 | 関数適用 | 左 |
| 9 | `.` (フィールドアクセス) | 左 |
| 8 | `^` (累乗) | 右 |
| 7 | `*`, `/`, `mod` | 左 |
| 6 | `+`, `-` | 左 |
| 5 | `::` (cons) | 右 |
| 4 | `++` (連結) | 右 |
| 3 | `==`, `!=`, `<`, `>`, `<=`, `>=` | なし |
| 2 | `&&` | 右 |
| 1 | `\|\|` | 右 |
| 0 | `\|>` (パイプライン) | 左 |
| -1 | `$` (適用) | 右 |

## まとめ

この統一構文の利点：

1. **一貫性** - `let`による統一されたバインディング
2. **簡潔性** - 必要最小限のキーワード
3. **表現力** - パターンマッチング、エフェクト、型クラス
4. **可読性** - パイプライン演算子による明確なデータフロー
5. **拡張性** - 新しい構文糖衣を追加しやすい

既存のコードからの移行：
- `rec`キーワードは不要（自動検出）
- `match`は`case`に統一
- `fn`は関数定義では不要（匿名関数のみ）
- ブロックの使い方を統一