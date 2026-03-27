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
    "Http::request" => ("wasi:http/client@0.3.0-draft", "send")
    "Http::response_status" =>
      ("wasi:http/types@0.3.0-draft", "response-status")
    "Http::response_header" =>
      ("wasi:http/types@0.3.0-draft", "response-header")
    "Http::response_body" => ("wasi:http/types@0.3.0-draft", "response-body")
    "Http::close" => ("wasi:http/types@0.3.0-draft", "[drop]response")
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
fn write_fs_host_import(
  import_sec : ByteBuf,
  builtin_name : String,
  type_idx : Int,
) -> Unit {
  // Convert "Fs::read_file" -> "fs_read_file" for vibe module import name
  let func_name = fs_host_import_func_name(builtin_name)
  write_name(import_sec, "vibe")
  write_name(import_sec, func_name)
  import_sec.push((0).to_byte())
  write_u32_leb(import_sec, type_idx)
}

///|
fn fs_host_import_func_name(builtin_name : String) -> String {
  // "Fs::read_file" -> "fs_read_file"
  // "Fs::getcwd" -> "fs_getcwd"
  "fs_" + builtin_name[4:].to_string()
}

///|
fn exported_env_global_export_name(name : String) -> String {
  "__export_env_" + name
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
  let mut path_import_type = -1
  let mut dynamic_path_import_type = -1
  let mut env_args_len_type = -1
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
  let mut fs_host_arity0_type = -1
  let mut fs_host_arity1_type = -1
  let mut fs_host_arity2_type = -1
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
  if ctx.need_sh || ctx.need_path || ctx.need_env_get {
    path_import_type = type_count
    type_count += 1
  }
  if ctx.need_dynamic_path_resolve || ctx.need_env_args_get {
    dynamic_path_import_type = type_count
    type_count += 1
  }
  if ctx.need_env_args_len {
    env_args_len_type = type_count
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
  if ctx.need_fs && not(ctx.fs_host_imports) {
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
  if ctx.need_fs && ctx.fs_host_imports {
    // () -> i64
    fs_host_arity0_type = type_count
    type_count += 1
    // (i64) -> i64
    fs_host_arity1_type = type_count
    type_count += 1
    // (i64, i64) -> i64
    fs_host_arity2_type = type_count
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
  let linked_import_type_indices : Array[Int] = []
  for entry in ctx.linked_fn_imports_list {
    let (_, _, param_count, return_count) = entry
    let param_kinds : Array[ValueKind] = []
    for _ in 0..<param_count {
      param_kinds.push(ValueKind::I64)
    }
    let type_index = if return_count > 1 {
      let result_kinds : Array[ValueKind] = []
      for _ in 0..<return_count {
        result_kinds.push(ValueKind::I64)
      }
      ensure_sig_index(ctx, func_sig_with_env_multi(param_kinds, result_kinds))
    } else {
      ensure_sig_index(ctx, func_sig_with_env(param_kinds, ValueKind::I64))
    }
    linked_import_type_indices.push(type_index)
  }
  let exception_type_count = if ctx.need_exceptions { 1 } else { 0 }
  let stack_switching_type_count = if ctx.need_stack_switching { 3 } else { 0 }
  // Count unique effect op type signatures for type section
  let effect_arities_seen : Map[String, Bool] = {}
  for key, _ in ctx.effect_op_imports {
    if ctx.effect_handled_ops.contains(key) {
      continue
    }
    let arity = match ctx.effect_op_param_counts.get(key) {
      Some(n) => n
      None => 0
    }
    effect_arities_seen["P" + arity.to_string() + "R1"] = true
  }
  let effect_type_count = effect_arities_seen.length()
  let total_type_count = builtin_count +
    ctx.fn_sig_order.length() +
    exception_type_count +
    stack_switching_type_count +
    effect_type_count
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
  if ctx.need_sh || ctx.need_path || ctx.need_env_get {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((127).to_byte()) // i32 (raw string pointer)
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64 (tagged value)
  }
  if ctx.need_dynamic_path_resolve || ctx.need_env_args_get {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64 (tagged value)
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64 (tagged value)
  }
  if ctx.need_env_args_len {
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 0)
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
  if ctx.need_fs && not(ctx.fs_host_imports) {
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
  if ctx.need_fs && ctx.fs_host_imports {
    // fs_host_arity0_type: (func (result i64))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 0)
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64
    // fs_host_arity1_type: (func (param i64) (result i64))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64
    write_u32_leb(type_sec, 1)
    type_sec.push((126).to_byte()) // i64
    // fs_host_arity2_type: (func (param i64 i64) (result i64))
    type_sec.push((96).to_byte())
    write_u32_leb(type_sec, 2)
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
  // Collect effect op keys in stable order (used for both type and import sections)
  // Exclude user-defined effects that are handled by throw/catch (not imports)
  let effect_op_keys : Array[String] = []
  for key, _ in ctx.effect_op_imports {
    if not(ctx.effect_handled_ops.contains(key)) {
      effect_op_keys.push(key)
    }
  }
  // Effect operation types: (i64^N, i32) -> i64 for each unique param count
  // type_count at this point is builtin_count; add fn_sig + exception + stack_switching offset
  let effect_type_base = builtin_count +
    ctx.fn_sig_order.length() +
    exception_type_count +
    stack_switching_type_count
  let mut effect_type_next = effect_type_base
  let effect_op_type_indices : Map[String, Int] = {}
  let effect_op_type_by_arity : Map[String, Int] = {}
  for key in effect_op_keys {
    let arity = match ctx.effect_op_param_counts.get(key) {
      Some(n) => n
      None => 0
    }
    let type_key = "P" + arity.to_string() + "R1"
    match effect_op_type_by_arity.get(type_key) {
      Some(idx) => effect_op_type_indices[key] = idx
      None => {
        let idx = effect_type_next
        effect_type_next += 1
        effect_op_type_by_arity[type_key] = idx
        effect_op_type_indices[key] = idx
        // Write: (func (param i64*arity i32) (result i64))
        type_sec.push((96).to_byte()) // func type
        write_u32_leb(type_sec, arity + 1) // params: N i64 + 1 i32 env
        for _ in 0..<arity {
          type_sec.push((126).to_byte()) // i64
        }
        type_sec.push((127).to_byte()) // i32 (closure env)
        write_u32_leb(type_sec, 1) // 1 result
        type_sec.push((126).to_byte()) // i64
      }
    }
  }
  write_section(buf, 1, type_sec.to_array())

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
  if ctx.need_env_get {
    func_import_count += 1
  }
  if ctx.need_env_args_len {
    func_import_count += 1
  }
  if ctx.need_env_args_get {
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
  if ctx.need_fs && not(ctx.fs_host_imports) {
    func_import_count += 7
  }
  if ctx.need_fs && ctx.fs_host_imports {
    // fs host imports: read_file, exists, stat_token, write_file, write_bytes,
    // readdir, getcwd, chdir, is_dir, is_file, mkdir, mkdir_p, remove, rename, copy, append,
    // open_write, write_chunk, close_write
    func_import_count += 19
    // json host imports: json_parse, json_stringify
    func_import_count += 2
  }
  if ctx.need_socket {
    func_import_count += 13
  }
  if ctx.need_http && ctx.http_host_imports {
    func_import_count += 12
  }
  // Effect operation imports: each operation becomes one import
  for key in effect_op_keys {
    ctx.effect_op_imports[key] = func_import_count
    func_import_count += 1
  }
  // Linked function imports: pre-compiled library functions
  for entry in ctx.linked_fn_imports_list {
    let (_, func_name, param_count, return_count) = entry
    ctx.linked_fn_imports[func_name] = func_import_count
    ctx.linked_fn_param_counts[func_name] = param_count
    ctx.linked_fn_return_counts[func_name] = return_count
    func_import_count += 1
  }
  // Linked mode: import memory and __heap_ptr from library module
  let has_linked_imports = ctx.linked_fn_imports_list.length() > 0
  let linked_memory_import = if has_linked_imports { 1 } else { 0 }
  let linked_global_import = if has_linked_imports && ctx.use_heap_global {
    1
  } else {
    0
  }
  let global_import_count = (if ctx.use_js_strings {
      ctx.js_strings.names.length()
    } else {
      0
    }) +
    linked_global_import
  let import_count = func_import_count +
    global_import_count +
    linked_memory_import
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
      write_u32_leb(import_sec, path_import_type)
    }
    if ctx.need_dynamic_path_resolve {
      write_name(import_sec, "vibe")
      write_name(import_sec, "resolve-path")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, dynamic_path_import_type)
    }
    if ctx.need_sh {
      write_name(import_sec, "vibe")
      write_name(import_sec, "sh")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, path_import_type)
    }
    if ctx.need_env_get {
      write_name(import_sec, "vibe")
      write_name(import_sec, "env-get")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, path_import_type)
    }
    if ctx.need_env_args_len {
      write_name(import_sec, "vibe")
      write_name(import_sec, "args-len")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, env_args_len_type)
    }
    if ctx.need_env_args_get {
      write_name(import_sec, "vibe")
      write_name(import_sec, "args-get")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, dynamic_path_import_type)
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
    if ctx.need_fs && not(ctx.fs_host_imports) {
      // 1. get-directories
      write_name(import_sec, "wasi:filesystem/preopens@0.2.6")
      write_name(import_sec, "get-directories")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_get_dirs_type)
      // 2. open-at
      write_name(import_sec, "wasi:filesystem/types@0.2.6")
      write_name(import_sec, "[method]descriptor.open-at")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_open_at_type)
      // 3. read
      write_name(import_sec, "wasi:filesystem/types@0.2.6")
      write_name(import_sec, "[method]descriptor.read")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_read_type)
      // 4. write
      write_name(import_sec, "wasi:filesystem/types@0.2.6")
      write_name(import_sec, "[method]descriptor.write")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_write_type)
      // 5. metadata-hash-at
      write_name(import_sec, "wasi:filesystem/types@0.2.6")
      write_name(import_sec, "[method]descriptor.metadata-hash-at")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_stat_at_type)
      // 6. stat-at
      write_name(import_sec, "wasi:filesystem/types@0.2.6")
      write_name(import_sec, "[method]descriptor.stat-at")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_stat_at_type)
      // 7. resource-drop descriptor
      write_name(import_sec, "wasi:filesystem/types@0.2.6")
      write_name(import_sec, "[resource-drop]descriptor")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_get_dirs_type)
    }
    if ctx.need_fs && ctx.fs_host_imports {
      // Fs host imports: all tagged i64 calling convention
      write_fs_host_import(import_sec, "Fs::read_file", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::exists", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::stat_token", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::write_file", fs_host_arity2_type)
      write_fs_host_import(import_sec, "Fs::write_bytes", fs_host_arity2_type)
      write_fs_host_import(import_sec, "Fs::readdir", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::getcwd", fs_host_arity0_type)
      write_fs_host_import(import_sec, "Fs::chdir", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::is_dir", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::is_file", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::mkdir", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::mkdir_p", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::remove", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::rename", fs_host_arity2_type)
      write_fs_host_import(import_sec, "Fs::copy", fs_host_arity2_type)
      write_fs_host_import(import_sec, "Fs::append", fs_host_arity2_type)
      write_fs_host_import(import_sec, "Fs::open_write", fs_host_arity1_type)
      write_fs_host_import(import_sec, "Fs::write_chunk", fs_host_arity2_type)
      write_fs_host_import(import_sec, "Fs::close_write", fs_host_arity1_type)
      // Json host imports (reuse fs_host_arity1_type: i64 -> i64)
      write_name(import_sec, "vibe")
      write_name(import_sec, "json_parse")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_host_arity1_type)
      write_name(import_sec, "vibe")
      write_name(import_sec, "json_stringify")
      import_sec.push((0).to_byte())
      write_u32_leb(import_sec, fs_host_arity1_type)
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
        import_sec, ctx, "Http::request", http_host_arity4_type,
      )
      // response handle APIs
      write_http_host_import(
        import_sec, ctx, "Http::response_status", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::response_header", http_host_arity2_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::response_body", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::close", http_host_arity1_type,
      )
      // server APIs
      write_http_host_import(
        import_sec, ctx, "Http::listen", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::accept", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::request_method", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::request_url", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::request_header", http_host_arity2_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::request_body", http_host_arity1_type,
      )
      write_http_host_import(
        import_sec, ctx, "Http::respond", http_host_arity4_type,
      )
    }
    // Effect operation imports
    for key in effect_op_keys {
      let mut sep = 0
      let mut found = false
      for i = 0; i + 1 < key.length(); i = i + 1 {
        if key[i] == ':' && key[i + 1] == ':' {
          sep = i
          found = true
          break
        }
      }
      if found {
        let mod_name = key[0:sep].to_string()
        let fn_name = key[sep + 2:key.length()].to_string()
        write_name(import_sec, mod_name)
        write_name(import_sec, fn_name)
        import_sec.push((0).to_byte()) // func import
        let type_idx = match effect_op_type_indices.get(key) {
          Some(idx) => idx
          None => 0
        }
        write_u32_leb(import_sec, type_idx)
      }
    }
    // Linked function imports
    let mut linked_primary_module = ""
    for i, entry in ctx.linked_fn_imports_list {
      let (mod_name, fn_name, _, _) = entry
      if linked_primary_module.length() == 0 {
        linked_primary_module = mod_name
      }
      write_name(import_sec, mod_name)
      write_name(import_sec, fn_name)
      import_sec.push((0).to_byte()) // func import
      write_u32_leb(import_sec, linked_import_type_indices[i])
    }
    // Linked memory import: import memory from primary library module
    if has_linked_imports {
      write_name(import_sec, linked_primary_module)
      write_name(import_sec, "memory")
      import_sec.push((2).to_byte()) // memory import
      import_sec.push((0).to_byte()) // limits: no max
      write_u32_leb(import_sec, 1) // initial 1 page (library will have more)
    }
    // TODO: funcref table import for linked builds with closures
    // Linked __heap_ptr global import
    if has_linked_imports && ctx.use_heap_global {
      write_name(import_sec, linked_primary_module)
      write_name(import_sec, "__heap_ptr")
      import_sec.push((3).to_byte()) // global import
      import_sec.push((127).to_byte()) // i32
      import_sec.push((1).to_byte()) // mutable
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
    write_section(buf, 2, import_sec.to_array())
  }

  // function section
  let func_sec = ByteBuf::new()
  write_u32_leb(func_sec, funcs.length())
  for idx in func_type_indices {
    write_u32_leb(func_sec, idx)
  }
  write_section(buf, 3, func_sec.to_array())

  // table section (for function values + optional externref table)
  let funcref_slot_count = ctx.fn_table_order.length()
  let has_extern_table = ctx.need_extern_table && ctx.extern_table_next_slot > 0
  // Reserve table 0 for funcref when externref table is used,
  // so extern_table_index can stay stable at 1.
  let has_funcref_table = funcref_slot_count > 0 ||
    has_extern_table ||
    ctx.need_funcref_table
  // TODO: In linked mode with closures, import funcref table from library
  let import_funcref_table = false // not yet implemented
  let table_count = (if has_funcref_table && not(import_funcref_table) {
      1
    } else {
      0
    }) +
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
    write_section(buf, 4, table_sec.to_array())
  }

  // memory section (skip when importing memory from linked library)
  if not(has_linked_imports) {
    let mem_sec = ByteBuf::new()
    write_u32_leb(mem_sec, 1)
    mem_sec.push((0).to_byte())
    // Reserve enough linear memory for selfhost compile and bench loops.
    write_u32_leb(mem_sec, 1024)
    write_section(buf, 5, mem_sec.to_array())
  }

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
    write_section(buf, 13, tag_sec.to_array())
  }

  // global section
  let coverage_count = ctx.coverage_points.length()
  let coverage_bytes = coverage_count * 4
  let exported_env_global_count = ctx.exported_fn_env_globals.length()
  let need_fs_global = ctx.need_fs && not(ctx.fs_host_imports)
  let need_globals = ctx.use_heap_global ||
    ctx.need_stack_switching ||
    ctx.need_effect_resume ||
    ctx.coverage_enabled ||
    need_fs_global ||
    ctx.need_socket ||
    ctx.enable_rc ||
    exported_env_global_count > 0
  // In linked mode, __heap_ptr is imported (not defined in global section)
  let heap_global_in_section = ctx.use_heap_global && not(has_linked_imports)
  if need_globals {
    let global_sec = ByteBuf::new()
    let global_count = (if heap_global_in_section { 1 } else { 0 }) +
      (if ctx.need_stack_switching { 1 } else { 0 }) +
      (if ctx.need_effect_resume { 3 } else { 0 }) +
      (if ctx.coverage_enabled { 2 } else { 0 }) +
      (if need_fs_global { 1 } else { 0 }) +
      (if ctx.need_socket { 1 } else { 0 }) +
      (if ctx.enable_rc { 1 } else { 0 }) +
      exported_env_global_count
    write_u32_leb(global_sec, global_count)
    // Heap pointer global (skip when imported from library)
    if heap_global_in_section {
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
    // Effect resume globals: idx, count, buf_ptr
    if ctx.need_effect_resume {
      let base_idx = (if ctx.use_heap_global { 1 } else { 0 }) +
        (if ctx.need_stack_switching { 1 } else { 0 })
      ctx.effect_resume_idx_global = base_idx
      ctx.effect_resume_count_global = base_idx + 1
      ctx.effect_resume_buf_global = base_idx + 2
      for i in 0..<3 {
        let _ = i
        global_sec.push((127).to_byte()) // i32
        global_sec.push((1).to_byte()) // mutable
        emit_i32_const_raw(global_sec, 0)
        global_sec.push((11).to_byte()) // end
      }
    }
    if ctx.coverage_enabled {
      ctx.coverage_base_global_index = (if ctx.use_heap_global { 1 } else { 0 }) +
        (if ctx.need_stack_switching { 1 } else { 0 }) +
        (if ctx.need_effect_resume { 3 } else { 0 })
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
    if need_fs_global {
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
    if ctx.enable_rc {
      // RC free-list head global: i32, mutable, init = 0 (empty list)
      ctx.rc_free_list_global = (if ctx.use_heap_global { 1 } else { 0 }) +
        (if ctx.need_stack_switching { 1 } else { 0 }) +
        (if ctx.need_effect_resume { 3 } else { 0 }) +
        (if ctx.coverage_enabled { 2 } else { 0 }) +
        (if need_fs_global { 1 } else { 0 }) +
        (if ctx.need_socket { 1 } else { 0 })
      global_sec.push((127).to_byte()) // i32
      global_sec.push((1).to_byte()) // mutable
      emit_i32_const_raw(global_sec, 0)
      global_sec.push((11).to_byte()) // end
    }
    // Exported function env globals: store closure env pointers for external calls
    if exported_env_global_count > 0 {
      let mut env_global_idx = (if ctx.use_heap_global { 1 } else { 0 }) +
        (if ctx.need_stack_switching { 1 } else { 0 }) +
        (if ctx.need_effect_resume { 3 } else { 0 }) +
        (if ctx.coverage_enabled { 2 } else { 0 }) +
        (if need_fs_global { 1 } else { 0 }) +
        (if ctx.need_socket { 1 } else { 0 }) +
        (if ctx.enable_rc { 1 } else { 0 })
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
    write_section(buf, 6, global_sec.to_array())
  }

  // export section
  let user_export_count = ctx.exported_fns.length() -
    (if ctx.exported_fns.contains("_start") { 1 } else { 0 })
  let need_cabi_realloc_export = ctx.need_stdin_read_char ||
    ctx.need_socket ||
    ctx.need_http ||
    need_fs_global ||
    ctx.force_cabi_realloc
  let need_http_host_string_new_export = ctx.need_http && ctx.http_host_imports
  let emit_start = not(ctx.library_mode)
  // Library mode: export funcref table for linked builds
  let export_funcref_table = ctx.library_mode && has_funcref_table
  let export_count = (if emit_start { 2 } else { 1 }) + // _start + memory, or just memory
    user_export_count +
    exported_env_global_count +
    (if need_cabi_realloc_export { 1 } else { 0 }) +
    (if need_http_host_string_new_export { 1 } else { 0 }) +
    (if ctx.need_exceptions { 1 } else { 0 }) +
    (if ctx.need_stack_switching { 3 } else { 0 }) + // await_tag + sleep_tag + global
    (if ctx.coverage_enabled { 2 } else { 0 }) +
    (if need_fs_global { 1 } else { 0 }) +
    (if ctx.use_heap_global { 1 } else { 0 }) + // __heap_ptr global
    (if export_funcref_table { 1 } else { 0 })
  let export_sec = ByteBuf::new()
  write_u32_leb(export_sec, export_count)
  let run_index = func_import_count + funcs.length() - 1
  if emit_start {
    write_name(export_sec, "_start")
    export_sec.push((0).to_byte()) // func export
    write_u32_leb(export_sec, run_index)
  }
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
  // Export funcref table for library mode
  if export_funcref_table {
    write_name(export_sec, "__funcref_table")
    export_sec.push((1).to_byte()) // table export
    write_u32_leb(export_sec, 0) // table index 0
  }
  // Export user functions (export let ...)
  // Skip "_start" here; handled above to avoid duplicate export.
  for name, _ in ctx.exported_fns {
    if name == "_start" {
      continue
    }
    match ctx.fn_indices.get(name) {
      Some(idx) => {
        write_name(export_sec, name)
        export_sec.push((0).to_byte()) // func export
        write_u32_leb(export_sec, func_import_count + idx)
      }
      None =>
        // Linked import alias: export the import directly
        match ctx.linked_fn_imports.get(name) {
          Some(import_idx) => {
            write_name(export_sec, name)
            export_sec.push((0).to_byte()) // func export
            write_u32_leb(export_sec, import_idx)
          }
          None => ()
        }
    }
  }
  if exported_env_global_count > 0 {
    for name, global_idx in ctx.exported_fn_env_globals {
      if global_idx >= 0 {
        write_name(export_sec, exported_env_global_export_name(name))
        export_sec.push((3).to_byte()) // global export
        write_u32_leb(export_sec, global_idx)
      }
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
  if ctx.use_heap_global {
    write_name(export_sec, "__heap_ptr")
    export_sec.push((3).to_byte()) // global export
    write_u32_leb(export_sec, 0)
  }
  if need_fs_global {
    write_name(export_sec, "__fs_root_descriptor")
    export_sec.push((3).to_byte()) // global export
    write_u32_leb(export_sec, fs_root_descriptor_global_index(ctx))
  }
  write_section(buf, 7, export_sec.to_array())

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
      for func_key in ctx.fn_table_order {
        write_u32_leb(
          elem_sec,
          decode_funcref_func_index(func_import_count, func_key),
        )
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
    write_section(buf, 9, elem_sec.to_array())
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
    code_sec.extend_buf(func_body)
  }
  write_section(buf, 10, code_sec.to_array())

  // data section
  let seg_count = ctx.strings.segments.length()
  if seg_count > 0 {
    let data_sec = ByteBuf::new()
    // In linked mode, ctx.strings.next_offset starts at 65536 (set before
    // scan_strings in emit_module_with_coverage), so seg.offset values are
    // already offset. No additional base needed.
    let use_packed = if seg_count > 1 {
      packed_data_content_len(ctx.strings) <
      segmented_data_content_len(ctx.strings)
    } else {
      false
    }
    if use_packed {
      let data = pack_string_segments(ctx.strings)
      // Use first segment's offset (already includes linked offset)
      let first_offset = if ctx.strings.segments.length() > 0 {
        ctx.strings.segments[0].offset
      } else {
        0
      }
      write_u32_leb(data_sec, 1)
      data_sec.push((0).to_byte())
      emit_i32_const_raw(data_sec, first_offset)
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
    write_section(buf, 11, data_sec.to_array())
  }
  // debug-only error map section: code -> original literal message.
  if ctx.embed_error_strings && ctx.error_codes.names.length() > 0 {
    write_custom_section(
      buf,
      "vibe.error_map",
      build_error_map_custom_content(ctx),
    )
  }
  // Effect manifest: list required capabilities for CLI pre-flight check.
  // Format: newline-separated capability names.
  {
    let caps : Array[String] = []
    if ctx.need_fs {
      caps.push("Fs")
    }
    if ctx.need_http && ctx.http_host_imports {
      caps.push("Http")
    }
    if ctx.need_socket {
      caps.push("Socket")
    }
    if ctx.need_sh {
      caps.push("Process")
    }
    if ctx.need_env_get || ctx.need_env_args_len || ctx.need_env_args_get {
      caps.push("Env")
    }
    if ctx.need_stdout_write_char {
      caps.push("Stdout")
    }
    if ctx.need_stdin_read_char {
      caps.push("Stdin")
    }
    if ctx.need_sleep {
      caps.push("Async")
    }
    for key, _ in ctx.effect_op_imports {
      if not(ctx.effect_handled_ops.contains(key)) {
        caps.push(key)
      }
    }
    if caps.length() > 0 {
      let manifest = ByteBuf::new()
      for cap in caps {
        for i = 0; i < cap.length(); i = i + 1 {
          manifest.push(cap[i].to_int().to_byte())
        }
        manifest.push((10).to_byte())
      }
      write_custom_section(buf, "vibe.capabilities", manifest.to_array())
    }
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
  write_section(buf, 0, sec.to_array())
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
  out.to_array()
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
priv struct StaticFoldNamedField {
  name : String
  value : StaticFoldValue
}

///|
priv enum StaticFoldValue {
  Int(value~ : Int64)
  Bool(value~ : Bool)
  String(value~ : String)
  Tuple(items~ : Array[StaticFoldValue])
  Array(items~ : Array[StaticFoldValue])
  Record(fields~ : Array[StaticFoldNamedField])
  Map(fields~ : Array[StaticFoldNamedField])
  Ctor(name~ : String, args~ : Array[StaticFoldValue])
}

///|
fn static_fold_clone_env(
  env : Map[String, StaticFoldValue],
) -> Map[String, StaticFoldValue] {
  let out : Map[String, StaticFoldValue] = {}
  for k, v in env {
    out[k] = v
  }
  out
}

///|
fn static_fold_clone_bindings(
  bindings : Map[String, StaticFoldValue],
) -> Map[String, StaticFoldValue] {
  let out : Map[String, StaticFoldValue] = {}
  for k, v in bindings {
    out[k] = v
  }
  out
}

///|
fn static_fold_value_eq(
  left : StaticFoldValue,
  right : StaticFoldValue,
) -> Bool {
  match (left, right) {
    (
      StaticFoldValue::Int(value=left_value),
      StaticFoldValue::Int(value=right_value),
    ) => left_value == right_value
    (
      StaticFoldValue::Bool(value=left_value),
      StaticFoldValue::Bool(value=right_value),
    ) => left_value == right_value
    (
      StaticFoldValue::String(value=left_value),
      StaticFoldValue::String(value=right_value),
    ) => left_value == right_value
    (
      StaticFoldValue::Tuple(items=left_items),
      StaticFoldValue::Tuple(items=right_items),
    )
    | (
      StaticFoldValue::Array(items=left_items),
      StaticFoldValue::Array(items=right_items),
    ) =>
      if left_items.length() != right_items.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<left_items.length() {
          if not(static_fold_value_eq(left_items[i], right_items[i])) {
            ok = false
          }
        }
        ok
      }
    (
      StaticFoldValue::Ctor(name=left_name, args=left_args),
      StaticFoldValue::Ctor(name=right_name, args=right_args),
    ) =>
      if left_name != right_name || left_args.length() != right_args.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<left_args.length() {
          if not(static_fold_value_eq(left_args[i], right_args[i])) {
            ok = false
          }
        }
        ok
      }
    (
      StaticFoldValue::Record(fields=left_fields),
      StaticFoldValue::Record(fields=right_fields),
    )
    | (
      StaticFoldValue::Map(fields=left_fields),
      StaticFoldValue::Map(fields=right_fields),
    ) =>
      if left_fields.length() != right_fields.length() {
        false
      } else {
        let mut ok = true
        for i in 0..<left_fields.length() {
          if left_fields[i].name != right_fields[i].name ||
            not(
              static_fold_value_eq(left_fields[i].value, right_fields[i].value),
            ) {
            ok = false
          }
        }
        ok
      }
    _ => false
  }
}

///|
fn static_fold_render_call_args(
  values : Array[StaticFoldValue],
  span : @core.Span,
) -> Array[@core.CallArg]? {
  let args : Array[@core.CallArg] = []
  for value in values {
    match static_fold_render_value(value, span) {
      Some(expr) => args.push(@core.CallArg::{ label: None, expr, span })
      None => return None
    }
  }
  Some(args)
}

///|
fn static_fold_render_record_fields(
  fields : Array[StaticFoldNamedField],
  span : @core.Span,
) -> Array[@core.RecordFieldExpr]? {
  let out : Array[@core.RecordFieldExpr] = []
  for field in fields {
    match static_fold_render_value(field.value, span) {
      Some(expr) =>
        out.push(@core.RecordFieldExpr::{ name: field.name, expr, span })
      None => return None
    }
  }
  Some(out)
}

///|
fn static_fold_render_map_fields(
  fields : Array[StaticFoldNamedField],
  span : @core.Span,
) -> Array[@core.MapFieldExpr]? {
  let out : Array[@core.MapFieldExpr] = []
  for field in fields {
    match static_fold_render_value(field.value, span) {
      Some(expr) =>
        out.push(@core.MapFieldExpr::{ key: field.name, expr, span })
      None => return None
    }
  }
  Some(out)
}

///|
fn static_fold_render_value(
  value : StaticFoldValue,
  span : @core.Span,
) -> @core.Expr? {
  match value {
    StaticFoldValue::Int(value~) => Some(@core.Expr::Int(value~, span~))
    StaticFoldValue::Bool(value~) => Some(@core.Expr::Bool(value~, span~))
    StaticFoldValue::String(value~) => Some(@core.Expr::String(value~, span~))
    StaticFoldValue::Tuple(items~) => {
      let exprs : Array[@core.Expr] = []
      for item in items {
        match static_fold_render_value(item, span) {
          Some(expr) => exprs.push(expr)
          None => return None
        }
      }
      Some(@core.Expr::Tuple(items=exprs, span~))
    }
    StaticFoldValue::Array(items~) => {
      let exprs : Array[@core.Expr] = []
      for item in items {
        match static_fold_render_value(item, span) {
          Some(expr) => exprs.push(expr)
          None => return None
        }
      }
      Some(@core.Expr::Array(items=exprs, span~))
    }
    StaticFoldValue::Record(fields~) =>
      match static_fold_render_record_fields(fields, span) {
        Some(rendered) => Some(@core.Expr::Record(fields=rendered, span~))
        None => None
      }
    StaticFoldValue::Map(fields~) =>
      match static_fold_render_map_fields(fields, span) {
        Some(rendered) => Some(@core.Expr::Map(fields=rendered, span~))
        None => None
      }
    StaticFoldValue::Ctor(name~, args~) =>
      if args.length() == 0 {
        Some(@core.Expr::Ident(name~, span~))
      } else {
        match static_fold_render_call_args(args, span) {
          Some(rendered_args) =>
            Some(
              @core.Expr::Call(name~, type_args=[], args=rendered_args, span~),
            )
          None => None
        }
      }
    // No other variants to convert
  }
}

///|
fn static_fold_builtin_call(
  name : String,
  args : Array[StaticFoldValue],
) -> StaticFoldValue? {
  let normalized_name = match thin_prelude_builtin_target(name) {
    Some(target) => target
    None => name
  }
  match normalized_name {
    "__add" =>
      if args.length() == 2 {
        match (args[0], args[1]) {
          (StaticFoldValue::Int(value=left), StaticFoldValue::Int(value=right)) =>
            Some(StaticFoldValue::Int(value=left + right))
          _ => None
        }
      } else {
        None
      }
    "__sub" =>
      if args.length() == 2 {
        match (args[0], args[1]) {
          (StaticFoldValue::Int(value=left), StaticFoldValue::Int(value=right)) =>
            Some(StaticFoldValue::Int(value=left - right))
          _ => None
        }
      } else {
        None
      }
    "__mul" =>
      if args.length() == 2 {
        match (args[0], args[1]) {
          (StaticFoldValue::Int(value=left), StaticFoldValue::Int(value=right)) =>
            Some(StaticFoldValue::Int(value=left * right))
          _ => None
        }
      } else {
        None
      }
    "__div" =>
      if args.length() == 2 {
        match (args[0], args[1]) {
          (StaticFoldValue::Int(value=_), StaticFoldValue::Int(value=0L)) =>
            None
          (StaticFoldValue::Int(value=left), StaticFoldValue::Int(value=right)) =>
            Some(StaticFoldValue::Int(value=left / right))
          _ => None
        }
      } else {
        None
      }
    "__mod" =>
      if args.length() == 2 {
        match (args[0], args[1]) {
          (StaticFoldValue::Int(value=_), StaticFoldValue::Int(value=0L)) =>
            None
          (StaticFoldValue::Int(value=left), StaticFoldValue::Int(value=right)) =>
            Some(StaticFoldValue::Int(value=left % right))
          _ => None
        }
      } else {
        None
      }
    "__lt" =>
      if args.length() == 2 {
        match (args[0], args[1]) {
          (StaticFoldValue::Int(value=left), StaticFoldValue::Int(value=right)) =>
            Some(StaticFoldValue::Bool(value=left < right))
          _ => None
        }
      } else {
        None
      }
    "__eq" =>
      if args.length() == 2 {
        Some(
          StaticFoldValue::Bool(value=static_fold_value_eq(args[0], args[1])),
        )
      } else {
        None
      }
    "and" =>
      if args.length() == 2 {
        match (args[0], args[1]) {
          (StaticFoldValue::Bool(value=left), StaticFoldValue::Bool(value=right)
          ) => Some(StaticFoldValue::Bool(value=left && right))
          _ => None
        }
      } else {
        None
      }
    "or" =>
      if args.length() == 2 {
        match (args[0], args[1]) {
          (StaticFoldValue::Bool(value=left), StaticFoldValue::Bool(value=right)
          ) => Some(StaticFoldValue::Bool(value=left || right))
          _ => None
        }
      } else {
        None
      }
    "not" =>
      if args.length() == 1 {
        match args[0] {
          StaticFoldValue::Bool(value~) =>
            Some(StaticFoldValue::Bool(value=not(value)))
          _ => None
        }
      } else {
        None
      }
    _ => None
  }
}

///|
fn static_fold_match_pat(
  pat : @core.Pat,
  value : StaticFoldValue,
  bindings : Map[String, StaticFoldValue],
) -> Bool {
  match pat {
    @core.Pat::Wildcard(..) => true
    @core.Pat::Bind(name~, ..) => {
      bindings[name] = value
      true
    }
    @core.Pat::Int(value=pat_value, ..) =>
      match value {
        StaticFoldValue::Int(value=value_int) => pat_value == value_int
        _ => false
      }
    @core.Pat::Bool(value=pat_value, ..) =>
      match value {
        StaticFoldValue::Bool(value=value_bool) => pat_value == value_bool
        _ => false
      }
    @core.Pat::String(value=pat_value, ..) =>
      match value {
        StaticFoldValue::String(value=value_string) => pat_value == value_string
        _ => false
      }
    @core.Pat::Tuple(items~, ..) =>
      match value {
        StaticFoldValue::Tuple(items=value_items) =>
          if items.length() != value_items.length() {
            false
          } else {
            let mut ok = true
            for i in 0..<items.length() {
              if not(static_fold_match_pat(items[i], value_items[i], bindings)) {
                ok = false
              }
            }
            ok
          }
        _ => false
      }
    @core.Pat::Ctor(name~, args~, ..) =>
      match value {
        StaticFoldValue::Ctor(name=value_name, args=value_args) => {
          let pat_name = @core.strip_ctor_qualifier(name)
          if pat_name != value_name || args.length() != value_args.length() {
            false
          } else {
            let mut ok = true
            for i in 0..<args.length() {
              if not(static_fold_match_pat(args[i], value_args[i], bindings)) {
                ok = false
              }
            }
            ok
          }
        }
        _ => false
      }
    @core.Pat::Or(pats~, ..) => {
      for sub_pat in pats {
        let trial = static_fold_clone_bindings(bindings)
        if static_fold_match_pat(sub_pat, value, trial) {
          for name, bound_value in trial {
            bindings[name] = bound_value
          }
          return true
        }
      }
      false
    }
    @core.Pat::Record(fields~, ..) =>
      match value {
        StaticFoldValue::Record(fields=value_fields) => {
          let value_map : Map[String, StaticFoldValue] = {}
          for vf in value_fields {
            value_map[vf.name] = vf.value
          }
          let mut ok = true
          for pf in fields {
            match value_map.get(pf.name) {
              Some(vv) =>
                if not(static_fold_match_pat(pf.pat, vv, bindings)) {
                  ok = false
                }
              None => ok = false
            }
          }
          ok
        }
        _ => false
      }
    _ => false
  }
}

///|
fn static_fold_eval_block(
  body : @core.Module,
  env : Map[String, StaticFoldValue],
) -> StaticFoldValue? {
  let scope_env = static_fold_clone_env(env)
  let mut result : StaticFoldValue? = None
  for stmt in body.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..)
      | @core.Stmt::ExportLet(rec~, name~, expr~, ..) =>
        if rec {
          return None
        } else {
          match static_fold_eval_expr(expr, scope_env) {
            Some(value) => {
              scope_env[name] = value
              result = Some(value)
            }
            None => return None
          }
        }
      @core.Stmt::Expr(expr~, ..) =>
        match static_fold_eval_expr(expr, scope_env) {
          Some(value) => result = Some(value)
          None => return None
        }
      _ => return None
    }
  }
  result
}

///|
fn static_fold_eval_expr(
  expr : @core.Expr,
  env : Map[String, StaticFoldValue],
) -> StaticFoldValue? {
  match expr {
    @core.Expr::Int(value~, ..) => Some(StaticFoldValue::Int(value~))
    @core.Expr::Bool(value~, ..) => Some(StaticFoldValue::Bool(value~))
    @core.Expr::String(value~, ..) => Some(StaticFoldValue::String(value~))
    @core.Expr::Ident(name~, ..) =>
      match env.get(name) {
        Some(value) => Some(value)
        None =>
          if @core.is_ctor_name(name) {
            Some(
              StaticFoldValue::Ctor(name=@core.strip_ctor_qualifier(name), args=[]),
            )
          } else {
            None
          }
      }
    @core.Expr::Tuple(items~, ..) => {
      let values : Array[StaticFoldValue] = []
      for item in items {
        match static_fold_eval_expr(item, env) {
          Some(value) => values.push(value)
          None => return None
        }
      }
      Some(StaticFoldValue::Tuple(items=values))
    }
    @core.Expr::Array(items~, ..) => {
      let values : Array[StaticFoldValue] = []
      for item in items {
        match static_fold_eval_expr(item, env) {
          Some(value) => values.push(value)
          None => return None
        }
      }
      Some(StaticFoldValue::Array(items=values))
    }
    @core.Expr::Record(fields~, ..) => {
      let values : Array[StaticFoldNamedField] = []
      for field in fields {
        match static_fold_eval_expr(field.expr, env) {
          Some(value) =>
            values.push(StaticFoldNamedField::{ name: field.name, value })
          None => return None
        }
      }
      Some(StaticFoldValue::Record(fields=values))
    }
    @core.Expr::Map(fields~, ..) => {
      let values : Array[StaticFoldNamedField] = []
      for field in fields {
        match static_fold_eval_expr(field.expr, env) {
          Some(value) =>
            values.push(StaticFoldNamedField::{ name: field.key, value })
          None => return None
        }
      }
      Some(StaticFoldValue::Map(fields=values))
    }
    @core.Expr::Fn(..) => None
    @core.Expr::Block(body~, ..) => static_fold_eval_block(body, env)
    @core.Expr::If(cond~, then_body~, else_body~, ..) =>
      match static_fold_eval_expr(cond, env) {
        Some(StaticFoldValue::Bool(value~)) =>
          if value {
            static_fold_eval_block(then_body, env)
          } else {
            static_fold_eval_block(else_body, env)
          }
        _ => None
      }
    @core.Expr::Match(scrutinee~, arms~, ..) =>
      match static_fold_eval_expr(scrutinee, env) {
        Some(scrutinee_value) => {
          for arm in arms {
            let bindings : Map[String, StaticFoldValue] = {}
            if static_fold_match_pat(arm.pat, scrutinee_value, bindings) {
              let arm_env = static_fold_clone_env(env)
              for name, value in bindings {
                arm_env[name] = value
              }
              match arm.cond {
                Some(cond) =>
                  match static_fold_eval_expr(cond, arm_env) {
                    Some(StaticFoldValue::Bool(value=true)) =>
                      return static_fold_eval_expr(arm.expr, arm_env)
                    Some(StaticFoldValue::Bool(value=false)) => ()
                    _ => return None
                  }
                None => return static_fold_eval_expr(arm.expr, arm_env)
              }
            }
          }
          None
        }
        None => None
      }
    @core.Expr::Call(name~, type_args~, args~, ..) => {
      if type_args.length() > 0 {
        return None
      }
      let values : Array[StaticFoldValue] = []
      for arg in args {
        if arg.label is Some(_) {
          return None
        }
        match static_fold_eval_expr(arg.expr, env) {
          Some(value) => values.push(value)
          None => return None
        }
      }
      if @core.is_ctor_name(name) {
        Some(
          StaticFoldValue::Ctor(
            name=@core.strip_ctor_qualifier(name),
            args=values,
          ),
        )
      } else {
        match static_fold_builtin_call(name, values) {
          Some(value) => Some(value)
          None => None
        }
      }
    }
    _ => None
  }
}

///|
fn static_fold_stmt(
  stmt : @core.Stmt,
  env : Map[String, StaticFoldValue],
) -> @core.Stmt {
  match stmt {
    @core.Stmt::Let(rec~, name~, expr~, span~) =>
      match static_fold_eval_expr(expr, env) {
        Some(value) =>
          match static_fold_render_value(value, expr.span()) {
            Some(next_expr) =>
              @core.Stmt::Let(rec~, name~, expr=next_expr, span~)
            None => stmt
          }
        None => stmt
      }
    @core.Stmt::ExportLet(rec~, name~, expr~, span~) =>
      match static_fold_eval_expr(expr, env) {
        Some(value) =>
          match static_fold_render_value(value, expr.span()) {
            Some(next_expr) =>
              @core.Stmt::ExportLet(rec~, name~, expr=next_expr, span~)
            None => stmt
          }
        None => stmt
      }
    @core.Stmt::Expr(expr~, span~) =>
      match static_fold_eval_expr(expr, env) {
        Some(value) =>
          match static_fold_render_value(value, expr.span()) {
            Some(next_expr) => @core.Stmt::Expr(expr=next_expr, span~)
            None => stmt
          }
        None => stmt
      }
    _ => stmt
  }
}

///|
fn static_fold_stmt_binding_value(
  stmt : @core.Stmt,
  env : Map[String, StaticFoldValue],
) -> (String, StaticFoldValue)? {
  match stmt {
    @core.Stmt::Let(expr~, name~, ..)
    | @core.Stmt::ExportLet(expr~, name~, ..) =>
      match static_fold_eval_expr(expr, env) {
        Some(value) => Some((name, value))
        None => None
      }
    _ => None
  }
}

///|
fn static_fold_bind_local_names(
  bound : Map[String, Bool],
  names : Array[String],
) -> Map[String, Bool] {
  let next_bound : Map[String, Bool] = {}
  for name, _ in bound {
    next_bound[name] = true
  }
  for name in names {
    next_bound[name] = true
  }
  next_bound
}

///|
fn static_fold_collect_pat_names(pat : @core.Pat) -> Array[String] {
  let names : Array[String] = []
  collect_pat_bindings_codegen(pat, names)
  names
}

///|
fn static_fold_count_ref_name(
  name : String,
  candidates : Map[String, Bool],
  counts : Map[String, Int],
  bound : Map[String, Bool],
) -> Unit {
  if bound.contains(name) || not(candidates.contains(name)) {
    return
  }
  match counts.get(name) {
    Some(value) => counts[name] = value + 1
    None => counts[name] = 1
  }
}

///|
fn static_fold_count_refs_expr(
  expr : @core.Expr,
  candidates : Map[String, Bool],
  counts : Map[String, Int],
  bound : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Ident(name~, ..) =>
      static_fold_count_ref_name(name, candidates, counts, bound)
    @core.Expr::Call(name~, args~, ..) => {
      if not(@core.is_ctor_name(name)) {
        static_fold_count_ref_name(name, candidates, counts, bound)
      }
      for arg in args {
        static_fold_count_refs_expr(arg.expr, candidates, counts, bound)
      }
    }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for item in items {
        static_fold_count_refs_expr(item, candidates, counts, bound)
      }
    @core.Expr::TupleIndex(expr=inner, ..)
    | @core.Expr::Yield(expr=inner, ..)
    | @core.Expr::Spread(expr=inner, ..) =>
      static_fold_count_refs_expr(inner, candidates, counts, bound)
    @core.Expr::Record(fields~, ..) =>
      for field in fields {
        static_fold_count_refs_expr(field.expr, candidates, counts, bound)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        static_fold_count_refs_expr(field.expr, candidates, counts, bound)
      }
    @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        static_fold_count_refs_expr(field.expr, candidates, counts, bound)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      static_fold_count_refs_expr(cond, candidates, counts, bound)
      static_fold_count_refs_module_into(then_body, candidates, counts, bound)
      static_fold_count_refs_module_into(else_body, candidates, counts, bound)
    }
    @core.Expr::Block(body~, ..) | @core.Expr::Handle(body~, ..) =>
      static_fold_count_refs_module_into(body, candidates, counts, bound)
    @core.Expr::Fn(params~, body~, ..) => {
      let names : Array[String] = []
      for param in params {
        names.push(param.name)
      }
      static_fold_count_refs_module_into(
        body,
        candidates,
        counts,
        static_fold_bind_local_names(bound, names),
      )
    }
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      static_fold_count_refs_expr(scrutinee, candidates, counts, bound)
      for arm in arms {
        let arm_bound = static_fold_bind_local_names(
          bound,
          static_fold_collect_pat_names(arm.pat),
        )
        match arm.cond {
          Some(cond) =>
            static_fold_count_refs_expr(cond, candidates, counts, arm_bound)
          None => ()
        }
        static_fold_count_refs_expr(arm.expr, candidates, counts, arm_bound)
      }
    }
    @core.Expr::ForIn(iterable~, value_name~, index_name~, body~, ..) => {
      static_fold_count_refs_expr(iterable, candidates, counts, bound)
      let names : Array[String] = [value_name]
      match index_name {
        Some(name) => names.push(name)
        None => ()
      }
      static_fold_count_refs_module_into(
        body,
        candidates,
        counts,
        static_fold_bind_local_names(bound, names),
      )
    }
    @core.Expr::While(cond~, body~, ..) => {
      static_fold_count_refs_expr(cond, candidates, counts, bound)
      static_fold_count_refs_module_into(body, candidates, counts, bound)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      let names : Array[String] = []
      for param in params {
        static_fold_count_refs_expr(param.init, candidates, counts, bound)
        names.push(param.name)
      }
      static_fold_count_refs_module_into(
        body,
        candidates,
        counts,
        static_fold_bind_local_names(bound, names),
      )
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(inner) =>
          static_fold_count_refs_expr(inner, candidates, counts, bound)
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for arg in args {
        static_fold_count_refs_expr(arg, candidates, counts, bound)
      }
    @core.Expr::Perform(args~, ..) =>
      for arg in args {
        static_fold_count_refs_expr(arg.expr, candidates, counts, bound)
      }
    _ => ()
  }
}

///|
fn static_fold_count_refs_module(
  ast : @core.Module,
  candidates : Map[String, Bool],
) -> Map[String, Int] {
  let counts : Map[String, Int] = {}
  static_fold_count_refs_module_into(ast, candidates, counts, {})
  counts
}

///|
fn static_fold_count_refs_module_into(
  ast : @core.Module,
  candidates : Map[String, Bool],
  counts : Map[String, Int],
  bound : Map[String, Bool],
) -> Unit {
  let scope_bound : Map[String, Bool] = {}
  for name, _ in bound {
    scope_bound[name] = true
  }
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::Let(rec~, name~, expr~, ..)
      | @core.Stmt::ExportLet(rec~, name~, expr~, ..)
      | @core.Stmt::InternalExportLet(rec~, name~, expr~, ..) => {
        let expr_bound = if rec {
          static_fold_bind_local_names(scope_bound, [name])
        } else {
          scope_bound
        }
        static_fold_count_refs_expr(expr, candidates, counts, expr_bound)
      }
      @core.Stmt::LetMut(name~, expr~, ..) => {
        static_fold_count_refs_expr(expr, candidates, counts, scope_bound)
        scope_bound[name] = true
      }
      @core.Stmt::Assign(name~, expr~, ..) => {
        static_fold_count_ref_name(name, candidates, counts, scope_bound)
        static_fold_count_refs_expr(expr, candidates, counts, scope_bound)
      }
      @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
        static_fold_count_refs_expr(target, candidates, counts, scope_bound)
        static_fold_count_refs_expr(index, candidates, counts, scope_bound)
        static_fold_count_refs_expr(value, candidates, counts, scope_bound)
      }
      @core.Stmt::LetPat(pat~, expr~, ..) => {
        static_fold_count_refs_expr(expr, candidates, counts, scope_bound)
        for name in static_fold_collect_pat_names(pat) {
          scope_bound[name] = true
        }
      }
      @core.Stmt::LetPatElse(pat~, expr~, else_body~, ..) => {
        static_fold_count_refs_expr(expr, candidates, counts, scope_bound)
        static_fold_count_refs_module_into(
          else_body, candidates, counts, scope_bound,
        )
        for name in static_fold_collect_pat_names(pat) {
          scope_bound[name] = true
        }
      }
      @core.Stmt::Expr(expr~, ..) =>
        static_fold_count_refs_expr(expr, candidates, counts, scope_bound)
      @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
        static_fold_count_refs_module_into(
          body, candidates, counts, scope_bound,
        )
      _ => ()
    }
  }
}

