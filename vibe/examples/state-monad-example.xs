-- Test State monad implementation

import "../lib/state.xs"
import "../lib/do-notation.xs"
import "../lib/result.xs"

-- カウンターの例
let counter =
  DoNotation.>>= State.get (\n ->
    DoNotation.>> (State.put (n + 1))
      (State.stateReturn n)) in

-- 3回カウントアップ
let count3Times =
  DoNotation.>>= counter (\a ->
    DoNotation.>>= counter (\b ->
      DoNotation.>>= counter (\c ->
        State.stateReturn [a, b, c]))) in

-- テスト実行
let dummy1 = IO.print "=== State Monad Test ===" in
let result = State.runState count3Times 0 in
case result of {
  [values, finalState] ->
    let dummy2 = IO.print (String.concat "Values: " (toString values)) in
    IO.print (String.concat "Final state: " (Int.toString finalState))
} in

-- Resultモナドのテスト
let dummy3 = IO.print "\n=== Result Monad Test ===" in

let safeDivide x y =
  if y = 0 {
    Result.Err "Division by zero"
  } else {
    Result.Ok (x / y)
  } in

-- 成功ケース
let result1 = safeDivide 10 2 in
let dummy4 = case result1 of {
  Result.Ok value -> IO.print (String.concat "10 / 2 = " (Int.toString value));
  Result.Err err -> IO.print (String.concat "Error: " err)
} in

-- エラーケース
let result2 = safeDivide 10 0 in
let dummy5 = case result2 of {
  Result.Ok value -> IO.print (String.concat "Result: " (Int.toString value));
  Result.Err err -> IO.print (String.concat "Error: " err)
} in

-- Result連鎖
let computation =
  Result.andThen (safeDivide 20 4) (\x ->
    Result.andThen (safeDivide x 2) (\y ->
      Result.Ok (y + 1))) in

case computation of {
  Result.Ok value -> IO.print (String.concat "Computation result: " (Int.toString value));
  Result.Err err -> IO.print (String.concat "Computation error: " err)
}

-- ヘルパー関数
where {
  toString x = "<value>";  -- 仮実装
  last = rec last lst ->
    case lst of {
      [x] -> x;
      h :: t -> last t
    }
}