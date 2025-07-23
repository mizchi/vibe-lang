-- Pair (tuple) data structure

module Pair {
  export Pair, pair, fst, snd
  
  -- ペア型の定義
  type Pair a b =
    | Pair a b
  
  -- ペアを作成
  let pair x y = Pair x y
  
  -- ペアの最初の要素を取得
  let fst p =
    case p of {
      Pair x y -> x
    }
  
  -- ペアの2番目の要素を取得
  let snd p =
    case p of {
      Pair x y -> y
    }
})