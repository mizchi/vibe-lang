# XS言語の新構文設計

## 設計原則

1. **最小限の構文**: `let`キーワードは`=`があれば不要
2. **順序独立**: do式以外では定義の順序は関係ない
3. **統一的なスコープ**: `let in`と`where`を統合した設計
4. **インタラクティブ性**: シェルでの段階的な構築をサポート

## 基本構文

### 関数定義と型の自動埋め込み

```haskell
-- ユーザーが入力
double x = x * 2

-- 評価後、型が自動的に埋め込まれる
double :: Num a => a -> a
double x = x * 2

-- より複雑な例
-- ユーザー入力（ブロックは式として評価される）
factorial n = if n <= 0 { 1 } else { n * factorial (n - 1) }

-- 単一式の場合はブロック不要
factorial n = if n <= 0 then 1 else n * factorial (n - 1)

-- 評価後
factorial :: (Num a, Ord a) => a -> a
factorial n = if n <= 0 then 1 else n * factorial (n - 1)

-- 部分的な型注釈も可能
-- ユーザー入力（一部の型を指定）
processInt :: Int -> _
processInt x = show x ++ "!"

-- 評価後（_が推論結果で置換）
processInt :: Int -> String
processInt x = show x ++ "!"
```

### 型推論の段階的な具体化

```haskell
-- 初回定義時
map :: (a -> b) -> [a] -> [b]
map f [] = []
map f (x:xs) = f x : map f xs

-- 使用時に型が特殊化されていく
-- ユーザー入力
doubles = map (*2)

-- 評価後（型が具体化）
doubles :: Num a => [a] -> [a]
doubles = map (*2)

-- さらに使用
result = doubles [1,2,3]

-- resultの型も記録
result :: [Int]  -- デフォルト数値型に推論
result = doubles [1,2,3]
```

### ブロックとスコープ

ブロック`{}`は最後に評価した式を返す一貫したルール：

```haskell
-- ブロックは式として評価される
result = {
  z = x + y    -- x, yはこの後で定義されるが問題ない
  x = 10
  y = 20
  z            -- 最後の式がブロックの値
}
-- result == 30

-- ブロックは式なので、どこでも使える
x = 5 + {
  a = 2
  b = 3
  a * b  -- 6を返す
}
-- x == 11

-- whereとlet...inの統合
-- 以下はすべて同じ意味
quicksort xs = {
  case xs of {
    [] -> []
    (p:rest) -> {
      smaller = quicksort (filter (<p) rest)
      larger = quicksort (filter (>=p) rest)
      smaller ++ [p] ++ larger
    }
  }
}

-- または（トップレベルでの定義）
quicksort xs = {
  smaller = quicksort (filter (<p) rest)
  larger = quicksort (filter (>=p) rest)
  
  case xs of {
    [] -> []
    (p:rest) -> smaller ++ [p] ++ larger
  }
}

-- whereスタイル（後方互換性のため）
quicksort xs = case xs of {
  [] -> []
  (p:rest) -> smaller ++ [p] ++ larger
} where {
  smaller = quicksort (filter (<p) rest)
  larger = quicksort (filter (>=p) rest)
}
```

### 統一的なスコープルール

```haskell
-- ブロック = スコープ = 相互再帰可能な定義の集合
compute input = {
  -- これらはすべて相互に参照可能
  result = process normalized
  normalized = normalize input
  process x = helper x * 2
  helper x = if x > 0 then x else -x  -- 単一式なのでブロック不要
  
  result  -- ブロックの値
}

-- whereは単なる構文糖
f x = g x where g y = y + 1
-- は以下と同じ
f x = { g y = y + 1; g x }

-- let...inも構文糖
f x = let y = x + 1 in y * 2
-- は以下と同じ
f x = { y = x + 1; y * 2 }
```

## 型注釈のベストプラクティス

### 基本方針：型を明示的に書く

```haskell
-- 推奨：トップレベル関数には型を書く
length :: [a] -> Int
length [] = 0
length (_:xs) = 1 + length xs

-- ローカル定義には必要に応じて
processData :: [Int] -> Int
processData xs = {
  -- ローカル関数の型は推論に任せてもOK
  helper x = x * 2
  sum (map helper xs)
}

-- ただし複雑な場合は型を書く
processComplex :: [a] -> (a -> Bool) -> [(a, Int)]
processComplex xs pred = {
  -- 複雑なローカル関数には型注釈
  indexedFilter :: [(a, Int)] -> [(a, Int)]
  indexedFilter = filter (pred . fst)
  
  indexedFilter (zip xs [0..])
}
```

### ワイルドカード型注釈

```haskell
-- 一部だけ指定して残りは推論
parseAndProcess :: String -> _
parseAndProcess input = {
  parsed = parseInt input
  case parsed of {
    Just n -> n * 2
    Nothing -> 0
  }
}
-- 評価後: parseAndProcess :: String -> Int

-- 複数のワイルドカード
transform :: _ -> _ -> Maybe Int
transform x y = 
  if valid x y 
  then Just (combine x y)
  else Nothing
-- 評価後の推論結果がエディタに表示される
-- transform :: String -> String -> Maybe Int
```

## ブロックとif/caseの統一的ルール

### ブロックは式

