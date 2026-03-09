///|
fn write_func_type(
  buf : ByteBuf,
  params : Array[ValueKind],
  results : Array[ValueKind],
) -> Unit {
  buf.push((96).to_byte())
  write_u32_leb(buf, params.length())
  for kind in params {
    buf.push(valtype_byte(kind))
  }
  write_u32_leb(buf, results.length())
  for r in results {
    buf.push(valtype_byte(r))
  }
}

///|
fn http_host_import_binding(
  ctx : CodegenCtx,
  builtin_name : String,
) -> (String, String) {
  if not(ctx.http_component_wasi_shim) {
    return ("vibe:http", builtin_name)
  }
  match builtin_name {
    "http_request" => ("wasi:http/client@0.3.0-draft", "send")
    "http_response_status" => ("wasi:http/types@0.3.0-draft", "response-status")
    "http_response_header" => ("wasi:http/types@0.3.0-draft", "response-header")
    "http_response_body" => ("wasi:http/types@0.3.0-draft", "response-body")
    "http_close" => ("wasi:http/types@0.3.0-draft", "[drop]response")
    _ => ("vibe:http", builtin_name)
  }
}

///|
fn write_http_host_import(
  import_sec : ByteBuf,
  ctx : CodegenCtx,
  builtin_name : String,
  type_idx : Int,
) -> Unit {
  let (module_name, func_name) = http_host_import_binding(ctx, builtin_name)
  write_name(import_sec, module_name)
  write_name(import_sec, func_name)
  import_sec.push((0).to_byte())
  write_u32_leb(import_sec, type_idx)
}

