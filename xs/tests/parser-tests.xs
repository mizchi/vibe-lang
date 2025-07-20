;; Tests for the XS parser

(module ParserTests
  (import Parser)
  (import Lexer)
  (import TestRunner)
  
  ;; レキサーのテスト
  (let test-lexer-simple (fn ()
    (let tokens (Lexer.tokenize "(+ 1 2)") in
      (do
        (assert-eq 5 (length tokens))  ; (, +, 1, 2, ), EOF
        (match (nth tokens 0)
          ((Token (LParen) _ _) true))
        (match (nth tokens 1)
          ((Token (Symbol "+") _ _) true))
        (match (nth tokens 2)
          ((Token (IntLit 1) _ _) true))))))
  
  ;; パーサーのテスト: 整数リテラル
  (let test-parse-int (fn ()
    (let ast (Parser.parse "42") in
      (match ast
        ((IntLit 42) true)
        (_ (error "Failed to parse integer"))))))
  
  ;; パーサーのテスト: シンボル
  (let test-parse-symbol (fn ()
    (let ast (Parser.parse "foo") in
      (match ast
        ((Symbol "foo") true)
        (_ (error "Failed to parse symbol"))))))
  
  ;; パーサーのテスト: 簡単なリスト
  (let test-parse-list (fn ()
    (let ast (Parser.parse "(+ 1 2)") in
      (match ast
        ((Apply (Symbol "+") (list (IntLit 1) (IntLit 2))) true)
        (_ (error "Failed to parse list"))))))
  
  ;; パーサーのテスト: let式
  (let test-parse-let (fn ()
    (let ast (Parser.parse "(let x 10)") in
      (match ast
        ((Let "x" (IntLit 10)) true)
        (_ (error "Failed to parse let"))))))
  
  ;; パーサーのテスト: 関数定義
  (let test-parse-fn (fn ()
    (let ast (Parser.parse "(fn (x y) (+ x y))") in
      (match ast
        ((Lambda params body) 
          (and (= 2 (length params))
               (match body
                 ((Apply (Symbol "+") _) true)
                 (_ false))))
        (_ (error "Failed to parse function"))))))
  
  ;; すべてのテストを実行
  (let all-tests
    (list
      (pair "lexer-simple" test-lexer-simple)
      (pair "parse-int" test-parse-int)
      (pair "parse-symbol" test-parse-symbol)
      (pair "parse-list" test-parse-list)
      (pair "parse-let" test-parse-let)
      (pair "parse-fn" test-parse-fn)))
  
  ;; テストを実行する関数
  (let run-all-tests (fn ()
    (TestRunner.run-tests all-tests))))