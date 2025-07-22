;; String utilities for XS self-hosting

(module StringUtils
  (export stringAt stringSlice stringContains findChar elem)
  
  ;; 文字列の指定位置の文字を取得（簡易版）
  ;; 実際にはビルトイン関数として実装する必要がある
  (let stringAt (fn (str idx)
    (if (or (< idx 0) (>= idx (stringLength str)))
        (error "String index out of bounds")
        ;; ここは仮実装。実際のビルトインが必要
        (stringSlice str idx (+ idx 1)))))
  
  ;; 文字列のスライス
  ;; stringSlice is now a builtin function, no need to alias
  
  ;; 文字列が部分文字列を含むかチェック
  (rec stringContains (str substr)
    (stringContainsAt str substr 0))
  
  ;; 指定位置から部分文字列を探す
  (rec stringContainsAt (str substr pos)
    (if (> (+ pos (stringLength substr)) (stringLength str))
        false
        (if (strEq (stringSlice str pos (+ pos (stringLength substr))) substr)
            true
            (stringContainsAt str substr (+ pos 1)))))
  
  ;; 文字列から文字を探す
  (rec findChar (str ch fromPos)
    (if (>= fromPos (stringLength str))
        -1
        (if (strEq (stringAt str fromPos) ch)
            fromPos
            (findChar str ch (+ fromPos 1)))))
  
  ;; リストに要素が含まれるかチェック（汎用版）
  (rec elem (x lst)
    (match lst
      ((list) false)
      ((list h t) 
        (if (strEq x h)
            true
            (elem x t))))))