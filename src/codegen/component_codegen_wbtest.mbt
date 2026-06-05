///|
// Build a minimal core wasm with type section, function section, export section
fn build_test_core_wasm(
  type_sigs : Array[(Array[Byte], Array[Byte])],
  func_type_indices : Array[Int],
  exports : Array[(String, Int, Int)], // (name, kind, index)
) -> Bytes {
  let buf : Array[Byte] = []
  // magic + version
  for
    b in [
      b'\x00', b'\x61', b'\x73', b'\x6d', b'\x01', b'\x00', b'\x00', b'\x00',
    ] {
    buf.push(b)
  }

  // Type section (id=1)
  let type_sec : Array[Byte] = []
  type_sec.push(type_sigs.length().to_byte())
  for sig in type_sigs {
    type_sec.push(b'\x60') // func type
    type_sec.push(sig.0.length().to_byte()) // param count
    for b in sig.0 {
      type_sec.push(b)
    }
    type_sec.push(sig.1.length().to_byte()) // result count
    for b in sig.1 {
      type_sec.push(b)
    }
  }
  buf.push(b'\x01') // section id
  component_write_uleb128(buf, type_sec.length())
  for b in type_sec {
    buf.push(b)
  }

  // Function section (id=3)
  let func_sec : Array[Byte] = []
  func_sec.push(func_type_indices.length().to_byte())
  for idx in func_type_indices {
    func_sec.push(idx.to_byte())
  }
  buf.push(b'\x03')
  component_write_uleb128(buf, func_sec.length())
  for b in func_sec {
    buf.push(b)
  }

  // Code section (id=10) - minimal empty function bodies
  let code_sec : Array[Byte] = []
  code_sec.push(func_type_indices.length().to_byte())
  for _ in func_type_indices {
    // minimal function body: 0 locals, end
    code_sec.push(b'\x02')
    code_sec.push(b'\x00')
    code_sec.push(b'\x0b')
  }
  buf.push(b'\x0a')
  component_write_uleb128(buf, code_sec.length())
  for b in code_sec {
    buf.push(b)
  }

  // Export section (id=7)
  let export_sec : Array[Byte] = []
  export_sec.push(exports.length().to_byte())
  for export_entry in exports {
    let name_bytes = @utf8.encode(export_entry.0).to_array()
    export_sec.push(name_bytes.length().to_byte())
    for b in name_bytes {
      export_sec.push(b)
    }
    export_sec.push(export_entry.1.to_byte()) // kind
    export_sec.push(export_entry.2.to_byte()) // index
  }
  buf.push(b'\x07')
  component_write_uleb128(buf, export_sec.length())
  for b in export_sec {
    buf.push(b)
  }

  Bytes::from_array(buf)
}

///|
test "parse_core_export_funcs finds exported function with correct sig" {
  // Type 0: () -> i64, Type 1: (i64, i64) -> i64
  let core_wasm = build_test_core_wasm(
    [
      ([], [b'\x7e']), // type 0: () -> i64
      ([b'\x7e', b'\x7e'], [b'\x7e']),
    ], // type 1: (i64, i64) -> i64
    [0, 1], // func 0 uses type 0, func 1 uses type 1
    [("run", 0, 0), ("add", 0, 1)], // (name, kind=func, func_index)
  )
  let exports = parse_core_export_funcs(core_wasm)
  assert_eq(exports.length(), 2)
  // run: () -> i64
  let run = exports[0]
  assert_eq(run.name, "run")
  assert_eq(run.sig.params.length(), 0)
  assert_eq(run.sig.results.length(), 1)
  assert_eq(run.sig.results[0], b'\x7e')
  // add: (i64, i64) -> i64
  let add = exports[1]
  assert_eq(add.name, "add")
  assert_eq(add.sig.params.length(), 2)
  assert_eq(add.sig.params[0], b'\x7e')
  assert_eq(add.sig.results.length(), 1)
}