///|
fn strip_unused_top_level_static_bindings(
  ast : @core.Module,
  candidates : Map[String, Bool],
) -> @core.Module {
  if candidates.length() == 0 {
    return ast
  }
  let mut current = ast
  let mut changed = true
  while changed {
    changed = false
    let counts = static_fold_count_refs_module(current, candidates)
    let stmts : Array[@core.Stmt] = []
    for stmt in current.stmts {
      match stmt {
        @core.Stmt::Let(name~, ..) =>
          if name != "run" &&
            candidates.contains(name) &&
            not(counts.contains(name)) {
            changed = true
          } else {
            stmts.push(stmt)
          }
        _ => stmts.push(stmt)
      }
    }
    current = @core.Module::{ stmts, }
  }
  current
}

///|
fn static_fold_module(ast : @core.Module) -> @core.Module {
  let env : Map[String, StaticFoldValue] = {}
  let candidates : Map[String, Bool] = {}
  let stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    let next_stmt = static_fold_stmt(stmt, env)
    stmts.push(next_stmt)
    match next_stmt {
      @core.Stmt::Let(rec=true, name~, expr=@core.Expr::Fn(..), ..) =>
        candidates[name] = true
      _ =>
        match static_fold_stmt_binding_value(next_stmt, env) {
          Some((name, value)) => {
            env[name] = value
            match next_stmt {
              @core.Stmt::Let(..) => candidates[name] = true
              _ => ()
            }
          }
          None => ()
        }
    }
  }
  strip_unused_top_level_static_bindings(@core.Module::{ stmts, }, candidates)
}

