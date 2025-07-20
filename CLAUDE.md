# XS Language - AI向け高速静的解析言語

## 概要
XS言語は、AIが理解・解析しやすいように設計された静的型付き関数型プログラミング言語です。コンテンツアドレス型のコード管理、純粋関数型設計、そしてAIフレンドリーなエラーメッセージにより、AIによるコード理解と生成を最適化します。

## 言語の特徴

### 1. コンテンツアドレス型コードベース（Unison風）
- すべての式がSHA256ハッシュで一意に識別される
- 同じコードは常に同じハッシュを生成（決定論的）
- 変更の追跡が容易で、AIが差分を効率的に理解できる
- UCM（Unison Codebase Manager）風のedit/update機能

### 2. 純粋関数型プログラミング
- 副作用のない純粋関数のみ
- 自動カリー化による部分適用
- 参照透過性により、AIが関数の振る舞いを確実に予測可能
- Perceus参照カウントによる効率的なメモリ管理

### 3. S式ベースの構文
- パーサー実装の効率化
- ASTの構造が明確で、AIが解析しやすい
- LISPファミリーの単純で一貫した構文

### 4. Hindley-Milner型推論
- 明示的な型注釈を最小限に
- 完全な型推論により、AIが型情報を活用しやすい
- Let多相による柔軟な型システム

### 5. AIフレンドリーなエラーメッセージ
- 構造化されたエラー情報（カテゴリー、提案、メタデータ）
- 型変換の自動提案
- レーベンシュタイン距離による類似変数名の提案
- トークン効率的な英語メッセージ（将来的に多言語化予定）

## アーキテクチャ

### crateの構成
- **xs_core**: 共通型定義、IR、ビルトイン関数、エラーコンテキスト
- **parser**: S式パーサー、メタデータ保持パーサー
- **checker**: HM型推論エンジン、改善されたエラーメッセージ
- **interpreter**: インタープリター実装
- **cli**: コマンドラインツール (xsc)
- **shell**: REPL実装、UCM風のコード管理
- **codebase**: Unison風構造化コードベース
- **xs_salsa**: インクリメンタルコンパイル
- **perceus**: Perceus GC変換
- **wasm_backend**: WebAssembly GCコード生成
- **runtime**: 統一ランタイムインターフェース

### メタデータ管理
- ASTとは別にコメントや一時変数ラベルを管理
- NodeIdによる一意な識別
- コード展開時にメタデータを考慮した整形

## 基本構文

```lisp
; 変数定義
(let x 42)
(let y: Int 10)  ; 型注釈（オプション）

; 関数定義（自動カリー化）
(let add (lambda (x y) (+ x y)))
(let inc (add 1))  ; 部分適用

; let-in構文（ローカルバインディング）
(let x 10 in (+ x 5))  ; 結果: 15
(let x 5 in
  (let y 10 in
    (* x y)))  ; 結果: 50

; 再帰関数
(rec factorial (n)
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

; rec内でlet-in使用（内部ヘルパー関数）
(rec quicksort (lst)
  (match lst
    ((list) (list))
    ((list pivot rest)
      (let smaller (filter (lambda (x) (< x pivot)) rest) in
        (let larger (filter (lambda (x) (>= x pivot)) rest) in
          (append (quicksort smaller)
                  (cons pivot (quicksort larger))))))))

; let-rec（相互再帰対応）
(let-rec even (n) (if (= n 0) true (odd (- n 1))))
(let-rec odd (n) (if (= n 0) false (even (- n 1))))

; パターンマッチング
(match xs
  ((list) 0)           ; 空リスト
  ((list h t) (+ 1 (length t))))  ; cons パターン

; 代数的データ型
(type Option a
  (None)
  (Some a))

(type Result e a
  (Error e)
  (Ok a))

; モジュール
(module Math
  (export add multiply factorial)
  (let add (lambda (x y) (+ x y)))
  ...)

; インポート
(import Math)
(import List as L)
```

## 標準ライブラリ

### core.xs
- 基本的な関数合成、恒等関数、定数関数
- Maybe/Either型と関連関数
- ブーリアン演算、数値ヘルパー

### list.xs
- リスト操作: map, filter, fold-left, fold-right
- リスト生成: range, replicate
- リスト検索: find, elem, all, any

### math.xs
- 数学関数: pow, factorial, gcd, lcm
- 数値述語: even, odd, positive, negative
- 統計関数: sum, product, average

### string.xs
- 文字列操作: concat, join, repeat
- 文字列比較: str-eq, str-neq

## XS Shell (REPL)

### 基本コマンド
- `help` - ヘルプ表示
- `history [n]` - 評価履歴表示
- `ls` - 名前付き式の一覧
- `name <hash> <name>` - ハッシュプレフィックスで式に名前を付ける
- `update` - 変更をコードベースにコミット
- `edits` - 保留中の編集を表示

### 使用例
```
xs> (let double (lambda (x) (* x 2)))
double : (-> Int Int) = <closure>
  [bac2c0f3]

xs> (double 21)
42 : Int
  [af3d2e89]

xs> name bac2 double_fn
Named double_fn : (-> Int Int) = <closure> [bac2c0f3]

xs> update
Updated 1 definitions:
+ double_fn
```

## エラーメッセージの設計

### エラーカテゴリー
- **SYNTAX**: 構文エラー
- **TYPE**: 型エラー
- **SCOPE**: スコープエラー（未定義変数など）
- **PATTERN**: パターンマッチエラー
- **MODULE**: モジュール関連エラー
- **RUNTIME**: 実行時エラー

### エラー構造
```
ERROR[TYPE]: Type mismatch: expected type 'Int', but found type 'String'
Location: line 3, column 5
Code: (+ x y)
Type mismatch: expected Int, found String
Suggestions:
  1. Convert string to integer using 'int_of_string'
     Replace with: (int_of_string y)
```

## 実装状況

### 完了済み機能
- ✅ S式パーサー（コメント保持対応）
- ✅ HM型推論（完全な型推論サポート）
- ✅ 基本的なインタープリター
- ✅ CLIツール (xsc parse/check/run/bench)
- ✅ REPL (XS Shell)
- ✅ コンテンツアドレス型コードベース
- ✅ 自動カリー化と部分適用
- ✅ 標準ライブラリ（core, list, math, string）
- ✅ パターンマッチング
- ✅ 代数的データ型
- ✅ モジュールシステム（基本実装）
- ✅ ASTメタデータ管理
- ✅ AIフレンドリーなエラーメッセージ

### 開発中/計画中
- ✅ rec内部定義の修正（let-in構文で解決）
- 📋 Unison風テスト結果キャッシュシステム
- 📋 Effect System
- 📋 WASIサンドボックス
- 📋 並列実行サポート
- 📋 より高度な型システム（GADTs、型クラスなど）

## パフォーマンス
- インクリメンタルコンパイル（Salsa使用）
- Perceus参照カウントによる効率的なGC
- WebAssembly GCターゲット
- 型チェッカーベンチマーク実装済み

## テストカバレッジ
現在のテストカバレッジ: 76.63%

## 開発方針
1. **AIファースト**: すべての設計判断はAIによる理解・生成を優先
2. **純粋性**: 副作用を排除し、予測可能な動作を保証
3. **効率性**: 静的解析の高速化を重視
4. **拡張性**: 将来の機能追加を考慮したモジュラー設計

## 今後の展望
- マルチコアCPUでの並列実行
- より高度な型システム（依存型、線形型など）
- ビジュアルプログラミング対応
- AIによる自動最適化
- 分散コードベース対応