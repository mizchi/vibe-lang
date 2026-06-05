///|
fn is_threads_stateful_builtin(name : String) -> Bool {
  match name {
    "Threads::channel_new"
    | "Threads::send"
    | "Threads::recv"
    | "Threads::spawn"
    | "Threads::wait" => true
    _ => false
  }
}

///|
fn emit_tagged_int_from_i32(buf : ByteBuf) -> Unit {
  emit_i64_extend_i32_u(buf)
  emit_i64_const_raw(buf, 2L)
  emit_i64_shl(buf)
}

///|
fn selected_threads_lowering(
  ctx : CodegenCtx,
  name : String,
) -> @threads.ThreadCompiledStatefulLowering raise WasmGenError {
  let backend = match @threads.thread_backend_from_id(ctx.thread_backend_id) {
    Some(backend) => backend
    None =>
      raise WasmGenError::Unsupported(
        name + ": unknown thread backend " + ctx.thread_backend_id,
      )
  }
  @threads.thread_backend_compiled_stateful_lowering(backend)
}

///|
fn require_linear_local_threads(
  ctx : CodegenCtx,
  name : String,
) -> Unit raise WasmGenError {
  let lowering = selected_threads_lowering(ctx, name)
  if lowering != @threads.ThreadCompiledStatefulLowering::LinearLocalStateful {
    raise WasmGenError::Unsupported(
      name +
      " requires compiled thread lowering linear-local; selected " +
      ctx.thread_backend_id +
      " has " +
      @threads.thread_compiled_stateful_lowering_id(lowering),
    )
  }
  if ctx.use_js_strings {
    raise WasmGenError::Unsupported(
      name + " linear-local lowering requires --wasm backend",
    )
  }
}

///|
fn require_shared_atomic_threads(
  ctx : CodegenCtx,
  name : String,
) -> Unit raise WasmGenError {
  let lowering = selected_threads_lowering(ctx, name)
  if lowering != @threads.ThreadCompiledStatefulLowering::SharedAtomicStateful {
    raise WasmGenError::Unsupported(
      name +
      " requires compiled thread lowering shared-atomic; selected " +
      ctx.thread_backend_id +
      " has " +
      @threads.thread_compiled_stateful_lowering_id(lowering),
    )
  }
  if ctx.use_js_strings {
    raise WasmGenError::Unsupported(
      name + " shared-atomic lowering requires --wasm backend",
    )
  }
}

///|
fn compile_threads_linear_local(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  require_linear_local_threads(ctx, name)
  match name {
    "Threads::channel_new" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::channel_new", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      require_heap(ctx)
      let channel_local = alloc_temp_local(ctx)
      emit_heap_alloc(ctx, buf, 16, channel_local)
      emit_local_get(buf, channel_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_store(buf, 0)
      emit_local_get(buf, channel_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_store(buf, 4)
      emit_local_get(buf, channel_local)
      emit_i64_const_raw(buf, tag_ptr64(ctx.strings.intern(""), tag_obj))
      emit_i64_store(buf, 8)
      emit_local_get(buf, channel_local)
      emit_tagged_int_from_i32(buf)
    }
    "Threads::send" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::send", 2,
      )
      let channel_local = alloc_temp_local(ctx)
      let message_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, channel_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, message_local)
      emit_local_get(buf, channel_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_store(buf, 4)
      emit_local_get(buf, channel_local)
      emit_local_get(buf, message_local)
      emit_i64_store(buf, 8)
      emit_i64_const_raw(buf, tag_bool_value64(true))
    }
    "Threads::recv" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::recv", 1,
      )
      let channel_local = alloc_temp_local(ctx)
      let message_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, channel_local)
      emit_local_get(buf, channel_local)
      emit_i32_load(buf, 4)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      emit_string_const(ctx, buf, "")
      emit_else(buf)
      emit_local_get(buf, channel_local)
      emit_i64_load(buf, 8)
      emit_local_set(buf, message_local)
      emit_local_get(buf, channel_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_store(buf, 4)
      emit_local_get(buf, message_local)
      emit_end(buf)
    }
    "Threads::spawn" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::spawn", 2,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_drop(buf)
      emit_i64_const_tagged(buf, 1L)
    }
    "Threads::wait" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::wait", 1,
      )
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      emit_i64_const_tagged(buf, 0L)
    }
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}

