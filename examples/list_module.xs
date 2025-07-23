module ListUtils {
  export length, head, tail, sum
  
  rec length xs =
    case xs of {
      [] -> 0
      _ :: rest -> 1 + (length rest)
    }
  
  let head xs =
    case xs of {
      [] -> 0
      x :: _ -> x
    }
  
  let tail xs =
    case xs of {
      [] -> []
      _ :: rest -> rest
    }
  
  rec sum xs =
    case xs of {
      [] -> 0
      x :: rest -> x + (sum rest)
    }
}