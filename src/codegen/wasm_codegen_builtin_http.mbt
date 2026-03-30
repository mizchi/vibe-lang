///|
fn compile_builtin_http(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
  args : Array[@core.CallArg],
  _is_user_fn : Bool,
) -> Unit raise WasmGenError {
  match name {
    // --- HTTP builtins (P3 draft — raise error, interpreter-only for now) ---
    "Http::request"
    | "Http::response_status"
    | "Http::response_header"
    | "Http::response_body"
    | "Http::close"
    | "Http::listen"
    | "Http::accept"
    | "Http::request_method"
    | "Http::request_url"
    | "Http::request_header"
    | "Http::request_body"
    | "Http::respond" =>
      if ctx.need_http && ctx.http_host_imports {
        if ctx.use_js_strings {
          raise WasmGenError::Unsupported(
            "http host imports require --wasm backend",
          )
        }
        match name {
          "Http::request" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request", 4,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            compile_expr(ctx, buf, pos_args[2])
            compile_expr(ctx, buf, pos_args[3])
            emit_heap_pre_call_sync(ctx, buf)
            emit_call(buf, import_index_http_request(ctx))
            emit_heap_post_call_sync(ctx, buf)
          }
          "Http::response_status" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::response_status", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_heap_pre_call_sync(ctx, buf)
            emit_call(buf, import_index_http_response_status(ctx))
            emit_heap_post_call_sync(ctx, buf)
          }
          "Http::response_header" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::response_header", 2,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            emit_heap_pre_call_sync(ctx, buf)
            emit_call(buf, import_index_http_response_header(ctx))
            emit_heap_post_call_sync(ctx, buf)
          }
          "Http::response_body" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::response_body", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_heap_pre_call_sync(ctx, buf)
            emit_call(buf, import_index_http_response_body(ctx))
            emit_heap_post_call_sync(ctx, buf)
          }
          "Http::close" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::close", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_heap_pre_call_sync(ctx, buf)
            emit_call(buf, import_index_http_close(ctx))
            emit_heap_post_call_sync(ctx, buf)
            buf.push((26).to_byte()) // drop host return
            emit_i64_const_raw(buf, tag_int_value64(0L))
          }
          "Http::listen" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::listen", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_heap_pre_call_sync(ctx, buf)
            emit_call(buf, import_index_http_listen(ctx))
            emit_heap_post_call_sync(ctx, buf)
          }
          "Http::accept" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::accept", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_heap_pre_call_sync(ctx, buf)
            emit_call(buf, import_index_http_accept(ctx))
            emit_heap_post_call_sync(ctx, buf)
          }
          "Http::request_method" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request_method", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_heap_pre_call_sync(ctx, buf)
            emit_call(buf, import_index_http_request_method(ctx))
            emit_heap_post_call_sync(ctx, buf)
          }
          "Http::request_url" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request_url", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_request_url(ctx))
          }
          "Http::request_header" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request_header", 2,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            emit_call(buf, import_index_http_request_header(ctx))
          }
          "Http::request_body" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::request_body", 1,
            )
            compile_expr(ctx, buf, pos_args[0])
            emit_call(buf, import_index_http_request_body(ctx))
          }
          "Http::respond" => {
            let pos_args = extract_positional_exprs_with_arity(
              args, "Http::respond", 4,
            )
            compile_expr(ctx, buf, pos_args[0])
            compile_expr(ctx, buf, pos_args[1])
            compile_expr(ctx, buf, pos_args[2])
            compile_expr(ctx, buf, pos_args[3])
            emit_call(buf, import_index_http_respond(ctx))
            buf.push((26).to_byte()) // drop host return
            emit_i64_const_raw(buf, tag_int_value64(0L))
          }
          _ => raise WasmGenError::Unsupported("unknown http builtin: " + name)
        }
      } else {
        // WASI P3 HTTP is draft; emit raise with error message instead of
        // unreachable trap so the error is catchable by try/catch.
        let msg = name + " is not available on wasm target"
        if not(ctx.use_js_strings) && not(ctx.embed_error_strings) {
          emit_i64_const_tagged(buf, intern_error_code(ctx, msg).to_int64())
        } else if ctx.use_js_strings {
          emit_string_const(ctx, buf, msg)
        } else {
          emit_i64_const_raw(buf, tag_ptr64(ctx.strings.intern(msg), tag_obj))
        }
        buf.push((8).to_byte()) // throw
        write_u32_leb(buf, ctx.error_tag_index)
      }
    _ => raise WasmGenError::Unsupported(pre_user_builtin_unhandled_marker)
  }
}
