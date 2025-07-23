-- Bootstrap script to test self-hosting implementation

-- 必要なモジュールをインポート
import "lib/string-utils.xs"
import "lib/control.xs"
import "lib/pair.xs"
import "parser/lexer.xs"
import "parser/parser.xs"
import "checker/types.xs"
import "checker/checker.xs"
import "tests/test-runner.xs"
import "tests/parser-tests.xs"

-- 簡単なテストプログラム
let testProgram1 = "(+ 1 2)"
let testProgram2 = "(let x 10)"
let testProgram3 = "(fn (x) (* x 2))"

-- レキサーのテスト
IO.print "=== Lexer Test ==="
let tokens = Lexer.tokenize testProgram1
IO.print (String.concat "Tokens for '" 
                       (String.concat testProgram1 
                                     (String.concat "': " 
                                                   (Int.toString (List.length tokens)))))

-- パーサーのテスト
IO.print "\n=== Parser Test ==="
let ast1 = Parser.parse testProgram1
IO.print "Parsed (+ 1 2)"

let ast2 = Parser.parse testProgram2
IO.print "Parsed (let x 10)"

let ast3 = Parser.parse testProgram3
IO.print "Parsed (fn (x) (* x 2))"

-- 型検査のテスト
IO.print "\n=== Type Checker Test ==="
let type1 = TypeChecker.typeCheck ast1
IO.print (String.concat "Type of (+ 1 2): " (TypeChecker.typeToString type1))

let type3 = TypeChecker.typeCheck ast3
IO.print (String.concat "Type of (fn (x) (* x 2)): " (TypeChecker.typeToString type3))

-- テストスイートの実行
IO.print "\n=== Running Test Suite ==="
ParserTests.runAllTests