-- expect: 12
let applyTwice f x =
  let once = f x in
    f once in
applyTwice (fn n -> n * 2) 3