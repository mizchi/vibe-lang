-- 代数的データ型とパターンマッチング

-- Option型の定義
type Option = Some value | None

-- Result型の定義  
type Result = Ok value | Err error

-- パターンマッチングの使用
case Some 42 of {
  Some x -> x * 2;
  None -> 0
}  -- => 84

-- リストのパターンマッチング
case [1, 2, 3] of {
  [] -> "empty";
  [x] -> "one element";
  [x, y] -> "two elements";
  [x, y, z] -> "three elements";
  _ -> "many elements"
}  -- => "three elements"