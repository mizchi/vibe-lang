# ビルトイン関数の名前空間設計

## 概要

現在のグローバルなビルトイン関数を、型ごとの名前空間（モジュール）に整理します。

## 設計方針

1. **型ベースの組織化**: 各プリミティブ型に対応するモジュール
2. **統一的な命名規則**: 一貫性のある関数名
3. **後方互換性**: 既存コードへの影響を最小限に
4. **拡張性**: 新しい関数の追加が容易

## 名前空間の構成

### Int モジュール
```lisp
Int.add         ; (Int -> Int -> Int)     旧: +
Int.sub         ; (Int -> Int -> Int)     旧: -
Int.mul         ; (Int -> Int -> Int)     旧: *
Int.div         ; (Int -> Int -> Int)     旧: /
Int.mod         ; (Int -> Int -> Int)     旧: %
Int.toString    ; (Int -> String)         旧: int-to-string
Int.fromString  ; (String -> Int)         旧: string-to-int
Int.lt          ; (Int -> Int -> Bool)    旧: <
Int.gt          ; (Int -> Int -> Bool)    旧: >
Int.lte         ; (Int -> Int -> Bool)    旧: <=
Int.gte         ; (Int -> Int -> Bool)    旧: >=
Int.eq          ; (Int -> Int -> Bool)    旧: =
```

### String モジュール
```lisp
String.concat      ; (String -> String -> String)  旧: str-concat
String.length      ; (String -> Int)               旧: string-length
String.toInt       ; (String -> Int)               旧: string-to-int
String.fromInt     ; (Int -> String)               旧: int-to-string
String.substring   ; (String -> Int -> Int -> String)  新規
String.split       ; (String -> String -> List String) 新規
String.join        ; (List String -> String -> String)  新規
```

### List モジュール
```lisp
List.cons       ; (a -> List a -> List a)          旧: cons
List.head       ; (List a -> Option a)             新規
List.tail       ; (List a -> Option (List a))      新規
List.length     ; (List a -> Int)                  新規
List.map        ; ((a -> b) -> List a -> List b)   新規
List.filter     ; ((a -> Bool) -> List a -> List a) 新規
List.fold       ; ((a -> b -> b) -> b -> List a -> b) 新規
```

### Float モジュール
```lisp
Float.add       ; (Float -> Float -> Float)  旧: +.
Float.sub       ; (Float -> Float -> Float)  新規
Float.mul       ; (Float -> Float -> Float)  新規
Float.div       ; (Float -> Float -> Float)  新規
Float.toString  ; (Float -> String)          新規
Float.fromString; (String -> Float)          新規
```

### IO モジュール
```lisp
IO.print        ; (a -> a)                   旧: print
IO.println      ; (a -> a)                   新規
IO.readLine     ; (() -> String)             新規
```

## 実装戦略

### フェーズ1: 基盤実装
1. モジュール付き識別子のパース対応
2. 型チェッカーでの名前空間解決
3. インタープリターでの実行サポート

### フェーズ2: 関数の移行
1. 新しい名前空間に関数を追加
2. 既存の関数は非推奨として残す
3. ドキュメントの更新

### フェーズ3: 拡張
1. 新しい便利関数の追加
2. Option/Result型のサポート
3. より高度な関数の実装

## 使用例

### 現在のコード
```lisp
(let result (str-concat "Count: " (int-to-string 42)))
(print result)
```

### 名前空間を使用したコード
```lisp
(let result (String.concat "Count: " (Int.toString 42)))
(IO.print result)
```

### モジュールのインポート
```lisp
(import Int (toString))
(import String (concat length))

(let result (concat "Count: " (toString 42)))
```

## 技術的考慮事項

1. **パーサーの拡張**: ドット記法のサポート
2. **型環境の階層化**: モジュールごとの名前空間
3. **エラーメッセージ**: モジュール名を含む明確なエラー
4. **パフォーマンス**: 名前解決のオーバーヘッドを最小化