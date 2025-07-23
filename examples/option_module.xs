module OptionUtils {
  export mapOption, isSome, isNone
  
  let mapOption opt f =
    case opt of {
      Some x -> Some (f x)
      None -> None
    }
  
  let isSome opt =
    case opt of {
      Some _ -> true
      None -> false
    }
  
  let isNone opt =
    case opt of {
      Some _ -> false
      None -> true
    }
}