```haskell
-- すべてのブロックは最後の式を返す
value = {
  x = 10
  y = 20
  x + y  -- 30を返す
}

-- if式は任意の式を取る（ブロックも単一式も）
result = if condition then expr1 else expr2
result = if condition then { expr1 } else { expr2 }  -- ブロックも式

-- ブロックが必要な場合の例
processData x = if x > 0 {
  log "Processing positive value: ${x}"
  normalized = x / 100.0
  clamped = min normalized 1.0
  clamped * scale  -- 最後の式が返される
} else {
  log "Processing non-positive value: ${x}"
  0.0  -- 最後の式が返される
}

-- case式も同様
result = case maybeValue of {
  Just x -> x * 2  -- 単一式
  Nothing -> {     -- ブロックも使える
    log "No value found"
    defaultValue
  }
}
```

## インタラクティブな穴埋め（@記法）

### 基本的な穴

```haskell
-- 型推論による穴
> add5 :: _ -> Int
> add5 x = x + @
? Complete expression (inferred type: Int, x :: Int):
> 5
add5 :: Int -> Int
add5 x = x + 5

-- 明示的な型付き穴
> process :: [Int] -> _
> process = map @:(Int -> String)
? Complete function of type (Int -> String):
> show
process :: [Int] -> [String]
process = map show
```

### 段階的な構築

```haskell
-- 複数の穴を順番に埋める
> calculate = {
    x = @ :: Int
    y = @ :: Int
    x * y + @
  }
? Enter value for x (Int):
> 10
? Enter value for y (Int):
> 20
? Complete expression (Num a => a):
> 5
calculate :: Int = 205

-- 名前付き穴
> transform = map @f [1,2,3] where @f :: Int -> String
? Define function f (Int -> String):
> \n -> "number: " ++ show n
transform :: [String] = ["number: 1", "number: 2", "number: 3"]
```

### コンテキスト付き穴

```haskell
-- 穴の中で周囲の変数を参照
> scale factor list = map @ list
? Complete expression (current bindings: factor :: Num a => a):
> (* factor)
scale :: Num a => a -> [a] -> [a]

-- より複雑な例
> process data = {
    cleaned = filter (>0) data
    mapped = map @ cleaned
    sum mapped
  }
? Complete expression (context: cleaned :: (Num a, Ord a) => [a]):
> \x -> x * x
process :: (Num a, Ord a) => [a] -> a
```

## Effect Systemの設計原則

### Koka風の代数的エフェクト

```haskell
-- 基本原則
-- 1. Effectは明示的に定義される
-- 2. withでハンドラーを注入
-- 3. 静的解析でハンドラーの存在を保証

-- Effect付き計算
computation :: () -> <State Int, IO> String
computation () = {
  n <- get ()
  print "Current state: ${n}"
  put (n + 1)
  return "done"
}

-- ハンドラーで実行
main = with ioHandler {
  with stateHandler 0 {
    computation ()
  }
}

-- 純粋な計算（Effectなし）
pure :: Int -> Int
pure x = x * 2

-- ctl（限定継続）による制御
-- 継続を捕獲して操作
searchFirst :: forall a. (a -> Bool) -> [a] -> <Exception> a
searchFirst pred list = {
  for x in list {
    if pred x then return x
  }
  raise "Not found"
}

-- ハンドラーで早期脱出を実装
result = with earlyExitHandler {
  searchFirst even [1, 3, 4, 5]
}  -- 4を返す
```

## 型クラスとインスタンス

```haskell
-- 型クラス定義
class Eq a where {
  (==) :: a -> a -> Bool
  (/=) :: a -> a -> Bool
  
  -- デフォルト実装
  x /= y = not (x == y)
}

-- インスタンス定義
instance Eq Bool where {
  True == True = True
  False == False = True
  _ == _ = False
}
```

## 関数適用と結合ルール

### 基本的な関数適用

```haskell
-- 括弧なしの関数適用（左結合）
f x y z  -- ((f x) y) z と同じ

-- 例
map double list
filter isEven (take 10 numbers)
foldl add 0 list
```

### | 演算子（パイプライン - 最優先）

```haskell
-- | は左の値を右の関数に渡す（Unixパイプと同じ）
x | f  -- f x と同じ

-- 基本的なパイプライン
[1..10] | filter even | map (*2) | sum

-- 複数行での使用
result = getData config
       | validate
       | transform rules  
       | format template
       | print

-- 部分適用との組み合わせ
"hello.txt" | readFile | lines | map words | concat | length
```

### パイプラインでの関数適用

```haskell
-- 引数付き関数をパイプラインで使う
[1..10] | filter (> 5) | map (* 2) | foldl (+) 0

-- セクション記法
[1..10] | filter (> 5) | map (*2) | sum

-- ラムダ式
[1..10] | filter (\x -> x > 5 && x < 8) | sum

-- 複数引数の関数
"hello world" | split ' ' | join "-"  -- "hello-world"
```

### $ 演算子（低優先順位の適用）

```haskell
-- $ は | よりも優先順位が低い
print $ [1..10] | filter even | sum

-- ネストしたパイプライン
process $ getData config | validate | case result of {
  Ok data -> data | transform | save
  Err msg -> log msg
}

-- 関数合成との組み合わせ
apply $ f . g . h
```

### . 演算子（関数合成）

```haskell
-- パイプラインで使う関数を事前に合成
process = validate . transform . normalize

-- パイプラインと合成
[1..10] | process . filter even | sum

-- ポイントフリースタイル
sumOfEvens = filter even . map (*2) . sum
```

### 実用的なパターン

```haskell
-- パターン1: 純粋なパイプライン
result = input | stage1 | stage2 | stage3 | output

-- パターン2: 条件分岐を含む
result = getData key 
       | validate 
       | \data -> if isValid data 
                  then data | process | Ok
                  else Err "Invalid data"

-- パターン3: do記法との組み合わせ
main = do
  contents <- "data.txt" | readFile
  let processed = contents | lines | filter (not . null) | parse
  processed | validate | print

-- パターン4: エラーハンドリング
safeProcess input = input 
                  | parseInt 
                  | maybe (Left "Parse error") Right
                  | fmap (* 2)
                  | either error show
```

