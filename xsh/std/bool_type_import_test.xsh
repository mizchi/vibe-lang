import { Bool } from "./bool.xsh"

test "bool_method_with_type_import_only" {
  let t = true
  assert(eq(t.to_int(), 1))
  assert(not(Bool::from_int(0)))
}
