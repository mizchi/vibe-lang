// Explicit type args ignored - inferred from actual args (known issue)
let swap = [A, B](a: A, b: B) -> (B, A) { (b, a) }
swap[Int](1, "hello")

__DATA__
{"last": "(\"hello\", 1)"}