### ワンライナーのベストプラクティス

```haskell
-- シンプルな変換
quickSum = [1..100] | filter even | sum

-- ファイル処理
wordCount = "file.txt" | readFile | words | length

-- 複雑な処理（適度に改行）
report = getData url | parseJSON | extract "users" 
       | filter active | map summarize | formatTable

-- ネストしたデータ処理
stats = users | groupBy department 
              | map (\(dept, us) -> (dept, us | map salary | average))
              | sortBy snd
```

### 優先順位と結合性

```haskell
-- 優先順位（高い順）
-- 1. 関数適用（スペース）- 左結合
-- 2. . （関数合成）- 右結合  
-- 3. | （パイプ）- 左結合
-- 4. $ （低優先度適用）- 右結合

-- 例
print $ [1..10] | filter even . map (*2) | sum
-- 解釈: print ([1..10] | (filter even . map (*2)) | sum)
```

### シェルコマンドとの統合

```haskell
-- バッククォートでシェルコマンド
files = `ls -la` | lines | filter (endsWith ".hs")

-- より安全なコマンド実行
files = sh "ls" ["-la"] | lines | filter (endsWith ".hs")

-- パイプラインの組み合わせ
`cat data.txt` | lines | filter (not . null) | parse | process
```

## パイプラインとコンポジション

```haskell
-- Unix風パイプ（&使用）
result = input
  & filter isValid
  & map process
  & foldl combine initial

-- 関数合成（.使用）
pipeline = filter isValid . map process . foldl combine initial

-- $を使った適用
result = foldl combine initial $ map process $ filter isValid input

-- ポイントフリースタイル
sumOfSquares = map (^2) . sum
countEvens = length . filter even
```

## モジュールとインポート

```haskell
-- モジュール定義
module DataUtils {
  -- エクスポートリスト
  export (process, transform, Config)
  
  -- 実装
  process x = transform (prepare x)
  transform = map helper
  helper x = x * 2
  prepare x = x + 1
  
  -- 型定義
  type Config = { name :: String, value :: Int }
}

-- インポート
import DataUtils (process, Config)
import qualified Data.Map as M

-- ローカルモジュール（ブロック内限定）
result = {
  module Local {
    helper x = x * 2
  }
  map Local.helper [1,2,3]
}
```

## Effect System (Koka風)

### 基本的なEffect定義

```haskell
-- Effectの定義
effect State s {
  get :: () -> s
  put :: s -> ()
}

effect IO {
  readFile :: String -> String
  writeFile :: String -> String -> ()
  print :: String -> ()
}

effect Exception {
  raise :: forall a. String -> a
  catch :: forall a. (() -> a) -> (String -> a) -> a
}

-- コントロールオペレーター
effect Async {
  await :: forall a. Promise a -> a
  yield :: () -> ()
}

-- 代数的エフェクト
effect Choice {
  choose :: forall a. [a] -> a  -- 非決定的選択
}
```

### Effect型とハンドラー合成

```haskell
-- Effect型表記
increment :: () -> <State Int> Int
increment () = {
  x <- get ()
  put (x + 1)
  get ()
}

-- 複数のEffect
readAndProcess :: String -> <IO, State Int> String
readAndProcess filename = {
  content <- readFile filename
  count <- get ()
  put (count + 1)
  print "Processing file #${count}"
  return (toUpper content)
}

-- 純粋な関数（Effectなし）
double :: Int -> Int
double x = x * 2

-- 明示的なEffect注釈
pureComputation :: Int -> <> Int
pureComputation x = x * 2

-- ハンドラーの合成
-- 複数のEffectを扱う
combined :: () -> <IO, State Int> String
combined () = {
  msg <- readAndProcess "data.txt"
  n <- get ()
  print "Processed ${n} files"
  return msg
}

-- ハンドラーをネストして実行
result = with ioHandler {
  with stateHandler 0 {
    combined ()
  }
}

-- またはハンドラーを合成
composedHandler = composeHandlers ioHandler (stateHandler 0)
result = with composedHandler (combined ())
```

### withハンドラー (Koka風)

```haskell
-- withでハンドラーを注入
with handler <effect-expr>

-- State Effectのハンドラー
stateHandler :: forall a. s -> handler {State s} a (a, s)
stateHandler initial = handler {
  return x = (x, initial)
  
  get () k = with stateHandler initial (k initial)
  put s k = with stateHandler s (k ())
}

-- 使用例
result = with stateHandler 0 {
  x <- get ()
  put (x + 1)
  y <- get ()
  return y
}
-- result == (1, 1)

-- control演算子（限定継続）
ctl :: forall a b e. ((a -> e b) -> e b) -> e a

-- 例：例外のハンドラー
exceptionHandler :: forall a. handler {Exception} a (Maybe a)
exceptionHandler = handler {
  return x = Just x
  
  raise msg k = Nothing  -- 継続を破棄
  
  catch action handler k = 
    case (with exceptionHandler action) of {
      Just x -> k x
      Nothing -> k (handler "exception raised")
    }
}

-- IO Effectのハンドラー（実際のIO操作）
ioHandler :: handler {IO} a a
ioHandler = handler {
  return x = x
  
  readFile path k = k (unsafePerformIO (System.readFile path))
  writeFile path content k = k (unsafePerformIO (System.writeFile path content))
  print msg k = k (unsafePerformIO (System.print msg))
}
```

### 純粋な関数との統合