///|
fn build_module(ctx : CodegenCtx, funcs : Array[WasmFunc]) -> Bytes {
  let buf = ByteBuf::new()
  // magic + version
  buf.push((0).to_byte())
  buf.push((97).to_byte())
  buf.push((115).to_byte())
  buf.push((109).to_byte())
  buf.push((1).to_byte())
  buf.push((0).to_byte())
  buf.push((0).to_byte())
  buf.push((0).to_byte())

  // type section
  let type_sec = ByteBuf::new()
  let ref_type = valtype_byte(ValueKind::ExternRef)
  let mut type_count = 0
  let mut js_length_type = -1
  let mut js_char_code_at_type = -1
  let mut js_substring_type = -1
  let mut js_concat_type = -1
  let mut js_equals_type = -1
  let mut import_type = -1
  let mut sleep_type = -1
  let mut wasi_stream_get_type = -1
  let mut stdout_write_char_type = -1
  let mut stdin_read_char_type = -1
  let mut fs_get_dirs_type = -1
  let mut fs_open_at_type = -1
  let mut fs_read_type = -1
  let mut fs_write_type = -1
  let mut fs_stat_at_type = -1
  let mut socket_instance_network_type = -1
  let mut socket_create_tcp_type = -1
  let mut socket_start_connect_type = -1
  let mut socket_finish_connect_type = -1
  let mut socket_subscribe_type = -1
  let mut socket_poll_type = -1
  let mut socket_shutdown_type = -1
  let mut socket_resource_drop_type = -1
  let mut socket_stream_read_type = -1
  let mut socket_stream_write_type = -1
  let mut http_host_arity1_type = -1
  let mut http_host_arity2_type = -1
  let mut http_host_arity4_type = -1
  if ctx.need_js_length {
    js_length_type = type_count
    type_count += 1
  }
  if ctx.need_js_char_code_at {
    js_char_code_at_type = type_count
    type_count += 1
  }
  if ctx.need_js_substring {
    js_substring_type = type_count
    type_count += 1
  }
  if ctx.need_js_concat {
    js_concat_type = type_count
    type_count += 1
  }
  if ctx.need_js_equals {
    js_equals_type = type_count
    type_count += 1
  }
  if ctx.need_sh || ctx.need_path || ctx.need_dynamic_path_resolve {
    import_type = type_count
    type_count += 1
  }
  if ctx.need_sleep {
    sleep_type = type_count
    type_count += 1
  }
  if ctx.need_stdout_write_char || ctx.need_stdin_read_char {
    wasi_stream_get_type = type_count
    type_count += 1
  }
  if ctx.need_stdout_write_char {
    stdout_write_char_type = type_count
    type_count += 1
  }
  if ctx.need_stdin_read_char {
    stdin_read_char_type = type_count
    type_count += 1
  }
  if ctx.need_fs {
    // fs_get_dirs_type: (i32) -> () — shared by get-directories and resource-drop
    fs_get_dirs_type = type_count
    type_count += 1
    // fs_open_at_type: (i32, i32, i32, i32, i32, i32, i32) -> ()
    fs_open_at_type = type_count
    type_count += 1
    // fs_read_type: (i32, i64, i64, i32) -> ()
    fs_read_type = type_count
    type_count += 1
    // fs_write_type: (i32, i32, i32, i64, i32) -> ()
    fs_write_type = type_count
    type_count += 1
    // fs_stat_at_type: (i32, i32, i32, i32, i32) -> ()
    fs_stat_at_type = type_count
    type_count += 1
  }
  if ctx.need_socket {
    // socket_instance_network_type: () -> (i32)
    socket_instance_network_type = type_count
    type_count += 1
    // socket_create_tcp_type: (i32, i32) -> ()
    socket_create_tcp_type = type_count
    type_count += 1
    // socket_start_connect_type: (i32 x 15) -> ()
    socket_start_connect_type = type_count
    type_count += 1
    // socket_finish_connect_type: (i32, i32) -> ()
    socket_finish_connect_type = type_count
    type_count += 1
    // socket_subscribe_type: (i32) -> (i32)
    socket_subscribe_type = type_count
    type_count += 1
    // socket_poll_type: (i32, i32, i32) -> ()
    socket_poll_type = type_count
    type_count += 1
    // socket_shutdown_type: (i32, i32, i32) -> ()
    socket_shutdown_type = type_count
    type_count += 1
    // socket_resource_drop_type: (i32) -> ()
    socket_resource_drop_type = type_count
    type_count += 1
    // socket_stream_read_type: (i32, i64, i32) -> () — same as stdin read
    socket_stream_read_type = type_count
    type_count += 1
    // socket_stream_write_type: (i32, i32, i32, i32) -> () — same as stdout write
    socket_stream_write_type = type_count
    type_count += 1
  }
  if ctx.need_http && ctx.http_host_imports {
    // (i64) -> i64
    http_host_arity1_type = type_count
    type_count += 1
    // (i64, i64) -> i64
    http_host_arity2_type = type_count
    type_count += 1
    // (i64, i64, i64, i64) -> i64
    http_host_arity4_type = type_count
    type_count += 1
  }
  let builtin_count = type_count
  let func_type_indices : Array[Int] = []
  for func in funcs {
    let key = func_sig_key_from_parts(func.params, func.results)
    let idx = match ctx.fn_sig_type_indices.get(key) {
      Some(i) => i
      None => builtin_count
    }
    func_type_indices.push(idx)
  }
  let exception_type_count = if ctx.need_exceptions { 1 } else { 0 }
  let stack_switching_type_count = if ctx.need_stack_switching { 3 } else { 0 }
  let total_type_count = builtin_count +
    ctx.fn_sig_order.length() +
    exception_type_count +
    stack_switching_type_count
  write_u32_leb(type_sec, total_type_count)
  if ctx.need_js_length {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push(ref_type)
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
  }
  if ctx.need_js_char_code_at {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push(ref_type)
    type_sec.push((127).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
  }
  if ctx.need_js_substring {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 3)
    type_sec.push(ref_type)
    type_sec.push((127).to_byte())
    type_sec.push((127).to_byte())
    write_u32_leb(type_sec, 1)
    write_ref_extern(type_sec)
  }
  if ctx.need_js_concat {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push(ref_type)
    type_sec.push(ref_type)
    write_u32_leb(type_sec, 1)
    write_ref_extern(type_sec)
  }
  if ctx.need_js_equals {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push(ref_type)
    type_sec.push(ref_type)
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
  }
  if ctx.need_sh || ctx.need_path || ctx.need_dynamic_path_resolve {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64 (tagged value)
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64 (tagged value)
  }
  if ctx.need_sleep {
    // sleep type: (func (param i64)) - takes ms as tagged value, returns nothing
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64 (tagged value)
    write_u32_leb(type_sec, 0) // no results
  }
  if ctx.need_stdout_write_char || ctx.need_stdin_read_char {
    // stream getter type: (func (result i32))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 0)
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte())
  }
  if ctx.need_stdout_write_char {
    // wasi stdout method type:
    // (func (param i32 stream i32 ptr i32 len i32 retptr))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 4)
    type_sec.push((127).to_byte())
    type_sec.push((127).to_byte())
    type_sec.push((127).to_byte())
    type_sec.push((127).to_byte())
    write_u32_leb(type_sec, 0)
  }
  if ctx.need_stdin_read_char {
    // wasi stdin method type: (func (param i32 stream i64 len i32 retptr))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 3)
    type_sec.push((127).to_byte())
    type_sec.push((126).to_byte())
    type_sec.push((127).to_byte())
    write_u32_leb(type_sec, 0)
  }
  if ctx.need_fs {
    // fs_get_dirs_type: (func (param i32) -> ()) — get-directories & resource-drop
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte()) // i32
    write_u32_leb(type_sec, 0)
    // fs_open_at_type: (func (param i32 i32 i32 i32 i32 i32 i32) -> ())
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 7)
    type_sec.push((127).to_byte()) // i32 self
    type_sec.push((127).to_byte()) // i32 path-flags
    type_sec.push((127).to_byte()) // i32 path-ptr
    type_sec.push((127).to_byte()) // i32 path-len
    type_sec.push((127).to_byte()) // i32 open-flags
    type_sec.push((127).to_byte()) // i32 desc-flags
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
    // fs_read_type: (func (param i32 i64 i64 i32) -> ())
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 4)
    type_sec.push((127).to_byte()) // i32 self
    type_sec.push((126).to_byte()) // i64 length
    type_sec.push((126).to_byte()) // i64 offset
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
    // fs_write_type: (func (param i32 i32 i32 i64 i32) -> ())
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 5)
    type_sec.push((127).to_byte()) // i32 self
    type_sec.push((127).to_byte()) // i32 buf-ptr
    type_sec.push((127).to_byte()) // i32 buf-len
    type_sec.push((126).to_byte()) // i64 offset
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
    // fs_stat_at_type: (func (param i32 i32 i32 i32 i32) -> ())
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 5)
    type_sec.push((127).to_byte()) // i32 self
    type_sec.push((127).to_byte()) // i32 path-flags
    type_sec.push((127).to_byte()) // i32 path-ptr
    type_sec.push((127).to_byte()) // i32 path-len
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
  }
  if ctx.need_socket {
    // socket_instance_network_type: () -> (i32)
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 0)
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte()) // i32
    // socket_create_tcp_type: (i32, i32) -> ()
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push((127).to_byte()) // i32 family
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
    // socket_start_connect_type: (i32 x 15) -> ()
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 15)
    for i = 0; i < 15; i = i + 1 {
      type_sec.push((127).to_byte()) // i32
    }
    write_u32_leb(type_sec, 0)
    // socket_finish_connect_type: (i32, i32) -> ()
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push((127).to_byte()) // i32 self
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
    // socket_subscribe_type: (i32) -> (i32)
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte()) // i32 self
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte()) // i32 pollable
    // socket_poll_type: (i32, i32, i32) -> ()
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 3)
    type_sec.push((127).to_byte()) // i32 list_ptr
    type_sec.push((127).to_byte()) // i32 list_len
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
    // socket_shutdown_type: (i32, i32, i32) -> ()
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 3)
    type_sec.push((127).to_byte()) // i32 self
    type_sec.push((127).to_byte()) // i32 shutdown-type
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
    // socket_resource_drop_type: (i32) -> ()
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte()) // i32 handle
    write_u32_leb(type_sec, 0)
    // socket_stream_read_type: (i32, i64, i32) -> ()
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 3)
    type_sec.push((127).to_byte()) // i32 self
    type_sec.push((126).to_byte()) // i64 len
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
    // socket_stream_write_type: (i32, i32, i32, i32) -> ()
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 4)
    type_sec.push((127).to_byte()) // i32 self
    type_sec.push((127).to_byte()) // i32 ptr
    type_sec.push((127).to_byte()) // i32 len
    type_sec.push((127).to_byte()) // i32 retptr
    write_u32_leb(type_sec, 0)
  }
  if ctx.need_http && ctx.http_host_imports {
    // http_host_arity1_type: (func (param i64) (result i64))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64
    // http_host_arity2_type: (func (param i64 i64) (result i64))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
    type_sec.push((126).to_byte()) // i64
    type_sec.push((126).to_byte()) // i64
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64
    // http_host_arity4_type: (func (param i64 i64 i64 i64) (result i64))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 4)
    type_sec.push((126).to_byte()) // i64
    type_sec.push((126).to_byte()) // i64
    type_sec.push((126).to_byte()) // i64
    type_sec.push((126).to_byte()) // i64
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64
  }
  for sig in ctx.fn_sig_order {
    write_func_type(type_sec, sig.params, sig.results)
  }
  if ctx.need_exceptions {
    ctx.error_tag_type_index = builtin_count + ctx.fn_sig_order.length()
    // tag type: (param <valtype>) -> () (no results)
    type_sec.push((96).to_byte()) // func type
    write_u32_leb(type_sec, 1) // param count = 1
    if ctx.use_js_strings {
      type_sec.push(ref_type) // externref
    } else {
      type_sec.push((126).to_byte()) // i64 (tagged value)
    }
    write_u32_leb(type_sec, 0) // result count = 0
  }
  // Stack switching types
  if ctx.need_stack_switching {
    // Await tag type: (func (param i64)) - one-way, no result
    ctx.await_tag_type_index = builtin_count +
      ctx.fn_sig_order.length() +
      exception_type_count
    type_sec.push((96).to_byte()) // func type
    write_u32_leb(type_sec, 1) // param count = 1
    type_sec.push((126).to_byte()) // i64 (tagged value)
    write_u32_leb(type_sec, 0) // result count = 0
    // Run function type: (func (result i64))
    ctx.run_func_type_index = ctx.await_tag_type_index + 1
    type_sec.push((96).to_byte()) // func type
    write_u32_leb(type_sec, 0) // param count = 0
    write_u32_leb(type_sec, 1) // result count = 1
    type_sec.push((126).to_byte()) // i64 (tagged value)
    // Run continuation type: (cont $run_func_type)
    // Type index = ctx.run_func_type_index + 1
    type_sec.push((0x5d).to_byte()) // cont type (0x5d per stack-switching spec)
    write_u32_leb(type_sec, ctx.run_func_type_index) // function type index
  }
  write_section(buf, 1, type_sec.data)

  // import section
  let mut func_import_count = 0
  if ctx.need_js_length {
    func_import_count += 1
  }
  if ctx.need_js_char_code_at {
    func_import_count += 1
  }
  if ctx.need_js_substring {
    func_import_count += 1
  }
  if ctx.need_js_concat {
    func_import_count += 1
  }
  if ctx.need_js_equals {
    func_import_count += 1
  }
  if ctx.need_path {
    func_import_count += 1
  }
  if ctx.need_dynamic_path_resolve {
    func_import_count += 1
  }
  if ctx.need_sh {
    func_import_count += 1
  }
  if ctx.need_sleep {
    ctx.sleep_import_index = func_import_count
    func_import_count += 1
  }
  if ctx.need_stdout_write_char {
    func_import_count += 2
  }
  if ctx.need_stdin_read_char {
    func_import_count += 2
  }
  if ctx.need_fs {
    func_import_count += 6
  }
  if ctx.need_socket {
    func_import_count += 13
  }
  if ctx.need_http && ctx.http_host_imports {
    func_import_count += 12
  }
  let global_import_count = if ctx.use_js_strings {
    ctx.js_strings.names.length()
  } else {
    0
  }
  let import_count = func_import_count + global_import_count
  if import_count > 0 {
    let import_sec = ByteBuf::new()
    write_u32_leb(import_sec, import_count)
    if ctx.need_js_length {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "length")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_length_type)
    }
    if ctx.need_js_char_code_at {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "charCodeAt")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_char_code_at_type)
    }
    if ctx.need_js_substring {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "substring")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_substring_type)
    }
    if ctx.need_js_concat {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "concat")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_concat_type)
    }
    if ctx.need_js_equals {
      write_name(import_sec, "wasm:js-string")
      write_name(import_sec, "equals")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, js_equals_type)
    }
    if ctx.need_path {
      write_name(import_sec, "vibe")
      write_name(import_sec, "path")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, import_type)
    }
    if ctx.need_dynamic_path_resolve {
      write_name(import_sec, "vibe")
      write_name(import_sec, "resolve_path")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, import_type)
    }
    if ctx.need_sh {
      write_name(import_sec, "vibe")
      write_name(import_sec, "sh")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, import_type)
    }
    if ctx.need_sleep {
      write_name(import_sec, "vibe")
      write_name(import_sec, "sleep")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, sleep_type)
    }
    if ctx.need_stdout_write_char {
      write_name(import_sec, "wasi:cli/stdout@0.2.0")
      write_name(import_sec, "get-stdout")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, wasi_stream_get_type)
      write_name(import_sec, "wasi:io/streams@0.2.0")
      write_name(import_sec, "[method]output-stream.blocking-write-and-flush")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, stdout_write_char_type)
    }
    if ctx.need_stdin_read_char {
      write_name(import_sec, "wasi:cli/stdin@0.2.0")
      write_name(import_sec, "get-stdin")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, wasi_stream_get_type)
      write_name(import_sec, "wasi:io/streams@0.2.0")
      write_name(import_sec, "[method]input-stream.blocking-read")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, stdin_read_char_type)
    }
    if ctx.need_fs {
      // 1. get-directories
      write_name(import_sec, "wasi:filesystem/preopens@0.3.0")
      write_name(import_sec, "get-directories")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_get_dirs_type)
      // 2. open-at
      write_name(import_sec, "wasi:filesystem/types@0.3.0")
      write_name(import_sec, "[method]descriptor.open-at")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_open_at_type)
      // 3. read
      write_name(import_sec, "wasi:filesystem/types@0.3.0")
      write_name(import_sec, "[method]descriptor.read")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_read_type)
      // 4. write
      write_name(import_sec, "wasi:filesystem/types@0.3.0")
      write_name(import_sec, "[method]descriptor.write")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_write_type)
      // 5. stat-at
      write_name(import_sec, "wasi:filesystem/types@0.3.0")
      write_name(import_sec, "[method]descriptor.stat-at")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_stat_at_type)
      // 6. resource-drop descriptor
      write_name(import_sec, "wasi:filesystem/types@0.3.0")
      write_name(import_sec, "[resource-drop]descriptor")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_get_dirs_type)
    }
    if ctx.need_socket {
      // 1. instance-network
      write_name(import_sec, "wasi:sockets/instance-network@0.2.0")
      write_name(import_sec, "instance-network")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_instance_network_type)
      // 2. create-tcp-socket
      write_name(import_sec, "wasi:sockets/tcp-create-socket@0.2.0")
      write_name(import_sec, "create-tcp-socket")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_create_tcp_type)
      // 3. start-connect
      write_name(import_sec, "wasi:sockets/tcp@0.2.0")
      write_name(import_sec, "[method]tcp-socket.start-connect")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_start_connect_type)
      // 4. finish-connect
      write_name(import_sec, "wasi:sockets/tcp@0.2.0")
      write_name(import_sec, "[method]tcp-socket.finish-connect")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_finish_connect_type)
      // 5. subscribe
      write_name(import_sec, "wasi:sockets/tcp@0.2.0")
      write_name(import_sec, "[method]tcp-socket.subscribe")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_subscribe_type)
      // 6. poll
      write_name(import_sec, "wasi:io/poll@0.2.0")
      write_name(import_sec, "poll")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_poll_type)
      // 7. input-stream.blocking-read
      write_name(import_sec, "wasi:io/streams@0.2.0")
      write_name(import_sec, "[method]input-stream.blocking-read")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_stream_read_type)
      // 8. output-stream.blocking-write-and-flush
      write_name(import_sec, "wasi:io/streams@0.2.0")
      write_name(import_sec, "[method]output-stream.blocking-write-and-flush")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_stream_write_type)
      // 9. shutdown
      write_name(import_sec, "wasi:sockets/tcp@0.2.0")
      write_name(import_sec, "[method]tcp-socket.shutdown")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_shutdown_type)
      // 10. resource-drop tcp-socket
      write_name(import_sec, "wasi:sockets/tcp@0.2.0")
      write_name(import_sec, "[resource-drop]tcp-socket")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_resource_drop_type)
      // 11. resource-drop input-stream
      write_name(import_sec, "wasi:io/streams@0.2.0")
      write_name(import_sec, "[resource-drop]input-stream")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_resource_drop_type)
      // 12. resource-drop output-stream
      write_name(import_sec, "wasi:io/streams@0.2.0")
      write_name(import_sec, "[resource-drop]output-stream")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_resource_drop_type)
      // 13. resource-drop pollable
      write_name(import_sec, "wasi:io/poll@0.2.0")
      write_name(import_sec, "[resource-drop]pollable")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, socket_resource_drop_type)
    }
    if ctx.need_http && ctx.http_host_imports {
      // http_request(method, url, headers, body) -> handle
      write_http_host_import(
        import_sec, ctx, "http_request", http_host_arity4_type,
      )
      // response handle APIs
      write_http_host_import(
        import_sec, ctx, "http_response_status", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_response_header", http_host_arity2_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_response_body", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_close", http_host_arity1_type,
      )
      // server APIs
      write_http_host_import(
        import_sec, ctx, "http_listen", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_accept", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_request_method", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_request_url", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_request_header", http_host_arity2_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_request_body", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "http_respond", http_host_arity4_type,
      )
    }
    if ctx.use_js_strings {
      for name in ctx.js_strings.names {
        write_name(import_sec, "string_constants")
        write_name(import_sec, name)
        import_sec.push((3).to_byte())
        import_sec.push(ref_type)
        import_sec.push((0).to_byte())
      }
    }
    write_section(buf, 2, import_sec.data)
  }

  // function section
  let func_sec = ByteBuf::new()
  write_u32_leb(func_sec, funcs.length())
  for idx in func_type_indices {
    write_u32_leb(func_sec, idx)
  }
  write_section(buf, 3, func_sec.data)

  // table section (for function values + optional externref table)
  let funcref_slot_count = ctx.fn_table_order.length()
  let has_extern_table = ctx.need_extern_table && ctx.extern_table_next_slot > 0
  // Reserve table 0 for funcref when externref table is used,
  // so extern_table_index can stay stable at 1.
  let has_funcref_table = funcref_slot_count > 0 || has_extern_table
  let table_count = (if has_funcref_table { 1 } else { 0 }) +
    (if has_extern_table { 1 } else { 0 })
  if table_count > 0 {
    let table_sec = ByteBuf::new()
    write_u32_leb(table_sec, table_count)
    if has_funcref_table {
      // table 0: funcref
      table_sec.push((112).to_byte()) // funcref
      table_sec.push((0).to_byte()) // limits: min only
      write_u32_leb(table_sec, funcref_slot_count)
    }
    if has_extern_table {
      // table 1 (or 0 if no funcref table): externref
      table_sec.push((111).to_byte()) // externref
      table_sec.push((0).to_byte()) // limits: min only
      write_u32_leb(table_sec, ctx.extern_table_next_slot)
    }
    write_section(buf, 4, table_sec.data)
  }

  // memory section
  let mem_sec = ByteBuf::new()
  write_u32_leb(mem_sec, 1)
  mem_sec.push((0).to_byte())
  // Reserve enough linear memory for selfhost compile and bench loops.
  write_u32_leb(mem_sec, 1024)
  write_section(buf, 5, mem_sec.data)

  // tag section (section ID 13, placed between memory and global per spec)
  let tag_count = (if ctx.need_exceptions { 1 } else { 0 }) +
    (if ctx.need_stack_switching { 2 } else { 0 }) // await + sleep
  if tag_count > 0 {
    let tag_sec = ByteBuf::new()
    write_u32_leb(tag_sec, tag_count)
    if ctx.need_exceptions {
      tag_sec.push((0).to_byte()) // attribute: 0x00 = exception
      write_u32_leb(tag_sec, ctx.error_tag_type_index) // type index
    }
    if ctx.need_stack_switching {
      // await tag comes after error tag (if present)
      ctx.await_tag_index = if ctx.need_exceptions { 1 } else { 0 }
      tag_sec.push((0).to_byte()) // attribute: 0x00
      write_u32_leb(tag_sec, ctx.await_tag_type_index) // type index
      // sleep tag comes after await tag
      ctx.sleep_tag_index = ctx.await_tag_index + 1
      tag_sec.push((0).to_byte()) // attribute: 0x00
      write_u32_leb(tag_sec, ctx.await_tag_type_index) // same type as await
    }
    write_section(buf, 13, tag_sec.data)
  }

  // global section
  let coverage_count = ctx.coverage_points.length()
  let coverage_bytes = coverage_count * 4
  let exported_env_global_count = ctx.exported_fn_env_globals.length()
  let need_globals = ctx.use_heap_global ||
    ctx.need_stack_switching ||
    ctx.coverage_enabled ||
    ctx.need_fs ||
    ctx.need_socket ||
    exported_env_global_count > 0
  if need_globals {
    let global_sec = ByteBuf::new()
    let global_count = (if ctx.use_heap_global { 1 } else { 0 }) +
      (if ctx.need_stack_switching { 1 } else { 0 }) +
      (if ctx.coverage_enabled { 2 } else { 0 }) +
      (if ctx.need_fs { 1 } else { 0 }) +
      (if ctx.need_socket { 1 } else { 0 }) +
      exported_env_global_count
    write_u32_leb(global_sec, global_count)
    // Heap pointer global
    if ctx.use_heap_global {
      global_sec.push((127).to_byte()) // i32
      global_sec.push((1).to_byte()) // mutable
      let heap_start = align4(ctx.strings.next_offset + coverage_bytes)
      emit_i32_const_raw(global_sec, heap_start)
      global_sec.push((11).to_byte()) // end
    }
    // Async result global for stack switching
    if ctx.need_stack_switching {
      ctx.async_result_global_index = if ctx.use_heap_global { 1 } else { 0 }
      global_sec.push((126).to_byte()) // i64 (tagged value)
      global_sec.push((1).to_byte()) // mutable
      emit_i64_const_raw(global_sec, 0L) // initial value = 0
      global_sec.push((11).to_byte()) // end
    }
    if ctx.coverage_enabled {
      ctx.coverage_base_global_index = (if ctx.use_heap_global { 1 } else { 0 }) +
        (if ctx.need_stack_switching { 1 } else { 0 })
      ctx.coverage_count_global_index = ctx.coverage_base_global_index + 1
      // Coverage counter base offset (immutable)
      global_sec.push((127).to_byte()) // i32
      global_sec.push((0).to_byte()) // immutable
      emit_i32_const_raw(global_sec, ctx.coverage_base_offset)
      global_sec.push((11).to_byte()) // end
      // Coverage counter count (immutable)
      global_sec.push((127).to_byte()) // i32
      global_sec.push((0).to_byte()) // immutable
      emit_i32_const_raw(global_sec, coverage_count)
      global_sec.push((11).to_byte()) // end
    }
    if ctx.need_fs {
      // fs_root_descriptor global: i32, mutable, init = -1 (uninitialized)
      global_sec.push((127).to_byte()) // i32
      global_sec.push((1).to_byte()) // mutable
      emit_i32_const_raw(global_sec, -1)
      global_sec.push((11).to_byte()) // end
    }
    if ctx.need_socket {
      // socket_table_base global: i32, mutable, init = 0 (unallocated)
      global_sec.push((127).to_byte()) // i32
      global_sec.push((1).to_byte()) // mutable
      emit_i32_const_raw(global_sec, 0)
      global_sec.push((11).to_byte()) // end
    }
    // Exported function env globals: store closure env pointers for external calls
    if exported_env_global_count > 0 {
      let mut env_global_idx = (if ctx.use_heap_global { 1 } else { 0 }) +
        (if ctx.need_stack_switching { 1 } else { 0 }) +
        (if ctx.coverage_enabled { 2 } else { 0 }) +
        (if ctx.need_fs { 1 } else { 0 }) +
        (if ctx.need_socket { 1 } else { 0 })
      for name, _ in ctx.exported_fn_env_globals {
        // Mutable i32 global, initial value 0
        global_sec.push((127).to_byte()) // i32
        global_sec.push((1).to_byte()) // mutable
        emit_i32_const_raw(global_sec, 0)
        global_sec.push((11).to_byte()) // end
        ctx.exported_fn_env_globals[name] = env_global_idx
        env_global_idx = env_global_idx + 1
      }
    }
    write_section(buf, 6, global_sec.data)
  }

  // export section
  let user_export_count = ctx.exported_fns.length()
  let need_cabi_realloc_export = ctx.need_stdin_read_char ||
    ctx.need_socket ||
    ctx.need_http ||
    ctx.force_cabi_realloc
  let need_http_host_string_new_export = ctx.need_http && ctx.http_host_imports
  let export_count = 2 +
    user_export_count +
    (if need_cabi_realloc_export { 1 } else { 0 }) +
    (if need_http_host_string_new_export { 1 } else { 0 }) +
    (if ctx.need_exceptions { 1 } else { 0 }) +
    (if ctx.need_stack_switching { 3 } else { 0 }) + // await_tag + sleep_tag + global
    (if ctx.coverage_enabled { 2 } else { 0 }) +
    1 // __heap_ptr global
  let export_sec = ByteBuf::new()
  write_u32_leb(export_sec, export_count)
  write_name(export_sec, "run")
  export_sec.push((0).to_byte()) // func export
  let run_index = func_import_count + funcs.length() - 1
  write_u32_leb(export_sec, run_index)
  let helper_count_before_run = (if need_cabi_realloc_export { 1 } else { 0 }) +
    (if need_http_host_string_new_export { 1 } else { 0 })
  let helper_base_func_index = run_index - helper_count_before_run
  if need_cabi_realloc_export {
    write_name(export_sec, "cabi_realloc")
    export_sec.push((0).to_byte()) // func export
    write_u32_leb(export_sec, helper_base_func_index)
  }
  if need_http_host_string_new_export {
    write_name(export_sec, "vibe_http_host_string_new")
    export_sec.push((0).to_byte()) // func export
    let string_new_index = helper_base_func_index +
      (if need_cabi_realloc_export { 1 } else { 0 })
    write_u32_leb(export_sec, string_new_index)
  }
  write_name(export_sec, "memory")
  export_sec.push((2).to_byte()) // memory export
  write_u32_leb(export_sec, 0)
  // Export user functions (export let ...)
  for name, _ in ctx.exported_fns {
    match ctx.fn_indices.get(name) {
      Some(idx) => {
        write_name(export_sec, name)
        export_sec.push((0).to_byte()) // func export
        write_u32_leb(export_sec, func_import_count + idx)
      }
      None => ()
    }
  }
  if ctx.need_exceptions {
    write_name(export_sec, "error")
    export_sec.push((4).to_byte()) // tag export
    write_u32_leb(export_sec, 0) // tag index 0
  }
  if ctx.need_stack_switching {
    write_name(export_sec, "await")
    export_sec.push((4).to_byte()) // tag export
    write_u32_leb(export_sec, ctx.await_tag_index)
    // Export sleep tag for runtime to handle sleep operations
    write_name(export_sec, "sleep")
    export_sec.push((4).to_byte()) // tag export
    write_u32_leb(export_sec, ctx.sleep_tag_index)
    // Export async_result global for runtime to write resolved values
    write_name(export_sec, "async_result")
    export_sec.push((3).to_byte()) // global export
    write_u32_leb(export_sec, ctx.async_result_global_index)
  }
  if ctx.coverage_enabled {
    write_name(export_sec, "__vibe_cov_base")
    export_sec.push((3).to_byte()) // global export
    write_u32_leb(export_sec, ctx.coverage_base_global_index)
    write_name(export_sec, "__vibe_cov_count")
    export_sec.push((3).to_byte()) // global export
    write_u32_leb(export_sec, ctx.coverage_count_global_index)
  }
  // Export __heap_ptr global (global 0) for external memory management
  write_name(export_sec, "__heap_ptr")
  export_sec.push((3).to_byte()) // global export
  write_u32_leb(export_sec, 0)
  write_section(buf, 7, export_sec.data)

  // element section
  let need_elem = funcref_slot_count > 0 || ctx.need_stack_switching
  if need_elem {
    let elem_sec = ByteBuf::new()
    let elem_count = (if funcref_slot_count > 0 { 1 } else { 0 }) +
      (if ctx.need_stack_switching { 1 } else { 0 })
    write_u32_leb(elem_sec, elem_count)
    // Active element segment for indirect calls (table)
    if funcref_slot_count > 0 {
      elem_sec.push((0).to_byte())
      emit_i32_const_raw(elem_sec, 0)
      elem_sec.push((11).to_byte())
      write_u32_leb(elem_sec, funcref_slot_count)
      for func_idx in ctx.fn_table_order {
        write_u32_leb(elem_sec, func_import_count + func_idx)
      }
    }
    // Declarative element segment for stack switching (ref.func $run)
    if ctx.need_stack_switching {
      // element kind 3 = declarative, funcref
      elem_sec.push((3).to_byte()) // declarative
      elem_sec.push((0).to_byte()) // elemkind = funcref
      write_u32_leb(elem_sec, 1) // 1 function
      write_u32_leb(elem_sec, run_index) // run function index
    }
    write_section(buf, 9, elem_sec.data)
  }

  // code section
  let code_sec = ByteBuf::new()
  write_u32_leb(code_sec, funcs.length())
  for func in funcs {
    let func_body = ByteBuf::new()
    if func.locals.length() == 0 {
      write_u32_leb(func_body, 0)
    } else {
      let group_kinds : Array[ValueKind] = []
      let group_counts : Array[Int] = []
      for kind in func.locals {
        if group_kinds.length() == 0 ||
          group_kinds[group_kinds.length() - 1] != kind {
          group_kinds.push(kind)
          group_counts.push(1)
        } else {
          let last = group_counts.length() - 1
          group_counts[last] = group_counts[last] + 1
        }
      }
      write_u32_leb(func_body, group_kinds.length())
      for i in 0..<group_kinds.length() {
        write_u32_leb(func_body, group_counts[i])
        func_body.push(valtype_byte(group_kinds[i]))
      }
    }
    func_body.extend(func.body)
    write_u32_leb(code_sec, func_body.len())
    code_sec.extend(func_body.data)
  }
  write_section(buf, 10, code_sec.data)

  // data section
  let seg_count = ctx.strings.segments.length()
  if seg_count > 0 {
    let data_sec = ByteBuf::new()
    let use_packed = if seg_count > 1 {
      packed_data_content_len(ctx.strings) <
      segmented_data_content_len(ctx.strings)
    } else {
      false
    }
    if use_packed {
      let data = pack_string_segments(ctx.strings)
      write_u32_leb(data_sec, 1)
      data_sec.push((0).to_byte())
      emit_i32_const_raw(data_sec, 0)
      data_sec.push((11).to_byte())
      write_u32_leb(data_sec, data.length())
      data_sec.extend(data)
    } else {
      write_u32_leb(data_sec, seg_count)
      for seg in ctx.strings.segments {
        data_sec.push((0).to_byte())
        emit_i32_const_raw(data_sec, seg.offset)
        data_sec.push((11).to_byte())
        write_u32_leb(data_sec, seg.bytes.length())
        data_sec.extend(seg.bytes)
      }
    }
    write_section(buf, 11, data_sec.data)
  }
  // debug-only error map section: code -> original literal message.
  if ctx.embed_error_strings && ctx.error_codes.names.length() > 0 {
    write_custom_section(
      buf,
      "vibe.error_map",
      build_error_map_custom_content(ctx),
    )
  }
  buf.to_bytes()
}