///|
fn thin_prelude_builtin_target(name : String) -> String? {
  match name {
    "add" => Some("__add")
    "sub" => Some("__sub")
    "mul" => Some("__mul")
    "div" => Some("__div")
    "eq" => Some("__eq")
    "lt" => Some("__lt")
    "assert" => Some("__assert")
    "assert_true" => Some("__assert")
    "assert_eq" => Some("__assert_eq")
    _ => None
  }
}

///|
fn is_thin_prelude_builtin_wrapper_expr(
  name : String,
  expr : @core.Expr,
) -> Bool {
  match thin_prelude_builtin_target(name) {
    Some(target) =>
      match expr {
        @core.Expr::Fn(params~, body~, ..) =>
          if body.stmts.length() != 1 {
            false
          } else {
            match body.stmts[0] {
              @core.Stmt::Expr(
                expr=@core.Expr::Call(name=call_name, args~, ..),
                ..
              ) =>
                if call_name != target || args.length() != params.length() {
                  false
                } else {
                  let mut ok = true
                  for i in 0..<params.length() {
                    match args[i].expr {
                      @core.Expr::Ident(name=arg_name, ..) =>
                        if arg_name != params[i].name {
                          ok = false
                        }
                      _ => ok = false
                    }
                  }
                  ok
                }
              _ => false
            }
          }
        _ => false
      }
    None => false
  }
}

