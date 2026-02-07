trait Eq
trait Show
impl Show for String
impl [T: Show] Eq for T
let id = [U: Eq](x: U) -> U { x }
id(1)

__DATA__
{"error_contains":"context=Some(\"argument\")"}