///|
fn write_section(buf : ByteBuf, id : Int, content : Array[Byte]) -> Unit {
  buf.push(id.to_byte())
  write_u32_leb(buf, content.length())
  buf.extend(content)
}

///|
fn write_custom_section(
  buf : ByteBuf,
  name : String,
  content : Array[Byte],
) -> Unit {
  let sec = ByteBuf::new()
  write_name(sec, name)
  sec.extend(content)
  write_section(buf, 0, sec.data)
}

///|
fn build_error_map_custom_content(ctx : CodegenCtx) -> Array[Byte] {
  let out = ByteBuf::new()
  write_u32_leb(out, 1) // schema version
  let count = ctx.error_codes.names.length()
  write_u32_leb(out, count)
  for i in 0..<count {
    write_u32_leb(out, i + 1)
    write_name(out, ctx.error_codes.names[i])
  }
  out.data
}

///|
fn restore_locals(ctx : CodegenCtx, saved : Map[String, Int]) -> Unit {
  let to_remove : Array[String] = []
  for name, _ in ctx.locals {
    if not(saved.contains(name)) {
      to_remove.push(name)
    }
  }
  for name in to_remove {
    ctx.locals.remove(name)
  }
  for name, idx in saved {
    ctx.locals[name] = idx
  }
}

