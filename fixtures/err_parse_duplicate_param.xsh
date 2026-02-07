// Duplicate parameter name - second x shadows first
let f = (x: Int, x: Int) -> Int { x }
f(1, 2)

__DATA__
{"last": "2"}
