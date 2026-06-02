///|
fn compile_builtin_io(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  is_user_fn : Bool,
) -> Unit raise WasmGenError {
  match name {
    "sh" => {
      let pos_args = extract_positional_exprs_with_arity(args, "sh", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_sh(ctx))
      emit_heap_post_call_sync(ctx, buf)
      emit_drop(buf)
      emit_i64_const_tagged(buf, 0L)
    }
    "path" => {
      let pos_args = extract_positional_exprs_with_arity(args, "path", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_path(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    "Env::get" if !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(args, "Env::get", 1)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_env_get(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    "Env::args_len" if !is_user_fn => {
      let _ = extract_positional_exprs_with_arity(args, "Env::args_len", 0)
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_env_args_len(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    "Env::args_get" if !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Env::args_get", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_env_args_get(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    "sleep" => {
      // sleep(ms) - call imported sleep function
      let pos_args = extract_positional_exprs_with_arity(args, "sleep", 1)
      // Compile the duration argument (tagged int)
      compile_expr_i32(ctx, buf, pos_args[0])
      // Call imported sleep function (host will untag: ms >> 2)
      buf.push((0x10).to_byte()) // call
      write_u32_leb(buf, ctx.sleep_import_index)
      // Return Unit (tagged 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    "Stdout::write_char" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Stdout::write_char", 1,
      )
      require_heap(ctx)
      let code_local = alloc_temp_local(ctx)
      let out_stream_local = alloc_temp_local(ctx)
      let scratch_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, code_local)
      emit_local_get(buf, ctx.heap_local)
      emit_local_set(buf, scratch_local)
      emit_local_get(buf, scratch_local)
      emit_local_get(buf, code_local)
      emit_i32_store8(buf, 0)
      emit_call(buf, import_index_stdout_get_stream(ctx))
      emit_local_set(buf, out_stream_local)
      emit_local_get(buf, out_stream_local)
      emit_local_get(buf, scratch_local)
      emit_i32_const_raw(buf, 1)
      emit_local_get(buf, scratch_local)
      emit_i32_const_raw(buf, 4)
      emit_i32_add(buf)
      emit_call(buf, import_index_stdout_write_stream(ctx))
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    "Stdout::write_stream" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Stdout::write_stream requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Stdout::write_stream", 1,
      )
      require_heap(ctx)
      let raw_local = alloc_temp_local(ctx)
      let len_local = alloc_temp_local(ctx)
      let out_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, raw_local)
      emit_local_get(buf, raw_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, len_local)
      emit_local_get(buf, len_local)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((5).to_byte()) // else
      emit_call(buf, import_index_stdout_get_stream(ctx))
      emit_local_set(buf, out_stream_local)
      emit_heap_alloc(ctx, buf, align4(8), ret_area_local)
      emit_local_get(buf, out_stream_local)
      emit_local_get(buf, raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf)
      emit_local_get(buf, len_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_stdout_write_stream(ctx))
      emit_i64_const_raw(buf, tag_int_value64(0L))
      buf.push((11).to_byte()) // end if
    }
    "Stdin::read_char" => {
      let _ = extract_positional_exprs_with_arity(args, "Stdin::read_char", 0)
      require_heap(ctx)
      let in_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let data_ptr_local = alloc_temp_local(ctx)
      let data_len_local = alloc_temp_local(ctx)
      emit_call(buf, import_index_stdin_get_stream(ctx))
      emit_local_set(buf, in_stream_local)
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // imported `blocking-read` may call cabi_realloc; sync local heap first.
      emit_heap_pre_call_sync(ctx, buf)
      emit_local_get(buf, in_stream_local)
      // i64.const 1 (len=1)
      buf.push((66).to_byte())
      buf.push((1).to_byte())
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_stdin_read_stream(ctx))
      // reload heap in case cabi_realloc bumped it.
      emit_heap_post_call_sync(ctx, buf)
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, data_ptr_local)
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, data_len_local)
      emit_local_get(buf, data_len_local)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      buf.push((5).to_byte()) // else
      emit_local_get(buf, data_ptr_local)
      emit_i32_load8_u(buf, 0)
      emit_i64_extend_i32_s(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      // tag_int = 0, i64.or is a no-op
      buf.push((11).to_byte()) // end if
      buf.push((5).to_byte()) // else
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      buf.push((11).to_byte()) // end if
    }
    "Stdin::read_stream" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Stdin::read_stream requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Stdin::read_stream", 1,
      )
      require_heap(ctx)
      let in_stream_local = alloc_temp_local(ctx)
      let req_len_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let data_ptr_local = alloc_temp_local(ctx)
      let data_len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let copy_i_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, req_len_local)
      emit_local_get(buf, req_len_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_lt_s(buf)
      buf.push((4).to_byte()) // if
      buf.push((64).to_byte()) // empty result
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, req_len_local)
      buf.push((11).to_byte()) // end if
      emit_call(buf, import_index_stdin_get_stream(ctx))
      emit_local_set(buf, in_stream_local)
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // imported `blocking-read` may call cabi_realloc; sync local heap first.
      emit_heap_pre_call_sync(ctx, buf)
      emit_local_get(buf, in_stream_local)
      emit_local_get(buf, req_len_local)
      // i64.extend_i32_u
      buf.push((173).to_byte())
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_stdin_read_stream(ctx))
      // reload heap in case cabi_realloc bumped it.
      emit_heap_post_call_sync(ctx, buf)
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, data_ptr_local)
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, data_len_local)
      emit_local_get(buf, data_len_local)
      emit_i32_const_raw(buf, 11) // align4(8 + len) == (len + 11) & -4
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, data_len_local)
      emit_i32_store(buf, 4)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, copy_i_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, copy_i_local)
      emit_local_get(buf, data_len_local)
      emit_i32_lt_s(buf)
      emit_i32_eqz(buf)
      emit_br_if(buf, 1)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_add(buf)
      emit_local_get(buf, data_ptr_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 0)
      emit_i32_store8(buf, 8)
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, copy_i_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
      buf.push((5).to_byte()) // else
      emit_heap_alloc(ctx, buf, align4(8), obj_local)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_store(buf, 4)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
      buf.push((11).to_byte()) // end if
    }
    "Fs::exists" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("Fs::exists requires --wasm backend")
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::exists", 1,
        )
        compile_expr(ctx, buf, pos_args[0])
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_host_exists(ctx))
        emit_heap_post_call_sync(ctx, buf)
      } else {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::exists", 1,
        )
        require_heap(ctx)
        let raw_local = alloc_temp_local(ctx)
        let len_local = alloc_temp_local(ctx)
        let ret_area_local = alloc_temp_local(ctx)
        let root_desc_local = alloc_temp_local(ctx)
        let fs_global = fs_root_descriptor_global_index(ctx)
        // Initialize root descriptor if needed
        emit_global_get(buf, fs_global)
        emit_i32_const_raw(buf, -1)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        emit_local_get(buf, ret_area_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_get_directories(ctx))
        emit_heap_post_call_sync(ctx, buf)
        // Load first descriptor from list: retptr[0]=list_ptr, retptr[4]=list_len
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 0)
        emit_i32_load(buf, 0) // first entry: descriptor handle at [list_ptr+0]
        emit_global_set(buf, fs_global)
        buf.push((11).to_byte()) // end if
        emit_global_get(buf, fs_global)
        emit_local_set(buf, root_desc_local)
        // Extract path string: raw_ptr, len
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, raw_local)
        emit_local_get(buf, raw_local)
        emit_i32_load(buf, 4) // len
        emit_local_set(buf, len_local)
        // Allocate retptr for stat-at result (needs ~96 bytes)
        emit_heap_alloc(ctx, buf, align4(96), ret_area_local)
        // Sync heap before WASI call
        emit_heap_pre_call_sync(ctx, buf)
        // stat-at(root_desc, 0, path_ptr, path_len, retptr)
        emit_local_get(buf, root_desc_local)
        emit_i32_const_raw(buf, 0) // path-flags: no symlink follow
        emit_local_get(buf, raw_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf) // path data ptr
        emit_local_get(buf, len_local)
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_fs_stat_at(ctx))
        // Reload heap after WASI call
        emit_heap_post_call_sync(ctx, buf)
        // Check discriminant: 0=ok (exists), 1=err (not exists)
        emit_local_get(buf, ret_area_local)
        emit_i32_load8_u(buf, 0)
        emit_i32_eqz(buf) // 0 means ok -> true
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_i64_const_raw(buf, tag_int_value64(1L)) // true
        buf.push((5).to_byte()) // else
        emit_i64_const_raw(buf, tag_int_value64(0L)) // false
        buf.push((11).to_byte()) // end if
      } // end else (WASI path)
    }
    "Fs::stat_token" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Fs::stat_token requires --wasm backend",
        )
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::stat_token", 1,
        )
        compile_expr(ctx, buf, pos_args[0])
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_host_stat_token(ctx))
        emit_heap_post_call_sync(ctx, buf)
      } else {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::stat_token", 1,
        )
        require_heap(ctx)
        let raw_local = alloc_temp_local(ctx)
        let len_local = alloc_temp_local(ctx)
        let ret_area_local = alloc_temp_local(ctx)
        let root_desc_local = alloc_temp_local(ctx)
        let fs_global = fs_root_descriptor_global_index(ctx)
        emit_global_get(buf, fs_global)
        emit_i32_const_raw(buf, -1)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        emit_local_get(buf, ret_area_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_get_directories(ctx))
        emit_heap_post_call_sync(ctx, buf)
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 0)
        emit_i32_load(buf, 0)
        emit_global_set(buf, fs_global)
        buf.push((11).to_byte()) // end if
        emit_global_get(buf, fs_global)
        emit_local_set(buf, root_desc_local)
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, raw_local)
        emit_local_get(buf, raw_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, len_local)
        emit_heap_alloc(ctx, buf, align4(24), ret_area_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_local_get(buf, root_desc_local)
        emit_i32_const_raw(buf, 0)
        emit_local_get(buf, raw_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf)
        emit_local_get(buf, len_local)
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_fs_metadata_hash_at(ctx))
        emit_heap_post_call_sync(ctx, buf)
        emit_local_get(buf, ret_area_local)
        emit_i32_load8_u(buf, 0)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if
        buf.push((126).to_byte()) // result i64
        emit_local_get(buf, ret_area_local)
        emit_i64_load(buf, 8)
        emit_local_get(buf, ret_area_local)
        emit_i64_load(buf, 16)
        emit_i64_xor(buf)
        emit_i64_const_raw(buf, 2305843009213693951L)
        emit_i64_and(buf)
        emit_i64_const_raw(buf, 2L)
        emit_i64_shl(buf)
        buf.push((5).to_byte()) // else
        emit_i64_const_raw(buf, tag_int_value64(0L))
        buf.push((11).to_byte()) // end if
      } // end else (WASI path)
    }
    "Fs::read_file" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported("Fs::read_file requires --wasm backend")
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::read_file", 1,
        )
        compile_expr(ctx, buf, pos_args[0])
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_host_read_file(ctx))
        emit_heap_post_call_sync(ctx, buf)
      } else {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::read_file", 1,
        )
        require_heap(ctx)
        let raw_local = alloc_temp_local(ctx)
        let len_local = alloc_temp_local(ctx)
        let ret_area_local = alloc_temp_local(ctx)
        let root_desc_local = alloc_temp_local(ctx)
        let opened_desc_local = alloc_temp_local(ctx)
        let data_ptr_local = alloc_temp_local(ctx)
        let data_len_local = alloc_temp_local(ctx)
        let obj_local = alloc_temp_local(ctx)
        let copy_i_local = alloc_temp_local(ctx)
        let alloc_size_local = alloc_temp_local(ctx)
        let fs_global = fs_root_descriptor_global_index(ctx)
        // Initialize root descriptor if needed
        emit_global_get(buf, fs_global)
        emit_i32_const_raw(buf, -1)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        emit_local_get(buf, ret_area_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_get_directories(ctx))
        emit_heap_post_call_sync(ctx, buf)
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 0)
        emit_i32_load(buf, 0)
        emit_global_set(buf, fs_global)
        buf.push((11).to_byte()) // end if
        emit_global_get(buf, fs_global)
        emit_local_set(buf, root_desc_local)
        // Extract path string
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, raw_local)
        emit_local_get(buf, raw_local)
        emit_i32_load(buf, 4) // len
        emit_local_set(buf, len_local)
        // Allocate retptr for open-at result
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        // Sync heap
        emit_heap_pre_call_sync(ctx, buf)
        // open-at(root_desc, 0, path_ptr, path_len, 0, 1, retptr)
        // open-flags=0 (none), desc-flags=1 (read)
        emit_local_get(buf, root_desc_local)
        emit_i32_const_raw(buf, 0) // path-flags
        emit_local_get(buf, raw_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf) // path data ptr
        emit_local_get(buf, len_local)
        emit_i32_const_raw(buf, 0) // open-flags: none
        emit_i32_const_raw(buf, 1) // desc-flags: read
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_fs_open_at(ctx))
        // Reload heap
        emit_heap_post_call_sync(ctx, buf)
        // Check open result: retptr[0] discriminant
        emit_local_get(buf, ret_area_local)
        emit_i32_load8_u(buf, 0)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (ok)
        buf.push((126).to_byte()) // result i64
        // opened_desc = retptr[4]
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, opened_desc_local)
        // Allocate retptr for read result
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        // Sync heap
        emit_heap_pre_call_sync(ctx, buf)
        // read(opened_desc, max_len=0x7FFFFFFF, offset=0, retptr)
        emit_local_get(buf, opened_desc_local)
        // i64.const 0x7FFFFFFF (max read length)
        buf.push((66).to_byte())
        write_i64_leb(buf, 0x7FFFFFFFL)
        // i64.const 0 (offset)
        buf.push((66).to_byte())
        buf.push((0).to_byte())
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_fs_read(ctx))
        // Reload heap
        emit_heap_post_call_sync(ctx, buf)
        // resource-drop opened descriptor
        emit_local_get(buf, opened_desc_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_resource_drop(ctx))
        emit_heap_post_call_sync(ctx, buf)
        // Check read result: retptr[0] discriminant
        emit_local_get(buf, ret_area_local)
        emit_i32_load8_u(buf, 0)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (ok)
        buf.push((126).to_byte()) // result i64
        // data_ptr = retptr[4], data_len = retptr[8]
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, data_ptr_local)
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 8)
        emit_local_set(buf, data_len_local)
        // Allocate vibe string: align4(8 + data_len)
        emit_local_get(buf, data_len_local)
        emit_i32_const_raw(buf, 11) // (len + 8 + 3) & ~3 == (len + 11) & -4
        emit_i32_add(buf)
        emit_i32_const_raw(buf, -4)
        emit_i32_and(buf)
        emit_local_set(buf, alloc_size_local)
        emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
        // Write string header
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_string) // tag = obj_string
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, data_len_local)
        emit_i32_store(buf, 4)
        // Copy bytes from data_ptr to obj+8
        emit_i32_const_raw(buf, 0)
        emit_local_set(buf, copy_i_local)
        emit_block(buf)
        emit_loop(buf)
        emit_local_get(buf, copy_i_local)
        emit_local_get(buf, data_len_local)
        emit_i32_lt_s(buf)
        emit_i32_eqz(buf)
        emit_br_if(buf, 1)
        emit_local_get(buf, obj_local)
        emit_local_get(buf, copy_i_local)
        emit_i32_add(buf)
        emit_local_get(buf, data_ptr_local)
        emit_local_get(buf, copy_i_local)
        emit_i32_add(buf)
        emit_i32_load8_u(buf, 0)
        emit_i32_store8(buf, 8)
        emit_local_get(buf, copy_i_local)
        emit_i32_const_raw(buf, 1)
        emit_i32_add(buf)
        emit_local_set(buf, copy_i_local)
        emit_br(buf, 0)
        emit_end(buf)
        emit_end(buf)
        // Return tagged string pointer
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        buf.push((5).to_byte()) // else (read error)
        // Return empty string on read error
        emit_heap_alloc(ctx, buf, align4(8), obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        buf.push((11).to_byte()) // end if (read)
        buf.push((5).to_byte()) // else (open error)
        // Return empty string on open error
        emit_heap_alloc(ctx, buf, align4(8), obj_local)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, obj_string)
        emit_i32_store(buf, 0)
        emit_local_get(buf, obj_local)
        emit_i32_const_raw(buf, 0)
        emit_i32_store(buf, 4)
        emit_local_get(buf, obj_local)
        emit_i64_extend_i32_u(buf)
        emit_i64_const_raw(buf, tag_obj.to_int64())
        emit_i64_or(buf)
        buf.push((11).to_byte()) // end if (open)
      } // end else (WASI path)
    }
    "Fs::write_file" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Fs::write_file requires --wasm backend",
        )
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::write_file", 2,
        )
        compile_expr(ctx, buf, pos_args[0])
        compile_expr(ctx, buf, pos_args[1])
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_host_write_file(ctx))
        emit_heap_post_call_sync(ctx, buf)
      } else {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::write_file", 2,
        )
        require_heap(ctx)
        let path_raw_local = alloc_temp_local(ctx)
        let path_len_local = alloc_temp_local(ctx)
        let content_raw_local = alloc_temp_local(ctx)
        let content_len_local = alloc_temp_local(ctx)
        let ret_area_local = alloc_temp_local(ctx)
        let root_desc_local = alloc_temp_local(ctx)
        let opened_desc_local = alloc_temp_local(ctx)
        let fs_global = fs_root_descriptor_global_index(ctx)
        // Initialize root descriptor if needed
        emit_global_get(buf, fs_global)
        emit_i32_const_raw(buf, -1)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        emit_local_get(buf, ret_area_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_get_directories(ctx))
        emit_heap_post_call_sync(ctx, buf)
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 0)
        emit_i32_load(buf, 0)
        emit_global_set(buf, fs_global)
        buf.push((11).to_byte()) // end if
        emit_global_get(buf, fs_global)
        emit_local_set(buf, root_desc_local)
        // Extract path string
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, path_raw_local)
        emit_local_get(buf, path_raw_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, path_len_local)
        // Extract content string
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, content_raw_local)
        emit_local_get(buf, content_raw_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, content_len_local)
        // Allocate retptr for open-at result
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        // Sync heap
        emit_heap_pre_call_sync(ctx, buf)
        // open-at(root_desc, 0, path_ptr, path_len, 5, 2, retptr)
        // open-flags=5 (create|truncate), desc-flags=2 (write)
        emit_local_get(buf, root_desc_local)
        emit_i32_const_raw(buf, 0) // path-flags
        emit_local_get(buf, path_raw_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf) // path data ptr
        emit_local_get(buf, path_len_local)
        emit_i32_const_raw(buf, 5) // open-flags: create(1) | truncate(4) = 5
        emit_i32_const_raw(buf, 2) // desc-flags: write(2)
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_fs_open_at(ctx))
        // Reload heap
        emit_heap_post_call_sync(ctx, buf)
        // Check open result
        emit_local_get(buf, ret_area_local)
        emit_i32_load8_u(buf, 0)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (ok)
        buf.push((126).to_byte()) // result i64
        // opened_desc = retptr[4]
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, opened_desc_local)
        // Allocate retptr for write result
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        // Sync heap
        emit_heap_pre_call_sync(ctx, buf)
        // write(opened_desc, content_data_ptr, content_len, offset=0, retptr)
        emit_local_get(buf, opened_desc_local)
        emit_local_get(buf, content_raw_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf) // content data ptr
        emit_local_get(buf, content_len_local)
        // i64.const 0 (offset)
        buf.push((66).to_byte())
        buf.push((0).to_byte())
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_fs_write(ctx))
        // Reload heap
        emit_heap_post_call_sync(ctx, buf)
        // resource-drop opened descriptor
        emit_local_get(buf, opened_desc_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_resource_drop(ctx))
        emit_heap_post_call_sync(ctx, buf)
        // Return Unit
        emit_i64_const_raw(buf, tag_int_value64(0L))
        buf.push((5).to_byte()) // else (open error)
        emit_i64_const_raw(buf, tag_int_value64(0L))
        buf.push((11).to_byte()) // end if
      } // end else (WASI path for Fs::write_file)
    }
    // Bytes::from_array / from_string / to_string / length / get migrated to
    // the shared builtin registry (registry_bytes.mbt / builtin_registry.mbt).
    "Int64Array::make" => {
      // Int64Array::make(len, default) -> buffer of `len` i64 cells, each
      // initialized to the tagged `default` value. Header [tag,len,cap,data].
      require_heap(ctx)
      let pos_args = extract_positional_exprs_with_arity(
        args, "Int64Array::make", 2,
      )
      let len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let data_local = alloc_temp_local(ctx)
      let data_size_local = alloc_temp_local(ctx)
      let i_local = alloc_temp_local(ctx)
      let default_local = alloc_temp_local_with_kind(ctx, ValueKind::I64)
      // len = untag(arg0)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, len_local)
      // default (tagged i64) stored verbatim
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_local_set(buf, default_local)
      // obj header alloc (16 bytes)
      emit_heap_alloc(ctx, buf, align4(16), obj_local)
      // data_size = len * 8
      emit_local_get(buf, len_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_mul(buf)
      emit_local_set(buf, data_size_local)
      emit_heap_alloc_local(ctx, buf, data_size_local, data_local)
      // header: [obj_int64array, len, cap=len, data_ptr]
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_int64array)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, len_local)
      emit_i32_store(buf, 4)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, len_local)
      emit_i32_store(buf, 8)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, data_local)
      emit_i32_store(buf, 12)
      // fill: for i in 0..<len { data[i*8] = default }
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, i_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, i_local)
      emit_local_get(buf, len_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1)
      emit_local_get(buf, data_local)
      emit_local_get(buf, i_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_get(buf, default_local)
      emit_i64_store(buf, 0)
      emit_local_get(buf, i_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, i_local)
      emit_br(buf, 0)
      emit_end(buf)
      emit_end(buf)
      // return tagged obj pointer
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
    }
    "Int64Array::length" => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Int64Array::length", 1,
      )
      let ptr_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 4) // len
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf) // tag as Int
    }
    "Int64Array::get" => {
      // Int64Array::get(a, idx) -> stored tagged i64 Int (no truncation)
      let pos_args = extract_positional_exprs_with_arity(
        args, "Int64Array::get", 2,
      )
      let ptr_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, idx_local)
      // addr = data_ptr + idx * 8
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 12) // data_ptr
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i64_load(buf, 0) // tagged Int, returned verbatim
    }
    "Int64Array::set" => {
      // Int64Array::set(a, idx, v) -> store tagged i64 verbatim
      let pos_args = extract_positional_exprs_with_arity(
        args, "Int64Array::set", 3,
      )
      let ptr_local = alloc_temp_local(ctx)
      let idx_local = alloc_temp_local(ctx)
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, ptr_local)
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_i64_const_raw(buf, 2L)
      emit_i64_shr_s(buf)
      emit_i32_wrap_i64(buf)
      emit_local_set(buf, idx_local)
      // addr = data_ptr + idx * 8
      emit_local_get(buf, ptr_local)
      emit_i32_load(buf, 12)
      emit_local_get(buf, idx_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      // value (tagged i64) stored verbatim
      compile_expr_i32(ctx, buf, pos_args[2])
      emit_i64_store(buf, 0)
      emit_i64_const_tagged(buf, 0L) // Unit
    }
    // Bytes::new / push / set / append / blit / fill / slice / concat /
    // to_array migrated to the shared builtin registry
    // (registry_bytes.mbt / builtin_registry.mbt).
    "Fs::write_bytes" => {
      // fs_write_bytes(path, bytes) -> Unit
      // Accept both raw Bytes and BytesView payloads.
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Fs::write_bytes requires --wasm backend",
        )
      }
      if ctx.fs_host_imports {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::write_bytes", 2,
        )
        compile_expr(ctx, buf, pos_args[0])
        compile_expr(ctx, buf, pos_args[1])
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_host_write_bytes(ctx))
        emit_heap_post_call_sync(ctx, buf)
      } else {
        let pos_args = extract_positional_exprs_with_arity(
          args, "Fs::write_bytes", 2,
        )
        require_heap(ctx)
        let path_raw_local = alloc_temp_local(ctx)
        let path_len_local = alloc_temp_local(ctx)
        let bytes_ptr_local = alloc_temp_local(ctx)
        let bytes_len_local = alloc_temp_local(ctx)
        let bytes_cap_local = alloc_temp_local(ctx)
        let data_size_local = alloc_temp_local(ctx)
        let data_ptr_local = alloc_temp_local(ctx)
        let ret_area_local = alloc_temp_local(ctx)
        let root_desc_local = alloc_temp_local(ctx)
        let opened_desc_local = alloc_temp_local(ctx)
        let _idx_local = alloc_temp_local(ctx) // reserved (packed bytes removed conversion loop)
        let fs_global = fs_root_descriptor_global_index(ctx)
        // Initialize root descriptor if needed
        emit_global_get(buf, fs_global)
        emit_i32_const_raw(buf, -1)
        emit_i32_eq(buf)
        buf.push((4).to_byte()) // if
        buf.push((64).to_byte()) // void
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        emit_local_get(buf, ret_area_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_get_directories(ctx))
        emit_heap_post_call_sync(ctx, buf)
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 0)
        emit_i32_load(buf, 0)
        emit_global_set(buf, fs_global)
        buf.push((11).to_byte()) // end if
        emit_global_get(buf, fs_global)
        emit_local_set(buf, root_desc_local)
        // Extract path string
        compile_expr_i32(ctx, buf, pos_args[0])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, path_raw_local)
        emit_local_get(buf, path_raw_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, path_len_local)
        // Resolve bytes header so raw Bytes and BytesView share one path.
        compile_expr_i32(ctx, buf, pos_args[1])
        emit_untag_ptr_i32(buf)
        emit_local_set(buf, bytes_ptr_local)
        emit_bytes_load_header(
          ctx, buf, bytes_ptr_local, bytes_len_local, bytes_cap_local, data_ptr_local,
        )
        emit_local_get(buf, bytes_len_local)
        emit_local_set(buf, data_size_local)
        // Allocate retptr for open-at result
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        // Sync heap
        emit_heap_pre_call_sync(ctx, buf)
        // open-at(root_desc, 0, path_ptr, path_len, 5, 2, retptr)
        emit_local_get(buf, root_desc_local)
        emit_i32_const_raw(buf, 0) // path-flags
        emit_local_get(buf, path_raw_local)
        emit_i32_const_raw(buf, 8)
        emit_i32_add(buf) // path data ptr
        emit_local_get(buf, path_len_local)
        emit_i32_const_raw(buf, 5) // open-flags: create(1) | truncate(4) = 5
        emit_i32_const_raw(buf, 2) // desc-flags: write(2)
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_fs_open_at(ctx))
        // Reload heap
        emit_heap_post_call_sync(ctx, buf)
        // Check open result
        emit_local_get(buf, ret_area_local)
        emit_i32_load8_u(buf, 0)
        emit_i32_eqz(buf)
        buf.push((4).to_byte()) // if (ok)
        buf.push((126).to_byte()) // result i64
        // opened_desc = retptr[4]
        emit_local_get(buf, ret_area_local)
        emit_i32_load(buf, 4)
        emit_local_set(buf, opened_desc_local)
        // Allocate retptr for write result
        emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
        // Sync heap
        emit_heap_pre_call_sync(ctx, buf)
        // write(opened_desc, data_ptr, bytes_len, offset=0, retptr)
        emit_local_get(buf, opened_desc_local)
        emit_local_get(buf, data_ptr_local)
        emit_local_get(buf, data_size_local)
        // i64.const 0 (offset)
        buf.push((66).to_byte())
        buf.push((0).to_byte())
        emit_local_get(buf, ret_area_local)
        emit_call(buf, import_index_fs_write(ctx))
        // Reload heap
        emit_heap_post_call_sync(ctx, buf)
        // resource-drop opened descriptor
        emit_local_get(buf, opened_desc_local)
        emit_heap_pre_call_sync(ctx, buf)
        emit_call(buf, import_index_fs_resource_drop(ctx))
        emit_heap_post_call_sync(ctx, buf)
        // Return Unit
        emit_i64_const_raw(buf, tag_int_value64(0L))
        buf.push((5).to_byte()) // else (open error)
        emit_i64_const_raw(buf, tag_int_value64(0L))
        buf.push((11).to_byte()) // end if
      } // end else (WASI path)
    }
    "Socket::tcp_connect" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Socket::tcp_connect requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Socket::tcp_connect", 2,
      )
      require_heap(ctx)
      let host_raw_local = alloc_temp_local(ctx)
      let host_len_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let network_local = alloc_temp_local(ctx)
      let socket_local = alloc_temp_local(ctx)
      let pollable_local = alloc_temp_local(ctx)
      let input_stream_local = alloc_temp_local(ctx)
      let output_stream_local = alloc_temp_local(ctx)
      let port_local = alloc_temp_local(ctx)
      let table_base_local = alloc_temp_local(ctx)
      let slot_local = alloc_temp_local(ctx)
      let a_local = alloc_temp_local(ctx)
      let b_local = alloc_temp_local(ctx)
      let c_local = alloc_temp_local(ctx)
      let d_local = alloc_temp_local(ctx)
      let i_local = alloc_temp_local(ctx)
      let acc_local = alloc_temp_local(ctx)
      let sock_global = socket_table_global_index(ctx)
      // Extract host string
      compile_expr_i32(ctx, buf, pos_args[0])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, host_raw_local)
      emit_local_get(buf, host_raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, host_len_local)
      // Extract port (untag)
      compile_expr(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_local_set(buf, port_local)
      // Parse IPv4 address: host bytes -> a.b.c.d
      // Initialize accumulators
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, a_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, b_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, c_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, d_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, acc_local)
      emit_i32_const_raw(buf, 0) // octet_index
      emit_local_set(buf, slot_local)
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, i_local)
      // Loop over host bytes
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, i_local)
      emit_local_get(buf, host_len_local)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if i >= len
      // Load byte
      emit_local_get(buf, host_raw_local)
      emit_local_get(buf, i_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8) // +8 for string data offset
      // Check if '.' (0x2E)
      emit_i32_const_raw(buf, 0x2E)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if (is dot)
      buf.push((64).to_byte()) // void
      // Store acc into current octet, advance
      emit_local_get(buf, slot_local)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if slot==0
      buf.push((64).to_byte())
      emit_local_get(buf, acc_local)
      emit_local_set(buf, a_local)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_eq(buf)
      buf.push((4).to_byte()) // if slot==1
      buf.push((64).to_byte())
      emit_local_get(buf, acc_local)
      emit_local_set(buf, b_local)
      buf.push((5).to_byte()) // else
      emit_local_get(buf, acc_local)
      emit_local_set(buf, c_local)
      buf.push((11).to_byte()) // end if slot==1
      buf.push((11).to_byte()) // end if slot==0
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, acc_local)
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, slot_local)
      buf.push((5).to_byte()) // else (digit)
      // acc = acc * 10 + (byte - '0')
      emit_local_get(buf, acc_local)
      emit_i32_const_raw(buf, 10)
      emit_i32_mul(buf)
      emit_local_get(buf, host_raw_local)
      emit_local_get(buf, i_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 8) // +8 for string data offset
      emit_i32_const_raw(buf, 0x30) // '0'
      emit_i32_sub(buf)
      emit_i32_add(buf)
      emit_local_set(buf, acc_local)
      buf.push((11).to_byte()) // end if (dot/digit)
      // i++
      emit_local_get(buf, i_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, i_local)
      emit_br(buf, 0) // continue loop
      emit_end(buf) // end loop
      emit_end(buf) // end block
      // Last octet
      emit_local_get(buf, acc_local)
      emit_local_set(buf, d_local)
      // Allocate connection table if not yet done (256 bytes for 16 entries)
      emit_global_get(buf, sock_global)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if (table not allocated)
      buf.push((64).to_byte())
      emit_heap_alloc(ctx, buf, 256, table_base_local)
      emit_local_get(buf, table_base_local)
      emit_global_set(buf, sock_global)
      buf.push((11).to_byte()) // end if
      emit_global_get(buf, sock_global)
      emit_local_set(buf, table_base_local)
      // Allocate retptr (16 bytes)
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap before WASI calls
      emit_heap_pre_call_sync(ctx, buf)
      // 1. instance-network() -> network
      emit_call(buf, import_index_socket_instance_network(ctx))
      emit_local_set(buf, network_local)
      // 2. create-tcp-socket(family=0 IPv4, retptr)
      emit_i32_const_raw(buf, 0) // IPv4
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_create_tcp(ctx))
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 0) // discriminant
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if ok
      buf.push((126).to_byte()) // result i64
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4) // socket handle
      emit_local_set(buf, socket_local)
      // 3. start-connect(self, network, disc=0, port, a, b, c, d, 0,0,0,0,0,0, retptr)
      emit_local_get(buf, socket_local)
      emit_local_get(buf, network_local)
      emit_i32_const_raw(buf, 0) // disc: IPv4
      emit_local_get(buf, port_local)
      emit_local_get(buf, a_local)
      emit_local_get(buf, b_local)
      emit_local_get(buf, c_local)
      emit_local_get(buf, d_local)
      emit_i32_const_raw(buf, 0) // padding
      emit_i32_const_raw(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_i32_const_raw(buf, 0)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_start_connect(ctx))
      // 4. subscribe(socket) -> pollable
      emit_local_get(buf, socket_local)
      emit_call(buf, import_index_socket_subscribe(ctx))
      emit_local_set(buf, pollable_local)
      // 5. poll([pollable], 1, retptr) - write pollable handle to retptr area
      emit_local_get(buf, ret_area_local)
      emit_local_get(buf, pollable_local)
      emit_i32_store(buf, 0)
      emit_local_get(buf, ret_area_local) // list_ptr
      emit_i32_const_raw(buf, 1) // list_len
      emit_local_get(buf, ret_area_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // retptr (offset by 8 to avoid clobbering list)
      emit_call(buf, import_index_socket_poll(ctx))
      // 6. resource-drop pollable
      emit_local_get(buf, pollable_local)
      emit_call(buf, import_index_socket_drop_pollable(ctx))
      // 7. finish-connect(socket, retptr)
      emit_local_get(buf, socket_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_finish_connect(ctx))
      // Reload heap after WASI calls
      emit_heap_post_call_sync(ctx, buf)
      // Check finish-connect result
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 0) // discriminant
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if ok
      buf.push((126).to_byte()) // result i64
      // input_stream = retptr[4], output_stream = retptr[8]
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, input_stream_local)
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, output_stream_local)
      // Find free slot in connection table
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, slot_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_ge_s(buf)
      emit_br_if(buf, 1) // break if slot >= 16
      // Check in_use flag: table_base + slot*16 + 12
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_i32_load(buf, 12) // in_use
      emit_i32_eqz(buf)
      emit_br_if(buf, 1) // break if in_use == 0
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, slot_local)
      emit_br(buf, 0) // continue
      emit_end(buf) // end loop
      emit_end(buf) // end block
      // Store entry: [socket, input_stream, output_stream, 1]
      // entry_addr = table_base + slot * 16
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, slot_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_set(buf, ret_area_local) // reuse as entry_addr
      emit_local_get(buf, ret_area_local)
      emit_local_get(buf, socket_local)
      emit_i32_store(buf, 0)
      emit_local_get(buf, ret_area_local)
      emit_local_get(buf, input_stream_local)
      emit_i32_store(buf, 4)
      emit_local_get(buf, ret_area_local)
      emit_local_get(buf, output_stream_local)
      emit_i32_store(buf, 8)
      emit_local_get(buf, ret_area_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_store(buf, 12) // in_use = 1
      // Return slot as tagged int
      emit_local_get(buf, slot_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, 2L)
      emit_i64_shl(buf)
      buf.push((5).to_byte()) // else (finish-connect failed)
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      buf.push((11).to_byte()) // end if (finish-connect)
      buf.push((5).to_byte()) // else (create-tcp-socket failed)
      emit_i64_const_raw(buf, tag_int_value64(-1L))
      buf.push((11).to_byte()) // end if (create-tcp-socket)
    }
    "Socket::tcp_read" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Socket::tcp_read requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Socket::tcp_read", 2,
      )
      require_heap(ctx)
      let handle_local = alloc_temp_local(ctx)
      let max_bytes_local = alloc_temp_local(ctx)
      let table_base_local = alloc_temp_local(ctx)
      let entry_addr_local = alloc_temp_local(ctx)
      let input_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let data_ptr_local = alloc_temp_local(ctx)
      let data_len_local = alloc_temp_local(ctx)
      let obj_local = alloc_temp_local(ctx)
      let copy_i_local = alloc_temp_local(ctx)
      let alloc_size_local = alloc_temp_local(ctx)
      let sock_global = socket_table_global_index(ctx)
      // Extract handle (untag)
      compile_expr(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, handle_local)
      // Extract max_bytes (untag)
      compile_expr(ctx, buf, pos_args[1])
      emit_untag_int_i32(buf)
      emit_local_set(buf, max_bytes_local)
      // Load table base
      emit_global_get(buf, sock_global)
      emit_local_set(buf, table_base_local)
      // entry_addr = table_base + handle * 16
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, handle_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_set(buf, entry_addr_local)
      // input_stream = entry[4]
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, input_stream_local)
      // Allocate retptr
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      emit_heap_pre_call_sync(ctx, buf)
      // blocking-read(input_stream, max_bytes as i64, retptr)
      emit_local_get(buf, input_stream_local)
      emit_local_get(buf, max_bytes_local)
      emit_i64_extend_i32_u(buf) // convert to i64
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_stream_read(ctx))
      // Reload heap
      emit_heap_post_call_sync(ctx, buf)
      // Check result: retptr[0] discriminant
      emit_local_get(buf, ret_area_local)
      emit_i32_load8_u(buf, 0)
      emit_i32_eqz(buf)
      buf.push((4).to_byte()) // if ok
      buf.push((126).to_byte()) // result i64
      // data_ptr = retptr[4], data_len = retptr[8]
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, data_ptr_local)
      emit_local_get(buf, ret_area_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, data_len_local)
      // Allocate vibe string: align4(8 + data_len)
      emit_local_get(buf, data_len_local)
      emit_i32_const_raw(buf, 11)
      emit_i32_add(buf)
      emit_i32_const_raw(buf, -4)
      emit_i32_and(buf)
      emit_local_set(buf, alloc_size_local)
      emit_heap_alloc_local(ctx, buf, alloc_size_local, obj_local)
      // Write string header
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, data_len_local)
      emit_i32_store(buf, 4)
      // Copy bytes
      emit_i32_const_raw(buf, 0)
      emit_local_set(buf, copy_i_local)
      emit_block(buf)
      emit_loop(buf)
      emit_local_get(buf, copy_i_local)
      emit_local_get(buf, data_len_local)
      emit_i32_lt_s(buf)
      emit_i32_eqz(buf)
      emit_br_if(buf, 1)
      emit_local_get(buf, obj_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_add(buf)
      emit_local_get(buf, data_ptr_local)
      emit_local_get(buf, copy_i_local)
      emit_i32_add(buf)
      emit_i32_load8_u(buf, 0)
      emit_i32_store8(buf, 8)
      emit_local_get(buf, copy_i_local)
      emit_i32_const_raw(buf, 1)
      emit_i32_add(buf)
      emit_local_set(buf, copy_i_local)
      emit_br(buf, 0)
      emit_end(buf) // end loop
      emit_end(buf) // end block
      // Return tagged string pointer
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
      buf.push((5).to_byte()) // else (read error)
      // Return empty string on error
      emit_heap_alloc(ctx, buf, align4(8), obj_local)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, obj_string)
      emit_i32_store(buf, 0)
      emit_local_get(buf, obj_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_store(buf, 4)
      emit_local_get(buf, obj_local)
      emit_i64_extend_i32_u(buf)
      emit_i64_const_raw(buf, tag_obj.to_int64())
      emit_i64_or(buf)
      buf.push((11).to_byte()) // end if
    }
    "Socket::tcp_write" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Socket::tcp_write requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Socket::tcp_write", 2,
      )
      require_heap(ctx)
      let handle_local = alloc_temp_local(ctx)
      let data_raw_local = alloc_temp_local(ctx)
      let data_len_local = alloc_temp_local(ctx)
      let table_base_local = alloc_temp_local(ctx)
      let entry_addr_local = alloc_temp_local(ctx)
      let output_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let sock_global = socket_table_global_index(ctx)
      // Extract handle (untag)
      compile_expr(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, handle_local)
      // Extract data string
      compile_expr_i32(ctx, buf, pos_args[1])
      emit_untag_ptr_i32(buf)
      emit_local_set(buf, data_raw_local)
      emit_local_get(buf, data_raw_local)
      emit_i32_load(buf, 4) // len
      emit_local_set(buf, data_len_local)
      // Load table base
      emit_global_get(buf, sock_global)
      emit_local_set(buf, table_base_local)
      // entry_addr = table_base + handle * 16
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, handle_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_set(buf, entry_addr_local)
      // output_stream = entry[8]
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, output_stream_local)
      // Allocate retptr
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // Sync heap
      emit_heap_pre_call_sync(ctx, buf)
      // blocking-write-and-flush(output_stream, data_ptr+8, data_len, retptr)
      emit_local_get(buf, output_stream_local)
      emit_local_get(buf, data_raw_local)
      emit_i32_const_raw(buf, 8)
      emit_i32_add(buf) // data ptr
      emit_local_get(buf, data_len_local)
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_stream_write(ctx))
      // Reload heap
      emit_heap_post_call_sync(ctx, buf)
      // Return Unit (tagged 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    "Socket::tcp_close" => {
      if ctx.use_js_strings {
        raise WasmGenError::Unsupported(
          "Socket::tcp_close requires --wasm backend",
        )
      }
      let pos_args = extract_positional_exprs_with_arity(
        args, "Socket::tcp_close", 1,
      )
      require_heap(ctx)
      let handle_local = alloc_temp_local(ctx)
      let table_base_local = alloc_temp_local(ctx)
      let entry_addr_local = alloc_temp_local(ctx)
      let socket_local = alloc_temp_local(ctx)
      let input_stream_local = alloc_temp_local(ctx)
      let output_stream_local = alloc_temp_local(ctx)
      let ret_area_local = alloc_temp_local(ctx)
      let sock_global = socket_table_global_index(ctx)
      // Extract handle (untag)
      compile_expr(ctx, buf, pos_args[0])
      emit_untag_int_i32(buf)
      emit_local_set(buf, handle_local)
      // Load table base
      emit_global_get(buf, sock_global)
      emit_local_set(buf, table_base_local)
      // entry_addr = table_base + handle * 16
      emit_local_get(buf, table_base_local)
      emit_local_get(buf, handle_local)
      emit_i32_const_raw(buf, 16)
      emit_i32_mul(buf)
      emit_i32_add(buf)
      emit_local_set(buf, entry_addr_local)
      // Load 3 handles
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 0)
      emit_local_set(buf, socket_local)
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 4)
      emit_local_set(buf, input_stream_local)
      emit_local_get(buf, entry_addr_local)
      emit_i32_load(buf, 8)
      emit_local_set(buf, output_stream_local)
      // Allocate retptr for shutdown
      emit_heap_alloc(ctx, buf, align4(16), ret_area_local)
      // shutdown(socket, 2=both, retptr)
      emit_local_get(buf, socket_local)
      emit_i32_const_raw(buf, 2) // both
      emit_local_get(buf, ret_area_local)
      emit_call(buf, import_index_socket_shutdown(ctx))
      // resource-drop input-stream
      emit_local_get(buf, input_stream_local)
      emit_call(buf, import_index_socket_drop_input(ctx))
      // resource-drop output-stream
      emit_local_get(buf, output_stream_local)
      emit_call(buf, import_index_socket_drop_output(ctx))
      // resource-drop tcp-socket
      emit_local_get(buf, socket_local)
      emit_call(buf, import_index_socket_drop_tcp(ctx))
      // Mark entry as free: in_use = 0
      emit_local_get(buf, entry_addr_local)
      emit_i32_const_raw(buf, 0)
      emit_i32_store(buf, 12) // in_use = 0
      // Return Unit (tagged 0)
      emit_i64_const_raw(buf, tag_int_value64(0L))
    }
    // Fs builtins that only have host import codegen (no WASI path)
    "Fs::readdir" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::readdir", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_readdir(ctx))
    }
    "Fs::getcwd" if ctx.fs_host_imports => {
      let _ = extract_positional_exprs_with_arity(args, "Fs::getcwd", 0)
      emit_call(buf, import_index_fs_host_getcwd(ctx))
    }
    "Fs::chdir" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::chdir", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_chdir(ctx))
    }
    "Fs::is_dir" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::is_dir", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_is_dir(ctx))
    }
    "Fs::is_file" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::is_file", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_is_file(ctx))
    }
    "Fs::mkdir" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::mkdir", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_mkdir(ctx))
    }
    "Fs::mkdir_p" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::mkdir_p", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_mkdir_p(ctx))
    }
    "Fs::remove" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::remove", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_fs_host_remove(ctx))
    }
    "Fs::rename" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::rename", 2)
      compile_expr(ctx, buf, pos_args[0])
      compile_expr(ctx, buf, pos_args[1])
      emit_call(buf, import_index_fs_host_rename(ctx))
    }
    "Fs::copy" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::copy", 2)
      compile_expr(ctx, buf, pos_args[0])
      compile_expr(ctx, buf, pos_args[1])
      emit_call(buf, import_index_fs_host_copy(ctx))
    }
    "Fs::append" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(args, "Fs::append", 2)
      compile_expr(ctx, buf, pos_args[0])
      compile_expr(ctx, buf, pos_args[1])
      emit_call(buf, import_index_fs_host_append(ctx))
    }
    "Fs::open_write" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Fs::open_write", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_fs_host_open_write(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    "Fs::write_chunk" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Fs::write_chunk", 2,
      )
      compile_expr(ctx, buf, pos_args[0])
      compile_expr(ctx, buf, pos_args[1])
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_fs_host_write_chunk(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    "Fs::close_write" if ctx.fs_host_imports => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Fs::close_write", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_heap_pre_call_sync(ctx, buf)
      emit_call(buf, import_index_fs_host_close_write(ctx))
      emit_heap_post_call_sync(ctx, buf)
    }
    // Json host imports (vibe module, available when fs_host_imports is set).
    // Skip when the user has shadowed the builtin with a same-named definition,
    // matching the convention used by other builtins (e.g. `Env::get`).
    "Json::parse" if ctx.fs_host_imports && !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(args, "Json::parse", 1)
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_json_host_parse(ctx))
    }
    "Json::stringify" if ctx.fs_host_imports && !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Json::stringify", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_json_host_stringify(ctx))
    }
    "Json::get" if ctx.fs_host_imports && !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(args, "Json::get", 2)
      compile_expr(ctx, buf, pos_args[0])
      compile_expr(ctx, buf, pos_args[1])
      emit_call(buf, import_index_json_host_get(ctx))
    }
    "Json::string" if ctx.fs_host_imports && !is_user_fn => {
      let pos_args = extract_positional_exprs_with_arity(
        args, "Json::string", 1,
      )
      compile_expr(ctx, buf, pos_args[0])
      emit_call(buf, import_index_json_host_string(ctx))
    }
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}
