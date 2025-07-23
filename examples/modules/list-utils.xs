-- リストユーティリティモジュール
module ListUtils {
  export length, head, tail, nth, take, drop, filter, map, foldLeft, foldRight
  
  -- リストの長さ
  rec length list =
    case list of {
      [] -> 0
      x :: xs -> 1 + (length xs)
    }
  
  -- 先頭要素を取得
  let head list =
    case list of {
      x :: xs -> Some x
      [] -> None
    }
  
  -- 先頭以外を取得
  let tail list =
    case list of {
      x :: xs -> xs
      [] -> []
    }
  
  -- n番目の要素を取得 (0-indexed)
  rec nth n list =
    case list of {
      [] -> None
      x :: xs ->
        if eq n 0 {
          Some x
        } else {
          nth (n - 1) xs
        }
    }
  
  -- 最初のn個を取得
  rec take n list =
    if n <= 0 {
      []
    } else {
      case list of {
        [] -> []
        x :: xs -> x :: (take (n - 1) xs)
      }
    }
  
  -- 最初のn個を除いたリストを返す
  rec drop n list =
    if n <= 0 {
      list
    } else {
      case list of {
        [] -> []
        x :: xs -> drop (n - 1) xs
      }
    }
  
  -- フィルタリング
  rec filter pred list =
    case list of {
      [] -> []
      x :: xs ->
        if pred x {
          x :: (filter pred xs)
        } else {
          filter pred xs
        }
    }
  
  -- マップ
  rec map f list =
    case list of {
      [] -> []
      x :: xs -> (f x) :: (map f xs)
    }
  
  -- 左畳み込み
  rec foldLeft f acc list =
    case list of {
      [] -> acc
      x :: xs -> foldLeft f (f acc x) xs
    }
  
  -- 右畳み込み
  rec foldRight f list acc =
    case list of {
      [] -> acc
      x :: xs -> f x (foldRight f xs acc)
    }
}