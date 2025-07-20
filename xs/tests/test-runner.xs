;; Test runner for XS self-hosting

(module TestRunner
  (export test assert run-tests TestResult)
  
  ;; テスト結果の型
  (type TestResult
    (Pass String)
    (Fail String String))  ; test name, error message
  
  ;; アサーション
  (let assert (fn (condition message)
    (if (not condition)
        (error message)
        true)))
  
  ;; 等価性のアサーション
  (let assert-eq (fn (expected actual)
    (assert (= expected actual)
            (string-concat "Expected: " 
                          (string-concat (to-string expected)
                                        (string-concat " but got: " 
                                                      (to-string actual)))))))
  
  ;; テスト関数を実行
  (let test (fn (name test-fn)
    (try
      (do
        (test-fn)
        (Pass name))
      (catch e
        (Fail name e)))))
  
  ;; テストのリストを実行
  (rec run-tests (tests)
    (let results (map run-single-test tests) in
      (print-results results)))
  
  ;; 単一のテストを実行
  (let run-single-test (fn (test-pair)
    (match test-pair
      ((pair name test-fn)
        (test name test-fn)))))
  
  ;; 結果を表示
  (rec print-results (results)
    (let passed (count-passed results) in
    (let failed (count-failed results) in
    (let total (length results) in
      (do
        (print-each-result results)
        (print (string-concat "\nTests: " 
                             (string-concat (int-to-string total)
                                           (string-concat " total, "
                                                         (string-concat (int-to-string passed)
                                                                       (string-concat " passed, "
                                                                                     (string-concat (int-to-string failed)
                                                                                                   " failed")))))))))))
  
  ;; 各結果を表示
  (rec print-each-result (results)
    (match results
      ((list) ())
      ((list h t)
        (do
          (print-result h)
          (print-each-result t)))))
  
  ;; 単一の結果を表示
  (let print-result (fn (result)
    (match result
      ((Pass name)
        (print (string-concat "✓ " name)))
      ((Fail name error)
        (print (string-concat "✗ " 
                             (string-concat name
                                           (string-concat ": " error))))))))
  
  ;; パスしたテストをカウント
  (rec count-passed (results)
    (match results
      ((list) 0)
      ((list (Pass _) t) (+ 1 (count-passed t)))
      ((list _ t) (count-passed t))))
  
  ;; 失敗したテストをカウント
  (rec count-failed (results)
    (match results
      ((list) 0)
      ((list (Fail _ _) t) (+ 1 (count-failed t)))
      ((list _ t) (count-failed t))))
  
  ;; try-catch の簡易実装（実際にはビルトインが必要）
  (let try (fn (expr catch-fn)
    ;; ここは仮実装
    expr))
  
  ;; do記法の簡易実装（順次実行）
  (let do (fn (exprs)
    ;; 実際にはマクロとして実装が必要
    (last exprs)))
  
  ;; リストの最後の要素
  (rec last (lst)
    (match lst
      ((list) (error "Empty list"))
      ((list x) x)
      ((list _ t) (last t)))))