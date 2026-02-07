// Expected string got int
let expect_str = (s: String) -> String { s }
expect_str(42)

__DATA__
{"error_contains": "Mismatch"}
