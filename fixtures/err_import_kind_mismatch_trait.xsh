use ./fixtures/modules/import_explicit_kind_lib.xsh {  trait add_eq  }
add_eq(1, 1)

__DATA__
{"compile_error":"expected trait export: add_eq"}