///|
fn thin_prelude_builtin_wrapper_name(stmt : @core.Stmt) -> String? {
  match stmt {
    @core.Stmt::Let(rec=false, name~, expr~, ..) =>
      if is_thin_prelude_builtin_wrapper_expr(name, expr) {
        Some(name)
      } else {
        None
      }
    _ => None
  }
}

///|
fn collect_bare_ident_refs_expr(
  expr : @core.Expr,
  candidates : Map[String, Bool],
  found : Map[String, Bool],
) -> Unit {
  match expr {
    @core.Expr::Ident(name~, ..) =>
      if candidates.contains(name) {
        found[name] = true
      }
    @core.Expr::Call(args~, ..) =>
      for arg in args {
        collect_bare_ident_refs_expr(arg.expr, candidates, found)
      }
    @core.Expr::Tuple(items~, ..) | @core.Expr::Array(items~, ..) =>
      for item in items {
        collect_bare_ident_refs_expr(item, candidates, found)
      }
    @core.Expr::TupleIndex(expr=inner, ..)
    | @core.Expr::Yield(expr=inner, ..)
    | @core.Expr::Spread(expr=inner, ..) =>
      collect_bare_ident_refs_expr(inner, candidates, found)
    @core.Expr::Record(fields~, ..) =>
      for field in fields {
        collect_bare_ident_refs_expr(field.expr, candidates, found)
      }
    @core.Expr::Map(fields~, ..) =>
      for field in fields {
        collect_bare_ident_refs_expr(field.expr, candidates, found)
      }
    @core.Expr::StructLit(fields~, ..) =>
      for field in fields {
        collect_bare_ident_refs_expr(field.expr, candidates, found)
      }
    @core.Expr::If(cond~, then_body~, else_body~, ..) => {
      collect_bare_ident_refs_expr(cond, candidates, found)
      collect_bare_ident_refs_module(then_body, candidates, found)
      collect_bare_ident_refs_module(else_body, candidates, found)
    }
    @core.Expr::Block(body~, ..)
    | @core.Expr::Handle(body~, ..)
    | @core.Expr::Fn(body~, ..) =>
      collect_bare_ident_refs_module(body, candidates, found)
    @core.Expr::Match(scrutinee~, arms~, ..) => {
      collect_bare_ident_refs_expr(scrutinee, candidates, found)
      for arm in arms {
        match arm.cond {
          Some(cond) => collect_bare_ident_refs_expr(cond, candidates, found)
          None => ()
        }
        collect_bare_ident_refs_expr(arm.expr, candidates, found)
      }
    }
    @core.Expr::ForIn(iterable~, body~, ..) => {
      collect_bare_ident_refs_expr(iterable, candidates, found)
      collect_bare_ident_refs_module(body, candidates, found)
    }
    @core.Expr::While(cond~, body~, ..) => {
      collect_bare_ident_refs_expr(cond, candidates, found)
      collect_bare_ident_refs_module(body, candidates, found)
    }
    @core.Expr::Loop(params~, body~, ..) => {
      for param in params {
        collect_bare_ident_refs_expr(param.init, candidates, found)
      }
      collect_bare_ident_refs_module(body, candidates, found)
    }
    @core.Expr::Break(value~, ..) =>
      match value {
        Some(inner) => collect_bare_ident_refs_expr(inner, candidates, found)
        None => ()
      }
    @core.Expr::Continue(args~, ..) =>
      for arg in args {
        collect_bare_ident_refs_expr(arg, candidates, found)
      }
    @core.Expr::Perform(args~, ..) =>
      for arg in args {
        collect_bare_ident_refs_expr(arg.expr, candidates, found)
      }
    _ => ()
  }
}

