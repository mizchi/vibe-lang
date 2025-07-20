# XS Language Test Runner Design

## 概要

XS言語に組み込みのテストランナーを実装します。これにより、XS言語で書かれたテストを`xsc test`コマンドで実行できるようになります。

## 設計方針

1. **シンプルで直感的なAPI**: 最小限の学習コストで使える
2. **純粋関数型**: 副作用を最小限に抑えた設計
3. **明確なエラーレポート**: 失敗時に何が問題かすぐわかる
4. **拡張可能**: 将来的な機能追加を考慮

## テストの構造

### テスト定義
```lisp
(test "addition works correctly"
  (assert-eq (+ 1 2) 3))

(test "string concatenation"
  (assert-eq (String.concat "Hello, " "World!") "Hello, World!"))
```

### テストスイート
```lisp
(test-suite "Math operations"
  (test "addition" (assert-eq (+ 1 1) 2))
  (test "subtraction" (assert-eq (- 5 3) 2))
  (test "multiplication" (assert-eq (* 3 4) 12)))
```

## アサーション関数

### 基本的なアサーション
```lisp
; 値が真であることを確認
(assert expr)
(assert expr "custom error message")

; 値が等しいことを確認
(assert-eq actual expected)
(assert-eq actual expected "custom message")

; 値が等しくないことを確認
(assert-neq actual expected)

; エラーが発生することを確認
(assert-error expr)
(assert-error expr "expected error message")
```

### 型アサーション
```lisp
(assert-type value Type)
(assert-int value)
(assert-string value)
(assert-list value)
```

## 実装アプローチ

### フェーズ1: 基本機能
1. `assert`と`assert-eq`の実装
2. `test`マクロの実装
3. シンプルなテスト実行機能

### フェーズ2: 拡張機能
1. テストスイートのサポート
2. setup/teardownの機能
3. テストのフィルタリング

### フェーズ3: 高度な機能
1. プロパティベーステスト
2. ベンチマーク機能
3. カバレッジ測定

## テスト結果の表現

```lisp
(type TestResult
  (Pass String)              ; test name
  (Fail String String)       ; test name, error message
  (Error String String))     ; test name, exception message

(type TestReport
  (TestReport 
    Int                      ; total tests
    Int                      ; passed
    Int                      ; failed
    (List TestResult)))      ; detailed results
```

## CLI統合

```bash
# すべてのテストを実行
xsc test

# 特定のファイルのテストを実行
xsc test tests/math.xs

# 特定のパターンにマッチするテストを実行
xsc test --filter "string"

# 詳細な出力
xsc test --verbose
```

## サンプルテストファイル

```lisp
; tests/example.xs
(import Test (assert assert-eq test))

(test "basic arithmetic"
  (assert-eq (+ 2 2) 4))

(test "list operations"
  (assert-eq (List.cons 1 (list 2 3)) (list 1 2 3)))

(test "string operations"
  (assert-eq (String.length "hello") 5))

(test "expected failure example"
  (assert-eq 1 2))  ; This should fail

(test "error handling"
  (assert-error (/ 1 0)))
```

## 期待される出力

```
Running tests in tests/example.xs...

✓ basic arithmetic
✓ list operations  
✓ string operations
✗ expected failure example
  Expected: 2
  Actual: 1
  at tests/example.xs:13
✓ error handling

Test Summary:
  Total: 5
  Passed: 4
  Failed: 1
```