```haskell
-- 純粋な関数（Effectなし）
double :: Int -> Int
double x = x * 2

-- Effect付き関数
effectful :: '{State Int} Int
effectful = do '{State Int} {
  x <- get
  -- 純粋な関数を普通に呼べる
  let doubled = double x
  put doubled
  return doubled
}

-- 純粋な値をEffect文脈に持ち上げ
pure :: a -> '{e} a
pure x = do '{e} x

-- Effect関数の合成
compose :: (b -> '{e} c) -> (a -> '{e} b) -> (a -> '{e} c)
compose f g x = do '{e} {
  y <- g x
  f y
}

-- 条件付きEffect
when :: Bool -> '{e} () -> '{e} ()
when condition action = 
  if condition 
  then action
  else do '{e} ()
```

### 高度なハンドラーパターン

```haskell
-- 非決定的計算のハンドラー
choiceHandler :: forall a. handler {Choice} a [a]
choiceHandler = handler {
  return x = [x]
  
  choose options k = 
    -- すべての選択肢を試す
    concat (map k options)
}

-- 使用例：すべての組み合わせを生成
allPairs :: () -> <Choice> (Int, Int)
allPairs () = {
  x <- choose [1, 2, 3]
  y <- choose [4, 5]
  return (x, y)
}

result = with choiceHandler (allPairs ())
-- result == [(1,4), (1,5), (2,4), (2,5), (3,4), (3,5)]

-- エフェクトの局所化
localState :: forall a. Int -> (() -> <State Int> a) -> a
localState initial action = 
  with stateHandler initial (action ())

-- 使用例
compute :: () -> <> Int
compute () = {
  x = localState 10 \() -> {
    n <- get ()
    put (n * 2)
    get ()
  }
  y = localState 5 \() -> {
    n <- get ()
    put (n + 3)
    get ()
  }
  x + y  -- 20 + 8 = 28
}

-- 制御フローの変更
earlyReturn :: forall a. handler {Return a} a a
earlyReturn = handler {
  return x = x
  
  -- ctlで継続を捕獲
  earlyExit v = ctl \k -> v  -- 継続を無視して値を返す
}
```

### シェルでのEffect

```haskell
-- シェルコマンドはIOエフェクトを持つ
xsh> cat "file.txt" | toUpper | save "output.txt"
-- 暗黙的にIOハンドラーで実行される

-- 明示的なハンドラー実行
xsh> with ioHandler {
       content <- readFile "data.json"
       let parsed = parseJson content
       print parsed
     }

-- 純粋な計算（Effectなし）
xsh> map double [1,2,3]
[2,4,6]

-- Effect付き計算の合成
xsh> with ioHandler {
       with stateHandler [] {
         files <- ls "*.txt"
         for file in files {
           content <- readFile file
           lines <- get ()
           put (lines ++ [content])
         }
         get ()
       }
     }

-- 非決定的計算の実行
xsh> with choiceHandler {
       x <- choose [1, 2, 3]
       y <- choose [10, 20]
       guard (x + y > 12)
       return (x, y)
     }
[(2, 20), (3, 10), (3, 20)]
```

### Effect推論と静的解析

```haskell
-- Effect推論
autoInfer = {
  x <- get ()      -- State効果を推論
  print "x=${x}"   -- IO効果を推論
  put (x + 1)
}
-- 推論結果: () -> <State a, IO> ()

-- 純粋性の推論
pureFn x y = x + y * 2
-- 推論: Int -> Int -> Int (Effectなし)

effectfulFn x = {
  print "Computing..."
  x * 2
}
-- 推論: Int -> <IO> Int

-- 静的解析でハンドラーの存在を検証
-- コンパイル時にハンドラーチェイン全体を解析
program :: () -> <State Int, IO> String
program () = {
  n <- get ()
  print "Current: ${n}"
  put (n + 1)
  return "done"
}

-- OK: すべてのEffectにハンドラーがある
main = with ioHandler {
  with stateHandler 0 {
    program ()
  }
}

-- エラー: Stateハンドラーが不足
-- bad = with ioHandler (program ())

-- Effectの局所性を静的に検証
scoped :: () -> <IO> Int
scoped () = {
  -- State効果は内部で完結
  n = with stateHandler 10 {
    x <- get ()
    put (x * 2)
    get ()
  }
  print "Result: ${n}"
  return n
}
```

### Effectとパイプライン

```haskell
-- パイプラインでのEffect処理
processFiles :: [String] -> <IO, Logger> [Result]
processFiles files = 
  files 
    | filter (endsWith ".txt")
    | traverse \file -> {
        log Debug "Processing ${file}"
        content <- readFile file
        case parse content of {
          Ok data -> return Success (file, data)
          Err e -> {
            log Error "Failed to parse ${file}: ${e}"
            return Failure (file, e)
          }
        }
      }

-- 純粋なパイプライン
pureProcess :: [Int] -> [Int]
pureProcess nums = nums 
  | filter (> 0)
  | map (* 2)
  | take 10

-- Effectfulパイプライン演算子
(|>>) :: <e> a -> (a -> <e> b) -> <e> b
x |>> f = x >>= f

-- ハンドラー付きパイプライン
withPipeline :: handler h e a b -> <e> a -> (a -> <e> b) -> b
withPipeline h effect f = with h {
  x <- effect
  f x
}

-- 使用例
result = with ioHandler {
  "config.json" 
    |> readFile 
    |> parseJson
    |>> \config -> readFile config.dataFile
    |>> processData
}

-- パイプラインハンドラー
pipeHandler :: forall a. [a] -> handler {Choice} a a
pipeHandler values = handler {
  return x = x
  
  choose _ k = 
    -- パイプライン内で最初の成功を返す
    case filter isSuccess (map k values) of {
      [] -> error "No successful choice"
      (x:_) -> x
    }
}
```

