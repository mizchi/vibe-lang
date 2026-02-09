trait Eq
enum NoShow { NoShow(Int) }
impl [T: Show] Eq for T
let id = [U: Eq](x: U) -> U { x }
id(NoShow(1))

__DATA__
{"error_contains":"context=Some(\"argument\")"}
