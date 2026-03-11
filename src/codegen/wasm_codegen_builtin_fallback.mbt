///|
fn is_wasm_runtime_fallback_builtin(name : String) -> Bool {
  match name {
    // JSON helpers are currently interpreter-only.
    "Json::parse"
    | "Json::stringify"
    | "Json::parse_lines"
    | "Json::stringify_lines"
    | "Lines::parse"
    | "Lines::stringify"
    | "Json::type_of"
    | "Json::string"
    | "Json::get"
    | "Json::index"
    | "Json::number"
    | "Json::bool"
    | "Json::is_null"
    | "Json::length"
    | "Json::keys"
    // All string builtins now have native WASM implementations in
    // wasm_codegen_call_builtin_pre_user.mbt.
    // Filesystem helpers not mapped to wasm imports yet.
    | "Fs::chdir"
    | "Fs::copy"
    | "Fs::readdir"
    | "Fs::is_dir"
    | "Fs::is_file"
    | "Fs::mkdir"
    | "Fs::mkdir_p"
    | "Fs::getcwd"
    | "Fs::remove"
    | "Fs::rename"
    | "Fs::append"
    // LLM and interactive helpers are host-runtime specific.
    | "Llm::complete"
    | "Rlm::run"
    | "Rlm::finalize"
    | "PromptText::new"
    | "PromptText::to_string"
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
