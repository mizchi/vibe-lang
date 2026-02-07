// Function call with wrong number of args
let f = (a: Int, b: Int) -> Int { a + b }
f(1, 2, 3)

__DATA__
{"error_contains": "arg", "todo": true}