///|
fn emit_shared_channel_cell_addr(
  buf : ByteBuf,
  channel_local : Int,
  index_local : Int,
) -> Unit {
  let abi = @threads.shared_thread_channel_abi()
  emit_local_get(buf, channel_local)
  emit_i32_const_raw(buf, abi.size)
  emit_i32_add(buf)
  emit_local_get(buf, index_local)
  emit_i32_const_raw(buf, abi.cell_size)
  emit_i32_mul(buf)
  emit_i32_add(buf)
}

///|
fn emit_shared_channel_atomic_load_field(
  buf : ByteBuf,
  channel_local : Int,
  offset : Int,
) -> Unit {
  emit_local_get(buf, channel_local)
  emit_i32_atomic_load(buf, offset)
}

///|
fn emit_shared_channel_atomic_store_field_const(
  buf : ByteBuf,
  channel_local : Int,
  offset : Int,
  value : Int,
) -> Unit {
  emit_local_get(buf, channel_local)
  emit_i32_const_raw(buf, value)
  emit_i32_atomic_store(buf, offset)
}

///|
fn emit_shared_slot_atomic_load_field(
  buf : ByteBuf,
  slot_local : Int,
  offset : Int,
) -> Unit {
  emit_local_get(buf, slot_local)
  emit_i32_atomic_load(buf, offset)
}

///|
fn emit_shared_slot_atomic_store_field_const(
  buf : ByteBuf,
  slot_local : Int,
  offset : Int,
  value : Int,
) -> Unit {
  emit_local_get(buf, slot_local)
  emit_i32_const_raw(buf, value)
  emit_i32_atomic_store(buf, offset)
}

///|
fn thread_spawn_mode_code_from_expr(expr : @core.Expr) -> Int {
  match expr {
    @core.Expr::String(value="alloc-probe", ..) =>
      @threads.thread_task_mode_code(@threads.ThreadTaskMode::AllocProbe)
    _ => @threads.thread_task_mode_code(@threads.ThreadTaskMode::Normal)
  }
}

///|
fn thread_worker_is_noop_name(value : String) -> Bool {
  value == "alloc-probe" || value == "noop"
}

///|
fn register_thread_worker_func(ctx : CodegenCtx, func_idx : Int) -> Unit {
  for existing in ctx.thread_worker_func_indices {
    if existing == func_idx {
      return
    }
  }
  ctx.thread_worker_func_indices.push(func_idx)
}

///|
fn is_thread_worker_func(ctx : CodegenCtx, func_idx : Int) -> Bool {
  for existing in ctx.thread_worker_func_indices {
    if existing == func_idx {
      return true
    }
  }
  false
}

///|
fn register_thread_worker_func_name(ctx : CodegenCtx, value : String) -> Unit {
  if thread_worker_is_noop_name(value) {
    return
  }
  match ctx.fn_indices.get(value) {
    Some(func_idx) => register_thread_worker_func(ctx, func_idx)
    None => ()
  }
}

///|
fn thread_worker_is_int_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Int => true
    @core.Type::Named(name="Int", args=[]) => true
    _ => false
  }
}

///|
fn thread_worker_is_string_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::String => true
    @core.Type::Named(name="String", args=[]) => true
    _ => false
  }
}

///|
fn thread_worker_is_supported_channel_payload_type(ty : @core.Type) -> Bool {
  thread_worker_is_int_type(ty) || thread_worker_is_string_type(ty)
}

///|
fn thread_worker_is_array_int_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Array(elem) => thread_worker_is_int_type(elem)
    @core.Type::Named(name="Array", args=[elem]) => thread_worker_is_int_type(elem)
    _ => false
  }
}

///|
fn thread_worker_is_supported_channel_array_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Array(elem) => thread_worker_is_supported_channel_payload_type(elem)
    @core.Type::Named(name="Array", args=[elem]) =>
      thread_worker_is_supported_channel_payload_type(elem)
    _ => false
  }
}

///|
fn thread_worker_is_supported_channel_type(ty : @core.Type) -> Bool {
  match ty {
    @core.Type::Named(name="ThreadChannel", args=[payload]) =>
      thread_worker_is_supported_channel_payload_type(payload) ||
      thread_worker_is_supported_channel_array_type(payload)
    _ => false
  }
}

///|
fn thread_worker_has_supported_channel_param(
  ctx : CodegenCtx,
  value : String,
) -> Bool {
  match ctx.fn_param_types.get(value) {
    Some(types) =>
      types.length() == 1 && thread_worker_is_supported_channel_type(types[0])
    None => false
  }
}