///|
fn collect_bare_ident_refs_stmt(
  stmt : @core.Stmt,
  candidates : Map[String, Bool],
  found : Map[String, Bool],
) -> Unit {
  match stmt {
    @core.Stmt::Let(expr~, ..)
    | @core.Stmt::ExportLet(expr~, ..)
    | @core.Stmt::InternalExportLet(expr~, ..)
    | @core.Stmt::LetMut(expr~, ..)
    | @core.Stmt::Assign(expr~, ..)
    | @core.Stmt::Expr(expr~, ..)
    | @core.Stmt::LetPat(expr~, ..) =>
      collect_bare_ident_refs_expr(expr, candidates, found)
    @core.Stmt::LetPatElse(expr~, else_body~, ..) => {
      collect_bare_ident_refs_expr(expr, candidates, found)
      collect_bare_ident_refs_module(else_body, candidates, found)
    }
    @core.Stmt::IndexAssign(target~, index~, value~, ..) => {
      collect_bare_ident_refs_expr(target, candidates, found)
      collect_bare_ident_refs_expr(index, candidates, found)
      collect_bare_ident_refs_expr(value, candidates, found)
    }
    @core.Stmt::Test(body~, ..) | @core.Stmt::Bench(body~, ..) =>
      collect_bare_ident_refs_module(body, candidates, found)
    _ => ()
  }
}

