trait Eq
enum NoShow { NoShow(Int) }
impl Eq for NoShow
let id = [T: Eq + Show](x: T) -> T { x }
id(NoShow(1))

__DATA__
{"error_contains":"Named(name=\"Show\""}
