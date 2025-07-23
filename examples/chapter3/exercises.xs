; Chapter 3 練習問題の解答例

; 必要な高階関数
(rec map (f lst)
  (match lst
    ((list) (list))
    ((list h ... rest) (cons (f h) (map f rest)))))

(rec filter (pred lst)
  (match lst
    ((list) (list))
    ((list h ... rest)
      (if (pred h)
          (cons h (filter pred rest))
          (filter pred rest)))))

(rec foldLeft (f init lst)
  (match lst
    ((list) init)
    ((list h ... rest) (foldLeft f (f init h) rest))))

; 問題1: flatMap関数の実装（リストのリストを平坦化しながらmap）
(rec flatMap (f lst)
  (let concat (rec append (lst1 lst2)
    (match lst1
      ((list) lst2)
      ((list h ... rest) (cons h (append rest lst2))))))
  
  (rec flatMapHelper (lst)
    (match lst
      ((list) (list))
      ((list h ... rest)
        (concat (f h) (flatMapHelper rest)))))
  
  (flatMapHelper lst))

; テスト
; (flatMap (fn (x) (list x (* x 2))) (list 1 2 3))
; ; (list 1 2 2 4 3 6)

; (flatMap (fn (x) (if (> x 0) (list x) (list))) (list -1 2 -3 4))
; ; (list 2 4)

; 問題2: groupBy関数の実装（要素を関数の結果でグループ化）
(rec groupBy (keyFn lst)
  ; ヘルパー関数：キーが一致する要素を集める
  (let collectByKey (rec collect (key lst)
    (filter (fn (x) (= (keyFn x) key)) lst)))
  
  ; ヘルパー関数：ユニークなキーを取得
  (let uniqueKeys (rec getKeys (lst seen)
    (match lst
      ((list) seen)
      ((list h ... rest)
        (let key (keyFn h))
        (let alreadySeen (rec contains (k lst)
          (match lst
            ((list) false)
            ((list h2 ... rest2)
              (if (= k h2) true (contains k rest2))))))
        (if (alreadySeen key seen)
            (getKeys rest seen)
            (getKeys rest (cons key seen)))))))
  
  ; メイン処理
  (let keys (uniqueKeys lst (list)))
  (map (fn (key) 
    (list key (collectByKey key lst))) 
    keys))

; テスト
; (groupBy (fn (x) (% x 2)) (list 1 2 3 4 5 6))
; ; (list (list 1 (list 1 3 5)) (list 0 (list 2 4 6)))

; (groupBy (fn (s) (strLength s)) (list "a" "bb" "ccc" "dd" "e"))
; ; (list (list 1 (list "a" "e")) (list 2 (list "bb" "dd")) (list 3 (list "ccc")))

; 問題3: 簡単なパーサーコンビネータの実装
(type ParseResult a
  (ParseError String)
  (ParseOk a String))  ; 値と残りの文字列

; パーサーの型は String -> ParseResult a
(let returnParser (fn (value)
  (fn (input) (ParseOk value input))))

(let failParser (fn (msg)
  (fn (input) (ParseError msg))))

; 文字を1つ読む
(let charParser (fn (c)
  (fn (input)
    (if (= (strLength input) 0)
        (ParseError "unexpected end of input")
        (let firstChar (strAt input 0))
        (if (= firstChar c)
            (ParseOk c (strSlice input 1))
            (ParseError (strConcat "expected " c)))))))

; パーサーの連結（bind操作）
(let bindParser (fn (parser f)
  (fn (input)
    (match (parser input)
      ((ParseError msg) (ParseError msg))
      ((ParseOk value rest) ((f value) rest))))))

; パーサーの選択（or操作）
(let orParser (fn (parser1 parser2)
  (fn (input)
    (match (parser1 input)
      ((ParseOk v r) (ParseOk v r))
      ((ParseError _) (parser2 input))))))

; 数字パーサーの例
(let digitParser
  (orParser (charParser "0")
    (orParser (charParser "1")
      (orParser (charParser "2")
        (orParser (charParser "3")
          (orParser (charParser "4")
            (orParser (charParser "5")
              (orParser (charParser "6")
                (orParser (charParser "7")
                  (orParser (charParser "8")
                    (charParser "9")))))))))))

; テスト
; (digitParser "5abc")  ; (ParseOk "5" "abc")
; (digitParser "xyz")   ; (ParseError "expected 9")

; より高度な例：2桁の数字をパース
(let twoDigitParser
  (bindParser digitParser (fn (d1)
    (bindParser digitParser (fn (d2)
      (returnParser (strConcat d1 d2)))))))

; (twoDigitParser "42xyz")  ; (ParseOk "42" "xyz")
; (twoDigitParser "4")      ; (ParseError "unexpected end of input")