///|
fn thread_worker_has_supported_return(ctx : CodegenCtx, value : String) -> Bool {
  match ctx.fn_return_types.get(value) {
    Some(ty) =>
      thread_worker_is_int_type(ty) ||
      thread_worker_is_string_type(ty) ||
      thread_worker_is_array_int_type(ty)
    None => true
  }
}

///|
fn thread_spawn_worker_func_code_from_expr(
  ctx : CodegenCtx,
  expr : @core.Expr,
) -> Int raise WasmGenError {
  match expr {
    @core.Expr::String(value~, ..) => {
      if thread_worker_is_noop_name(value) {
        return 0
      }
      match ctx.fn_indices.get(value) {
        Some(func_idx) => {
          if fn_index_needs_env(ctx, func_idx) {
            raise WasmGenError::Unsupported(
              "Threads::spawn worker requires capture-free top-level function: " +
              value,
            )
          }
          let params = match ctx.fn_params.get(value) {
            Some(kinds) => kinds
            None => []
          }
          let ret = match ctx.fn_returns.get(value) {
            Some(kind) => kind
            None => ValueKind::I64
          }
          if params.length() != 1 ||
            params[0] != ValueKind::I64 ||
            ret != ValueKind::I64 ||
            !thread_worker_has_supported_channel_param(ctx, value) ||
            !thread_worker_has_supported_return(ctx, value) {
            raise WasmGenError::Unsupported(
              "Threads::spawn worker currently supports ThreadChannel[Int|String|Array[Int]|Array[String]] -> Int|String|Array[Int] only: " +
              value,
            )
          }
          register_thread_worker_func(ctx, func_idx)
          func_idx + 1
        }
        None =>
          raise WasmGenError::Unsupported(
            "Threads::spawn worker function not found: " + value,
          )
      }
    }
    _ =>
      raise WasmGenError::Unsupported(
        "Threads::spawn worker name must be a string literal",
      )
  }
}

///|
fn emit_component_thread_alloc_probe(
  ctx : CodegenCtx,
  buf : ByteBuf,
  task_local : Int,
  i_local : Int,
  ptr_local : Int,
  checksum_local : Int,
) -> Unit {
  let slot = @threads.component_thread_slot_abi()
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, i_local)
  emit_i32_const_raw(buf, 0)
  emit_local_set(buf, checksum_local)
  emit_block(buf)
  emit_loop(buf)
  emit_local_get(buf, i_local)
  emit_i32_const_raw(buf, 512)
  emit_i32_ge_s(buf)
  emit_br_if(buf, 1)
  emit_i32_const_raw(buf, 0)
  emit_i32_const_raw(buf, 16)
  emit_i32_atomic_rmw_add(buf, shared_heap_cursor_offset(ctx))
  emit_local_set(buf, ptr_local)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, task_local)
  emit_i32_store(buf, 0)
  emit_local_get(buf, ptr_local)
  emit_local_get(buf, i_local)
  emit_i32_store(buf, 4)
  emit_local_get(buf, ptr_local)
  emit_i32_const_raw(buf, 0x54485244)
  emit_i32_store(buf, 8)
  emit_local_get(buf, checksum_local)
  emit_local_get(buf, ptr_local)
  emit_i32_add(buf)
  emit_local_set(buf, checksum_local)
  emit_local_get(buf, i_local)
  emit_i32_const_raw(buf, 1)
  emit_i32_add(buf)
  emit_local_set(buf, i_local)
  emit_br(buf, 0)
  emit_end(buf)
  emit_end(buf)
  emit_local_get(buf, task_local)
  emit_local_get(buf, checksum_local)
  emit_tagged_int_from_i32(buf)
  emit_i64_atomic_store(buf, slot.payload_offset)
}

///|
fn emit_component_thread_worker_dispatch(
  ctx : CodegenCtx,
  buf : ByteBuf,
  task_local : Int,
  worker_code_local : Int,
  worker_result_local : Int,
) -> Unit {
  let slot = @threads.component_thread_slot_abi()
  emit_local_get(buf, task_local)
  emit_i32_atomic_load(buf, slot.worker_func_offset)
  emit_local_set(buf, worker_code_local)
  for func_idx in ctx.thread_worker_func_indices {
    emit_local_get(buf, worker_code_local)
    emit_i32_const_raw(buf, func_idx + 1)
    emit_i32_eq(buf)
    emit_if(buf)
    emit_local_get(buf, task_local)
    emit_i32_atomic_load(buf, slot.input_offset)
    emit_tagged_int_from_i32(buf)
    emit_i32_const_raw(buf, 0)
    emit_call(buf, func_import_count(ctx) + func_idx)
    emit_local_set(buf, worker_result_local)
    emit_local_get(buf, task_local)
    emit_local_get(buf, worker_result_local)
    emit_i64_atomic_store(buf, slot.payload_offset)
    emit_end(buf)
  }
}