///|
fn restore_local_kinds(
  ctx : CodegenCtx,
  saved : Map[String, ValueKind],
) -> Unit {
  let to_remove : Array[String] = []
  for name, _ in ctx.local_kinds {
    if not(saved.contains(name)) {
      to_remove.push(name)
    }
  }
  for name in to_remove {
    ctx.local_kinds.remove(name)
  }
  for name, kind in saved {
    ctx.local_kinds[name] = kind
  }
}

///|
/// Recursively strip type-assertion identity blocks from an expression.
/// First tries unwrap_type_assert_block, then recurses into sub-expressions.
fn strip_type_assert_expr(expr : @core.Expr) -> @core.Expr {
  let expr = unwrap_type_assert_block(expr)
  match expr {
    @core.Expr::Block(body~, span~) =>
      @core.Expr::Block(body=strip_type_assert_module(body), span~)
    @core.Expr::Fn(
      type_params~,
      type_bounds~,
      params~,
      ret~,
      effects~,
      body~,
      span~
    ) =>
      @core.Expr::Fn(
        type_params~,
        type_bounds~,
        params~,
        ret~,
        effects~,
        body=strip_type_assert_module(body),
        span~,
      )
    @core.Expr::If(cond~, then_body~, else_body~, span~) =>
      @core.Expr::If(
        cond=strip_type_assert_expr(cond),
        then_body=strip_type_assert_module(then_body),
        else_body=strip_type_assert_module(else_body),
        span~,
      )
    @core.Expr::Match(scrutinee~, arms~, span~) => {
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        new_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond.map(strip_type_assert_expr),
          expr: strip_type_assert_expr(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Match(
        scrutinee=strip_type_assert_expr(scrutinee),
        arms=new_arms,
        span~,
      )
    }
    @core.Expr::Handle(body~, arms~, span~) => {
      let new_arms : Array[@core.MatchArm] = []
      for arm in arms {
        new_arms.push(@core.MatchArm::{
          pat: arm.pat,
          cond: arm.cond.map(strip_type_assert_expr),
          expr: strip_type_assert_expr(arm.expr),
          span: arm.span,
        })
      }
      @core.Expr::Handle(
        body=strip_type_assert_module(body),
        arms=new_arms,
        span~,
      )
    }
    @core.Expr::While(cond~, body~, span~) =>
      @core.Expr::While(
        cond=strip_type_assert_expr(cond),
        body=strip_type_assert_module(body),
        span~,
      )
    @core.Expr::Loop(params~, body~, span~) => {
      let new_params : Array[@core.LoopParam] = []
      for param in params {
        new_params.push(@core.LoopParam::{
          name: param.name,
          init: strip_type_assert_expr(param.init),
          span: param.span,
        })
      }
      @core.Expr::Loop(
        params=new_params,
        body=strip_type_assert_module(body),
        span~,
      )
    }
    @core.Expr::ForIn(value_name~, index_name~, iterable~, body~, span~) =>
      @core.Expr::ForIn(
        value_name~,
        index_name~,
        iterable=strip_type_assert_expr(iterable),
        body=strip_type_assert_module(body),
        span~,
      )
    @core.Expr::Call(name~, type_args~, args~, span~) => {
      let new_args : Array[@core.CallArg] = []
      for arg in args {
        new_args.push(@core.CallArg::{
          label: arg.label,
          expr: strip_type_assert_expr(arg.expr),
          span: arg.span,
        })
      }
      @core.Expr::Call(name~, type_args~, args=new_args, span~)
    }
    @core.Expr::Tuple(items~, span~) => {
      let new_items = items.map(strip_type_assert_expr)
      @core.Expr::Tuple(items=new_items, span~)
    }
    @core.Expr::Array(items~, span~) => {
      let new_items = items.map(strip_type_assert_expr)
      @core.Expr::Array(items=new_items, span~)
    }
    @core.Expr::Record(fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: strip_type_assert_expr(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Record(fields=new_fields, span~)
    }
    @core.Expr::Map(fields~, span~) => {
      let new_fields : Array[@core.MapFieldExpr] = []
      for field in fields {
        new_fields.push(@core.MapFieldExpr::{
          key: field.key,
          expr: strip_type_assert_expr(field.expr),
          span: field.span,
        })
      }
      @core.Expr::Map(fields=new_fields, span~)
    }
    @core.Expr::StructLit(name~, type_args~, fields~, span~) => {
      let new_fields : Array[@core.RecordFieldExpr] = []
      for field in fields {
        new_fields.push(@core.RecordFieldExpr::{
          name: field.name,
          expr: strip_type_assert_expr(field.expr),
          span: field.span,
        })
      }
      @core.Expr::StructLit(name~, type_args~, fields=new_fields, span~)
    }
    @core.Expr::TupleIndex(expr=inner, index~, span~) =>
      @core.Expr::TupleIndex(expr=strip_type_assert_expr(inner), index~, span~)
    @core.Expr::Raise(value~, span~) =>
      @core.Expr::Raise(value=strip_type_assert_expr(value), span~)
    @core.Expr::Break(value~, span~) =>
      @core.Expr::Break(value=value.map(strip_type_assert_expr), span~)
    @core.Expr::Continue(args~, span~) => {
      let new_args = args.map(strip_type_assert_expr)
      @core.Expr::Continue(args=new_args, span~)
    }
    @core.Expr::Yield(expr=inner, span~) =>
      @core.Expr::Yield(expr=strip_type_assert_expr(inner), span~)
    _ => expr
  }
}

///|
/// Strip type-assertion identity blocks from a statement.
fn strip_type_assert_stmt(stmt : @core.Stmt) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      @core.Stmt::Let(rec~, name~, expr=strip_type_assert_expr(expr), span~)
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      @core.Stmt::ExportLet(
        rec~,
        name~,
        expr=strip_type_assert_expr(expr),
        span~,
      )
    @core.Stmt::LetMut(name~, expr~, span~) =>
      @core.Stmt::LetMut(name~, expr=strip_type_assert_expr(expr), span~)
    @core.Stmt::Assign(name~, expr~, span~) =>
      @core.Stmt::Assign(name~, expr=strip_type_assert_expr(expr), span~)
    @core.Stmt::Expr(expr~, span~) =>
      @core.Stmt::Expr(expr=strip_type_assert_expr(expr), span~)
    @core.Stmt::LetPat(pat~, expr~, span~) =>
      @core.Stmt::LetPat(pat~, expr=strip_type_assert_expr(expr), span~)
    @core.Stmt::LetPatElse(pat~, expr~, else_body~, span~) =>
      @core.Stmt::LetPatElse(
        pat~,
        expr=strip_type_assert_expr(expr),
        else_body=strip_type_assert_module(else_body),
        span~,
      )
    @core.Stmt::IndexAssign(target~, index~, value~, span~) =>
      @core.Stmt::IndexAssign(
        target=strip_type_assert_expr(target),
        index=strip_type_assert_expr(index),
        value=strip_type_assert_expr(value),
        span~,
      )
    _ => stmt
  }
}

