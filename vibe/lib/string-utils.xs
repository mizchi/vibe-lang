-- String utilities for XS self-hosting

module StringUtils {
  export stringAt, stringSlice, stringContains, findChar, elem
  
  -- 文字列の指定位置の文字を取得（簡易版）
  -- 実際にはビルトイン関数として実装する必要がある
  let stringAt = \str idx ->
    if idx < 0 || idx >= String.length str {
      error "String index out of bounds"
    } else {
      -- ここは仮実装。実際のビルトインが必要
      stringSlice str idx (idx + 1)
    }
  
  -- 文字列のスライス
  -- stringSlice is now a builtin function, no need to alias
  
  -- 文字列が部分文字列を含むかチェック
  rec stringContains str substr =
    stringContainsAt str substr 0
  
  -- 指定位置から部分文字列を探す
  rec stringContainsAt str substr pos =
    if (pos + String.length substr) > String.length str {
      false
    } else {
      if String.eq (stringSlice str pos (pos + String.length substr)) substr {
        true
      } else {
        stringContainsAt str substr (pos + 1)
      }
    }
  
  -- 文字列から文字を探す
  rec findChar str ch fromPos =
    if fromPos >= String.length str {
      -1
    } else {
      if String.eq (stringAt str fromPos) ch {
        fromPos
      } else {
        findChar str ch (fromPos + 1)
      }
    }
  
  -- リストに要素が含まれるかチェック（汎用版）
  rec elem x lst =
    case lst of {
      [] -> false;
      h :: t -> 
        if String.eq x h {
          true
        } else {
          elem x t
        }
    }
}