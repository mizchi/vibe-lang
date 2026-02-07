# TODO

## WASM-visible Primitive API Expansion

### Done (baseline)

- [x] Allow wasm type aliases in type positions: `i32`, `f32`, `f64`
- [x] Reserve `i32`/`f32`/`f64` as non-redefinable type names
- [x] Add `examples/std/wasm/types.xsh` (`I32`/`F32`/`F64` aliases)
- [x] Add initial opcode-style API set in `examples/std/wasm/opcodes.xsh`
- [x] Extend wasm codegen for numeric conversion builtins:
  `int_to_float`, `int_to_double`, `float_to_int`, `double_to_int`,
  `float_to_double`, `double_to_float`

### Next (remaining builtin instructions)

- [ ] Extend i32 integer opcodes:
  `i32_clz`, `i32_ctz`, `i32_popcnt`,
  `i32_div_u`, `i32_rem_u`,
  `i32_shr_u`, `i32_rotl`, `i32_rotr`,
  `i32_lt_u`, `i32_le_u`, `i32_gt_u`, `i32_ge_u`
- [ ] Extend f32 numeric opcodes:
  `f32_abs`, `f32_neg`, `f32_ceil`, `f32_floor`, `f32_trunc`, `f32_nearest`,
  `f32_sqrt`, `f32_min`, `f32_max`, `f32_copysign`
- [ ] Extend f64 numeric opcodes:
  `f64_abs`, `f64_neg`, `f64_ceil`, `f64_floor`, `f64_trunc`, `f64_nearest`,
  `f64_sqrt`, `f64_min`, `f64_max`, `f64_copysign`
- [ ] Add remaining conversion opcodes:
  `i32_wrap_i64`, `i64_extend_i32_s`, `i64_extend_i32_u`,
  unsigned conversion/truncation variants, reinterpret ops
- [ ] Define policy for memory-level opcodes exposure:
  load/store naming, alignment/offset API shape, and safety contract
- [ ] Add wasm-specific conformance tests for all opcode wrappers
  (interpreter parity + wasm backend parity)

### Notes

- API naming stays wasm-compatible by replacing `.` with `_`
  (example: wasm `i32.add` -> xsh `i32_add`).
- Keep CamelCase as the default user type style; permit lowercase
  wasm primitive spellings only for builtin wasm types.