///|
/// Recursively strip type-assertion identity blocks from a module/block.
fn strip_type_assert_module(ast : @core.Module) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    stmts.push(strip_type_assert_stmt(stmt))
  }
  @core.Module::{ stmts, }
}

///|
/// Emit a WASM module for a typed vibe AST.
fn emit_module_with_coverage(
  ctx : CodegenCtx,
  ast : @core.Module,
) -> WasmCoverageArtifact raise WasmGenError {
  // Pre-process: strip type-assertion identity blocks so that
  // collect_func_defs doesn't create dead identity stub functions.
  let ast = strip_type_assert_module(ast)
  // Collect exported function names
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(rec=_, name~, expr~, span=_) =>
        match expr {
          @core.Expr::Fn(..) => ctx.exported_fns[name] = true
          _ => ()
        }
      _ => ()
    }
  }
  let funcs = collect_func_defs(ast)
  let top_funcs = collect_top_level_funcs(ast)
  let top_keys : Map[String, Bool] = {}
  for f in top_funcs {
    top_keys[f.span_key] = true
  }
  for i in 0..<funcs.length() {
    let f = funcs[i]
    ctx.fn_closure_indices[f.span_key] = i
    ctx.fn_closure_captures[f.span_key] = f.captures
    match f.name {
      Some(name) => ctx.fn_indices[name] = i
      None => ()
    }
  }
  let fn_needs_env = compute_fn_env_requirements(funcs)
  for i in 0..<funcs.length() {
    ctx.fn_needs_env[i] = fn_needs_env[i]
  }
  // Identify exported functions with captures — they need env globals
  for name, _ in ctx.exported_fns {
    match ctx.fn_indices.get(name) {
      Some(idx) =>
        if funcs[idx].captures.length() > 0 {
          ctx.exported_fn_env_globals[name] = -1 // placeholder, assigned in build_module
        }
      None => ()
    }
  }
  scan_needs(ctx, ast)
  // Assign actual global indices for exported fn env globals.
  // Must happen after scan_needs so ctx.use_heap_global etc. are known,
  // and before compile_function so the prelude can reference the globals.
  if ctx.exported_fn_env_globals.length() > 0 {
    let mut env_global_idx = (if ctx.use_heap_global { 1 } else { 0 }) +
      (if ctx.need_stack_switching { 1 } else { 0 }) +
      (if ctx.coverage_enabled { 2 } else { 0 }) +
      (if ctx.need_fs { 1 } else { 0 }) +
      (if ctx.need_socket { 1 } else { 0 })
    for name, _ in ctx.exported_fn_env_globals {
      ctx.exported_fn_env_globals[name] = env_global_idx
      env_global_idx = env_global_idx + 1
    }
  }
  scan_strings(ctx, ast)
  if ctx.coverage_enabled {
    ctx.coverage_base_offset = align4(ctx.strings.next_offset)
  } else {
    ctx.coverage_base_offset = 0
  }
  let func_param_kinds : Array[Array[ValueKind]] = []
  let func_return_kinds : Array[ValueKind] = []
  for i in 0..<funcs.length() {
    let f = funcs[i]
    let kinds = param_kinds(ctx, f.params)
    func_param_kinds.push(kinds)
    match f.name {
      Some(name) => {
        ctx.fn_params[name] = kinds
        // Save parameter names for labeled args resolution
        let names : Array[String] = []
        for p in f.params {
          names.push(p.name)
        }
        ctx.fn_param_names[name] = names
        if top_keys.contains(f.span_key) {
          let default_ret = match f.ret {
            Some(r) => value_kind_from_type(ctx, r)
            None => ValueKind::I32
          }
          ctx.fn_returns[name] = default_ret
          // Register return signature if function returns a function type
          match f.ret {
            Some(r) =>
              match func_sig_from_type(ctx, r) {
                Some(sig) => ctx.fn_return_sigs[name] = sig
                None => ()
              }
            None =>
              // Try to infer from body's last expression
              match infer_body_return_sig(ctx, f.body) {
                Some(sig) => ctx.fn_return_sigs[name] = sig
                None => ()
              }
          }
        }
      }
      None => ()
    }
  }
  for i in 0..<funcs.length() {
    let f = funcs[i]
    let ret_kind = if top_keys.contains(f.span_key) {
      infer_func_return_kind(ctx, f.params, func_param_kinds[i], f.ret, f.body) catch {
        e =>
          match f.name {
            Some(name) =>
              raise WasmGenError::Unsupported(
                "in function " + name + ": " + e.to_string(),
              )
            None => raise e
          }
      }
    } else {
      // Nested functions: use declared return type or default I32
      match f.ret {
        Some(r) => value_kind_from_type(ctx, r)
        None => ValueKind::I32
      }
    }
    func_return_kinds.push(ret_kind)
    if top_keys.contains(f.span_key) {
      match f.name {
        Some(name) => ctx.fn_returns[name] = ret_kind
        None => ()
      }
    }
  }
  // Multi-value return analysis: iterative fixed-point to detect functions
  // that always return tuple literals, including cross-function call chains.
  // Pass 1: identify functions eligible without cross-function Call support
  for i in 0..<funcs.length() {
    let f = funcs[i]
    match f.name {
      Some(name) =>
        match tuple_return_kinds(ctx, f.ret) {
          Some(kinds) =>
            if body_always_returns_tuple(f.body, kinds.length(), name) {
              ctx.fn_multivalue_results[name] = kinds
            }
          None => ()
        }
      None => ()
    }
  }
  // Iterative passes: keep finding new eligible functions until convergence
  for pass = 0; pass < 10; pass = pass + 1 {
    let eligible_arity : Map[String, Int] = {}
    for entry in ctx.fn_multivalue_results {
      eligible_arity[entry.0] = entry.1.length()
    }
    let mut added = 0
    for i in 0..<funcs.length() {
      let f = funcs[i]
      match f.name {
        Some(name) =>
          if not(ctx.fn_multivalue_results.contains(name)) {
            match tuple_return_kinds(ctx, f.ret) {
              Some(kinds) =>
                if body_always_returns_tuple(
                    f.body,
                    kinds.length(),
                    name,
                    eligible_fns=Some(eligible_arity),
                  ) {
                  ctx.fn_multivalue_results[name] = kinds
                  added = added + 1
                }
              None => ()
            }
          }
        None => ()
      }
    }
    if added == 0 {
      break
    }
  }
  ctx.fn_sig_type_indices = {}
  ctx.fn_sig_order = []
  ctx.fn_type_indices = {}
  for f in funcs {
    for param in f.params {
      match func_sig_from_type(ctx, param.ty) {
        Some(sig) => ignore(ensure_sig_index(ctx, sig))
        None => ()
      }
    }
  }
  for i in 0..<funcs.length() {
    let sig = match funcs[i].name {
      Some(name) =>
        match ctx.fn_multivalue_results.get(name) {
          Some(results) => func_sig_with_env_multi(func_param_kinds[i], results)
          None => func_sig_with_env(func_param_kinds[i], func_return_kinds[i])
        }
      None => func_sig_with_env(func_param_kinds[i], func_return_kinds[i])
    }
    let type_idx = ensure_sig_index(ctx, sig)
    ctx.fn_type_indices[funcs[i].span_key] = type_idx
  }
  let run_sig = FuncSig::{ params: [], results: [ValueKind::I64] }
  let _ = ensure_sig_index(ctx, run_sig)
  let run_ast = filter_top_level_funcs(ctx, ast)
  let func_needs_heap : Array[Bool] = []
  let mut any_user_heap = false
  for f in funcs {
    let need = needs_heap_block(ctx, f.body)
    if need {
      any_user_heap = true
    }
    func_needs_heap.push(need)
  }
  // Check if any function body has ref cell variables requiring heap
  for i in 0..<funcs.length() {
    let mcv = compute_mut_captured_for_block(
      funcs[i].body.stmts,
      ctx.fn_closure_captures,
    )
    if mcv.length() > 0 {
      func_needs_heap[i] = true
      any_user_heap = true
    }
  }
  let mut run_need_heap = needs_heap_block(ctx, run_ast)
  // Check if top-level scope has ref cell variables
  let top_mut_captured = compute_mut_captured_for_block(
    run_ast.stmts,
    ctx.fn_closure_captures,
  )
  if top_mut_captured.length() > 0 {
    run_need_heap = true
    any_user_heap = true
  }
  if any_user_heap ||
    ctx.need_stdin_read_char ||
    ctx.need_fs ||
    ctx.need_socket ||
    ctx.need_http ||
    ctx.force_cabi_realloc {
    ctx.use_heap_global = true
    let global_imports = if ctx.use_js_strings {
      ctx.js_strings.names.length()
    } else {
      0
    }
    ctx.heap_global = global_imports
  }
  // Pre-compute stack switching indices
  if ctx.need_stack_switching {
    ctx.async_result_global_index = if ctx.use_heap_global { 1 } else { 0 }
    // Pre-compute tag indices: await and sleep come after error tag (if present)
    ctx.await_tag_index = if ctx.need_exceptions { 1 } else { 0 }
    ctx.sleep_tag_index = ctx.await_tag_index + 1
  }
  // Pre-compute sleep import index (before function compilation)
  if ctx.need_sleep {
    let mut import_count = 0
    if ctx.need_js_length {
      import_count += 1
    }
    if ctx.need_js_char_code_at {
      import_count += 1
    }
    if ctx.need_js_substring {
      import_count += 1
    }
    if ctx.need_js_concat {
      import_count += 1
    }
    if ctx.need_js_equals {
      import_count += 1
    }
    if ctx.need_path {
      import_count += 1
    }
    if ctx.need_dynamic_path_resolve {
      import_count += 1
    }
    if ctx.need_sh {
      import_count += 1
    }
    ctx.sleep_import_index = import_count
  }
  // Pre-compute extern_table_index for externref captures.
  // Table 0 is reserved for funcref table when extern table exists.
  ctx.extern_table_index = 1
  // Pre-compute ref cell capture flags for ALL functions before compile loop.
  // This is needed because compile_function runs before compile_expr_fn.
  precompute_ref_cell_captures_block(ctx, ast.stmts, top_mut_captured)
  let compiled_funcs : Array[WasmFunc] = []
  for i in 0..<funcs.length() {
    let f = funcs[i]
    match f.name {
      Some(name) => {
        // Function names can collide across lexical scopes (e.g. multiple `go`).
        // Rebind the current function before compiling its body so recursive calls
        // resolve to the right signature/index.
        ctx.fn_indices[name] = i
        ctx.fn_params[name] = func_param_kinds[i]
        let param_names : Array[String] = []
        for p in f.params {
          param_names.push(p.name)
        }
        ctx.fn_param_names[name] = param_names
        ctx.fn_returns[name] = func_return_kinds[i]
      }
      None => ()
    }
    let cap_kinds = match ctx.fn_closure_capture_kinds.get(f.span_key) {
      Some(kinds) => kinds
      None => []
    }
    let cap_ref_cells = match
      ctx.fn_closure_capture_is_ref_cell.get(f.span_key) {
      Some(flags) => flags
      None => []
    }
    compiled_funcs.push(
      compile_function(
        ctx,
        f.name,
        f.params,
        func_param_kinds[i],
        func_return_kinds[i],
        f.body,
        func_needs_heap[i],
        f.captures,
        cap_kinds,
        true,
        capture_is_ref_cell=cap_ref_cells,
      ),
    )
  }
  if ctx.need_stdin_read_char ||
    ctx.need_socket ||
    ctx.need_http ||
    ctx.force_cabi_realloc {
    let cabi_realloc_sig = FuncSig::{
      params: [ValueKind::I32, ValueKind::I32, ValueKind::I32, ValueKind::I32],
      results: [ValueKind::I32],
    }
    let _ = ensure_sig_index(ctx, cabi_realloc_sig)
    compiled_funcs.push(compile_cabi_realloc_function(ctx))
  }
  if ctx.need_http && ctx.http_host_imports {
    let host_string_new_sig = FuncSig::{
      params: [ValueKind::I32],
      results: [ValueKind::I64],
    }
    let _ = ensure_sig_index(ctx, host_string_new_sig)
    compiled_funcs.push(compile_http_host_string_new_function(ctx))
  }
  // Set mut_captured_vars for the top-level run function
  ctx.mut_captured_vars = top_mut_captured
  compiled_funcs.push(
    compile_function(
      ctx,
      None,
      [],
      [],
      ValueKind::I64,
      run_ast,
      run_need_heap,
      [],
      [],
      false,
    ),
  )
  let bytes = build_module(ctx, compiled_funcs)
  {
    bytes,
    counter_base: ctx.coverage_base_offset,
    counter_count: ctx.coverage_points.length(),
    points: ctx.coverage_points,
  }
}

