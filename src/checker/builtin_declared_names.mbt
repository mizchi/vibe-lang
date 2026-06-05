///|
/// Returns all builtin names declared in the checker's type-checking handlers.
/// This is the source of truth for which builtins the checker knows about.
pub fn checker_declared_builtin_names() -> Array[String] {
  [
    // Path
    "Path::ref", "Path::to_string", "Path::is_absolute", "Path::resolve",
    // Env
     "Env::get", "Env::args_len", "Env::args_get",
    // Stdin / Stdout
     "Stdin::read_char", "Stdin::read_stream", "Stdout::write_char", "Stdout::write_stream",
    // Fs
     "Fs::read_file", "Fs::read_string", "Fs::read_bytes", "Fs::write_file", "Fs::write_string",
    "Fs::write_bytes", "Fs::exists", "Fs::stat_token", "Fs::chdir", "Fs::copy", "Fs::readdir",
    "Fs::is_dir", "Fs::is_file", "Fs::mkdir", "Fs::mkdir_p", "Fs::getcwd", "Fs::remove",
    "Fs::rename", "Fs::append", "Fs::open_write", "Fs::write_chunk", "Fs::close_write",
    // Http
     "Http::listen", "Http::accept", "Http::close", "Http::request", "Http::request_method",
    "Http::request_url", "Http::request_header", "Http::request_body", "Http::respond",
    "Http::response_status", "Http::response_header", "Http::response_body",
    // Socket
     "Socket::tcp_connect", "Socket::tcp_read", "Socket::tcp_write", "Socket::tcp_close",
    // Int numeric
     "Int::abs", "Int::max", "Int::min", "Int::clamp", "Int::signum", "Int::is_even",
    "Int::is_odd", "Int::parse", "Int::to_float", "Int::to_double", "Int::to_string",
    // Float / Double
     "Float::to_int", "Float::to_double", "Float::to_string", "Double::to_int", "Double::to_float",
    "Double::to_string", "Double::parse", "Bool::to_string", "Double::abs", "Double::ceil",
    "Double::floor", "Double::max", "Double::min",
    // Char
     "Char::to_int", "Char::from_int",
    // String
     "String::length", "String::char_code_at", "String::from_char_code", "String::from_char_codes",
    "String::substring", "String::concat", "String::join", "String::equals", "String::index_of",
    "String::contains", "String::starts_with", "String::ends_with", "String::last_index_of",
    "String::count", "String::trim", "String::trim_start", "String::trim_end", "String::split",
    "String::replace", "String::replace_all", "String::to_lower", "String::to_upper",
    "String::unicode_length",
    // Array
     "Array::get", "Array::set", "Array::length", "Array::push", "Array::push_all",
    "Array::truncate", "Array::slice", "Array::concat", "Array::map", "Array::fold",
    "Array::filter", "Array::foreach", "Array::reverse", "Array::any", "Array::all",
    "Array::find", "Array::sort", "Array::contains", "Array::join",
    // Bytes
     "Bytes::new", "Bytes::length", "Bytes::get", "Bytes::set", "Bytes::push", "Bytes::append",
    "Bytes::blit", "Bytes::concat", "Bytes::fill", "Bytes::slice", "Bytes::from_array",
    "Bytes::from_string", "Bytes::to_array", "Bytes::to_string",
    // Int64Array (i64-cell buffer; avoids Array[Int] 32-bit truncation, #429)
     "Int64Array::make", "Int64Array::length", "Int64Array::get", "Int64Array::set",
    // Map
     "Map::get", "Map::get_or", "Map::set", "Map::delete", "Map::has", "Map::has_key",
    "Map::keys", "Map::values", "Map::map", "Map::filter",
    // Set
     "Set::new", "Set::add", "Set::remove", "Set::contains", "Set::size", "Set::from_array",
    "Set::to_array",
    // Json
     "Json::parse", "Json::stringify", "Json::parse_lines", "Json::stringify_lines",
    "Json::type_of", "Json::string", "Json::get", "Json::index", "Json::number",
    "Json::bool", "Json::is_null", "Json::length", "Json::keys", "Lines::parse",
    "Lines::stringify",
    // LLM / interactive
     "Llm::complete", "Rlm::run", "Rlm::finalize",
    // Threads (experimental)
     "Threads::probe_wat", "Threads::runtime_hints", "Threads::channel_new", "Threads::send",
    "Threads::recv", "Threads::spawn", "Threads::wait",
  ]
}
