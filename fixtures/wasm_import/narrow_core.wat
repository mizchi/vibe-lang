;; Core module of the narrow-width component fixture (narrow.wit, #3826),
;; built into narrow.component.wasm by scripts/build_wasm_import_fixtures.sh.
;; A u8 / s16 crosses as an i32; the component lifts the result's low bits.
(module
  (memory (export "memory") 1)
  (func (export "cabi_realloc") (param i32 i32 i32 i32) (result i32) (i32.const 0))
  (func (export "inc8") (param i32) (result i32) (i32.add (local.get 0) (i32.const 1)))
  (func (export "neg16") (param i32) (result i32) (i32.sub (i32.const 0) (local.get 0)))
)
