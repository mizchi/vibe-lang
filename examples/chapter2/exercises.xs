-- Chapter 2 練習問題の解答例

type Option a =
  | None
  | Some a

type Tree a =
  | Leaf a
  | Node (Tree a) a (Tree a)

-- 問題1: リストの最大値を求める関数（空リストの場合はOption型を使用）
rec maxList lst =
  match lst {
    [] -> None
    [x] -> Some x
    h :: rest ->
      match maxList rest {
        None -> Some h
        Some maxRest ->
          if h > maxRest {
            Some h
          } else {
            Some maxRest
          }
      }
  }

-- テスト
-- maxList []           -- None
-- maxList [5]          -- Some 5
-- maxList [3, 1, 4, 1, 5] -- Some 5
-- maxList [-3, -1, -4]  -- Some -1

-- 問題2: 二分木の深さを計算する関数
rec treeDepth tree =
  match tree {
    Leaf _ -> 1
    Node left _ right ->
      let leftDepth = treeDepth left in
      let rightDepth = treeDepth right in
        1 + (if leftDepth > rightDepth {
               leftDepth
             } else {
               rightDepth
             })
  }

-- テスト用の木
let sampleTree =
  Node (Node (Leaf 1) 2 (Leaf 3))
        4
        (Node (Leaf 5) 6 (Leaf 7))

-- treeDepth (Leaf 42)      -- 1
-- treeDepth sampleTree     -- 3

-- 問題3: リストから重複を除去する関数
rec removeDuplicates lst =
  let contains = rec elem x lst =
    match lst {
      [] -> false
      h :: rest ->
        if h == x {
          true
        } else {
          elem x rest
        }
    } in
  
  let removeHelper = rec removeHelper lst seen =
    match lst {
      [] -> []
      h :: rest ->
        if contains h seen {
          removeHelper rest seen
        } else {
          cons h (removeHelper rest (cons h seen))
        }
    } in
  
  removeHelper lst []

-- より効率的な実装（順序を保持しない）
rec removeDuplicatesUnordered lst =
  match lst {
    [] -> []
    h :: rest ->
      let filtered = rec filterOut x lst =
        match lst {
          [] -> []
          h2 :: rest2 ->
            if x == h2 {
              filterOut x rest2
            } else {
              cons h2 (filterOut x rest2)
            }
        } in
      cons h (removeDuplicatesUnordered (filtered h rest))
  }

-- テスト
-- removeDuplicates [1, 2, 3, 2, 1, 4]    -- [1, 2, 3, 4]
-- removeDuplicates ["a", "b", "a"]    -- ["a", "b"]
-- removeDuplicates []                -- []