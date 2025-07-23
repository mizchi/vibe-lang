let applyTwice f x =
  let once = f x in
    f once in
applyTwice (\n -> n * 2) 3