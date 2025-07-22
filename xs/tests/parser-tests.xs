;; Tests for the XS parser

(module ParserTests
  (import Parser)
  (import Lexer)
  (import TestRunner)
  
  ;; レキサーのテスト
  (let testLexerSimple (fn ()
    (let tokens (Lexer.tokenize "(+ 1 2)") in
      (do
        (assertEquals 5 (length tokens))  ; (, +, 1, 2, ), EOF
        (match (nth tokens 0)
          ((Token (LParen) _ _) true))
        (match (nth tokens 1)
          ((Token (Symbol "+") _ _) true))
        (match (nth tokens 2)
          ((Token (IntLit 1) _ _) true))))))
  
  ;; パーサーのテスト: 整数リテラル
  (let testParseInt (fn ()
    (let ast (Parser.parse "42") in
      (match ast
        ((IntLit 42) true)
        (_ (error "Failed to parse integer"))))))
  
  ;; パーサーのテスト: シンボル
  (let testParseSymbol (fn ()
    (let ast (Parser.parse "foo") in
      (match ast
        ((Symbol "foo") true)
        (_ (error "Failed to parse symbol"))))))
  
  ;; パーサーのテスト: 簡単なリスト
  (let testParseList (fn ()
    (let ast (Parser.parse "(+ 1 2)") in
      (match ast
        ((Apply (Symbol "+") (list (IntLit 1) (IntLit 2))) true)
        (_ (error "Failed to parse list"))))))
  
  ;; パーサーのテスト: let式
  (let testParseLet (fn ()
    (let ast (Parser.parse "(let x 10)") in
      (match ast
        ((Let "x" (IntLit 10)) true)
        (_ (error "Failed to parse let"))))))
  
  ;; パーサーのテスト: 関数定義
  (let testParseFn (fn ()
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
      (pair "lexer-simple" testLexerSimple)
      (pair "parse-int" testParseInt)
      (pair "parse-symbol" testParseSymbol)
      (pair "parse-list" testParseList)
      (pair "parse-let" testParseLet)
      (pair "parse-fn" testParseFn)))
  
  ;; テストを実行する関数
  (let runAllTests (fn ()
    (TestRunner.runTests all-tests))))