///|
fn emit_module(
  ctx : CodegenCtx,
  ast : @core.Module,
) -> Bytes raise WasmGenError {
  let artifact = emit_module_with_coverage(ctx, ast)
  artifact.bytes
}

///|
fn default_emit_options() -> WasmEmitOptions {
  wasm_emit_options()
}

///|
pub fn emit_module_wasm_with_options(
  ast : @core.Module,
  options : WasmEmitOptions,
) -> Bytes raise WasmGenError {
  let ctx = CodegenCtx::new(
    false,
    coverage_enabled=false,
    embed_error_strings=options.embed_error_strings,
    http_host_imports=options.http_host_imports,
    http_component_wasi_shim=options.http_component_wasi_shim,
    force_cabi_realloc=options.force_cabi_realloc,
  )
  emit_module(ctx, ast)
}

///|
pub fn emit_module_wasm(ast : @core.Module) -> Bytes raise WasmGenError {
  emit_module_wasm_with_options(ast, default_emit_options())
}

///|
pub fn emit_module_wasm_js_string_with_options(
  ast : @core.Module,
  options : WasmEmitOptions,
) -> Bytes raise WasmGenError {
  let _ = options
  let ctx = CodegenCtx::new(
    true,
    coverage_enabled=false,
    embed_error_strings=true,
  )
  emit_module(ctx, ast)
}

