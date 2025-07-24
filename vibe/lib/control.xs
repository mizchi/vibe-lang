-- Control flow utilities

module Control {
  export cond
  
  -- cond マクロの実装
  -- 実際にはマクロシステムが必要だが、関数として近似実装
  -- 使用例: condImpl [(condition1, expr1), (condition2, expr2), ...]
  rec condImpl clauses =
    case clauses of {
      [] -> error "No matching cond clause"
      (cond, expr) :: rest ->
        if cond {
          expr
        } else {
          condImpl rest
        }
    }
  
  -- condマクロのヘルパー
  -- 実際の使用では、パーサーレベルでの変換が必要
  let cond clauses = condImpl clauses
}