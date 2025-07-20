;; Bootstrap script to test self-hosting implementation

;; 必要なモジュールをインポート
(import "lib/string-utils.xs")
(import "lib/control.xs")
(import "lib/pair.xs")
(import "parser/lexer.xs")
(import "parser/parser.xs")
(import "checker/types.xs")
(import "checker/checker.xs")
(import "tests/test-runner.xs")
(import "tests/parser-tests.xs")

;; 簡単なテストプログラム
(let test-program-1 "(+ 1 2)")
(let test-program-2 "(let x 10)")
(let test-program-3 "(fn (x) (* x 2))")

;; レキサーのテスト
(print "=== Lexer Test ===")
(let tokens (Lexer.tokenize test-program-1))
(print (string-concat "Tokens for '" 
                     (string-concat test-program-1 
                                   (string-concat "': " 
                                                 (int-to-string (length tokens))))))

;; パーサーのテスト
(print "\n=== Parser Test ===")
(let ast1 (Parser.parse test-program-1))
(print "Parsed (+ 1 2)")

(let ast2 (Parser.parse test-program-2))
(print "Parsed (let x 10)")

(let ast3 (Parser.parse test-program-3))
(print "Parsed (fn (x) (* x 2))")

;; 型検査のテスト
(print "\n=== Type Checker Test ===")
(let type1 (TypeChecker.type-check ast1))
(print (string-concat "Type of (+ 1 2): " (TypeChecker.type-to-string type1)))

(let type3 (TypeChecker.type-check ast3))
(print (string-concat "Type of (fn (x) (* x 2)): " (TypeChecker.type-to-string type3)))

;; テストスイートの実行
(print "\n=== Running Test Suite ===")
(ParserTests.run-all-tests)