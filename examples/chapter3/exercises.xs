-- Chapter 3 練習問題の解答例

-- 必要な高階関数
rec map f lst =
  match lst {
    [] -> []
    h :: rest -> cons (f h) (map f rest)
  }

rec filter pred lst =
  match lst {
    [] -> []
    h :: rest ->
      if pred h {
        cons h (filter pred rest)
      } else {
        filter pred rest
      }
  }

rec foldLeft f init lst =
  match lst {
    [] -> init
    h :: rest -> foldLeft f (f init h) rest
  }

-- 問題1: flatMap関数の実装（リストのリストを平坦化しながらmap）
rec flatMap f lst =
  let concat = rec append lst1 lst2 =
    match lst1 {
      [] -> lst2
      h :: rest -> cons h (append rest lst2)
    } in
  
  let flatMapHelper = rec flatMapHelper lst =
    match lst {
      [] -> []
      h :: rest ->
        concat (f h) (flatMapHelper rest)
    } in
  
  flatMapHelper lst

-- テスト
-- flatMap (fn x -> [x, x * 2]) [1, 2, 3]
-- -- [1, 2, 2, 4, 3, 6]

-- flatMap (fn x -> if x > 0 { [x] } else { [] }) [-1, 2, -3, 4]
-- -- [2, 4]

-- 問題2: groupBy関数の実装（要素を関数の結果でグループ化）
rec groupBy keyFn lst =
  -- ヘルパー関数：キーが一致する要素を集める
  let collectByKey = rec collect key lst =
    filter (fn x -> keyFn x == key) lst in
  
  -- ヘルパー関数：ユニークなキーを取得
  let uniqueKeys = rec getKeys lst seen =
    match lst {
      [] -> seen
      h :: rest ->
        let key = keyFn h in
        let alreadySeen = rec contains k lst =
          match lst {
            [] -> false
            h2 :: rest2 ->
              if k == h2 { true } else { contains k rest2 }
          } in
        if alreadySeen key seen {
          getKeys rest seen
        } else {
          getKeys rest (cons key seen)
        }
    } in
  
  -- メイン処理
  let keys = uniqueKeys lst [] in
  map (fn key -> 
    [key, collectByKey key lst]) 
    keys

-- テスト
-- groupBy (fn x -> x % 2) [1, 2, 3, 4, 5, 6]
-- -- [[1, [1, 3, 5]], [0, [2, 4, 6]]]

-- groupBy (fn s -> strLength s) ["a", "bb", "ccc", "dd", "e"]
-- -- [[1, ["a", "e"]], [2, ["bb", "dd"]], [3, ["ccc"]]]

-- 問題3: 簡単なパーサーコンビネータの実装
type ParseResult a =
  | ParseError String
  | ParseOk a String  -- 値と残りの文字列

-- パーサーの型は String -> ParseResult a
let returnParser = fn value ->
  fn input -> ParseOk value input

let failParser = fn msg ->
  fn input -> ParseError msg

-- 文字を1つ読む
let charParser = fn c ->
  fn input ->
    if strLength input == 0 {
      ParseError "unexpected end of input"
    } else {
      let firstChar = strAt input 0 in
      if firstChar == c {
        ParseOk c (strSlice input 1)
      } else {
        ParseError (strConcat "expected " c)
      }
    }

-- パーサーの連結（bind操作）
let bindParser = fn parser f ->
  fn input ->
    match parser input {
      ParseError msg -> ParseError msg
      ParseOk value rest -> (f value) rest
    }

-- パーサーの選択（or操作）
let orParser = fn parser1 parser2 ->
  fn input ->
    match parser1 input {
      ParseOk v r -> ParseOk v r
      ParseError _ -> parser2 input
    }

-- 数字パーサーの例
let digitParser =
  orParser (charParser "0")
    (orParser (charParser "1")
      (orParser (charParser "2")
        (orParser (charParser "3")
          (orParser (charParser "4")
            (orParser (charParser "5")
              (orParser (charParser "6")
                (orParser (charParser "7")
                  (orParser (charParser "8")
                    (charParser "9")))))))))

-- テスト
-- digitParser "5abc"  -- ParseOk "5" "abc"
-- digitParser "xyz"   -- ParseError "expected 9"

-- より高度な例：2桁の数字をパース
let twoDigitParser =
  bindParser digitParser (fn d1 ->
    bindParser digitParser (fn d2 ->
      returnParser (strConcat d1 d2)))

-- twoDigitParser "42xyz"  -- ParseOk "42" "xyz"
-- twoDigitParser "4"      -- ParseError "unexpected end of input"