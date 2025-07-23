-- Enhanced string operations for XS

module StringOps {
  export stringAt, charAt, stringSlice, substring, indexOf, lastIndexOf,
         split, join, trim, startsWith, endsWith, replaceFirst, replaceAll,
         toLowerCase, toUpperCase, charCode, codeChar
  
  -- 文字列の指定位置の文字を取得
  -- これらは実際にはビルトイン関数として実装する必要がある
  -- ここではインターフェースのみ定義
  
  -- stringAt :: String -> Int -> String
  let stringAt = \str idx ->
    -- ビルトイン実装が必要
    error "stringAt: builtin implementation required"
  
  -- charAt :: String -> Int -> String (stringAtのエイリアス)
  let charAt = stringAt
  
  -- stringSlice :: String -> Int -> Int -> String
  -- ビルトイン関数stringSliceを使用（string-sliceから変更）
  -- let stringSlice = stringSlice -- 不要、ビルトイン関数を直接使用
  
  -- substring :: String -> Int -> Int -> String
  let substring = \str start end ->
    stringSlice str start end
  
  -- indexOf :: String -> String -> Int
  -- 部分文字列の最初の出現位置を返す（見つからなければ-1）
  rec indexOf str substr =
    indexOfFrom str substr 0
  
  rec indexOfFrom str substr fromPos =
    if (fromPos + String.length substr) > String.length str {
      -1
    } else {
      if String.eq (stringSlice str fromPos (fromPos + String.length substr)) substr {
        fromPos
      } else {
        indexOfFrom str substr (fromPos + 1)
      }
    }
  
  -- lastIndexOf :: String -> String -> Int
  -- 部分文字列の最後の出現位置を返す
  rec lastIndexOf str substr =
    lastIndexOfFrom str substr (String.length str - String.length substr)
  
  rec lastIndexOfFrom str substr fromPos =
    if fromPos < 0 {
      -1
    } else {
      if String.eq (stringSlice str fromPos (fromPos + String.length substr)) substr {
        fromPos
      } else {
        lastIndexOfFrom str substr (fromPos - 1)
      }
    }
  
  -- split :: String -> String -> [String]
  -- 文字列を区切り文字で分割（簡易版）
  rec split str delimiter =
    if String.eq str "" {
      [""]
    } else {
      splitHelper str delimiter 0 []
    }
  
  rec splitHelper str delimiter pos acc =
    let nextPos = indexOfFrom str delimiter pos in
      if nextPos == -1 {
        reverse (cons (stringSlice str pos (String.length str)) acc)
      } else {
        splitHelper str delimiter 
                    (nextPos + String.length delimiter)
                    (cons (stringSlice str pos nextPos) acc)
      }
  
  -- join :: [String] -> String -> String
  -- リストの文字列を区切り文字で結合
  rec join strings delimiter =
    case strings of {
      [] -> "";
      [s] -> s;
      s :: rest -> String.concat s (String.concat delimiter (join rest delimiter))
    }
  
  -- trim :: String -> String
  -- 前後の空白を削除（簡易版）
  let trim = \str ->
    trimEnd (trimStart str)
  
  -- trimStart :: String -> String
  rec trimStart str =
    if String.length str == 0 {
      str
    } else {
      let firstChar = stringAt str 0 in
        if isWhitespace firstChar {
          trimStart (stringSlice str 1 (String.length str))
        } else {
          str
        }
    }
  
  -- trimEnd :: String -> String
  rec trimEnd str =
    let len = String.length str in
      if len == 0 {
        str
      } else {
        let lastChar = stringAt str (len - 1) in
          if isWhitespace lastChar {
            trimEnd (stringSlice str 0 (len - 1))
          } else {
            str
          }
      }
  
  -- isWhitespace :: String -> Bool
  let isWhitespace = \ch ->
    String.eq ch " " ||
    String.eq ch "\t" ||
    String.eq ch "\n" ||
    String.eq ch "\r"
  
  -- startsWith :: String -> String -> Bool
  let startsWith = \str prefix ->
    if String.length prefix > String.length str {
      false
    } else {
      String.eq (stringSlice str 0 (String.length prefix)) prefix
    }
  
  -- endsWith :: String -> String -> Bool
  let endsWith = \str suffix ->
    let strLen = String.length str in
    let suffixLen = String.length suffix in
      if suffixLen > strLen {
        false
      } else {
        String.eq (stringSlice str (strLen - suffixLen) strLen) suffix
      }
  
  -- replaceFirst :: String -> String -> String -> String
  -- 最初の出現箇所のみ置換
  let replaceFirst = \str target replacement ->
    let pos = indexOf str target in
      if pos == -1 {
        str
      } else {
        String.concat (stringSlice str 0 pos)
                     (String.concat replacement
                                   (stringSlice str (pos + String.length target)
                                               (String.length str)))
      }
  
  -- replaceAll :: String -> String -> String -> String
  -- すべての出現箇所を置換
  rec replaceAll str target replacement =
    let pos = indexOf str target in
      if pos == -1 {
        str
      } else {
        let prefix = stringSlice str 0 pos in
        let suffix = stringSlice str (pos + String.length target) (String.length str) in
          String.concat prefix
                       (String.concat replacement
                                     (replaceAll suffix target replacement))
      }
  
  -- toLowerCase / toUpperCase は文字コード操作が必要なので省略
  let toLowerCase = \str ->
    error "toLowerCase: builtin implementation required"
  
  let toUpperCase = \str ->
    error "toUpperCase: builtin implementation required"
  
  -- charCode :: String -> Int
  -- 文字の文字コードを取得
  let charCode = \ch ->
    error "charCode: builtin implementation required"
  
  -- codeChar :: Int -> String
  -- 文字コードから文字を作成
  let codeChar = \code ->
    error "codeChar: builtin implementation required"
  
  -- ヘルパー関数
  rec reverse lst =
    reverseAcc lst []
  
  rec reverseAcc lst acc =
    case lst of {
      [] -> acc;
      h :: t -> reverseAcc t (cons h acc)
    }
}