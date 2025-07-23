-- Chapter 4 サンプルプロジェクト
-- コンテンツアドレス型コードベース管理のデモ

-- === ユーティリティライブラリ ===

-- 基本的な関数合成
let compose = fn (f : b -> c) (g : a -> b) ->
  fn x -> f (g x)

-- 恒等関数
let identity = fn x -> x

-- 定数関数
let constant = fn x -> fn _ -> x

-- 関数の引数を反転
let flip = fn (f : a -> b -> c) ->
  fn y x -> f x y

-- === リスト処理ライブラリ ===

-- map関数（型注釈付き）
rec map (f : a -> b) (lst : List a) =
  match lst {
    [] -> []
    h :: rest -> cons (f h) (map f rest)
  }

-- filter関数（型注釈付き）
rec filter (pred : a -> Bool) (lst : List a) =
  match lst {
    [] -> []
    h :: rest ->
      if pred h {
        cons h (filter pred rest)
      } else {
        filter pred rest
      }
  }

-- reduce/fold関数
rec reduce (f : acc -> a -> acc) (init : acc) (lst : List a) =
  match lst {
    [] -> init
    h :: rest -> reduce f (f init h) rest
  }

-- リストの長さ
let length = fn (lst : List a) ->
  reduce (fn acc _ -> acc + 1) 0 lst

-- リストの反転
let reverse = fn (lst : List a) ->
  reduce (flip cons) [] lst

-- === 数値処理ライブラリ ===

-- 範囲の生成
rec range (start : Int) (end : Int) =
  if start >= end {
    []
  } else {
    cons start (range (start + 1) end)
  }

-- 階乗（メモ化可能な純粋関数）
rec factorial (n : Int) =
  if n == 0 {
    1
  } else {
    n * factorial (n - 1)
  }

-- フィボナッチ数列（効率的な実装）
let fibonacci = fn (n : Int) ->
  let fibHelper = rec fibHelper n a b =
    if n == 0 {
      a
    } else {
      fibHelper (n - 1) b (a + b)
    } in
  fibHelper n 0 1

-- === 文字列処理ライブラリ ===

-- 文字列の繰り返し
rec repeatString (s : String) (n : Int) =
  if n == 0 {
    ""
  } else {
    strConcat s (repeatString s (n - 1))
  }

-- 文字列のリストを結合
let joinStrings = fn (sep : String) (lst : List String) ->
  match lst {
    [] -> ""
    [s] -> s
    s :: rest ->
      strConcat s (strConcat sep (joinStrings sep rest))
  }

-- === テスト用の純粋関数 ===

-- これらの関数は自動テスト生成でテストされる
let doubleInt = fn (x : Int) -> x * 2
let isPositiveInt = fn (x : Int) -> x > 0
let addInt = fn (x : Int) (y : Int) -> x + y

-- === メイン処理 ===

let main = fn () ->
  -- デモ: 関数合成
  let doubleAndInc = compose (fn x -> x + 1) doubleInt in
  
  -- デモ: 高階関数の使用
  let numbers = range 1 10 in
  let doubled = map doubleInt numbers in
  let evens = filter (fn n -> n % 2 == 0) doubled in
  
  -- デモ: 文字列処理
  let names = ["Alice", "Bob", "Charlie"] in
  let greeting = joinStrings ", " names in
  
  -- 結果の表示（実際の実装では副作用が必要）
  [doubled, evens, greeting]

-- このファイルを以下のコマンドで処理：
-- 1. XBinに保存:
--    cargo run --bin xsc -- codebase store sample-project.xs -o sample.xbin
--
-- 2. 自動テスト生成・実行:
--    cargo run --bin xsc -- codebase test sample.xbin
--
-- 3. 依存関係の確認:
--    cargo run --bin xsc -- codebase query sample.xbin deps main
--
-- 4. 変更の追跡（XS Shellで）:
--    xs> load sample.xbin
--    xs> edit doubleInt
--    xs> let doubleInt = fn (x : Int) -> x + x  -- 実装を変更
--    xs> edits
--    xs> update