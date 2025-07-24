-- Test string to int and back conversion
-- expect: "200"
let numStr = "100" in
  let num = String.toInt numStr in
    let doubled = num + num in
      Int.toString doubled