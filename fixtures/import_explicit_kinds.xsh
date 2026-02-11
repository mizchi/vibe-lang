use ./fixtures/modules/import_explicit_kind_lib.xsh {  trait Eq, type IntBox, add_eq  }

let box_id = (x: IntBox) -> IntBox { x }
add_eq(box_id(1), 1)

__DATA__
{"last":"1"}
