; Chapter 2 練習問題の解答例

(type Option a
  (None)
  (Some a))

(type Tree a
  (Leaf a)
  (Node (Tree a) a (Tree a)))

; 問題1: リストの最大値を求める関数（空リストの場合はOption型を使用）
(rec maxList (lst)
  (match lst
    ((list) (None))
    ((list x) (Some x))
    ((list h ... rest)
      (match (maxList rest)
        ((None) (Some h))
        ((Some maxRest)
          (if (> h maxRest)
              (Some h)
              (Some maxRest)))))))

; テスト
; (maxList (list))           ; (None)
; (maxList (list 5))         ; (Some 5)
; (maxList (list 3 1 4 1 5)) ; (Some 5)
; (maxList (list -3 -1 -4))  ; (Some -1)

; 問題2: 二分木の深さを計算する関数
(rec treeDepth (tree)
  (match tree
    ((Leaf _) 1)
    ((Node left _ right)
      (let leftDepth (treeDepth left))
      (let rightDepth (treeDepth right))
      (+ 1 (if (> leftDepth rightDepth)
               leftDepth
               rightDepth)))))

; テスト用の木
(let sampleTree
  (Node (Node (Leaf 1) 2 (Leaf 3))
        4
        (Node (Leaf 5) 6 (Leaf 7))))

; (treeDepth (Leaf 42))      ; 1
; (treeDepth sampleTree)     ; 3

; 問題3: リストから重複を除去する関数
(rec removeDuplicates (lst)
  (let contains (rec elem (x lst)
    (match lst
      ((list) false)
      ((list h ... rest)
        (if (= h x)
            true
            (elem x rest))))))
  
  (rec removeHelper (lst seen)
    (match lst
      ((list) (list))
      ((list h ... rest)
        (if (contains h seen)
            (removeHelper rest seen)
            (cons h (removeHelper rest (cons h seen)))))))
  
  (removeHelper lst (list)))

; より効率的な実装（順序を保持しない）
(rec removeDuplicatesUnordered (lst)
  (match lst
    ((list) (list))
    ((list h ... rest)
      (let filtered (rec filterOut (x lst)
        (match lst
          ((list) (list))
          ((list h2 ... rest2)
            (if (= x h2)
                (filterOut x rest2)
                (cons h2 (filterOut x rest2))))))
      (cons h (removeDuplicatesUnordered (filtered h rest))))))

; テスト
; (removeDuplicates (list 1 2 3 2 1 4))    ; (list 1 2 3 4)
; (removeDuplicates (list "a" "b" "a"))    ; (list "a" "b")
; (removeDuplicates (list))                ; (list)