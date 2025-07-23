-- XS言語の名前空間システムのデモ

-- Math名前空間に関数を定義
namespace Math {
  square x = x * x
  
  cube x = x * x * x
  
  factorial n =
    if n = 0 {
      1
    } else {
      n * (factorial (n - 1))
    }
}

-- Math.Utils名前空間に関数を定義
namespace Math.Utils {
  isPrime n =
    if n <= 1 {
      false
    } else {
      let checkDivisor d =
        if d * d > n {
          true
        } else if n % d = 0 {
          false
        } else {
          checkDivisor (d + 1)
        }
      in checkDivisor 2
    }
  
  gcd a b =
    if b = 0 {
      a
    } else {
      gcd b (a % b)
    }
}

-- 名前空間関数の使用例
-- 完全修飾名でアクセス
let result1 = Math.square 5         -- => 25
let result2 = Math.cube 3           -- => 27
let result3 = Math.factorial 5      -- => 120

-- Math.Utils の関数を使用
let result4 = Math.Utils.isPrime 17    -- => true
let result5 = Math.Utils.gcd 48 18     -- => 6

-- パイプライン演算子との組み合わせ
let result6 = 7 |> Math.square |> Math.Utils.isPrime  -- => false (49は素数ではない)

-- リスト処理との組み合わせ
let numbers = [1, 2, 3, 4, 5]
let squares = map Math.square numbers   -- => [1, 4, 9, 16, 25]
let primes = filter Math.Utils.isPrime numbers  -- => [2, 3, 5]

-- 名前空間は階層的に管理され、コンテンツアドレスで追跡される
-- これにより、バージョン管理と依存関係の解決が容易になる