## エラーハンドリング

```haskell
-- Either型による安全なエラーハンドリング
safeDivide x y = 
  if y == 0 
  then Left "Division by zero"
  else Right (x / y)

-- ブロックを使う場合（複数の処理がある時）
safeDivideWithLog x y = 
  if y == 0 {
    log "Division by zero attempted"
    Left "Division by zero"  -- 最後の式が返される
  } else {
    result = x / y
    log "Division successful: ${result}"
    Right result  -- 最後の式が返される
  }

-- ?演算子（Rustスタイル）
process input = {
  x <- parseInt input ?
  y <- readConfig "scale" ?
  return (x * y)
}
-- エラーの場合は早期リターン
```

## シェルでのコード変形

### 型推論結果の即時反映

```haskell
-- ユーザーが入力
xsh> double x = x * 2

-- シェルが即座にコードを変形して表示
xsh> double :: Num a => a -> a
     double x = x * 2

-- 複数行の場合
xsh> quicksort xs = {
       case xs of {
         [] -> []
         (p:rest) -> smaller ++ [p] ++ larger
       }
       smaller = quicksort (filter (<p) rest)
       larger = quicksort (filter (>=p) rest)
     }

-- 変形後（型が追加され、whereブロックが整理される）
xsh> quicksort :: Ord a => [a] -> [a]
     quicksort xs = {
       case xs of {
         [] -> []
         (p:rest) -> smaller ++ [p] ++ larger
       } where {
         smaller = quicksort (filter (<p) rest)
         larger = quicksort (filter (>=p) rest)
       }
     }
```

### ワイルドカード型の置換

```haskell
-- ユーザー入力（部分的な型注釈）
xsh> process :: String -> _
     process s = length s + 1

-- 評価後、ワイルドカードが置換される
xsh> process :: String -> Int
     process s = length s + 1

-- 複数のワイルドカード
xsh> combine :: _ -> _ -> (Int, String)
     combine x y = (length x, show y)

-- 変形後
xsh> combine :: [a] -> Show b => b -> (Int, String)
     combine x y = (length x, show y)
```

### インタラクティブな型の具体化

```haskell
-- 多相的な関数の定義
xsh> identity :: a -> a
     identity x = x

-- 使用時にコメントで具体的な型を記録
xsh> result = identity 42
     -- identity :: Int -> Int (at this call site)
     result :: Int = 42

-- より複雑な例
xsh> compose :: (b -> c) -> (a -> b) -> a -> c
     compose f g x = f (g x)

xsh> addThenDouble = compose (*2) (+1)
     -- compose :: (Int -> Int) -> (Int -> Int) -> Int -> Int
     addThenDouble :: Int -> Int
```

### 型駆動開発とコード生成

```haskell
-- 型シグネチャから実装を生成
xsh> sort :: Ord a => [a] -> [a]
xsh> sort = @
? Implement function of type (Ord a => [a] -> [a]):
? Some suggestions:
?   1. quicksort
?   2. mergesort  
?   3. \xs -> []  -- trivial
?   4. custom implementation
> 1

-- コードが生成され、即座に型チェックされる
xsh> sort :: Ord a => [a] -> [a]
     sort [] = []
     sort (p:xs) = sort smaller ++ [p] ++ sort larger
       where {
         smaller :: Ord a => [a]
         smaller = filter (<p) xs
         
         larger :: Ord a => [a]  
         larger = filter (>=p) xs
       }
```

### 履歴とコード変形

```haskell
-- セッション中のすべての定義を保持
xsh> :show session
double :: Num a => a -> a
double x = x * 2

triple :: Num a => a -> a
triple x = x * 3

compose :: (b -> c) -> (a -> b) -> a -> c
compose f g x = f (g x)

-- 特定の関数を再編集
xsh> :edit double
xsh> double x = x * 2.0  -- 変更

-- 型が変わったことを検出
xsh> double :: Fractional a => a -> a
     double x = x * 2.0

-- 依存する関数への影響を表示
xsh> Warning: Type of 'double' changed. 
     Functions that might be affected:
     - quadruple = compose double double
       Previous: Num a => a -> a
       Now: Fractional a => a -> a
```

### コードの正規化

```haskell
-- ユーザーの入力（スタイルが混在）
xsh> process xs = {
       let y = filter even xs in
       z where z = map (*2) y
     }

-- シェルが正規化して表示
xsh> process :: [Int] -> [Int]
     process xs = {
       y = filter even xs
       z = map (*2) y
       z
     }

-- または where スタイルに統一
xsh> :style where
xsh> process :: [Int] -> [Int]
     process xs = z
       where {
         y = filter even xs
         z = map (*2) y
       }
```

## 実装への変換とコンテンツアドレス

### 構文の脱糖（Desugar）

```haskell
-- ユーザーが書くコード
quicksort xs = case xs of {
  [] -> []
  (p:rest) -> smaller ++ [p] ++ larger
} where {
  smaller = quicksort (filter (<p) rest)
  larger = quicksort (filter (>=p) rest)
}

-- 脱糖後の内部表現（let...inに統一）
quicksort#a3f2d1 xs = 
  let smaller = quicksort#a3f2d1 (filter#b8c9e2 (<#core p) rest) in
  let larger = quicksort#a3f2d1 (filter#b8c9e2 (>=#core p) rest) in
  case xs of {
    [] -> []
    (p:rest) -> (++#core) ((++#core) smaller [p]) larger
  }

-- すべての参照がハッシュで固定される
```

