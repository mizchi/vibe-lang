-- Chapter 1 練習問題の解答例

-- 必要なライブラリ関数をインポート
import "../../xs/lib/string.xs" as String

-- 問題1: 摂氏を華氏に変換する関数
celsiusToFahrenheit c = c * 1.8 + 32.0

-- テスト
-- celsiusToFahrenheit 0.0   -- => 32.0
-- celsiusToFahrenheit 100.0 -- => 212.0
-- celsiusToFahrenheit 37.0  -- => 98.6

-- 問題2: 数値が偶数かどうかを判定する関数
isEven n = n % 2 = 0

-- テスト - 以下のコマンドで実行可能:
-- cargo run -p xs-tools --bin xsc -- run examples/chapter1/exercises.xs

-- 問題3: 文字列を反転する関数
reverseString str =
  let chars = String.toList str in
  let reversed = reverse chars in
  String.fromList reversed

-- 問題4: リストの最大値を求める関数
maximum lst =
  case lst of {
    [] -> error "Empty list has no maximum";
    [x] -> x;
    h :: t -> 
      let maxTail = maximum t in
      if h > maxTail { h } else { maxTail }
  }

-- 問題5: フィボナッチ数列のn番目の値を求める関数
fibonacci n =
  if n < 2 {
    n
  } else {
    fibonacci (n - 1) + fibonacci (n - 2)
  }

-- 実行例
let test1 = celsiusToFahrenheit 0.0      -- => 32.0
let test2 = isEven 42                     -- => true
let test3 = isEven 43                     -- => false
let test4 = fibonacci 10                  -- => 55

-- 結果を表示
[test1, test2, test3, test4]