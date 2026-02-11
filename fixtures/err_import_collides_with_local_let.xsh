let abs = (x: Int) -> Int { x }
use ./xsh/std/int.xsh {  abs  }

abs(-1)

__DATA__
{"compile_error":"duplicate declaration: abs"}