### シンボルのハッシュ管理

```haskell
-- 開発時：最新版を参照
xsh> map double [1,2,3]
-- 自動的に map#latest と double#latest を参照

-- 保存時：ハッシュで固定
map#c7d8a9 double#e5f6b7 [1,2,3]

-- 明示的なバージョン指定
xsh> map#c7d8a9 double [1,2,3]  -- 特定バージョンのmapを使用

-- 同一関数内での制約
-- エラー：同じ関数内で異なるバージョンのmapは使えない
processData xs = {
  result1 = map#v1 f xs  -- map#v1
  result2 = map#v2 g xs  -- エラー！別バージョンのmap
}
```

### 依存関係の保存

```haskell
-- 関数定義とその依存関係
Function {
  name: "quicksort",
  hash: "a3f2d1",
  type: "Ord a => [a] -> [a]",
  dependencies: {
    "filter": "b8c9e2",
    "<": "core.lt.d9e8f7",
    ">=": "core.gte.a1b2c3",
    "++": "core.append.f7e8d9"
  },
  body: <脱糖後のAST>
}

-- 依存関係の伝播
-- processListがquicksortを使用する場合
Function {
  name: "processList",
  hash: "f8g9h0",
  dependencies: {
    "quicksort": "a3f2d1",
    -- quicksortの依存も間接的に固定される
  }
}
```

### Nix風の評価環境固定

```haskell
-- 各式は評価時の環境を記録
Expression {
  code: "map double [1,2,3]",
  environment: {
    "map": {
      hash: "c7d8a9",
      type: "(a -> b) -> [a] -> [b]",
      closure: <関数の実装>
    },
    "double": {
      hash: "e5f6b7", 
      type: "Num a => a -> a",
      closure: <関数の実装>
    }
  },
  result: "[2,4,6]"
}

-- 環境の再現性
-- 同じ環境で評価すれば必ず同じ結果
```

### インクリメンタルな更新

```haskell
-- バージョン1
double#v1 x = x * 2

-- バージョン2（更新）
double#v2 x = x * 2.0  -- 型が変わる

-- 依存する関数への影響
quadruple#old = double#v1 . double#v1  -- Int -> Int
quadruple#new = double#v2 . double#v2  -- Fractional a => a -> a

-- コードベースは両方を保持
-- ユーザーは必要に応じて選択
```

### モジュール単位での固定

```haskell
-- モジュール定義
module DataProcessing#m1a2b3 {
  import List#l4c5d6 (map, filter, fold)
  import String#s7e8f9 (split, join)
  
  export processData, transformData
  
  -- すべての関数定義がこの環境で固定
  processData xs = map transform xs
  transformData s = join " " (split "," s)
}

-- 使用時
import DataProcessing#m1a2b3 (processData)
-- または最新版
import DataProcessing (processData)  -- #latest
```

### 制約と保証

```haskell
-- 1. 同一関数内での一貫性
function f x = {
  -- すべてのmapは同じバージョン
  a = map g xs
  b = map h ys  
  -- OK: 両方とも同じmap#hashを使用
}

-- 2. 型の一貫性
-- エラー：型が合わない
result = compose#v1 double#v2 increment#v1
-- double#v2の型変更により型エラー

-- 3. 純粋性の保証
-- 同じ入力と環境なら必ず同じ出力
evaluate env "map double [1,2,3]" == evaluate env "map double [1,2,3]"
```

### シェルでの操作

```haskell
-- 現在の環境を表示
xsh> :env
Current bindings:
  map      -> #c7d8a9 (latest)
  filter   -> #b8c9e2 (latest)
  double   -> #e5f6b7 (v2)

-- 特定バージョンに固定
xsh> :pin double v1
Pinned double to #d4e5f6

-- 依存関係の確認
xsh> :deps quicksort
quicksort#a3f2d1 depends on:
  - filter#b8c9e2
  - <#core.d9e8f7
  - >=#core.a1b2c3
  - ++#core.f7e8d9

-- スナップショットの作成
xsh> :snapshot myproject-v1.0
Saved environment snapshot with 42 bindings
```

## 実装への変換

この構文は最終的に以下のような内部表現に変換される：

```haskell
-- ソース（型注釈付き）
f :: Int -> Int
f x = { y = x + 1; z = y * 2; z }

-- 脱糖・固定後の内部表現
f#h1a2b3 :: Int -> Int
f#h1a2b3 = \(x :: Int) -> 
  let y :: Int = (+#core) x 1 in
  let z :: Int = (*#core) y 2 in
  z :: Int

-- メタデータ
FunctionMetadata {
  hash: "h1a2b3",
  dependencies: {
    "+": "core.add.x7y8z9",
    "*": "core.mul.a4b5c6"
  },
  typeSignature: "Int -> Int",
  purity: Pure
}
```

重要なのは：
1. whereやlet...inは脱糖されて統一的な内部表現になる
2. すべての参照はハッシュで固定され、評価環境が保存される
3. 同一関数内では同名の異なるバージョンは使用できない
4. 関数単位で依存関係が管理される
5. Nix風の再現可能なビルドが保証される

## 代数的データ型とキーワード引数

### 基本的なADT定義とパターンマッチ

```haskell
-- 伝統的なADT定義
type Result e a = Error e | Ok a
type Option a = None | Some a

-- レコード構文を持つADT
type User = User { 
  name :: String, 
  age :: Int, 
  email :: String 
}

type Config = Config {
  host :: String,
  port :: Int,
  secure :: Bool,
  timeout :: Maybe Int
}
```

