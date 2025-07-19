; 代数的データ型とパターンマッチング

; Option型の定義
(type Option (Some value) (None))

; Result型の定義  
(type Result (Ok value) (Err error))

; パターンマッチングの使用
(match (Some 42)
  ((Some x) (* x 2))
  ((None) 0))  ; => 84

; リストのパターンマッチング
(match (list 1 2 3)
  ((list) "empty")
  ((list x) "one element")
  ((list x y) "two elements")
  ((list x y z) "three elements")
  (_ "many elements"))  ; => "three elements"