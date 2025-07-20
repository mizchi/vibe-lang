# 文字列操作機能の実装計画

## 概要

UIライブラリの実装で最も必要性が高かった文字列操作機能を実装します。

## 実装する関数

### フェーズ1: 基本的な文字列操作

1. **文字列連結**
   ```lisp
   (str-concat "Hello, " "World!")  ; => "Hello, World!"
   ```

2. **数値変換**
   ```lisp
   (int-to-string 42)     ; => "42"
   (string-to-int "42")   ; => 42
   ```

3. **文字列長**
   ```lisp
   (string-length "Hello")  ; => 5
   ```

### フェーズ2: 高度な文字列操作

1. **部分文字列**
   ```lisp
   (substring "Hello" 1 3)  ; => "ell"
   ```

2. **文字列分割**
   ```lisp
   (string-split "a,b,c" ",")  ; => (list "a" "b" "c")
   ```

3. **文字列結合**
   ```lisp
   (string-join (list "a" "b" "c") ",")  ; => "a,b,c"
   ```

## 実装方法

### 1. ビルトイン関数として実装

**xs_core/src/builtin.rs**に追加:
```rust
pub enum Builtin {
    // 既存のビルトイン
    Add, Sub, Mul, Div,
    // 新規追加
    StrConcat,
    IntToString,
    StringToInt,
    StringLength,
}
```

### 2. 型チェッカーの更新

**checker/src/type_checker.rs**:
- 新しいビルトイン関数の型を定義
- 型推論ルールを追加

### 3. インタープリターの更新

**interpreter/src/interpreter.rs**:
- 各ビルトイン関数の実行ロジックを実装

### 4. IR生成の更新

**checker/src/ir_gen.rs**:
- 文字列操作のIR命令を生成

### 5. WebAssemblyバックエンドの更新

**wasm_backend/src/codegen.rs**:
- 文字列操作のWASM命令を生成
- 文字列のメモリレイアウトを定義

## テスト計画

### ユニットテスト
```lisp
; tests/string-operations.xs
(assert (= (str-concat "Hello" " World") "Hello World"))
(assert (= (int-to-string 123) "123"))
(assert (= (string-to-int "456") 456))
(assert (= (string-length "test") 4))
```

### 統合テスト
UIライブラリでの実際の使用例をテスト

## 実装スケジュール

1. **Day 1-2**: ビルトイン関数の基本実装
2. **Day 3-4**: 型チェッカーとインタープリターの更新
3. **Day 5-6**: IR生成とWASMバックエンドの更新
4. **Day 7**: テストとドキュメント作成

## 期待される効果

- UIライブラリで動的なテキスト表示が可能に
- デバッグ出力の改善
- より実用的なアプリケーション開発が可能に