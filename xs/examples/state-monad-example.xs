;; Test State monad implementation

(import "../lib/state.xs")
(import "../lib/do-notation.xs")
(import "../lib/result.xs")

;; カウンターの例
(let counter
  (DoNotation.>>= State.get (fn (n)
    (DoNotation.>> (State.put (+ n 1))
      (State.stateReturn n)))))

;; 3回カウントアップ
(let count3Times
  (DoNotation.>>= counter (fn (a)
    (DoNotation.>>= counter (fn (b)
      (DoNotation.>>= counter (fn (c)
        (State.stateReturn (list a b c)))))))))

;; テスト実行
(print "=== State Monad Test ===")
(let result (State.runState count3Times 0))
(match result
  ((pair values finalState)
    (do
      (print (string-concat "Values: " (toString values)))
      (print (string-concat "Final state: " (int-to-string finalState))))))

;; Resultモナドのテスト
(print "\n=== Result Monad Test ===")

(let safeDivide (fn (x y)
  (if (= y 0)
      (Result.Err "Division by zero")
      (Result.Ok (/ x y)))))

;; 成功ケース
(let result1 (safeDivide 10 2))
(match result1
  ((Result.Ok value) (print (string-concat "10 / 2 = " (int-to-string value))))
  ((Result.Err err) (print (string-concat "Error: " err))))

;; エラーケース
(let result2 (safeDivide 10 0))
(match result2
  ((Result.Ok value) (print (string-concat "Result: " (int-to-string value))))
  ((Result.Err err) (print (string-concat "Error: " err))))

;; Result連鎖
(let computation
  (Result.andThen (safeDivide 20 4) (fn (x)
    (Result.andThen (safeDivide x 2) (fn (y)
      (Result.Ok (+ y 1)))))))

(match computation
  ((Result.Ok value) (print (string-concat "Computation result: " (int-to-string value))))
  ((Result.Err err) (print (string-concat "Computation error: " err))))

;; ヘルパー関数
(let toString (fn (x) "<value>"))  ; 仮実装
(let do (fn (exprs) (last exprs)))
(rec last (lst)
  (match lst
    ((list x) x)
    ((list _ t) (last t))))