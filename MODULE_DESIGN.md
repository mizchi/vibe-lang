# XS言語 モジュールシステム設計

## 概要
XS言語のモジュールシステムは、AI向けの高速な静的解析を可能にすることを目的として設計されています。

## 設計方針
1. **明示的なエクスポート** - 公開するものを明確に宣言
2. **型安全なインポート** - 型チェッカーと統合されたインポート機構
3. **依存関係の静的解析** - モジュール間の依存を即座に解析可能
4. **シンプルな構文** - S式ベースの一貫した構文

## 構文

### モジュール定義
```lisp
(module ModuleName
  ; エクスポートする識別子のリスト
  (export identifier1 identifier2 Type1)
  
  ; モジュール本体
  (define identifier1 ...)
  (type Type1 ...)
  ...)
```

### インポート
```lisp
; 特定の識別子をインポート
(import (ModuleName identifier1 identifier2))

; モジュール全体をプレフィックス付きでインポート
(import ModuleName as M)

; 使用例
(M.identifier1 ...)
```

### 例：数学モジュール
```lisp
(module Math
  (export add sub mul div sqrt PI)
  
  (define PI 3.14159265359)
  
  (define add (lambda (x y) (+ x y)))
  (define sub (lambda (x y) (- x y)))
  (define mul (lambda (x y) (* x y)))
  (define div (lambda (x y) (/ x y)))
  
  ; 外部関数として後で実装
  (define sqrt (lambda (x) ...)))
```

### 例：データ構造モジュール
```lisp
(module DataStructures
  (export Stack push pop empty)
  
  (type Stack (Empty) (Node value rest))
  
  (define empty (Empty))
  
  (define push (lambda (stack value)
    (Node value stack)))
  
  (define pop (lambda (stack)
    (match stack
      ((Empty) (None))
      ((Node value rest) (Some value))))))
```

## 実装計画

### フェーズ1: AST拡張
1. `Module`式の追加
2. `Import`式の追加
3. `Export`宣言の追加

### フェーズ2: パーサー拡張
1. `module`キーワードの追加
2. `import`キーワードの追加
3. `export`キーワードの追加
4. モジュール名の解析
5. ドット記法（`M.identifier`）のサポート

### フェーズ3: 型チェッカー拡張
1. モジュール環境の管理
2. エクスポートされた識別子の型情報保存
3. インポート時の型チェック
4. 循環依存の検出

### フェーズ4: インタープリター拡張
1. モジュール値の保存
2. インポート機構の実装
3. 修飾名の解決

### フェーズ5: ファイルシステム統合
1. モジュールファイルの探索
2. 複数ファイルのコンパイル
3. モジュールキャッシュ

## 型システムとの統合
- エクスポートされた型は型環境に追加
- インポート時に型の一貫性をチェック
- モジュール間での型の共有

## AI向け最適化
1. **依存グラフの構築** - モジュール間の依存関係を即座に把握
2. **インクリメンタル解析** - 変更されたモジュールのみ再解析
3. **型情報のキャッシュ** - 高速な型クエリを可能に