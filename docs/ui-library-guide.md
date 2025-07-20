# XS UI Library Guide

XS言語で実装された宣言的UIライブラリの完全ガイドです。

## 概要

XS UIライブラリは、React風の宣言的UIプログラミングをXS言語で実現するライブラリです。純粋関数型言語の特性を活かし、予測可能で保守しやすいUIアプリケーションを構築できます。

## 主要コンポーネント

### 1. 仮想DOM (vdom.xs)

仮想DOMはUIの構造を表現するデータ構造です。

```lisp
(type VNode
  (Text String)
  (Element String (List Attr) (List VNode))
  (Fragment (List VNode)))
```

#### 使用例
```lisp
(div (list (attr "class" "container"))
     (list (h1 (list) (list (text "Hello, XS!")))))
```

### 2. 状態管理 (state.xs)

Redux風の状態管理システムを提供します。

```lisp
; アクション定義
(type Action
  (SetValue Int)
  (Increment)
  (Decrement)
  (Reset))

; レデューサー
(let reducer (fn (state action) ...))

; 状態の作成
(let initial-state (create-state 0))
```

### 3. 差分アルゴリズム (diff.xs)

仮想DOMツリーの効率的な差分計算を行います。

```lisp
; 差分計算
(let patches (diff old-vnode new-vnode))

; パッチの種類
(type Patch
  (Replace VNode)
  (UpdateText String String)
  (UpdateAttributes (List Attr) (List Attr))
  (AddChild Int VNode)
  (RemoveChild Int))
```

### 4. イベントハンドリング (events.xs)

統一的なイベントハンドリングシステムを提供します。

```lisp
; イベントハンドラーの作成
(on-click (fn (event) (UpdateState "clicked" 1)))
(on-input (fn (event) 
  (match event
    ((Input value) (SetText value))
    (_ NoOp))))
```

### 5. レンダリングエンジン (render.xs)

仮想DOMをHTMLに変換します。

```lisp
; 基本的なレンダリング
(render vnode)

; プリティプリント付きレンダリング
(render-to-string vnode (RenderOptions true 2))
```

## 完全なアプリケーション例

### カウンターアプリ

```lisp
(let counter-app (fn (count)
  (div (list)
       (list (h1 (list) (list (text "Counter")))
             (p (list) (list (text (Int.toString count))))
             (button (list (on-click (fn (_) Increment)))
                     (list (text "+")))))))
```

### Todoアプリ

```lisp
(let todo-app (fn (state)
  (match state
    ((AppState todos input-text)
      (div (list)
           (list (h1 (list) (list (text "Todo List")))
                 (input (list (attr "value" input-text)
                             (on-input (fn (e) (SetText e)))))
                 (button (list (on-click (fn (_) AddTodo)))
                         (list (text "Add")))
                 (ul (list) (List.map render-todo todos))))))))
```

## アーキテクチャの特徴

### 1. 純粋関数型設計
- すべてのコンポーネントは純粋関数
- 副作用はイベントハンドラーで管理
- 予測可能な状態遷移

### 2. 型安全性
- Hindley-Milner型推論による完全な型チェック
- パターンマッチングによる網羅的な分岐処理
- コンパイル時のエラー検出

### 3. パフォーマンス
- 効率的な差分アルゴリズム
- Perceus参照カウントによるメモリ管理
- 最小限のDOM更新

## 実装で発見された課題と解決策

### 課題1: 副作用の表現
XS言語にはIO型やEffect Systemがないため、イベントハンドラーの型が不完全です。
```lisp
; 現在: (fn (Event) Action)
; 理想: (fn (Event) IO Action)
```

### 課題2: 可変状態の管理
純粋関数型言語のため、状態更新は新しい状態の作成になります。これはReduxパターンと相性が良いです。

### 課題3: 文字列操作
当初は文字列操作関数が不足していましたが、`String.concat`、`Int.toString`などを実装して解決しました。

## 今後の拡張

1. **フックシステム**: useState、useEffect相当の機能
2. **ライフサイクル管理**: コンポーネントのマウント/アンマウント
3. **ルーティング**: SPAのためのルーターライブラリ
4. **スタイリング**: CSS-in-XSの実装
5. **サーバーサイドレンダリング**: 完全なSSRサポート

## まとめ

XS UIライブラリは、純粋関数型言語で宣言的UIプログラミングが可能であることを実証しました。型安全性と予測可能性により、大規模なアプリケーション開発にも適用できる基盤を提供します。