///|
test "generate_string_trampoline_module produces valid structure" {
  let trampoline = generate_string_trampoline_module(2)
  // Check magic number
  assert_eq(trampoline[0], b'\x00')
  assert_eq(trampoline[1], b'\x61')
  assert_eq(trampoline[2], b'\x73')
  assert_eq(trampoline[3], b'\x6d')
  // Parse exports from the trampoline
  let exports = parse_core_export_funcs(trampoline)
  assert_eq(exports.length(), 1)
  assert_eq(exports[0].name, "canon_func")
  // canon_func: (i32, i32, i32, i32) -> i64
  assert_eq(exports[0].sig.params.length(), 4)
  assert_eq(exports[0].sig.params[0], b'\x7f') // i32
  assert_eq(exports[0].sig.params[1], b'\x7f') // i32
  assert_eq(exports[0].sig.params[2], b'\x7f') // i32
  assert_eq(exports[0].sig.params[3], b'\x7f') // i32
  assert_eq(exports[0].sig.results.length(), 1)
  assert_eq(exports[0].sig.results[0], b'\x7e') // i64
}

///|
test "generate_string_trampoline_module supports string results" {
  let trampoline = generate_string_trampoline_module(
    1,
    result_kind=ComponentStringLiftResult::String,
  )
  let exports = parse_core_export_funcs(trampoline)
  assert_eq(exports.length(), 1)
  assert_eq(exports[0].name, "canon_func")
  assert_eq(exports[0].sig.params.length(), 2)
  assert_eq(exports[0].sig.results.length(), 1)
  assert_eq(exports[0].sig.results[0], b'\x7f')
}

///|
test "parse_core_export_funcs skips non-function exports" {
  // Type 0: () -> i64
  let core_wasm = build_test_core_wasm(
    [([], [b'\x7e'])],
    [0],
    [("run", 0, 0), ("memory", 2, 0)], // func + memory exports
  )
  let exports = parse_core_export_funcs(core_wasm)
  // Should only find the function export, not the memory export
  assert_eq(exports.length(), 1)
  assert_eq(exports[0].name, "run")
}

///|
test "component core type section emits shared thread start func type" {
  let buf : Array[Byte] = []
  emit_component_core_type_section_shared_start_func(buf)
  let expected = [
    b'\x03', // component core type section
     b'\x06', // section content length
     b'\x01', // type count
     b'\x65', // shared subtype
     b'\x60', // core func type
     b'\x01', // param count
     b'\x7f', // i32
     b'\x00', // result count
  ]
  assert_eq(buf, expected)
}

///|
test "component canon section emits thread.spawn-indirect" {
  let buf : Array[Byte] = []
  emit_canon_thread_spawn_indirect_section(buf, 0, 0)
  let expected = [
    b'\x08', // component canon section
     b'\x04', // section content length
     b'\x01', // canon definition count
     b'\x41', // thread.spawn-indirect
     b'\x00', // core func type index
     b'\x00', // table index
  ]
  assert_eq(buf, expected)
}

///|
test "component alias section can alias shared indirect function table" {
  let buf : Array[Byte] = []
  emit_alias_section(buf, 0, [("__indirect_function_table", core_sort_table)])
  let expected = [
    b'\x06', // component alias section
     b'\x1f', // section content length
     b'\x01', // alias count
     b'\x00', // core export from instance
     b'\x01', // sort: table
     b'\x01', // alias kind marker: export
     b'\x00', // core instance index
     b'\x19', // export name length
     b'\x5f', b'\x5f', b'\x69', b'\x6e', b'\x64', b'\x69', b'\x72', b'\x65', b'\x63',
    b'\x74', b'\x5f', b'\x66', b'\x75', b'\x6e', b'\x63', b'\x74', b'\x69', b'\x6f',
    b'\x6e', b'\x5f', b'\x74', b'\x61', b'\x62', b'\x6c', b'\x65',
  ]
  assert_eq(buf, expected)
}