///|
fn compile_component_thread_start_trampoline_function(
  ctx : CodegenCtx,
) -> WasmFunc {
  let slot = @threads.component_thread_slot_abi()
  let body = ByteBuf::new()
  emit_local_get(body, 0)
  emit_i32_atomic_load(body, slot.mode_offset)
  emit_i32_const_raw(
    body,
    @threads.thread_task_mode_code(@threads.ThreadTaskMode::AllocProbe),
  )
  emit_i32_eq(body)
  emit_if(body)
  emit_component_thread_alloc_probe(ctx, body, 0, 1, 2, 3)
  emit_else(body)
  emit_component_thread_worker_dispatch(ctx, body, 0, 4, 5)
  emit_end(body)
  emit_shared_slot_atomic_store_field_const(
    body,
    0,
    slot.state_offset,
    @threads.thread_task_state_code(@threads.ThreadTaskState::Terminal),
  )
  emit_local_get(body, 0)
  emit_i32_const_raw(body, 1)
  emit_memory_atomic_notify(body, slot.state_offset)
  emit_drop(body)
  emit_end(body)
  WasmFunc::{
    params: [ValueKind::I32],
    locals: [
      ValueKind::I32,
      ValueKind::I32,
      ValueKind::I32,
      ValueKind::I32,
      ValueKind::I64,
    ],
    results: [],
    body: body.to_array(),
    shared: true,
  }
}

