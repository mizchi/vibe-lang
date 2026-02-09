import { trait add_eq } from ./fixtures/modules/import_explicit_kind_lib.xsh
add_eq(1, 1)

__DATA__
{"compile_error":"expected trait export: add_eq"}
