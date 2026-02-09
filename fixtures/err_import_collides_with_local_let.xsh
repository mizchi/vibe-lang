let abs = (x: Int) -> Int { x }
import { abs } from "./xsh/std/int.xsh"

abs(-1)

__DATA__
{"compile_error":"duplicate declaration: abs"}