///|
fn compile_threads_shared_atomic(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
) -> Unit raise WasmGenError {
  require_shared_atomic_threads(ctx, name)
  let abi = @threads.shared_thread_channel_abi()
  match name {
    "Threads::channel_new" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::channel_new", 1,
      )
      let capacity_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      let channel_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, capacity_local)
      emit_local_get(buf, capacity_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_le_s(buf)
      emit_if(buf)
      emit_i32_const_raw(buf, 1)
      emit_local_set(buf, capacity_local)
      emit_end(buf)
      emit_local_get(buf, capacity_local)
      emit_i32_const_raw(buf, abi.cell_size)
      emit_i32_mul(buf)
      emit_i32_const_raw(buf, abi.size)
      emit_i32_add(buf)
      emit_local_set(buf, alloc_size_local)
      require_heap(ctx)
      emit_heap_alloc_local_aligned(ctx, buf, alloc_size_local, 8, channel_local)
      emit_shared_channel_atomic_store_field_const(
        buf,
        channel_local,
        abi.lock_offset,
        0,
      )
      emit_local_get(buf, channel_local)
      emit_local_get(buf, capacity_local)
      emit_i32_atomic_store(buf, abi.capacity_offset)
      emit_shared_channel_atomic_store_field_const(
        buf,
        channel_local,
        abi.length_offset,
        0,
      )
      emit_shared_channel_atomic_store_field_const(
        buf,
        channel_local,
        abi.head_offset,
        0,
      )
      emit_shared_channel_atomic_store_field_const(
        buf,
        channel_local,
        abi.tail_offset,
        0,
      )
      emit_shared_channel_atomic_store_field_const(
        buf,
        channel_local,
        abi.cells_offset,
        abi.size,
      )
      emit_shared_channel_atomic_store_field_const(
        buf,
        channel_local,
        abi.closed_offset,
        0,
      )
      emit_shared_channel_atomic_store_field_const(
        buf,
        channel_local,
        abi.send_epoch_offset,
        0,
      )
      emit_shared_channel_atomic_store_field_const(
        buf,
        channel_local,
        abi.recv_epoch_offset,
        0,
      )
      emit_local_get(buf, channel_local)
      emit_tagged_int_from_i32(buf)
    }
    "Threads::send" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::send", 2,
      )
      let channel_local = alloc_temp_local(ctx)
      let payload_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let tail_local = alloc_temp_local(ctx)
      let capacity_local = alloc_temp_local(ctx)
      let length_local = alloc_temp_local(ctx)
      let cell_addr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, channel_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, payload_local)
      emit_shared_channel_atomic_load_field(buf, channel_local, abi.tail_offset)
      emit_local_set(buf, tail_local)
      emit_shared_channel_atomic_load_field(
        buf,
        channel_local,
        abi.capacity_offset,
      )
      emit_local_set(buf, capacity_local)
      emit_shared_channel_cell_addr(buf, channel_local, tail_local)
      emit_local_set(buf, cell_addr_local)
      emit_local_get(buf, cell_addr_local)
      emit_local_get(buf, payload_local)
      emit_i64_atomic_store(buf, abi.cell_value_offset)
      emit_local_get(buf, tail_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_get(buf, capacity_local)
      emit_i32_rem_s(buf)
      emit_local_set(buf, tail_local)
      emit_local_get(buf, channel_local)
      emit_local_get(buf, tail_local)
      emit_i32_atomic_store(buf, abi.tail_offset)
      emit_shared_channel_atomic_load_field(
        buf,
        channel_local,
        abi.length_offset,
      )
      emit_local_set(buf, length_local)
      emit_local_get(buf, length_local)
      emit_local_get(buf, capacity_local)
      emit_i32_lt_u(buf)
      emit_if(buf)
      emit_local_get(buf, channel_local)
      emit_local_get(buf, length_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_i32_atomic_store(buf, abi.length_offset)
      emit_end(buf)
      emit_shared_channel_atomic_load_field(
        buf,
        channel_local,
        abi.send_epoch_offset,
      )
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, length_local)
      emit_local_get(buf, channel_local)
      emit_local_get(buf, length_local)
      emit_i32_atomic_store(buf, abi.send_epoch_offset)
      emit_i64_const_raw(buf, tag_bool_value64(true))
    }
    "Threads::recv" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::recv", 1,
      )
      let channel_local = alloc_temp_local(ctx)
      let head_local = alloc_temp_local(ctx)
      let capacity_local = alloc_temp_local(ctx)
      let length_local = alloc_temp_local(ctx)
      let payload_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      let cell_addr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, channel_local)
      emit_shared_channel_atomic_load_field(
        buf,
        channel_local,
        abi.length_offset,
      )
      emit_local_tee(buf, length_local)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      emit_string_const(ctx, buf, "")
      emit_else(buf)
      emit_shared_channel_atomic_load_field(buf, channel_local, abi.head_offset)
      emit_local_set(buf, head_local)
      emit_shared_channel_atomic_load_field(
        buf,
        channel_local,
        abi.capacity_offset,
      )
      emit_local_set(buf, capacity_local)
      emit_shared_channel_cell_addr(buf, channel_local, head_local)
      emit_local_set(buf, cell_addr_local)
      emit_local_get(buf, cell_addr_local)
      emit_i64_atomic_load(buf, abi.cell_value_offset)
      emit_local_set(buf, payload_local)
      emit_local_get(buf, head_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_get(buf, capacity_local)
      emit_i32_rem_s(buf)
      emit_local_set(buf, head_local)
      emit_local_get(buf, channel_local)
      emit_local_get(buf, head_local)
      emit_i32_atomic_store(buf, abi.head_offset)
      emit_local_get(buf, channel_local)
      emit_local_get(buf, length_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_sub(buf)
      emit_i32_atomic_store(buf, abi.length_offset)
      emit_shared_channel_atomic_load_field(
        buf,
        channel_local,
        abi.recv_epoch_offset,
      )
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, length_local)
      emit_local_get(buf, channel_local)
      emit_local_get(buf, length_local)
      emit_i32_atomic_store(buf, abi.recv_epoch_offset)
      emit_local_get(buf, payload_local)
      emit_end(buf)
    }
    "Threads::spawn" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::spawn", 2,
      )
      let slot = @threads.component_thread_slot_abi()
      let mode_code = thread_spawn_mode_code_from_expr(pos_args[0])
      let worker_func_code = thread_spawn_worker_func_code_from_expr(
        ctx,
        pos_args[0],
      )
      let task_local = alloc_temp_local(ctx)
      let channel_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_drop(buf)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_local_set(buf, channel_local)
      require_heap(ctx)
      emit_heap_alloc_aligned(ctx, buf, slot.stride, 8, task_local)
      emit_shared_slot_atomic_store_field_const(
        buf,
        task_local,
        slot.state_offset,
        @threads.thread_task_state_code(@threads.ThreadTaskState::Running),
      )
      emit_shared_slot_atomic_store_field_const(
        buf,
        task_local,
        slot.terminal_code_offset,
        @threads.thread_terminal_status_code(
          @threads.ThreadTerminalStatus::Completed,
        ),
      )
      emit_local_get(buf, task_local)
      emit_i64_const_raw(buf, 0L)
      emit_i64_atomic_store(buf, slot.payload_offset)
      emit_local_get(buf, task_local)
      emit_local_get(buf, channel_local)
      emit_i32_atomic_store(buf, slot.input_offset)
      emit_shared_slot_atomic_store_field_const(
        buf,
        task_local,
        slot.cancel_offset,
        0,
      )
      emit_shared_slot_atomic_store_field_const(
        buf,
        task_local,
        slot.mode_offset,
        mode_code,
      )
      emit_shared_slot_atomic_store_field_const(
        buf,
        task_local,
        slot.worker_func_offset,
        worker_func_code,
      )
      if ctx.thread_component_runtime_imports {
        if ctx.thread_spawn_indirect_import_index < 0 {
          raise WasmGenError::Unsupported(
            "Threads::spawn component runtime import index is not assigned",
          )
        }
        emit_i32_const_raw(buf, 0)
        emit_local_get(buf, task_local)
        buf.push((0x10).to_byte()) // call
        write_u32_leb(buf, ctx.thread_spawn_indirect_import_index)
        emit_drop(buf)
      } else {
        if mode_code ==
          @threads.thread_task_mode_code(@threads.ThreadTaskMode::AllocProbe) {
          let alloc_i_local = alloc_temp_local(ctx)
          let alloc_ptr_local = alloc_temp_local(ctx)
          let alloc_checksum_local = alloc_temp_local(ctx)
          emit_component_thread_alloc_probe(
            ctx, buf, task_local, alloc_i_local, alloc_ptr_local, alloc_checksum_local,
          )
        } else if worker_func_code > 0 {
          let worker_code_local = alloc_temp_local(ctx)
          let worker_result_local = alloc_temp_local_with_kind(
            ctx,
            ValueKind::I64,
          )
          emit_component_thread_worker_dispatch(
            ctx, buf, task_local, worker_code_local, worker_result_local,
          )
        }
        emit_shared_slot_atomic_store_field_const(
          buf,
          task_local,
          slot.state_offset,
          @threads.thread_task_state_code(@threads.ThreadTaskState::Terminal),
        )
        emit_local_get(buf, task_local)
        emit_i32_const_raw(buf, 1)
        emit_memory_atomic_notify(buf, slot.state_offset)
        emit_drop(buf)
      }
      emit_local_get(buf, task_local)
      emit_tagged_int_from_i32(buf)
    }
    "Threads::wait" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Threads::wait", 1,
      )
      let slot = @threads.component_thread_slot_abi()
      let task_local = alloc_temp_local(ctx)
      let state_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, task_local)
      emit_block(buf)
      emit_loop(buf)
      emit_shared_slot_atomic_load_field(buf, task_local, slot.state_offset)
      emit_local_tee(buf, state_local)
      emit_i32_const_raw(
        buf,
        @threads.thread_task_state_code(@threads.ThreadTaskState::Terminal),
      )
      emit_i32_eq(buf)
      emit_br_if(buf, 1)
      emit_local_get(buf, task_local)
      emit_local_get(buf, state_local)
      emit_i64_const_raw(buf, -1L)
      emit_memory_atomic_wait32(buf, slot.state_offset)
      emit_drop(buf)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      emit_local_get(buf, task_local)
      emit_i64_atomic_load(buf, slot.payload_offset)
    }
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}

///|
fn compile_builtin_threads(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Unit raise WasmGenError {
  if is_user_fn {
    raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
  if is_threads_stateful_builtin(name) {
    match selected_threads_lowering(ctx, name) {
      @threads.ThreadCompiledStatefulLowering::LinearLocalStateful =>
        compile_threads_linear_local(ctx, buf, name, args)
      @threads.ThreadCompiledStatefulLowering::SharedAtomicStateful =>
        compile_threads_shared_atomic(ctx, buf, name, args)
      @threads.ThreadCompiledStatefulLowering::NoCompiledStateful =>
        raise WasmGenError::Unsupported(
          name +
          " has no compiled thread lowering for backend " +
          ctx.thread_backend_id,
        )
    }
    return
  }
  raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
}