### キーワード引数風の構築

```haskell
-- 位置引数での構築（従来）
xsh> user1 = User "Alice" 30 "alice@example.com"

-- キーワード引数での構築（新機能）
xsh> user2 = User { name = "Bob", age = 25, email = "bob@example.com" }

-- 順序を自由に指定可能
xsh> user3 = User { email = "charlie@example.com", name = "Charlie", age = 35 }

-- デフォルト値との組み合わせ
xsh> config = Config { 
       host = "localhost",  -- 必須フィールド
       port = 8080,         -- 必須フィールド
       secure = true,       -- 必須フィールド
       -- timeout は Nothing がデフォルト
     }

-- 一部だけ指定（デフォルト値がある場合）
xsh> config2 = Config { 
       host = "api.example.com", 
       port = 443, 
       secure = true,
       timeout = Just 5000  -- オプショナルフィールドを明示的に指定
     }
```

### フィールド更新構文

```haskell
-- レコード更新（Haskellスタイル）
xsh> user4 = user3 { age = 36 }  -- ageだけ更新

-- 複数フィールドの更新
xsh> config3 = config { 
       host = "production.example.com",
       secure = false 
     }

-- ネストした更新
type Address = Address { street :: String, city :: String, zip :: String }
type Person = Person { name :: String, address :: Address }

xsh> person = Person { 
       name = "Alice",
       address = Address { 
         street = "123 Main St", 
         city = "Tokyo", 
         zip = "100-0001" 
       }
     }

-- ネストしたフィールドの更新
xsh> person2 = person { 
       address = person.address { city = "Osaka" } 
     }
```

### パターンマッチでのキーワード引数

```haskell
-- フィールド名を使ったパターンマッチ
processUser user = match user {
  User { name, age } -> 
    -- emailフィールドは無視
    print "Name: ${name}, Age: ${age}"
  
  User { email = e } | e `endsWith` "@admin.com" ->
    -- 管理者メールアドレスの特別処理
    print "Admin user: ${e}"
}

-- 部分的なマッチとガード
validateConfig cfg = match cfg {
  Config { port = p } | p < 1024 -> 
    Error "Privileged port requires root access"
  
  Config { secure = true, port = 80 } ->
    Error "HTTP port 80 cannot be secure"
  
  Config { timeout = Just t } | t < 1000 ->
    Error "Timeout too short"
  
  _ -> Ok cfg
}

-- アズパターンとの組み合わせ
xsh> processResult r = match r {
       Ok value@User { age } | age >= 18 -> 
         print "Adult user: ${value}"
       
       Ok value@User { } -> 
         print "Minor user: ${value}"
       
       Error msg -> 
         print "Error: ${msg}"
     }
```

### シェルでの対話的な使用

```haskell
-- タブ補完でフィールド名を提案
xsh> user = User { n<TAB>
     name = _

-- 型に基づいた補完
xsh> config = Config { 
       host = <TAB>  -- String型の値を提案
       port = <TAB>  -- Int型の値を提案
     }

-- 不完全な構築のエラー
xsh> badUser = User { name = "Test" }
Error: Missing required fields: age, email
Suggestion: User { name = "Test", age = _, email = _ }

-- インタラクティブな穴埋め
xsh> user = User { name = "Alice", age = @, email = @ }
? Enter value for age (Int):
> 30
? Enter value for email (String):
> alice@example.com
user :: User
```

### パイプラインでの使用

```haskell
-- レコードのフィールドを変換
users | map (\u -> u { age = u.age + 1 })  -- 全員の年齢を+1

-- フィールドでフィルタ
users | filter (\User { age } -> age >= 20)

-- フィールドを抽出してグループ化
users | groupBy (\User { city } -> city)

-- 複雑な変換パイプライン
rawData 
  | parseJSON 
  | map (\obj -> User { 
      name = obj."full_name", 
      age = obj."years", 
      email = obj."contact"."email" 
    })
  | filter (\User { age } -> age >= 18)
  | sortBy (\User { name } -> name)
```

### エラーハンドリングとバリデーション

```haskell
-- スマートコンストラクタ
mkUser :: String -> Int -> String -> Result String User
mkUser name age email = {
  validName <- if length name > 0 
    then Ok name 
    else Error "Name cannot be empty"
  
  validAge <- if age >= 0 && age <= 150 
    then Ok age 
    else Error "Invalid age"
  
  validEmail <- if email `contains` "@" 
    then Ok email 
    else Error "Invalid email"
  
  Ok (User { name = validName, age = validAge, email = validEmail })
}

-- シェルでの使用
xsh> mkUser "" 25 "test@example.com"
Error "Name cannot be empty"

xsh> mkUser "Alice" 200 "alice@example.com"
Error "Invalid age"

xsh> mkUser "Alice" 30 "alice@example.com"
Ok (User { name = "Alice", age = 30, email = "alice@example.com" })
```

### 型クラスとの統合

```haskell
-- 自動的にShow/Eq/Ordを導出
type User = User { name :: String, age :: Int, email :: String }
  deriving (Show, Eq, Ord)

-- カスタム実装
instance Show User where
  show (User { name, age }) = "${name} (${age} years old)"

-- JSONシリアライゼーション
instance ToJSON User where
  toJSON (User { name, age, email }) = {
    object [
      ("name", toJSON name),
      ("age", toJSON age), 
      ("email", toJSON email)
    ]
  }

instance FromJSON User where
  parseJSON obj = {
    name <- obj .: "name"
    age <- obj .: "age"
    email <- obj .: "email"
    pure (User { name, age, email })
  }
```

