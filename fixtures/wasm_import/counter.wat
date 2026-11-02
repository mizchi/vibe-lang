;; Fixture for `import ./counter.wasm { .. }` (typed core-wasm import).
;; Built into counter.wasm by scripts/build_wasm_import_fixtures.sh.
(module
  (memory (export "memory") 1)
  (global $count (mut i64) (i64.const 0))
  (data (i32.const 16) "hello")
  ;; i32 -> i32
  (func (export "Add_I32") (param i32 i32) (result i32)
    (i32.add (local.get 0) (local.get 1)))
  ;; i64 -> i64
  (func (export "mul64") (param i64 i64) (result i64)
    (i64.mul (local.get 0) (local.get 1)))
  ;; void, mutates state
  (func (export "bump") (param i64)
    (global.set $count (i64.add (global.get $count) (local.get 0))))
  (func (export "count") (result i64) (global.get $count))
  ;; unsigned read of an i32 that a caller may pass as 2^32-1
  (func (export "is_all_ones") (param i32) (result i32)
    (i32.eq (local.get 0) (i32.const -1)))
  ;; i64 result that does not fit a 63-bit Int
  (func (export "too_wide") (result i64) (i64.const 0x7fffffffffffffff))
  ;; not offered: float
  (func (export "half") (param f64) (result f64)
    (f64.mul (local.get 0) (f64.const 0.5)))
  ;; not offered: two exports with one vibe name
  (func (export "Same") (result i32) (i32.const 1))
  (func (export "same") (result i32) (i32.const 2))
  ;; string pointer into this module's own memory
  (func (export "greeting_ptr") (result i32) (i32.const 16))
  (func (export "greeting_len") (result i32) (i32.const 5))
)
