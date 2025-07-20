;; Enhanced string operations for XS

(module StringOps
  (export stringAt charAt stringSlice substring indexOf lastIndexOf
          split join trim startsWith endsWith replaceFirst replaceAll
          toLowerCase toUpperCase charCode codeChar)
  
  ;; 文字列の指定位置の文字を取得
  ;; これらは実際にはビルトイン関数として実装する必要がある
  ;; ここではインターフェースのみ定義
  
  ;; stringAt :: String -> Int -> String
  (let stringAt (fn (str idx)
    ;; ビルトイン実装が必要
    (error "stringAt: builtin implementation required")))
  
  ;; charAt :: String -> Int -> String (stringAtのエイリアス)
  (let charAt stringAt)
  
  ;; stringSlice :: String -> Int -> Int -> String
  ;; 既存のstring-sliceをlowerCamelに
  (let stringSlice string-slice)
  
  ;; substring :: String -> Int -> Int -> String
  (let substring (fn (str start end)
    (stringSlice str start end)))
  
  ;; indexOf :: String -> String -> Int
  ;; 部分文字列の最初の出現位置を返す（見つからなければ-1）
  (rec indexOf (str substr)
    (indexOfFrom str substr 0))
  
  (rec indexOfFrom (str substr fromPos)
    (if (> (+ fromPos (string-length substr)) (string-length str))
        -1
        (if (string-eq (stringSlice str fromPos (+ fromPos (string-length substr))) substr)
            fromPos
            (indexOfFrom str substr (+ fromPos 1)))))
  
  ;; lastIndexOf :: String -> String -> Int
  ;; 部分文字列の最後の出現位置を返す
  (rec lastIndexOf (str substr)
    (lastIndexOfFrom str substr (- (string-length str) (string-length substr))))
  
  (rec lastIndexOfFrom (str substr fromPos)
    (if (< fromPos 0)
        -1
        (if (string-eq (stringSlice str fromPos (+ fromPos (string-length substr))) substr)
            fromPos
            (lastIndexOfFrom str substr (- fromPos 1)))))
  
  ;; split :: String -> String -> [String]
  ;; 文字列を区切り文字で分割（簡易版）
  (rec split (str delimiter)
    (if (string-eq str "")
        (list "")
        (splitHelper str delimiter 0 (list))))
  
  (rec splitHelper (str delimiter pos acc)
    (let nextPos (indexOfFrom str delimiter pos) in
      (if (= nextPos -1)
          (reverse (cons (stringSlice str pos (string-length str)) acc))
          (splitHelper str delimiter 
                      (+ nextPos (string-length delimiter))
                      (cons (stringSlice str pos nextPos) acc)))))
  
  ;; join :: [String] -> String -> String
  ;; リストの文字列を区切り文字で結合
  (rec join (strings delimiter)
    (match strings
      ((list) "")
      ((list s) s)
      ((list s rest)
        (string-concat s (string-concat delimiter (join rest delimiter))))))
  
  ;; trim :: String -> String
  ;; 前後の空白を削除（簡易版）
  (let trim (fn (str)
    (trimEnd (trimStart str))))
  
  ;; trimStart :: String -> String
  (rec trimStart (str)
    (if (= (string-length str) 0)
        str
        (let firstChar (stringAt str 0) in
          (if (isWhitespace firstChar)
              (trimStart (stringSlice str 1 (string-length str)))
              str))))
  
  ;; trimEnd :: String -> String
  (rec trimEnd (str)
    (let len (string-length str) in
      (if (= len 0)
          str
          (let lastChar (stringAt str (- len 1)) in
            (if (isWhitespace lastChar)
                (trimEnd (stringSlice str 0 (- len 1)))
                str)))))
  
  ;; isWhitespace :: String -> Bool
  (let isWhitespace (fn (ch)
    (or (string-eq ch " ")
        (or (string-eq ch "\t")
            (or (string-eq ch "\n")
                (string-eq ch "\r"))))))
  
  ;; startsWith :: String -> String -> Bool
  (let startsWith (fn (str prefix)
    (if (> (string-length prefix) (string-length str))
        false
        (string-eq (stringSlice str 0 (string-length prefix)) prefix))))
  
  ;; endsWith :: String -> String -> Bool
  (let endsWith (fn (str suffix)
    (let strLen (string-length str) in
    (let suffixLen (string-length suffix) in
      (if (> suffixLen strLen)
          false
          (string-eq (stringSlice str (- strLen suffixLen) strLen) suffix))))))
  
  ;; replaceFirst :: String -> String -> String -> String
  ;; 最初の出現箇所のみ置換
  (let replaceFirst (fn (str target replacement)
    (let pos (indexOf str target) in
      (if (= pos -1)
          str
          (string-concat (stringSlice str 0 pos)
                        (string-concat replacement
                                      (stringSlice str (+ pos (string-length target))
                                                  (string-length str))))))))
  
  ;; replaceAll :: String -> String -> String -> String
  ;; すべての出現箇所を置換
  (rec replaceAll (str target replacement)
    (let pos (indexOf str target) in
      (if (= pos -1)
          str
          (let prefix (stringSlice str 0 pos) in
          (let suffix (stringSlice str (+ pos (string-length target)) (string-length str)) in
            (string-concat prefix
                          (string-concat replacement
                                        (replaceAll suffix target replacement))))))))
  
  ;; toLowerCase / toUpperCase は文字コード操作が必要なので省略
  (let toLowerCase (fn (str)
    (error "toLowerCase: builtin implementation required")))
  
  (let toUpperCase (fn (str)
    (error "toUpperCase: builtin implementation required")))
  
  ;; charCode :: String -> Int
  ;; 文字の文字コードを取得
  (let charCode (fn (ch)
    (error "charCode: builtin implementation required")))
  
  ;; codeChar :: Int -> String
  ;; 文字コードから文字を作成
  (let codeChar (fn (code)
    (error "codeChar: builtin implementation required")))
  
  ;; ヘルパー関数
  (rec reverse (lst)
    (reverseAcc lst (list)))
  
  (rec reverseAcc (lst acc)
    (match lst
      ((list) acc)
      ((list h t) (reverseAcc t (cons h acc))))))