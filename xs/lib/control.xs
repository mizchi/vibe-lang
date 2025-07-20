;; Control flow utilities

(module Control
  (export cond)
  
  ;; cond マクロの実装
  ;; 実際にはマクロシステムが必要だが、関数として近似実装
  ;; 使用例: (condImpl (list (pair condition1 expr1) (pair condition2 expr2) ...))
  (rec condImpl (clauses)
    (match clauses
      ((list) (error "No matching cond clause"))
      ((list (pair cond expr) rest)
        (if cond
            expr
            (condImpl rest)))))
  
  ;; condマクロのヘルパー
  ;; 実際の使用では、パーサーレベルでの変換が必要
  (let cond (fn (clauses) (condImpl clauses))))