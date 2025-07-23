-- 高階関数の例

-- map関数の実装と使用
let map f xs = case xs of {
  [] -> [];
  [head, ...tail] -> cons (f head) (map f tail)
}

-- 2倍にする関数
let double x = x * 2

-- リストの各要素を2倍にする
map double [1, 2, 3, 4, 5]  -- => [2, 4, 6, 8, 10]

-- filter関数の実装
let filter pred xs = case xs of {
  [] -> [];
  [head, ...tail] -> 
    if pred head { cons head (filter pred tail) }
    else { filter pred tail }
}

-- 偶数判定
let even? x = x % 2 = 0

-- 偶数のみ抽出
filter even? [1, 2, 3, 4, 5, 6]  -- => [2, 4, 6]

-- fold関数（左畳み込み）
let foldLeft f init xs = case xs of {
  [] -> init;
  [head, ...tail] -> foldLeft f (f init head) tail
}

-- リストの合計
foldLeft (\acc x -> acc + x) 0 [1, 2, 3, 4, 5]  -- => 15

-- 関数の合成
let compose f g = \x -> f (g x)

-- 2倍して1を足す関数
let doublePlusOne = compose (\x -> x + 1) double
doublePlusOne 5  -- => 11