-- XS Standard Library - Option Type
-- Option型の定義と関連関数

-- Option type definition
type Option a = None | Some a

-- map over an Option
let mapOption f opt = match opt {
  None -> None
  Some x -> Some (f x)
}

-- flatMap/bind for Option
let flatMapOption f opt = match opt {
  None -> None
  Some x -> f x
}

-- Get value with default
let getOrElse default opt = match opt {
  None -> default
  Some x -> x
}

-- Check if Option has value
let isSome opt = match opt {
  None -> false
  Some _ -> true
}

-- Check if Option is empty
let isNone opt = match opt {
  None -> true
  Some _ -> false
}

-- Convert Option to List
let optionToList opt = match opt {
  None -> []
  Some x -> [x]
}

-- Get value or error
let unwrap opt = match opt {
  None -> error "unwrap called on None"
  Some x -> x
}