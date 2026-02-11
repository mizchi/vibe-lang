use ./xsh/std/int.xsh {  abs  }
use ./xsh/std/int.xsh {  clamp as abs  }

abs(-1)

__DATA__
{"compile_error":"duplicate declaration: abs"}
