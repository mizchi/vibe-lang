///|
fn is_wasm_runtime_fallback_builtin(name : String) -> Bool {
  match name {
    // JSON helpers are currently interpreter-only.
    "from_json"
    | "to_json"
    | "from_jsonl"
    | "to_jsonl"
    | "from_lines"
    | "to_lines"
    | "json_type"
    | "json_string"
    | "json_get"
    | "json_index"
    | "json_number"
    | "json_bool"
    | "json_is_null"
    | "json_length"
    | "json_keys"
    // String convenience helpers that still go through interpreter builtins.
    // Note: string_contains, string_starts_with, string_ends_with,
    // string_last_index_of, string_index_of, string_count,
    // string_trim, string_trim_start, string_trim_end,
    // string_to_upper, string_to_lower, string_replace, string_replace_all
    // have native WASM implementations in wasm_codegen_call_builtin_pre_user.mbt.
    | "string_split"
    // Filesystem/env helpers not mapped to wasm imports yet.
    | "fs_chdir"
    | "fs_copy"
    | "fs_readdir"
    | "fs_is_dir"
    | "fs_is_file"
    | "fs_mkdir"
    | "fs_mkdir_p"
    | "fs_getcwd"
    | "fs_remove"
    | "fs_rename"
    | "fs_append"
    | "env_get"
    // LLM and interactive helpers are host-runtime specific.
    | "llm_complete"
    | "rlm_run"
    | "rlm_finalize"
    | "prompt_text"
    | "prompt_text_to_string"
    | "select"
    | "sh_lines" => true
    _ => false
  }
}

///|
fn emit_wasm_runtime_fallback_throw(
  ctx : CodegenCtx,
  buf : ByteBuf,
  name : String,
) -> Unit {
  let message = name + " is not available on wasm target"
  emit_i64_const_tagged(buf, intern_error_code(ctx, message).to_int64())
  buf.push((8).to_byte()) // throw
  write_u32_leb(buf, ctx.error_tag_index)
}
