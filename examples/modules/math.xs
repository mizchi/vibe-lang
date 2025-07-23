-- 数学モジュール
module Math {
  export add, sub, mul, div, pow, abs, max, min, PI, E
  
  -- 定数
  let PI = 3.14159265359
  let E = 2.71828182846
  
  -- 基本演算
  let add x y = x + y
  let sub x y = x - y
  let mul x y = x * y
  let div x y = x / y
  
  -- 累乗 (簡易実装)
  rec pow base exp =
    if eq exp 0 {
      1
    } else {
      base * (pow base (exp - 1))
    }
  
  -- 絶対値
  let abs x =
    if x < 0 {
      0 - x
    } else {
      x
    }
  
  -- 最大値
  let max x y =
    if x > y { x } else { y }
  
  -- 最小値
  let min x y =
    if x < y { x } else { y }
})