///|
pub fn emit_module_wasm_js_string(
  ast : @core.Module,
) -> Bytes raise WasmGenError {
  emit_module_wasm_js_string_with_options(ast, default_emit_options())
}

///|
pub fn emit_module_wasm_with_coverage_options(
  ast : @core.Module,
  options : WasmEmitOptions,
) -> WasmCoverageArtifact raise WasmGenError {
  let ctx = CodegenCtx::new(
    false,
    coverage_enabled=true,
    embed_error_strings=options.embed_error_strings,
    http_host_imports=options.http_host_imports,
    http_component_wasi_shim=options.http_component_wasi_shim,
  )
  emit_module_with_coverage(ctx, ast)
}

///|
pub fn emit_module_wasm_with_coverage(
  ast : @core.Module,
) -> WasmCoverageArtifact raise WasmGenError {
  emit_module_wasm_with_coverage_options(ast, default_emit_options())
}

///|
pub fn emit_module_wasm_js_string_with_coverage_options(
  ast : @core.Module,
  options : WasmEmitOptions,
) -> WasmCoverageArtifact raise WasmGenError {
  let _ = options
  let ctx = CodegenCtx::new(
    true,
    coverage_enabled=true,
    embed_error_strings=true,
  )
  emit_module_with_coverage(ctx, ast)
}

///|
pub fn emit_module_wasm_js_string_with_coverage(
  ast : @core.Module,
) -> WasmCoverageArtifact raise WasmGenError {
  emit_module_wasm_js_string_with_coverage_options(ast, default_emit_options())
}