///|
fn collect_bare_ident_refs_module(
  ast : @core.Module,
  candidates : Map[String, Bool],
  found : Map[String, Bool],
) -> Unit {
  for stmt in ast.stmts {
    collect_bare_ident_refs_stmt(stmt, candidates, found)
  }
}

///|
fn strip_unused_thin_prelude_builtin_wrappers(
  ast : @core.Module,
) -> @core.Module {
  let thin_wrappers : Map[String, Bool] = {}
  for stmt in ast.stmts {
    match thin_prelude_builtin_wrapper_name(stmt) {
      Some(name) => thin_wrappers[name] = true
      None => ()
    }
  }
  if thin_wrappers.length() == 0 {
    return ast
  }
  let bare_refs : Map[String, Bool] = {}
  collect_bare_ident_refs_module(ast, thin_wrappers, bare_refs)
  let stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    match thin_prelude_builtin_wrapper_name(stmt) {
      Some(name) => if bare_refs.contains(name) { stmts.push(stmt) }
      None => stmts.push(stmt)
    }
  }
  @core.Module::{ stmts, }
}

///|
fn ensure_run_ast_result(
  ast : @core.Module,
  exported_fns : Map[String, Bool],
) -> @core.Module {
  let stmts : Array[@core.Stmt] = []
  for stmt in ast.stmts {
    stmts.push(stmt)
  }
  let span = @core.Span::empty(0)
  // If user defined `export let run`, append a call to it so the
  // auto-generated top-level function returns run()'s result.
  if exported_fns.contains("run") {
    stmts.push(
      @core.Stmt::Expr(
        expr=@core.Expr::Call(name="run", type_args=[], args=[], span~),
        span~,
      ),
    )
  } else if stmts.length() == 0 {
    stmts.push(@core.Stmt::Expr(expr=@core.Expr::Int(value=0L, span~), span~))
  } else {
    match stmts[stmts.length() - 1] {
      @core.Stmt::Expr(..) => ()
      _ =>
        stmts.push(
          @core.Stmt::Expr(expr=@core.Expr::Int(value=0L, span~), span~),
        )
    }
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
  // Skip static folding when coverage is enabled to preserve counter globals.
  let ast = if ctx.coverage_enabled {
    strip_type_assert_module(ast)
  } else {
    strip_unused_thin_prelude_builtin_wrappers(
      static_fold_module(strip_type_assert_module(ast)),
    )
  }
  // Collect exported function names
  for stmt in ast.stmts {
    match stmt {
      @core.Stmt::ExportLet(rec=_, name~, expr~, span=_) =>
        match expr {
          @core.Expr::Fn(..) => ctx.exported_fns[name] = true
          // Alias: export let x = y — if y is a known function or linked import,
          // x should also be exported
          @core.Expr::Ident(..) => ctx.exported_fns[name] = true
          _ => ()
        }
      _ => ()
    }
  }
  // In library mode, bundled code converts ExportLet to plain Let.
  // Export all Let+Fn so linked callers can import them.
  if ctx.library_mode {
    for stmt in ast.stmts {
      match stmt {
        @core.Stmt::Let(name~, expr~, ..) =>
          match expr {
            @core.Expr::Fn(..) =>
              if not(ctx.exported_fns.contains(name)) {
                ctx.exported_fns[name] = true
              }
            _ => ()
          }
        _ => ()
      }
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
  // Named top-level functions with captures need a stable env pointer.
  // Exported functions use it for external calls, and non-exported top-level
  // functions use it when another closure captures them in merged modules.
  for i in 0..<funcs.length() {
    let f = funcs[i]
    match f.name {
      Some(name) =>
        if top_keys.contains(f.span_key) && f.captures.length() > 0 {
          ctx.exported_fn_env_globals[name] = -1
        }
      None => ()
    }
  }
  scan_needs(ctx, ast)
  // In linked mode, offset string data to avoid collision with library data.
  if ctx.linked_fn_imports_list.length() > 0 {
    ctx.strings.next_offset = 65536
  }
  scan_strings(ctx, ast)
  // Pre-compute linked import indices so compile_call_by_name can emit
  // correct call instructions. This mirrors the import count logic in
  // build_module but only for determining linked import func indices.
  if ctx.linked_fn_imports_list.length() > 0 {
    let mut pre_import_count = 0
    if ctx.need_js_length {
      pre_import_count += 1
    }
    if ctx.need_js_char_code_at {
      pre_import_count += 1
    }
    if ctx.need_js_substring {
      pre_import_count += 1
    }
    if ctx.need_js_concat {
      pre_import_count += 1
    }
    if ctx.need_js_equals {
      pre_import_count += 1
    }
    if ctx.need_path {
      pre_import_count += 1
    }
    if ctx.need_dynamic_path_resolve {
      pre_import_count += 1
    }
    if ctx.need_sh {
      pre_import_count += 1
    }
    if ctx.need_env_get {
      pre_import_count += 1
    }
    if ctx.need_env_args_len {
      pre_import_count += 1
    }
    if ctx.need_env_args_get {
      pre_import_count += 1
    }
    if ctx.need_sleep {
      pre_import_count += 1
    }
    if ctx.need_stdout_write_char {
      pre_import_count += 2
    }
    if ctx.need_stdin_read_char {
      pre_import_count += 2
    }
    if ctx.need_fs && not(ctx.fs_host_imports) {
      pre_import_count += 7
    }
    if ctx.need_fs && ctx.fs_host_imports {
      pre_import_count += 19
      // json host imports: json_parse, json_stringify
      pre_import_count += 2
    }
    if ctx.need_socket {
      pre_import_count += 13
    }
    if ctx.need_http && ctx.http_host_imports {
      pre_import_count += 12
    }
    // effect ops come before linked imports (exclude handled ops)
    pre_import_count += ctx.effect_op_imports.length() -
      ctx.effect_handled_ops.length()
    for entry in ctx.linked_fn_imports_list {
      let (_, func_name, param_count, return_count) = entry
      ctx.linked_fn_imports[func_name] = pre_import_count
      ctx.linked_fn_param_counts[func_name] = param_count
      ctx.linked_fn_return_counts[func_name] = return_count
      pre_import_count += 1
    }
  }
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
    let ret_kind = infer_func_return_kind(
      ctx,
      f.params,
      func_param_kinds[i],
      f.ret,
      f.body,
    ) catch {
      e =>
        match f.name {
          Some(name) =>
            raise WasmGenError::Unsupported(
              "in function " + name + ": " + e.to_string(),
            )
          None => raise e
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
  // Skip in linked build: inlined WASI deps may expose new multivalue-eligible
  // functions whose callers don't expect multi-value returns, causing stack
  // underflow at local_set after call sites.
  if ctx.linked_fn_imports_list.length() == 0 {
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
  } // end linked_fn_imports_list == 0 guard
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
  let run_ast = ensure_run_ast_result(
    filter_top_level_funcs(ctx, ast),
    ctx.exported_fns,
  )
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
  // S4: Populate per-function heap requirement for call-site sync elimination
  for i in 0..<funcs.length() {
    match funcs[i].name {
      Some(name) => ctx.fn_needs_heap[name] = func_needs_heap[i]
      None => ()
    }
  }
  // S8: Transitive propagation — if a function calls a heap-needing function,
  // it also needs heap (for pre/post call sync). Iterate until convergence.
  for _pass = 0; _pass < 10; _pass = _pass + 1 {
    let mut changed = false
    for i in 0..<funcs.length() {
      if not(func_needs_heap[i]) {
        if needs_heap_block(ctx, funcs[i].body) {
          func_needs_heap[i] = true
          any_user_heap = true
          changed = true
          match funcs[i].name {
            Some(name) => ctx.fn_needs_heap[name] = true
            None => ()
          }
        }
      }
    }
    if not(changed) {
      break
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
  // Linked library modules share their memory with dependents.
  // Even when they only expose static string data, the consumer needs
  // a stable heap_ptr export to reserve space after the library's segments.
  let require_library_heap_global = ctx.library_mode && not(ctx.use_js_strings)
  // In linked mode, always enable heap_global (library provides memory/heap_ptr)
  if require_library_heap_global ||
    any_user_heap ||
    ctx.linked_fn_imports_list.length() > 0 ||
    ctx.need_env_get ||
    ctx.need_env_args_get ||
    ctx.need_stdin_read_char ||
    ctx.need_fs ||
    ctx.need_socket ||
    ctx.need_http ||
    ctx.force_cabi_realloc ||
    ctx.enable_rc {
    ctx.use_heap_global = true
    // In linked mode, __heap_ptr is imported as the first global (index 0).
    // In non-linked mode, it's the first defined global (after js_string globals).
    let global_imports = if ctx.linked_fn_imports_list.length() > 0 {
      0 // __heap_ptr is imported global index 0
    } else if ctx.use_js_strings {
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
    if ctx.need_env_get {
      import_count += 1
    }
    if ctx.need_env_args_len {
      import_count += 1
    }
    if ctx.need_env_args_get {
      import_count += 1
    }
    ctx.sleep_import_index = import_count
  }
  // Assign actual global indices for exported fn env globals.
  // Must happen after global layout decisions (heap/async/fs/socket) settle,
  // and before compile_function so the generated code writes the final indices.
  if ctx.exported_fn_env_globals.length() > 0 {
    let mut env_global_idx = (if ctx.use_heap_global { 1 } else { 0 }) +
      (if ctx.need_stack_switching { 1 } else { 0 }) +
      (if ctx.coverage_enabled { 2 } else { 0 }) +
      (if ctx.need_fs && not(ctx.fs_host_imports) { 1 } else { 0 }) +
      (if ctx.need_socket { 1 } else { 0 })
    for name, _ in ctx.exported_fn_env_globals {
      ctx.exported_fn_env_globals[name] = env_global_idx
      env_global_idx = env_global_idx + 1
    }
  }
  // Pre-compute extern_table_index for externref captures.
  // Table 0 is reserved for funcref table when extern table exists.
  ctx.extern_table_index = 1
  // Assign effect operation import indices before compile loop.
  // func_import_count(ctx) already includes both effect ops and linked imports,
  // so subtract both to recover the base index where effect imports start.
  // Reuse the same key order as the import section to keep call indices aligned.
  {
    let effect_op_keys : Array[String] = []
    for key, _ in ctx.effect_op_imports {
      if not(ctx.effect_handled_ops.contains(key)) {
        effect_op_keys.push(key)
      }
    }
    let actual_effect_import_count = effect_op_keys.length()
    let base = func_import_count(ctx) -
      actual_effect_import_count -
      ctx.linked_fn_imports_list.length()
    for eidx, key in effect_op_keys {
      ctx.effect_op_imports[key] = base + eidx
    }
  }
  // Pre-compute effect resume global indices before compile loop
  if ctx.need_effect_resume {
    let base = (if ctx.use_heap_global { 1 } else { 0 }) +
      (if ctx.need_stack_switching { 1 } else { 0 })
    ctx.effect_resume_idx_global = base
    ctx.effect_resume_count_global = base + 1
    ctx.effect_resume_buf_global = base + 2
  }
  // Pre-compute RC free-list global index before compile loop.
  // This must match the global layout in build_module's global section.
  if ctx.enable_rc {
    ctx.rc_free_list_global = (if ctx.use_heap_global { 1 } else { 0 }) +
      (if ctx.need_stack_switching { 1 } else { 0 }) +
      (if ctx.need_effect_resume { 3 } else { 0 }) +
      (if ctx.coverage_enabled { 2 } else { 0 }) +
      (if ctx.need_fs && not(ctx.fs_host_imports) { 1 } else { 0 }) +
      (if ctx.need_socket { 1 } else { 0 })
  }
  // Pre-compute ref cell capture flags for ALL functions before compile loop.
  // This is needed because compile_function runs before compile_expr_fn.
  precompute_ref_cell_captures_block(ctx, ast.stmts, top_mut_captured)
  @profiler.profiler_enter("codegen/compile_functions")
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
    // Set up per-function RC actions if available
    let mut has_func_rc = false
    if ctx.enable_rc {
      match f.name {
        Some(name) =>
          match ctx.rc_func_actions.get(name) {
            Some(actions) => {
              let result = build_rc_action_maps(actions)
              ctx.rc_pre_actions = result.0
              ctx.rc_post_actions = result.1
              has_func_rc = true
            }
            None => ()
          }
        None => ()
      }
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
        emit_rc_stmt_actions=has_func_rc,
      ),
    )
  }
  if ctx.need_stdin_read_char ||
    ctx.need_socket ||
    ctx.need_http ||
    (ctx.need_fs && not(ctx.fs_host_imports)) ||
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
  // Restore top-level RC action maps (may have been overwritten by per-function actions)
  if ctx.enable_rc {
    let (pre, post) = build_rc_action_maps(
      ctx.rc_func_actions.get("_start").unwrap_or([]),
    )
    // Merge with the global rc_actions (from options.rc_actions)
    // Global actions are for backwards compat; _start func actions take precedence
    if pre.length() > 0 || post.length() > 0 {
      ctx.rc_pre_actions = pre
      ctx.rc_post_actions = post
    }
  }
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
      emit_rc_stmt_actions=ctx.enable_rc,
    ),
  )
  @profiler.profiler_leave()
  @profiler.profiler_enter("codegen/build_module")
  let bytes = build_module(ctx, compiled_funcs)
  @profiler.profiler_leave()
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
    fs_host_imports=options.fs_host_imports,
    force_cabi_realloc=options.force_cabi_realloc,
    library_mode=options.library_mode,
  )
  ctx.linked_fn_imports_list = options.linked_imports
  if options.enable_rc {
    ctx.enable_rc = true
    let (pre, post) = build_rc_action_maps(options.rc_actions)
    ctx.rc_pre_actions = pre
    ctx.rc_post_actions = post
    ctx.rc_func_actions = options.rc_func_actions
  }
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
    fs_host_imports=options.fs_host_imports,
  )
  emit_module_with_coverage(ctx, ast)
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
