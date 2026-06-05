///|
/// Returns all builtin names that have codegen handlers in the WASM backend.
/// This is used for contract verification: checker-declared builtins should
/// have corresponding codegen handlers (or be listed as runtime fallbacks).
pub fn codegen_registered_builtin_names() -> Array[String] {
  [
    // Env
    "Env::get", "Env::args_len", "Env::args_get",
    // Int numeric
     "Int::to_float", "Int::to_double", "Int::to_string", "Int::abs", "Int::max",
    "Int::min", "Int::clamp", "Int::signum", "Int::is_even", "Int::is_odd", "Int::parse",
    // Float / Double conversion
     "Float::to_int", "Float::to_double", "Float::to_string", "Double::to_int", "Double::to_float",
    "Double::to_string", "Double::parse", "Bool::to_string",
    // Char
     "Char::to_int", "Char::from_int",
    // String
     "String::length", "String::char_code_at", "String::substring", "String::concat",
    "String::join", "String::equals", "String::index_of", "String::contains", "String::starts_with",
    "String::ends_with", "String::last_index_of", "String::count", "String::trim",
    "String::trim_start", "String::trim_end", "String::split", "String::replace",
    "String::replace_all", "String::to_lower", "String::to_upper", "String::from_char_code",
    "String::from_char_codes", "String::unicode_length",
    // StringBuilder (codegen-handled via the shared builtin registry, #414 / #415)
     "StringBuilder::new", "StringBuilder::push", "StringBuilder::freeze",
    // ArrayBuilder / MapBuilder (codegen-handled via the shared builtin registry, #415)
     "ArrayBuilder::new", "ArrayBuilder::push", "ArrayBuilder::freeze", "MapBuilder::new",
    "MapBuilder::set", "MapBuilder::freeze",
    // Array
     "Array::get", "Array::set", "Array::length", "Array::push", "Array::push_all",
    "Array::truncate", "Array::slice", "Array::concat", "Array::with_capacity",
    // Bytes
     "Bytes::new", "Bytes::length", "Bytes::get", "Bytes::set", "Bytes::push", "Bytes::append",
    "Bytes::blit", "Bytes::concat", "Bytes::fill", "Bytes::slice", "Bytes::from_array",
    "Bytes::from_string", "Bytes::to_array", "Bytes::to_string",
    // Int64Array (i64-cell buffer, #429)
     "Int64Array::make", "Int64Array::length", "Int64Array::get", "Int64Array::set",
    // Map
     "Map::get", "Map::set", "Map::delete", "Map::has", "Map::has_key", "Map::keys",
    "Map::values", "Map::iter_length", "Map::iter_get",
    // Set
     "Set::new", "Set::add", "Set::remove", "Set::contains", "Set::size", "Set::from_array",
    "Set::to_array",
    // Path
     "Path::ref", "Path::resolve", "Path::is_absolute", "Path::to_string",
    // Fs
     "Fs::exists", "Fs::read_file", "Fs::write_file", "Fs::write_bytes", "Fs::stat_token",
    // Stdin / Stdout
     "Stdin::read_char", "Stdin::read_stream", "Stdout::write_char", "Stdout::write_stream",
    // Http
     "Http::listen", "Http::accept", "Http::close", "Http::request", "Http::request_method",
    "Http::request_url", "Http::request_header", "Http::request_body", "Http::respond",
    "Http::response_status", "Http::response_header", "Http::response_body",
    // Socket
     "Socket::tcp_connect", "Socket::tcp_read", "Socket::tcp_write", "Socket::tcp_close",
    // Json (host imports when fs_host_imports is set)
     "Json::parse", "Json::stringify", "Json::get", "Json::string",
  ]
}

///|
/// Returns all builtin names that are declared in the checker but known to
/// have no codegen handler (they throw a runtime error when called in WASM).
pub fn codegen_runtime_fallback_builtin_names() -> Array[String] {
  [
    // JSON (interpreter-only, except a small host-import subset)
    "Json::parse_lines", "Json::stringify_lines", "Lines::parse", "Lines::stringify",
    "Json::type_of", "Json::index", "Json::number", "Json::bool", "Json::is_null",
    "Json::length", "Json::keys",
    // Fs (not mapped to wasm imports yet)
     "Fs::chdir", "Fs::copy", "Fs::readdir", "Fs::is_dir", "Fs::is_file", "Fs::mkdir",
    "Fs::mkdir_p", "Fs::getcwd", "Fs::remove", "Fs::rename", "Fs::append",
    // Threads (experimental source-level API; only probe constants lower today)
     "Threads::probe_wat", "Threads::runtime_hints", "Threads::channel_new", "Threads::send",
    "Threads::recv", "Threads::spawn", "Threads::wait",
    // LLM / interactive
     "Llm::complete", "Rlm::run", "Rlm::finalize",
  ]
}
