// ADR-0046 contract: `T?` is parser sugar for `Option[T]`. The end-to-end
// behaviour is also exercised by host-CLI runs (see `let x : Int? =
// Some(42)` round-trips correctly), but locking the parser-side smoke
// here prevents the desugar from regressing silently.

///|
test "T? parses without error in let annotation" {
  let _ = parse_ast("let x : Int? = Some(42)") catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
}

///|
test "T?? parses without error in let annotation" {
  let _ = parse_ast("let x : Int?? = None") catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
}

///|
test "T?[] parses without error (Array[Option[T]])" {
  let _ = parse_ast("let xs : Int?[] = []") catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
}

///|
test "T? parses without error in fn parameter and return" {
  let _ = parse_ast("let f = (x: Int?) -> Int? { x }") catch {
    err => abort("parse failed: " + err.diagnostic().message)
  }
}