### シェル風の引数構文

```haskell
-- 関数呼び出し時のキーワード引数
-- 従来の呼び出し方
xsh> drawCircle (Point 10 20) 5 "red"

-- シェル風の呼び出し（キーワード引数を自動的にADTに変換）
xsh> drawCircle x=10 y=20 radius=5 color="red"
-- 自動的に以下に変換される：
-- drawCircle Point::{x:10 y:20} radius::5 color::"red"

-- 複雑な例
xsh> createWindow title="My App" size={width:800 height:600} position={x:100 y:100}
-- 変換後：
-- createWindow title::"My App" size::Size{width:800 height:600} position::Point{x:100 y:100}

-- 型推論による自動構築
xsh> plot points=[{x:0 y:0} {x:1 y:1} {x:2 y:4}] style="line"
-- pointsの要素は自動的にPoint型として推論
```

### nushell風のレコードアクセス

```haskell
-- ドット記法でのアクセス（シンプル）
xsh> user.name
"Alice"

xsh> config.server.host
"localhost"

-- パイプラインでのフィールドアクセス
xsh> users | get name  -- 全ユーザーの名前のリスト
["Alice", "Bob", "Charlie"]

xsh> users | select name age  -- 特定フィールドのみ抽出
[{name: "Alice", age: 30}, {name: "Bob", age: 25}, ...]

-- フィールドの更新（nushell風）
xsh> user | update age 31
User { name = "Alice", age = 31, email = "alice@example.com" }

xsh> users | update age {|it| it.age + 1}  -- 全員の年齢を+1

-- ネストしたフィールドの更新
xsh> config | update server.port 8081
```

### テーブル操作とレコード変換

```haskell
-- レコードのリストをテーブルとして表示
xsh> users | table
╭───┬─────────┬─────┬──────────────────────╮
│ # │  name   │ age │       email          │
├───┼─────────┼─────┼──────────────────────┤
│ 0 │ Alice   │  30 │ alice@example.com    │
│ 1 │ Bob     │  25 │ bob@example.com      │
│ 2 │ Charlie │  35 │ charlie@example.com  │
╰───┴─────────┴─────┴──────────────────────╯

-- テーブルからレコードへの変換
xsh> ls | toRecords FileInfo
-- ファイルシステムの情報をFileInfo型のレコードに変換

-- JSONとの相互変換
xsh> users | toJson
[{"name":"Alice","age":30,"email":"alice@example.com"},...]

xsh> cat users.json | fromJson | toRecords User
```

### 構造化データの操作

```haskell
-- where句でのフィルタリング（SQL風）
xsh> users | where age > 25
xsh> users | where name =~ "^A"  -- 正規表現マッチ
xsh> users | where email endsWith "@admin.com"

-- グループ化と集計
xsh> orders | groupBy customer | aggregate {
       customer: first customer
       total: sum amount
       count: length
     }

-- ソートとページング
xsh> users | sortBy age desc | take 10

-- 結合操作
xsh> users | join orders on id=userId
```

### コマンドライン引数の自動解析

```haskell
-- CLIコマンドの定義
def deploy [
  --env: String = "staging"    -- 環境
  --port: Int = 8080          -- ポート番号  
  --verbose: Bool = false     -- 詳細出力
  app: String                 -- アプリ名（必須）
] {
  let config = DeployConfig::{
    env: $env
    port: $port
    verbose: $verbose
    app: $app
  }
  runDeploy config
}

-- 呼び出し
xsh> deploy myapp --env=production --port=443 --verbose
-- または
xsh> deploy --env production --port 443 --verbose myapp
```

### 環境変数とレコードのマッピング

```haskell
-- 環境変数からレコードを構築
xsh> env | toRecord EnvConfig {
       mapping: {
         DATABASE_URL: database.url
         DATABASE_USER: database.user
         API_KEY: api.key
         PORT: { value: server.port, type: Int }
       }
     }

-- レコードから環境変数を設定
xsh> config | exportEnv {
       "DATABASE_URL": database.url
       "PORT": toString server.port
     }
```

### インタラクティブなレコード編集

```haskell
-- レコードの対話的編集
xsh> user | edit
╭─────────────────────────────────╮
│ Editing User                    │
├─────────────────────────────────┤
│ name:  [Alice                 ] │
│ age:   [30                    ] │
│ email: [alice@example.com     ] │
╰─────────────────────────────────╯
[Save] [Cancel]

-- 部分的な編集
xsh> config | edit server.port
Enter new value for server.port (current: 8080): 8081

-- バリデーション付き編集
xsh> user | edit --validate {
       age: { min: 0, max: 150 }
       email: { pattern: ".*@.*" }
     }
```

### 型安全なシェルスクリプト

```haskell
#!/usr/bin/env xsh

-- 型安全なスクリプト引数
type Args = Args {
  input: String
  output: String  
  format: Format
  verbose: Bool
}

-- メイン処理
main args = {
  content <- readFile args.input
  
  processed = content 
    | parse args.format 
    | transform 
    | validate
  
  if args.verbose 
  then print "Processing complete"
  
  writeFile args.output processed
}

-- コマンドライン引数の自動パース
main (parseArgs Args)

## まとめ

- `let`キーワードは`=`があれば不要
- ブロック内の定義は順序独立（相互再帰可能）
- `where`と`let...in`は同じスコープ規則の異なる構文
- do記法のみ順序が重要
- @記法により対話的な開発が可能
- 代数的データ型にキーワード引数構文を追加
- フィールド名によるパターンマッチをサポート
- レコード更新構文で関数型プログラミングを維持
- シェルでの対話的な使用を最適化