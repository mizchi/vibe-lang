import { trait Eq, type IntBox, add_eq } from ./fixtures/modules/import_explicit_kind_lib.xsh

let box_id = (x: IntBox) -> IntBox { x }
add_eq(box_id(1), 1)

__DATA__
{"last":"1"}
