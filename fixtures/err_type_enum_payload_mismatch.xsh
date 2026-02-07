// Enum payload type mismatch
enum Result { Ok(Int), Err(String) }
let r = Ok("hello")

__DATA__
{"error_contains": "Mismatch"}
