# XSセルフホスティングのためのビルトイン関数要件

## 必須のビルトイン関数

### 文字列操作
```lisp
;; 文字列の指定位置の文字を取得
(stringAt :: String -> Int -> String)

;; 文字のコードポイントを取得
(charCode :: String -> Int)

;; コードポイントから文字を作成
(codeChar :: Int -> String)

;; 文字列を小文字に変換
(toLowerCase :: String -> String)

;; 文字列を大文字に変換
(toUpperCase :: String -> String)

;; 既存のstring-sliceをlowerCamelに
(stringSlice :: String -> Int -> Int -> String)
```

### デバッグ支援
```lisp
;; 値を文字列に変換（デバッグ用）
(toString :: a -> String)

;; トレース出力（値をそのまま返す）
(trace :: String -> a -> a)
```

### IO操作（将来的に必要）
```lisp
;; ファイル読み込み
(readFile :: String -> Result String String)

;; ファイル書き込み
(writeFile :: String -> String -> Result () String)
```

## 実装計画

1. **Phase 1**: 文字列操作の基本関数
   - stringAt, charCode, codeChar の実装
   - 既存の string-slice を stringSlice にエイリアス

2. **Phase 2**: デバッグ支援
   - toString, trace の実装

3. **Phase 3**: 高度な文字列操作
   - toLowerCase, toUpperCase の実装

4. **Phase 4**: IO操作（将来）
   - readFile, writeFile の実装