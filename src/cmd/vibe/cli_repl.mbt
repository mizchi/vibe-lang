///|
fn repl_cmd(
  args : Array[String],
  _syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
  permissions? : @capability.CapabilitySet? = None,
) -> Unit {
  let mut tui_mode = false
  let mut ai_mode = false
  let mut posix_mode = true // default: posix mode (shell commands available)
  let sub_args : Array[String] = []
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--tui" => {
        tui_mode = true
        i += 1
      }
      "--ai" => {
        ai_mode = true
        i += 1
      }
      "--posix" => {
        posix_mode = true
        i += 1
      }
      "--no-posix" => {
        posix_mode = false
        i += 1
      }
      _ => {
        sub_args.push(args[i])
        i += 1
      }
    }
  }
  let syntax_mode = if posix_mode {
    @runtime.ParserMode::PosixMode
  } else {
    @runtime.ParserMode::VibeMode
  }
  match permissions {
    Some(_) => println("shell: sandbox permissions active")
    None => ()
  }
  if ai_mode {
    repl_ai_cmd(sub_args, syntax_mode, features, enable_llm~)
    return
  }
  if tui_mode {
    repl_tui_cmd(sub_args, syntax_mode, features, enable_llm~)
    return
  }
  // Default: interactive line REPL with readline-like editing
  repl_interactive_cmd(sub_args, syntax_mode, features, enable_llm~)
}

///|
enum ReplMetaCommandResult {
  NotMeta
  HandledContinue
  HandledExit
  HandledLoadSource(String)
} derive(Show, Eq)

///|
struct ReplSymbolMatch {
  entry : @frontend.SymbolEntry
  source : String
}

///|
struct VibeShellInvocation {
  subcommand : String
  args : Array[String]
  pipeline_tail : String?
}

///|
struct ReplSymbolsOptions {
  include_local : Bool
  include_builtin : Bool
  include_shell : Bool
} derive(Show, Eq)

///|
struct ReplSymbolsRow {
  scope : String
  kind : String
  name : String
  signature : String
  address : String
} derive(Show, Eq)

///|
fn repl_meta_command_names() -> Array[String] {
  [
    ":q", ":quit", ":exit", ":help", ":view", ":outline", ":peek", ":type", ":save",
    ":load", ":clear", ":source",
  ]
}

///|
fn repl_is_space_char(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///|
fn repl_split_words(line : String) -> Array[String] {
  let out : Array[String] = []
  let buf = StringBuilder::new()
  let mut in_token = false
  for ch in line {
    if repl_is_space_char(ch) {
      if in_token {
        out.push(buf.to_string())
        buf.reset()
        in_token = false
      }
    } else {
      buf.write_char(ch)
      in_token = true
    }
  }
  if in_token {
    out.push(buf.to_string())
  }
  out
}

///|
fn repl_split_first_pipeline(line : String) -> (String, String?) {
  let parts : Array[String] = []
  for part_view in line.split("|>") {
    parts.push(part_view.to_string())
  }
  if parts.length() <= 1 {
    return (line, None)
  }
  let tail = StringBuilder::new()
  for i in 1..<parts.length() {
    if i > 1 {
      tail.write_string("|>")
    }
    tail.write_string(parts[i])
  }
  let pipe_tail = tail.to_string().trim().to_string()
  let maybe_tail = if pipe_tail.length() == 0 { None } else { Some(pipe_tail) }
  (parts[0], maybe_tail)
}

///|
fn repl_reserved_shell_command_names() -> Array[String] {
  [
    "vibe", "view", "outline", "peek", "symbols", "search", "rename", "normalize",
    "help", "type",
  ]
}

///|
fn repl_vibe_shell_subcommand_names() -> Array[String] {
  ["help", "symbols", "outline", "view", "peek", "type", "normalize"]
}

///|
fn repl_is_vibe_shell_subcommand(name : String) -> Bool {
  for subcommand in repl_vibe_shell_subcommand_names() {
    if subcommand == name {
      return true
    }
  }
  false
}

///|
fn repl_is_reserved_shell_command_name(name : String) -> Bool {
  for cmd in repl_reserved_shell_command_names() {
    if cmd == name {
      return true
    }
  }
  false
}

///|
fn repl_warn_reserved_shell_binding(
  name : String,
  print_line : (String) -> Unit,
) -> Unit {
  if repl_is_reserved_shell_command_name(name) {
    print_line(
      "warn: `" +
      name +
      "` is reserved for shell commands; use `" +
      name +
      "(...)` for explicit function call.",
    )
  }
}

///|
fn repl_symbols_default_options() -> ReplSymbolsOptions {
  { include_local: true, include_builtin: false, include_shell: false }
}

///|
fn repl_symbols_scope_bits(scope : String) -> (Bool, Bool, Bool)? {
  match scope {
    "local" => Some((true, false, false))
    "builtin" => Some((false, true, false))
    "shell" => Some((false, false, true))
    "all" => Some((true, true, true))
    _ => None
  }
}

///|
fn repl_symbols_parse_scope_value(
  value : String,
  include_local : Bool,
  include_builtin : Bool,
  include_shell : Bool,
) -> Result[(Bool, Bool, Bool), String] {
  let mut next_local = include_local
  let mut next_builtin = include_builtin
  let mut next_shell = include_shell
  let mut consumed = false
  for part_view in value.split(",") {
    let part = part_view.to_string().trim().to_string()
    if part.length() == 0 {
      continue
    }
    match repl_symbols_scope_bits(part) {
      Some((l, b, s)) => {
        next_local = next_local || l
        next_builtin = next_builtin || b
        next_shell = next_shell || s
        consumed = true
      }
      None =>
        return Err(
          "symbols: unknown scope " +
          part +
          " (expected local|builtin|shell|all)",
        )
    }
  }
  if not(consumed) {
    return Err("symbols: missing value for --scope")
  }
  Ok((next_local, next_builtin, next_shell))
}

///|
fn repl_parse_symbols_options(
  args : Array[String],
) -> Result[ReplSymbolsOptions, String] {
  let mut include_local = false
  let mut include_builtin = false
  let mut include_shell = false
  let mut explicit = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--local" => {
        include_local = true
        explicit = true
        i += 1
      }
      "--builtin" => {
        include_builtin = true
        explicit = true
        i += 1
      }
      "--shell" => {
        include_shell = true
        explicit = true
        i += 1
      }
      "--all" => {
        include_local = true
        include_builtin = true
        include_shell = true
        explicit = true
        i += 1
      }
      "--scope" => {
        if i + 1 >= args.length() {
          return Err("symbols: missing value for --scope")
        }
        explicit = true
        match
          repl_symbols_parse_scope_value(
            args[i + 1],
            include_local,
            include_builtin,
            include_shell,
          ) {
          Ok((next_local, next_builtin, next_shell)) => {
            include_local = next_local
            include_builtin = next_builtin
            include_shell = next_shell
          }
          Err(err) => return Err(err)
        }
        i += 2
      }
      _ => return Err("symbols: unknown option " + arg)
    }
  }
  if not(explicit) {
    return Ok(repl_symbols_default_options())
  }
  Ok({ include_local, include_builtin, include_shell })
}

///|
fn repl_symbols_selected_scopes(opts : ReplSymbolsOptions) -> Array[String] {
  let scopes : Array[String] = []
  if opts.include_local {
    scopes.push("local")
  }
  if opts.include_builtin {
    scopes.push("builtin")
  }
  if opts.include_shell {
    scopes.push("shell")
  }
  scopes
}

///|
fn repl_collect_path_shell_commands() -> Array[String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = {}
  match @sys.get_env_var("PATH") {
    None => ()
    Some(path) =>
      for dir_view in path.split(":") {
        let dir = dir_view.to_string()
        let entries = @os_fs.read_dir(dir) catch { _ => [] }
        for name in entries {
          if seen.contains(name) {
            continue
          }
          let full_path = dir + "/" + name
          let is_file = @os_fs.is_file(full_path) catch { _ => false }
          if is_file {
            seen[name] = true
            out.push(name)
          }
        }
      }
  }
  out
}

///|
fn repl_shell_builtin_function_names() -> Array[String] {
  ["sh", "path", "addr", "exit"]
}

///|
fn repl_symbols_local_name_set(
  rows : Array[ReplSymbolsRow],
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for row in rows {
    out[row.name] = true
  }
  out
}

///|
fn repl_collect_local_symbols_rows(
  rt : @runtime.Runtime,
  scratch_db_path : String,
  scratch_source : String,
) -> Array[ReplSymbolsRow] {
  let matches = repl_collect_current_symbol_matches(
    scratch_db_path,
    scratch_source,
    None,
  )
  let out : Array[ReplSymbolsRow] = []
  for item in matches {
    let entry = item.entry
    let address = match rt.get_addr(entry.name) {
      Some(addr) => addr
      None => eval_scope_symbol_id_from_entry(entry)
    }
    out.push({
      scope: "local",
      kind: @frontend.symbol_kind_name(entry.kind),
      name: entry.name,
      signature: entry.signature,
      address,
    })
  }
  out
}

///|
fn repl_collect_builtin_symbols_rows(
  rt : @runtime.Runtime,
  local_names : Map[String, Bool],
) -> Array[ReplSymbolsRow] {
  let out : Array[ReplSymbolsRow] = []
  let seen : Map[String, Bool] = {}
  let type_env = rt.type_env()
  for name, _ in type_env.bindings {
    if seen.contains(name) ||
      local_names.contains(name) ||
      name.has_prefix("__") {
      continue
    }
    seen[name] = true
    let signature = match type_env.get(name) {
      Some(ty) => ty.to_string()
      None => "_"
    }
    let address = match rt.get_addr(name) {
      Some(addr) => addr
      None => ""
    }
    out.push({ scope: "builtin", kind: "value", name, signature, address })
  }
  for name in repl_shell_builtin_function_names() {
    if seen.contains(name) || local_names.contains(name) {
      continue
    }
    seen[name] = true
    let signature = match type_env.get(name) {
      Some(ty) => ty.to_string()
      None => "_"
    }
    let address = match rt.get_addr(name) {
      Some(addr) => addr
      None => ""
    }
    out.push({ scope: "builtin", kind: "builtin", name, signature, address })
  }
  out
}

///|
fn repl_collect_shell_symbols_rows() -> Array[ReplSymbolsRow] {
  let out : Array[ReplSymbolsRow] = []
  let seen : Map[String, Bool] = {}
  fn push_row(
    out : Array[ReplSymbolsRow],
    seen : Map[String, Bool],
    kind : String,
    name : String,
    signature : String,
  ) -> Unit {
    if seen.contains(name) {
      return
    }
    seen[name] = true
    out.push({ scope: "shell", kind, name, signature, address: "" })
  }
  push_row(out, seen, "meta", ":q", "quit shell")
  push_row(out, seen, "meta", ":quit", "quit shell")
  push_row(out, seen, "meta", ":exit", "quit shell")
  push_row(out, seen, "meta", ":help", "show help")
  push_row(out, seen, "meta", ":view", "view <symbol>")
  push_row(out, seen, "meta", ":outline", "outline [target]")
  push_row(out, seen, "meta", ":peek", "peek <symbol>")
  push_row(out, seen, "meta", ":type", "type <symbol>")
  push_row(out, seen, "vibe", "vibe", "vibe <subcommand>")
  for subcommand in repl_vibe_shell_subcommand_names() {
    push_row(out, seen, "vibe", subcommand, "vibe " + subcommand)
  }
  for command in repl_collect_path_shell_commands() {
    push_row(out, seen, "command", command, "-")
  }
  out
}

///|
fn repl_symbols_row_to_json(row : ReplSymbolsRow) -> Json {
  let obj : Map[String, Json] = {}
  obj["scope"] = Json::string(row.scope)
  obj["kind"] = Json::string(row.kind)
  obj["name"] = Json::string(row.name)
  obj["signature"] = Json::string(row.signature)
  obj["address"] = Json::string(row.address)
  obj["short_address"] = Json::string(
    if row.address.length() == 0 {
      ""
    } else {
      short_hash(row.address)
    },
  )
  Json::object(obj)
}

///|
fn repl_symbol_key(entry : @frontend.SymbolEntry) -> String {
  entry.path +
  "|" +
  entry.name +
  "|" +
  entry.signature +
  "|" +
  entry.span.start.to_string() +
  "|" +
  entry.span.end.to_string()
}

///|
fn repl_collect_symbol_matches_from_entries(
  db : @runtime.VibeDb,
  entries : Array[@frontend.SymbolEntry],
) -> Array[ReplSymbolMatch] {
  let out : Array[ReplSymbolMatch] = []
  let seen : Map[String, Bool] = {}
  for entry in entries {
    let key = repl_symbol_key(entry)
    if seen.contains(key) {
      continue
    }
    seen[key] = true
    match db.get_source(entry.path) {
      Some(source) => out.push({ entry, source })
      None => ()
    }
  }
  out
}

///|
fn repl_collect_current_symbol_matches(
  scratch_db_path : String,
  scratch_source : String,
  symbol : String?,
) -> Array[ReplSymbolMatch] {
  if scratch_source.trim().to_string().length() == 0 {
    return []
  }
  let db = @runtime.VibeDb::new()
  db.set_source(scratch_db_path, scratch_source)
  let index = @runtime.build_symbol_index(db, [scratch_db_path])
  let entries : Array[@frontend.SymbolEntry] = []
  for entry in index.entries {
    if entry.path != scratch_db_path {
      continue
    }
    match symbol {
      Some(name) => if entry.name == name { entries.push(entry) }
      None => entries.push(entry)
    }
  }
  repl_collect_symbol_matches_from_entries(db, entries)
}

///|
fn repl_workspace_entry_path() -> String {
  @vibe_fs.normalize_path(current_workspace_index_root() + "/index.vibe")
}

///|
fn repl_load_workspace_symbol_matches(
  symbol : String?,
) -> Result[Array[ReplSymbolMatch], String] {
  let workspace_entry = repl_workspace_entry_path()
  if not(@os_fs.path_exists(workspace_entry)) {
    return Ok([])
  }
  match @loader.load_db_with_paths(workspace_entry) {
    Ok((db, _, paths)) => {
      let index = @runtime.build_symbol_index(db, paths)
      let entries : Array[@frontend.SymbolEntry] = []
      match symbol {
        Some(name) =>
          for entry in index.find_exact(name) {
            entries.push(entry)
          }
        None =>
          for entry in index.entries {
            entries.push(entry)
          }
      }
      Ok(repl_collect_symbol_matches_from_entries(db, entries))
    }
    Err(err) => Err(err)
  }
}

///|
fn repl_symbol_match_location(item : ReplSymbolMatch) -> String {
  let (line, column) = symbol_line_col(item.source, item.entry.span)
  item.entry.path + ":" + line.to_string() + ":" + column.to_string()
}

///|
fn repl_print_multiple_matches(
  symbol : String,
  matches : Array[ReplSymbolMatch],
  print_line : (String) -> Unit,
) -> Unit {
  print_line("multiple matches for " + symbol + ":")
  for item in matches {
    let entry = item.entry
    print_line(
      "  " +
      @frontend.symbol_kind_name(entry.kind) +
      " " +
      entry.name +
      " : " +
      entry.signature +
      " @ " +
      repl_symbol_match_location(item),
    )
  }
}

///|
fn repl_resolve_symbol_matches(
  symbol : String,
  scratch_db_path : String,
  scratch_source : String,
) -> Array[ReplSymbolMatch] {
  let current = repl_collect_current_symbol_matches(
    scratch_db_path,
    scratch_source,
    Some(symbol),
  )
  if current.length() > 0 {
    return current
  }
  match repl_load_workspace_symbol_matches(Some(symbol)) {
    Ok(matches) => matches
    Err(_) => []
  }
}

///|
fn repl_print_outline_entries(
  entries : Array[ReplSymbolMatch],
  print_line : (String) -> Unit,
) -> Unit {
  for item in entries {
    let entry = item.entry
    print_line(
      @frontend.symbol_kind_name(entry.kind) +
      "\t" +
      entry.name +
      "\t" +
      repl_symbol_match_location(item) +
      "\t" +
      entry.signature,
    )
  }
}

///|
fn repl_symbol_match_to_json(
  item : ReplSymbolMatch,
  include_snippet? : Bool = false,
) -> Json {
  let entry = item.entry
  let (line, column) = symbol_line_col(item.source, entry.span)
  let obj : Map[String, Json] = {}
  obj["name"] = Json::string(entry.name)
  obj["kind"] = Json::string(@frontend.symbol_kind_name(entry.kind))
  obj["signature"] = Json::string(entry.signature)
  obj["path"] = Json::string(entry.path)
  obj["line"] = Json::number(line.to_double())
  obj["column"] = Json::number(column.to_double())
  obj["location"] = Json::string(repl_symbol_match_location(item))
  if include_snippet {
    obj["snippet"] = Json::string(
      symbol_line_text(item.source, entry.span).trim().to_string(),
    )
  }
  Json::object(obj)
}

///|
fn repl_symbol_matches_to_json(
  matches : Array[ReplSymbolMatch],
  include_snippet? : Bool = false,
) -> Json {
  let items : Array[Json] = []
  for item in matches {
    items.push(repl_symbol_match_to_json(item, include_snippet~))
  }
  Json::array(items)
}

///|
fn repl_vibe_error_json(command : String, message : String) -> Json {
  let obj : Map[String, Json] = {}
  obj["ok"] = Json::boolean(false)
  obj["command"] = Json::string(command)
  obj["error"] = Json::string(message)
  Json::object(obj)
}

///|
fn repl_parse_vibe_shell_invocation(line : String) -> VibeShellInvocation? {
  let trimmed = line.trim().to_string()
  if trimmed.length() == 0 {
    return None
  }
  let (head, pipeline_tail) = repl_split_first_pipeline(trimmed)
  let tokens = repl_split_words(head.trim().to_string())
  if tokens.length() == 0 {
    return None
  }
  let (subcommand, args_start) = if tokens[0] == "vibe" {
    if tokens.length() == 1 {
      return Some({ subcommand: "help", args: [], pipeline_tail })
    }
    (tokens[1], 2)
  } else {
    if not(repl_is_vibe_shell_subcommand(tokens[0])) {
      return None
    }
    (tokens[0], 1)
  }
  Some({ subcommand, args: args_tail(tokens, args_start), pipeline_tail })
}

///|
fn repl_vibe_symbols_json(
  rt : @runtime.Runtime,
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
) -> Json {
  let opts = match repl_parse_symbols_options(args) {
    Ok(v) => v
    Err(err) => return repl_vibe_error_json("symbols", err)
  }
  let selected_scopes = repl_symbols_selected_scopes(opts)
  let rows : Array[ReplSymbolsRow] = []
  let local_rows = if opts.include_local {
    repl_collect_local_symbols_rows(rt, scratch_db_path, scratch_source)
  } else {
    []
  }
  for row in local_rows {
    rows.push(row)
  }
  let local_names = repl_symbols_local_name_set(local_rows)
  if opts.include_builtin {
    for row in repl_collect_builtin_symbols_rows(rt, local_names) {
      rows.push(row)
    }
  }
  if opts.include_shell {
    for row in repl_collect_shell_symbols_rows() {
      rows.push(row)
    }
  }
  let items : Array[Json] = []
  for row in rows {
    items.push(repl_symbols_row_to_json(row))
  }
  let scopes_json : Array[Json] = []
  for scope in selected_scopes {
    scopes_json.push(Json::string(scope))
  }
  let obj : Map[String, Json] = {}
  obj["ok"] = Json::boolean(true)
  obj["command"] = Json::string("symbols")
  obj["scopes"] = Json::array(scopes_json)
  obj["items"] = Json::array(items)
  Json::object(obj)
}

///|
fn repl_vibe_outline_json(
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
) -> Json {
  if args.length() > 1 {
    return repl_vibe_error_json("outline", "usage: vibe outline [target]")
  }
  if args.length() == 0 {
    let current = repl_collect_current_symbol_matches(
      scratch_db_path,
      scratch_source,
      None,
    )
    let scope = if current.length() > 0 { "current" } else { "workspace" }
    let items = if current.length() > 0 {
      current
    } else {
      match repl_load_workspace_symbol_matches(None) {
        Ok(matches) => matches
        Err(_) => []
      }
    }
    let obj : Map[String, Json] = {}
    obj["ok"] = Json::boolean(true)
    obj["command"] = Json::string("outline")
    obj["scope"] = Json::string(scope)
    obj["items"] = repl_symbol_matches_to_json(items)
    return Json::object(obj)
  }
  let target = args[0]
  let entry_path = if target == "." || target == "project" {
    repl_workspace_entry_path()
  } else {
    @loader.resolve_entry_path(target)
  }
  match @loader.load_db_with_paths(entry_path) {
    Ok((db, entry, paths)) => {
      let index = @runtime.build_symbol_index(db, paths)
      let items = repl_collect_symbol_matches_from_entries(db, index.entries)
      let obj : Map[String, Json] = {}
      obj["ok"] = Json::boolean(true)
      obj["command"] = Json::string("outline")
      obj["scope"] = Json::string("target")
      obj["target"] = Json::string(entry)
      obj["items"] = repl_symbol_matches_to_json(items)
      Json::object(obj)
    }
    Err(err) => repl_vibe_error_json("outline", err)
  }
}

///|
fn repl_vibe_view_json(
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
) -> Json {
  if args.length() != 1 {
    return repl_vibe_error_json("view", "usage: vibe view <symbol>")
  }
  let symbol = args[0]
  let matches = repl_resolve_symbol_matches(
    symbol, scratch_db_path, scratch_source,
  )
  if matches.length() == 0 {
    return repl_vibe_error_json("view", "symbol not found: " + symbol)
  }
  let obj : Map[String, Json] = {}
  obj["command"] = Json::string("view")
  if matches.length() > 1 {
    obj["ok"] = Json::boolean(false)
    obj["error"] = Json::string("multiple matches")
    obj["query"] = Json::string(symbol)
    obj["candidates"] = repl_symbol_matches_to_json(matches)
  } else {
    obj["ok"] = Json::boolean(true)
    obj["item"] = repl_symbol_match_to_json(matches[0])
  }
  Json::object(obj)
}

///|
fn repl_vibe_peek_json(
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
) -> Json {
  if args.length() != 1 {
    return repl_vibe_error_json("peek", "usage: vibe peek <symbol>")
  }
  let symbol = args[0]
  let matches = repl_resolve_symbol_matches(
    symbol, scratch_db_path, scratch_source,
  )
  if matches.length() == 0 {
    return repl_vibe_error_json("peek", "symbol not found: " + symbol)
  }
  let obj : Map[String, Json] = {}
  obj["command"] = Json::string("peek")
  if matches.length() > 1 {
    obj["ok"] = Json::boolean(false)
    obj["error"] = Json::string("multiple matches")
    obj["query"] = Json::string(symbol)
    obj["candidates"] = repl_symbol_matches_to_json(
      matches,
      include_snippet=true,
    )
  } else {
    obj["ok"] = Json::boolean(true)
    obj["item"] = repl_symbol_match_to_json(matches[0], include_snippet=true)
  }
  Json::object(obj)
}

///|
fn repl_vibe_type_json(
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
) -> Json {
  if args.length() != 1 {
    return repl_vibe_error_json("type", "usage: vibe type <symbol>")
  }
  let symbol = args[0]
  let matches = repl_resolve_symbol_matches(
    symbol, scratch_db_path, scratch_source,
  )
  if matches.length() == 0 {
    return repl_vibe_error_json("type", "symbol not found: " + symbol)
  }
  let obj : Map[String, Json] = {}
  obj["command"] = Json::string("type")
  obj["query"] = Json::string(symbol)
  if matches.length() > 1 {
    obj["ok"] = Json::boolean(false)
    obj["error"] = Json::string("multiple matches")
    obj["candidates"] = repl_symbol_matches_to_json(matches)
  } else {
    let entry = matches[0].entry
    obj["ok"] = Json::boolean(true)
    obj["signature"] = Json::string(entry.signature)
    obj["item"] = repl_symbol_match_to_json(matches[0])
  }
  Json::object(obj)
}

///|
fn repl_vibe_normalize_json(
  args : Array[String],
  scratch_source : String,
) -> Json {
  let mut target = "scratch"
  let mut source = scratch_source
  let entry_names : Array[String] = []
  if args.length() > 0 {
    let first_arg = args[0]
    let first_path = @loader.resolve_entry_path(first_arg)
    let first_exists = @os_fs.path_exists(first_path)
    let first_is_file_like = first_arg == "." ||
      first_arg.has_prefix("./") ||
      first_arg.has_prefix("../") ||
      first_arg.has_prefix("/") ||
      first_arg.has_suffix(".vibe") ||
      first_arg.has_suffix(".mbt")
    let first_as_file = first_exists || first_is_file_like
    if first_as_file {
      target = first_path
      source = @os_fs.read_file_to_string(first_path) catch {
        e =>
          return repl_vibe_error_json(
            "normalize",
            "read failed: " + e.to_string(),
          )
      }
      for i in 1..<args.length() {
        entry_names.push(args[i])
      }
    } else {
      for arg in args {
        entry_names.push(arg)
      }
    }
  }
  let selected_entries : Array[String] = []
  let seen_entries : Map[String, Bool] = {}
  for name in entry_names {
    let trimmed = name.trim().to_string()
    if trimmed.length() == 0 || seen_entries.contains(trimmed) {
      continue
    }
    seen_entries[trimmed] = true
    selected_entries.push(trimmed)
  }
  if args.length() > 0 && selected_entries.length() == 0 && target == "scratch" {
    return repl_vibe_error_json(
      "normalize", "usage: vibe normalize [file] [entry ...] or normalize [entry ...]",
    )
  }
  if target != "scratch" &&
    args.length() == 1 &&
    source.trim().to_string().length() == 0 {
    return repl_vibe_error_json("normalize", "source is empty")
  }
  if source.trim().to_string().length() == 0 {
    return repl_vibe_error_json("normalize", "source is empty")
  }
  let normalized_result = if selected_entries.length() == 0 {
    normalize_source_text_for_shell(source)
  } else {
    normalize_source_text_with_entry_names_for_shell(source, selected_entries)
  }
  match normalized_result {
    Ok(normalized) => {
      let obj : Map[String, Json] = {}
      obj["ok"] = Json::boolean(true)
      obj["command"] = Json::string("normalize")
      obj["target"] = Json::string(target)
      let entries : Array[Json] = []
      for name in selected_entries {
        entries.push(Json::string(name))
      }
      obj["entries"] = Json::array(entries)
      obj["normalized"] = Json::string(normalized)
      Json::object(obj)
    }
    Err(err) => repl_vibe_error_json("normalize", err)
  }
}

///|
fn repl_vibe_help_json() -> Json {
  let commands : Array[Json] = []
  commands.push(
    Json::string(
      "symbols [--local|--builtin|--shell|--all|--scope <local,builtin,shell,all>]",
    ),
  )
  commands.push(Json::string("outline [target]"))
  commands.push(Json::string("view <symbol>"))
  commands.push(Json::string("peek <symbol>"))
  commands.push(Json::string("type <symbol>"))
  commands.push(
    Json::string("normalize [file] [entry ...] | normalize [entry ...]"),
  )
  commands.push(Json::string("vibe symbols"))
  commands.push(Json::string("vibe outline [target]"))
  commands.push(Json::string("vibe view <symbol>"))
  commands.push(Json::string("vibe peek <symbol>"))
  commands.push(Json::string("vibe type <symbol>"))
  commands.push(
    Json::string(
      "vibe normalize [file] [entry ...] | vibe normalize [entry ...]",
    ),
  )
  let obj : Map[String, Json] = {}
  obj["ok"] = Json::boolean(true)
  obj["command"] = Json::string("help")
  obj["commands"] = Json::array(commands)
  Json::object(obj)
}

///|
fn repl_vibe_subcommand_json(
  rt : @runtime.Runtime,
  invocation : VibeShellInvocation,
  scratch_db_path : String,
  scratch_source : String,
) -> Json {
  match invocation.subcommand {
    "help" => repl_vibe_help_json()
    "symbols" =>
      repl_vibe_symbols_json(
        rt,
        invocation.args,
        scratch_db_path,
        scratch_source,
      )
    "outline" =>
      repl_vibe_outline_json(invocation.args, scratch_db_path, scratch_source)
    "view" =>
      repl_vibe_view_json(invocation.args, scratch_db_path, scratch_source)
    "peek" =>
      repl_vibe_peek_json(invocation.args, scratch_db_path, scratch_source)
    "type" =>
      repl_vibe_type_json(invocation.args, scratch_db_path, scratch_source)
    "normalize" => repl_vibe_normalize_json(invocation.args, scratch_source)
    other => repl_vibe_error_json("vibe", "unknown subcommand: " + other)
  }
}

///|
fn repl_strip_vibe_json_flag(args : Array[String]) -> (Array[String], Bool) {
  let out : Array[String] = []
  let mut output_json = false
  for arg in args {
    if arg == "--json" {
      output_json = true
    } else {
      out.push(arg)
    }
  }
  (out, output_json)
}

///|
fn repl_json_string_or(
  obj : Map[String, Json],
  key : String,
  fallback : String,
) -> String {
  match obj.get(key) {
    Some(Json::String(value)) => value
    _ => fallback
  }
}

///|
fn repl_json_bool_or(
  obj : Map[String, Json],
  key : String,
  fallback : Bool,
) -> Bool {
  match obj.get(key) {
    Some(Json::True) => true
    Some(Json::False) => false
    _ => fallback
  }
}

///|
fn repl_json_array_or_empty(
  obj : Map[String, Json],
  key : String,
) -> Array[Json] {
  match obj.get(key) {
    Some(Json::Array(items)) => items
    _ => []
  }
}

///|
fn repl_json_string_array_or_empty(
  obj : Map[String, Json],
  key : String,
) -> Array[String] {
  let out : Array[String] = []
  for item in repl_json_array_or_empty(obj, key) {
    match item {
      Json::String(value) => out.push(value)
      _ => ()
    }
  }
  out
}

///|
fn repl_markdown_table_cell(value : String) -> String {
  let buf = StringBuilder::new()
  for ch in value {
    match ch {
      '\n' => buf.write_string("\\n")
      '\r' => ()
      '|' => buf.write_string("\\|")
      _ => buf.write_char(ch)
    }
  }
  let out = buf.to_string()
  if out.length() == 0 {
    "-"
  } else {
    out
  }
}

///|
fn repl_symbols_scope_title(scope : String) -> String {
  match scope {
    "local" => "local scope"
    "builtin" => "builtin scope"
    "shell" => "shell commands"
    _ => scope + " scope"
  }
}

///|
fn repl_symbols_items_for_scope(
  items : Array[Json],
  scope : String,
) -> Array[Json] {
  let out : Array[Json] = []
  for item in items {
    match item {
      Json::Object(obj) => {
        let row_scope = repl_json_string_or(obj, "scope", "")
        if row_scope == scope {
          out.push(item)
        }
      }
      _ => ()
    }
  }
  out
}

///|
fn repl_symbol_address_cell(obj : Map[String, Json]) -> String {
  let short_addr = repl_json_string_or(obj, "short_address", "")
  if short_addr.length() > 0 {
    return short_addr
  }
  let addr = repl_json_string_or(obj, "address", "")
  if addr.length() == 0 {
    "-"
  } else {
    short_hash(addr)
  }
}

///|
fn repl_print_symbols_scope_table(
  scope : String,
  items : Array[Json],
  print_line : (String) -> Unit,
) -> Unit {
  print_line(
    repl_symbols_scope_title(scope) + " (" + items.length().to_string() + ")",
  )
  print_line("| kind | name | signature | address |")
  print_line("| --- | --- | --- | --- |")
  if items.length() == 0 {
    print_line("| - | - | - | - |")
    return
  }
  for item in items {
    match item {
      Json::Object(obj) => {
        let kind = repl_markdown_table_cell(
          repl_json_string_or(obj, "kind", "?"),
        )
        let name = repl_markdown_table_cell(
          repl_json_string_or(obj, "name", "?"),
        )
        let signature = repl_markdown_table_cell(
          repl_json_string_or(obj, "signature", "_"),
        )
        let address = repl_markdown_table_cell(repl_symbol_address_cell(obj))
        print_line(
          "| " +
          kind +
          " | " +
          name +
          " | " +
          signature +
          " | " +
          address +
          " |",
        )
      }
      _ => ()
    }
  }
}

///|
fn repl_print_multiline_text(
  text : String,
  print_line : (String) -> Unit,
) -> Unit {
  for part in text.split("\n") {
    print_line(part.to_string())
  }
}

///|
fn repl_print_symbol_item_json(
  item : Json,
  print_line : (String) -> Unit,
  include_snippet? : Bool = false,
) -> Unit {
  match item {
    Json::Object(obj) => {
      let kind = repl_json_string_or(obj, "kind", "?")
      let name = repl_json_string_or(obj, "name", "?")
      let signature = repl_json_string_or(obj, "signature", "_")
      let location = repl_json_string_or(obj, "location", "?")
      print_line(kind + "\t" + name + "\t" + signature + "\t" + location)
      if include_snippet {
        let snippet = repl_json_string_or(obj, "snippet", "")
        if snippet.length() > 0 {
          print_line("  " + snippet)
        }
      }
    }
    _ => ()
  }
}

///|
fn repl_print_vibe_payload_human(
  payload : Json,
  print_line : (String) -> Unit,
) -> Unit {
  match payload {
    Json::Object(obj) => {
      let command = repl_json_string_or(obj, "command", "vibe")
      let ok = repl_json_bool_or(obj, "ok", true)
      if not(ok) {
        let err = repl_json_string_or(obj, "error", "unknown error")
        if err == "multiple matches" {
          let query = repl_json_string_or(obj, "query", "?")
          let candidates = repl_json_array_or_empty(obj, "candidates")
          print_line("multiple matches for " + query + ":")
          for candidate in candidates {
            repl_print_symbol_item_json(
              candidate,
              print_line,
              include_snippet=command == "peek",
            )
          }
          return
        }
        print_line("error: " + err)
        return
      }
      match command {
        "help" => {
          print_line("vibe commands:")
          for item in repl_json_array_or_empty(obj, "commands") {
            match item {
              Json::String(line) => print_line("  " + line)
              _ => ()
            }
          }
        }
        "symbols" => {
          let scopes = repl_json_string_array_or_empty(obj, "scopes")
          let items = repl_json_array_or_empty(obj, "items")
          if scopes.length() == 0 {
            print_line("symbols: (no scopes selected)")
            return
          }
          let mut printed = false
          for scope in scopes {
            if printed {
              print_line("")
            }
            printed = true
            let scoped_items = repl_symbols_items_for_scope(items, scope)
            repl_print_symbols_scope_table(scope, scoped_items, print_line)
          }
        }
        "outline" => {
          let scope = repl_json_string_or(obj, "scope", "")
          let target = repl_json_string_or(obj, "target", "")
          let items = repl_json_array_or_empty(obj, "items")
          if target.length() > 0 {
            print_line(
              "outline: " + target + " (" + items.length().to_string() + ")",
            )
          } else if scope.length() > 0 {
            print_line(
              "outline: " + scope + " (" + items.length().to_string() + ")",
            )
          } else {
            print_line("outline: " + items.length().to_string())
          }
          if items.length() == 0 {
            print_line("(no symbols)")
            return
          }
          for item in items {
            repl_print_symbol_item_json(item, print_line)
          }
        }
        "view" =>
          match obj.get("item") {
            Some(item) => repl_print_symbol_item_json(item, print_line)
            None => print_line("error: missing symbol item")
          }
        "peek" =>
          match obj.get("item") {
            Some(item) =>
              repl_print_symbol_item_json(
                item,
                print_line,
                include_snippet=true,
              )
            None => print_line("error: missing symbol item")
          }
        "type" => {
          let query = repl_json_string_or(obj, "query", "?")
          let signature = repl_json_string_or(obj, "signature", "_")
          print_line(query + " : " + signature)
        }
        "normalize" => {
          let target = repl_json_string_or(obj, "target", "scratch")
          print_line("normalize: " + target)
          let normalized = repl_json_string_or(obj, "normalized", "")
          repl_print_multiline_text(normalized, print_line)
        }
        _ => print_line(payload.stringify())
      }
    }
    _ => print_line(payload.stringify())
  }
}

///|
fn handle_repl_vibe_shell_command(
  rt : @runtime.Runtime,
  _syntax_mode : @runtime.ParserMode,
  line : String,
  scratch_db_path : String,
  scratch_source : String,
  print_line : (String) -> Unit,
) -> ReplMetaCommandResult {
  let parsed_invocation = match repl_parse_vibe_shell_invocation(line) {
    Some(v) => v
    None => return ReplMetaCommandResult::NotMeta
  }
  let (subcommand_args, output_json) = repl_strip_vibe_json_flag(
    parsed_invocation.args,
  )
  let invocation : VibeShellInvocation = {
    subcommand: parsed_invocation.subcommand,
    args: subcommand_args,
    pipeline_tail: parsed_invocation.pipeline_tail,
  }
  let payload = repl_vibe_subcommand_json(
    rt, invocation, scratch_db_path, scratch_source,
  )
  let payload_text = payload.stringify()
  match invocation.pipeline_tail {
    None => {
      if output_json {
        print_line(payload_text)
      } else {
        repl_print_vibe_payload_human(payload, print_line)
      }
      ReplMetaCommandResult::HandledContinue
    }
    Some(_) => {
      print_line(
        "error: shell pipeline transforms were removed from compiled shell; use --json and external tools",
      )
      ReplMetaCommandResult::HandledContinue
    }
  }
}

///|
fn repl_handle_view_meta_command(
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
  print_line : (String) -> Unit,
) -> ReplMetaCommandResult {
  if args.length() != 1 {
    print_line("usage: :view <symbol>")
    return ReplMetaCommandResult::HandledContinue
  }
  let symbol = args[0]
  let matches = repl_resolve_symbol_matches(
    symbol, scratch_db_path, scratch_source,
  )
  if matches.length() == 0 {
    print_line("symbol not found: " + symbol)
    return ReplMetaCommandResult::HandledContinue
  }
  if matches.length() > 1 {
    repl_print_multiple_matches(symbol, matches, print_line)
    return ReplMetaCommandResult::HandledContinue
  }
  let item = matches[0]
  print_line(item.entry.name + " : " + item.entry.signature)
  print_line("at " + repl_symbol_match_location(item))
  ReplMetaCommandResult::HandledContinue
}

///|
fn repl_handle_type_meta_command(
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
  print_line : (String) -> Unit,
) -> ReplMetaCommandResult {
  if args.length() != 1 {
    print_line("usage: :type <symbol>")
    return ReplMetaCommandResult::HandledContinue
  }
  let symbol = args[0]
  let matches = repl_resolve_symbol_matches(
    symbol, scratch_db_path, scratch_source,
  )
  if matches.length() == 0 {
    print_line("symbol not found: " + symbol)
    return ReplMetaCommandResult::HandledContinue
  }
  if matches.length() > 1 {
    repl_print_multiple_matches(symbol, matches, print_line)
    return ReplMetaCommandResult::HandledContinue
  }
  let item = matches[0]
  print_line(item.entry.name + " : " + item.entry.signature)
  ReplMetaCommandResult::HandledContinue
}

///|
fn repl_handle_peek_meta_command(
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
  print_line : (String) -> Unit,
) -> ReplMetaCommandResult {
  if args.length() != 1 {
    print_line("usage: :peek <symbol>")
    return ReplMetaCommandResult::HandledContinue
  }
  let symbol = args[0]
  let matches = repl_resolve_symbol_matches(
    symbol, scratch_db_path, scratch_source,
  )
  if matches.length() == 0 {
    print_line("symbol not found: " + symbol)
    return ReplMetaCommandResult::HandledContinue
  }
  if matches.length() > 1 {
    repl_print_multiple_matches(symbol, matches, print_line)
    return ReplMetaCommandResult::HandledContinue
  }
  let item = matches[0]
  let entry = item.entry
  print_line(
    @frontend.symbol_kind_name(entry.kind) +
    " " +
    entry.name +
    " : " +
    entry.signature,
  )
  print_line("at " + repl_symbol_match_location(item))
  let snippet = symbol_line_text(item.source, entry.span).trim().to_string()
  if snippet.length() > 0 {
    print_line(snippet)
  }
  ReplMetaCommandResult::HandledContinue
}

///|
fn repl_handle_outline_meta_command(
  args : Array[String],
  scratch_db_path : String,
  scratch_source : String,
  print_line : (String) -> Unit,
) -> ReplMetaCommandResult {
  if args.length() > 1 {
    print_line("usage: :outline [target]")
    return ReplMetaCommandResult::HandledContinue
  }
  if args.length() == 0 {
    let current = repl_collect_current_symbol_matches(
      scratch_db_path,
      scratch_source,
      None,
    )
    if current.length() > 0 {
      print_line("outline: current")
      repl_print_outline_entries(current, print_line)
      return ReplMetaCommandResult::HandledContinue
    }
    match repl_load_workspace_symbol_matches(None) {
      Ok(workspace) =>
        if workspace.length() == 0 {
          print_line("no symbols found in current module or workspace")
          ReplMetaCommandResult::HandledContinue
        } else {
          print_line("outline: workspace")
          repl_print_outline_entries(workspace, print_line)
          ReplMetaCommandResult::HandledContinue
        }
      Err(err) => {
        print_line("outline: " + err)
        ReplMetaCommandResult::HandledContinue
      }
    }
  } else {
    let target = args[0]
    let entry_path = if target == "." || target == "project" {
      repl_workspace_entry_path()
    } else {
      @loader.resolve_entry_path(target)
    }
    match @loader.load_db_with_paths(entry_path) {
      Ok((db, entry, paths)) => {
        let index = @runtime.build_symbol_index(db, paths)
        let items = repl_collect_symbol_matches_from_entries(db, index.entries)
        if items.length() == 0 {
          print_line("no symbols found in " + entry)
        } else {
          print_line("outline: " + entry)
          repl_print_outline_entries(items, print_line)
        }
        ReplMetaCommandResult::HandledContinue
      }
      Err(err) => {
        print_line("outline: " + err)
        ReplMetaCommandResult::HandledContinue
      }
    }
  }
}

///|
fn handle_repl_meta_command(
  line : String,
  scratch_db_path : String,
  scratch_source : String,
  print_line : (String) -> Unit,
) -> ReplMetaCommandResult {
  let trimmed = line.trim().to_string()
  if trimmed.length() == 0 {
    return ReplMetaCommandResult::NotMeta
  }
  match trimmed {
    ":q" | ":quit" | ":exit" | "exit" =>
      return ReplMetaCommandResult::HandledExit
    _ => ()
  }
  if not(trimmed.has_prefix(":")) {
    return ReplMetaCommandResult::NotMeta
  }
  let parts = repl_split_words(trimmed)
  if parts.length() == 0 {
    return ReplMetaCommandResult::HandledContinue
  }
  let cmd = parts[0]
  let cmd_args = args_tail(parts, 1)
  match cmd {
    ":view" =>
      repl_handle_view_meta_command(
        cmd_args, scratch_db_path, scratch_source, print_line,
      )
    ":outline" =>
      repl_handle_outline_meta_command(
        cmd_args, scratch_db_path, scratch_source, print_line,
      )
    ":type" =>
      repl_handle_type_meta_command(
        cmd_args, scratch_db_path, scratch_source, print_line,
      )
    ":peek" =>
      repl_handle_peek_meta_command(
        cmd_args, scratch_db_path, scratch_source, print_line,
      )
    ":save" => {
      if cmd_args.length() == 0 {
        print_line("usage: :save <filename.vibe>")
        return ReplMetaCommandResult::HandledContinue
      }
      let path = cmd_args[0]
      if scratch_source.trim().to_string().length() == 0 {
        print_line("nothing to save (empty session)")
        return ReplMetaCommandResult::HandledContinue
      }
      // DAG-aware save: deduplicate same-name let bindings (keep last)
      let deduped = repl_deduplicate_bindings(scratch_source)
      @os_fs.write_string_to_file(path, deduped) catch {
        e => {
          print_line("save failed: " + e.to_string())
          return ReplMetaCommandResult::HandledContinue
        }
      }
      let mut binding_count = 0
      for line_view in deduped.split("\n") {
        let l = line_view.to_string().trim().to_string()
        if l.has_prefix("let ") || l.has_prefix("export let ") {
          binding_count += 1
        }
      }
      print_line(
        "saved: " +
        path +
        " (" +
        binding_count.to_string() +
        " bindings, deduplicated)",
      )
      ReplMetaCommandResult::HandledContinue
    }
    ":load" => {
      if cmd_args.length() == 0 {
        print_line("usage: :load <filename.vibe>")
        return ReplMetaCommandResult::HandledContinue
      }
      let path = cmd_args[0]
      let content = @os_fs.read_file_to_string(path) catch {
        e => {
          print_line("load failed: " + e.to_string())
          return ReplMetaCommandResult::HandledContinue
        }
      }
      print_line(
        "loaded: " + path + " (" + content.length().to_string() + " bytes)",
      )
      ReplMetaCommandResult::HandledLoadSource(content)
    }
    ":clear" => {
      print_line("session cleared")
      ReplMetaCommandResult::HandledLoadSource("")
    }
    ":source" => {
      if scratch_source.trim().to_string().length() == 0 {
        print_line("(empty session)")
      } else {
        print_line(scratch_source)
      }
      ReplMetaCommandResult::HandledContinue
    }
    ":help" => {
      print_line("Available commands:")
      print_line("  :help            Show this help message")
      print_line("  :q/:quit/:exit   Exit the REPL")
      print_line("  :view <symbol>   View symbol definition")
      print_line("  :outline [target] Show symbol outline")
      print_line("  :peek <symbol>   Peek at symbol definition")
      print_line("  :type <symbol>   Show type of expression")
      print_line("  :save <file>     Save session to file")
      print_line("  :load <file>     Load session from file")
      print_line("  :clear           Clear session state")
      print_line("  :source          Show source of current session")
      ReplMetaCommandResult::HandledContinue
    }
    _ => {
      print_line("unknown command: " + cmd)
      ReplMetaCommandResult::HandledContinue
    }
  }
}

///|
let history_max_lines : Int = 10000

///|
fn get_history_file_path() -> String {
  match @sys.get_env_var("HOME") {
    Some(home) => home + "/.vibe_history"
    None => ".vibe_history"
  }
}

///|
fn load_history(target : Array[String]) -> Unit {
  let path = get_history_file_path()
  if not(@os_fs.path_exists(path)) {
    return
  }
  let content = @os_fs.read_file_to_string(path) catch { _ => return }
  if content.length() == 0 {
    return
  }
  let lines = content.split("\n")
  for line in lines {
    let trimmed = line.to_string()
    if trimmed.length() > 0 {
      target.push(trimmed)
    }
  }
}

///|
fn append_history(line : String) -> Unit {
  let path = get_history_file_path()
  // Read existing, append, trim to max
  let existing = @os_fs.read_file_to_string(path) catch { _ => "" }
  let lines : Array[String] = []
  if existing.length() > 0 {
    for part in existing.split("\n") {
      let s = part.to_string()
      if s.length() > 0 {
        lines.push(s)
      }
    }
  }
  // Dedup: remove previous occurrence of same line
  let deduped : Array[String] = []
  for item in lines {
    if item != line {
      deduped.push(item)
    }
  }
  deduped.push(line)
  // Trim to max
  let start = if deduped.length() > history_max_lines {
    deduped.length() - history_max_lines
  } else {
    0
  }
  let buf = StringBuilder::new()
  for i in start..<deduped.length() {
    buf.write_string(deduped[i])
    buf.write_char('\n')
  }
  @os_fs.write_string_to_file(path, buf.to_string()) catch {
    _ => ()
  }
}

///|
fn repl_tui_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let restore_namespace = match args {
    ["--restore"] => true
    [] => false
    _ => abort("shell --tui: unknown arg " + args[0])
  }
  let rt = new_cli_runtime(features, enable_llm~)
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  let restored_source = match
    resolve_repl_initial_source(scratch_db_path, restore_namespace) {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  let cache = CliEntryDbCache::new()
  let compiled_source_path = compiled_repl_temp_source_path()
  let compiled_wasm_path = compiled_repl_temp_wasm_path()
  defer remove_file_if_exists(compiled_source_path)
  defer remove_file_if_exists(compiled_wasm_path)
  let (initial_cols, initial_rows) = @tui.get_terminal_size()
  let (app, cleanup) = @tui.init_vnode_terminal(
    initial_cols, initial_rows, @tui.print_raw,
  )
  let width = Ref::new(initial_cols)
  let height = Ref::new(initial_rows)
  let outputs : Array[String] = []
  let history : Array[String] = []
  load_history(history)
  let vibe_names : Array[String] = @checker.prelude_names()
  let history_idx = Ref::new(-1)
  let history_draft = Ref::new("")
  let completion_session = @editor.CompletionSession::new()
  let completion_request_id : Ref[Int] = Ref::new(0)
  let last_popup_rect : Ref[OverlayRect?] = Ref::new(None)
  let completion_anchor : Ref[CompletionAnchor?] = Ref::new(None)
  let cleaned = Ref::new(false)
  fn cleanup_once() -> Unit {
    if cleaned.val {
      return
    }
    cleaned.val = true
    cleanup()
  }

  let input_rows = Ref::new(repl_input_rows_for_height(initial_rows))
  let input_editor = @editor.EditorState::new_with_kind(
    "",
    input_rows.val,
    @editor.HighlightKind::Plain,
  )
  let scratch_source_ref = Ref::new(restored_source)
  fn set_input_text(text : String) -> Unit {
    input_editor.set_text("")
    if text.length() > 0 {
      input_editor.replace_selection(text)
    }
  }

  fn push_unique(list : Array[String], value : String) -> Unit {
    for existing in list {
      if existing == value {
        return
      }
    }
    list.push(value)
  }

  fn collect_shell_commands() -> Array[String] {
    let out : Array[String] = []
    match @sys.get_env_var("PATH") {
      None => ()
      Some(path) =>
        for dir_view in path.split(":") {
          let dir = dir_view.to_string()
          let entries = @os_fs.read_dir(dir) catch { _ => [] }
          for name in entries {
            let full_path = dir + "/" + name
            let is_file = @os_fs.is_file(full_path) catch { _ => false }
            if is_file {
              push_unique(out, name)
            }
          }
        }
    }
    out
  }

  let shell_commands = collect_shell_commands()
  let repl_meta_commands = repl_meta_command_names()
  let vibe_builtins = ["sh", "path", "addr", "exit"]
  let vibe_keywords = [
    "let", "rec", "if", "match", "record", "test", "import", "true", "false",
  ]
  fn completion_visible() -> Bool {
    completion_session.is_visible() &&
    completion_session.get_items().length() > 0
  }

  fn current_view_state() -> ReplViewState {
    {
      width: width.val,
      height: height.val,
      input_rows: input_rows.val,
      outputs,
      history_len: history.length(),
    }
  }

  fn clear_rect(rect : OverlayRect) -> Unit {
    if rect.width <= 0 || rect.height <= 0 {
      return
    }
    let blank = " ".repeat(rect.width)
    for i = 0; i < rect.height; i = i + 1 {
      @tui.print_raw(@render.ansi_move_to(rect.row + i, rect.col) + blank)
    }
  }

  fn pad_to_width(text : String, width : Int) -> String {
    if width <= 0 {
      ""
    } else {
      let w = @core.string_display_width(text)
      if w >= width {
        text
      } else {
        text + " ".repeat(width - w)
      }
    }
  }

  fn completion_overlay(
    view : ReplViewState,
  ) -> (String?, OverlayRect?, CompletionAnchor?) {
    if not(completion_visible()) {
      return (None, None, None)
    }
    let items = completion_session.get_items()
    if items.length() == 0 {
      return (None, None, None)
    }
    let view_width = if view.width > 1 { view.width } else { 1 }
    let content_start = editor_content_start_col(input_editor)
    let screen_col = if content_start < view_width { content_start } else { 0 }
    let content_width = view_width - screen_col
    if content_width <= 1 {
      return (None, None, None)
    }
    let max_rows = 8
    let selected = completion_session.get_selected_index()
    let mut max_label_width = 0
    for item in items {
      let w = @core.string_display_width(item.label)
      if w > max_label_width {
        max_label_width = w
      }
    }
    let base_width = max_label_width + 1
    let cell_width = if base_width > content_width {
      content_width
    } else {
      base_width
    }
    if cell_width <= 0 {
      return (None, None, None)
    }
    let col_gap = 2
    let total_cell = cell_width + col_gap
    let cols = if total_cell <= content_width {
      let count = (content_width + col_gap) / total_cell
      if count > 0 {
        count
      } else {
        1
      }
    } else {
      1
    }
    let total_rows = (items.length() + cols - 1) / cols
    let preferred_rows = if total_rows > max_rows {
      max_rows
    } else {
      total_rows
    }
    if preferred_rows <= 0 {
      return (None, None, None)
    }
    let input_origin = repl_input_origin_row(view)
    let anchor_row = input_origin + view.input_rows - 1
    let available_below = view.height - footer_rows() - (anchor_row + 1)
    let available_above = anchor_row - header_rows()
    let anchor = pick_completion_anchor(
      completion_anchor.val,
      available_above,
      available_below,
    )
    let mut screen_row = 0
    let mut visible_rows = 0
    let mut chosen_anchor : CompletionAnchor? = None
    match anchor {
      Some(CompletionAnchor::Below) => {
        let v = if preferred_rows > available_below {
          available_below
        } else {
          preferred_rows
        }
        screen_row = anchor_row + 1
        visible_rows = v
        chosen_anchor = Some(CompletionAnchor::Below)
      }
      Some(CompletionAnchor::Above) => {
        let v = if preferred_rows > available_above {
          available_above
        } else {
          preferred_rows
        }
        screen_row = anchor_row - v
        visible_rows = v
        chosen_anchor = Some(CompletionAnchor::Above)
      }
      None => return (None, None, None)
    }
    if visible_rows <= 0 {
      return (None, None, None)
    }
    let selected_row = if selected >= 0 { selected / cols } else { 0 }
    let start_row = if total_rows <= visible_rows {
      0
    } else {
      let half = visible_rows / 2
      let s = selected_row - half
      if s < 0 {
        0
      } else if s + visible_rows > total_rows {
        total_rows - visible_rows
      } else {
        s
      }
    }
    let row_nodes : Array[@tui.TuiNode] = []
    let mut r = 0
    while r < visible_rows {
      let row_idx = start_row + r
      let cells : Array[@tui.TuiNode] = []
      let mut c = 0
      while c < cols {
        let idx = row_idx * cols + c
        let is_selected = idx == selected
        if idx < items.length() {
          let prefix = if is_selected { ">" } else { " " }
          let cell_text = pad_to_width(
            truncate_text(prefix + items[idx].label, cell_width),
            cell_width,
          )
          let fg = if is_selected { "white" } else { "rgb(170,170,170)" }
          cells.push(@tui.text(cell_text, fg~, bold=is_selected))
        } else {
          cells.push(@tui.text(" ".repeat(cell_width)))
        }
        if c < cols - 1 {
          cells.push(@tui.text(" ".repeat(col_gap), fg="rgb(90,90,90)"))
        }
        c += 1
      }
      row_nodes.push(@tui.row(cells))
      r += 1
    }
    let node = @tui.column(row_nodes)
    let overlay = @vnode.render_overlay_at(screen_col, screen_row, node)
    let rect : OverlayRect = {
      row: screen_row,
      col: screen_col,
      width: content_width,
      height: visible_rows,
    }
    (Some(overlay), Some(rect), chosen_anchor)
  }

  fn do_render() -> Unit {
    let view = current_view_state()
    let (overlay, next_rect, next_anchor) = completion_overlay(view)
    let mut need_clear = false
    match (last_popup_rect.val, next_rect) {
      (Some(prev), Some(next)) =>
        if not(prev.eq(next)) {
          clear_rect(prev)
          need_clear = true
        }
      (Some(prev), None) => {
        clear_rect(prev)
        need_clear = true
      }
      _ => ()
    }
    if need_clear {
      app.clear_prev_buffer()
    }
    @tui.print_raw(app.render_frame(render_repl_view(view, input_editor)))
    match overlay {
      Some(overlay_text) => @tui.print_raw(overlay_text)
      None => ()
    }
    last_popup_rect.val = next_rect
    completion_anchor.val = next_anchor
    let (cursor_row, cursor_col) = repl_cursor_pos(view, input_editor)
    @tui.print_raw(
      @render.ansi_move_to(cursor_row, cursor_col) + @render.ansi_show_cursor(),
    )
  }

  fn push_output_line(line : String) -> Unit {
    // Split multi-line strings into separate output entries
    for part in line.split("\n") {
      outputs.push(part.to_string())
    }
  }

  fn run_command(cmd : String) -> Bool {
    let trimmed = cmd.trim().to_string()
    if trimmed.length() == 0 {
      return true
    }
    push_output_line("> " + trimmed)
    match
      handle_repl_meta_command(
        trimmed,
        scratch_db_path,
        scratch_source_ref.val,
        push_output_line,
      ) {
      ReplMetaCommandResult::HandledExit => return false
      ReplMetaCommandResult::HandledLoadSource(_) => return false
      ReplMetaCommandResult::HandledContinue => return true
      ReplMetaCommandResult::NotMeta => ()
    }
    match
      handle_repl_vibe_shell_command(
        rt,
        syntax_mode,
        trimmed,
        scratch_db_path,
        scratch_source_ref.val,
        push_output_line,
      ) {
      ReplMetaCommandResult::HandledExit => return false
      ReplMetaCommandResult::HandledLoadSource(_) => return false
      ReplMetaCommandResult::HandledContinue => return true
      ReplMetaCommandResult::NotMeta => ()
    }
    let next_source = run_compiled_shell_line(
      cache,
      rt,
      syntax_mode,
      scratch_db_path,
      compiled_source_path,
      compiled_wasm_path,
      scratch_source_ref.val,
      trimmed,
      print_line=push_output_line,
    )
    if next_source != scratch_source_ref.val {
      scratch_source_ref.val = next_source
      match extract_let_name(trimmed) {
        Some(name) => push_unique(vibe_names, name)
        None => ()
      }
    }
    true
  }

  fn update_completion() -> Unit {
    let next_id = completion_request_id.val + 1
    completion_request_id.val = next_id
    let req = input_editor.completion_request(next_id)
    if is_in_fn_param_context(req.line_text, req.col) {
      completion_session.clear()
      return
    }
    let context = detect_completion_context(req.line_text, req.col)
    let method_info = detect_method_completion(req.line_text, req.col)
    let pipe_info = detect_pipe_completion(req.line_text, req.col)
    let prefix = match method_info {
      Some(info) => info.prefix
      None =>
        match pipe_info {
          Some(info) => info.prefix
          None => req.prefix
        }
    }
    let receiver_name = match method_info {
      Some(info) => Some(info.receiver)
      None =>
        match pipe_info {
          Some(info) => Some(info.receiver)
          None => None
        }
    }
    let env = rt.type_env()
    let receiver_ty = match receiver_name {
      Some(name) => env.get(name)
      None => None
    }
    fn accepts_receiver(name : String) -> Bool {
      match receiver_ty {
        None => true
        Some(rty) =>
          match env.get(name) {
            Some(@vibe_core.Type::Func(params~, ..)) => {
              let mut found = false
              let mut ok = false
              for param in params {
                if @vibe_core.ParamLabel::is_positional(param.label) {
                  found = true
                  ok = @checker.completion_param_matches(env, rty, param.ty)
                  break
                }
              }
              found && ok
            }
            _ => false
          }
      }
    }

    let method_like = method_info is Some(_) || pipe_info is Some(_)
    if prefix.length() == 0 && not(method_like) {
      completion_session.clear()
      return
    }
    completion_session.set_request(req)
    let items : Array[String] = []
    match context {
      CompletionContext::Shell => {
        let mut idx = history.length() - 1
        while idx >= 0 {
          let entry = history[idx]
          if entry.has_prefix(prefix) {
            push_unique(items, entry)
          }
          idx -= 1
        }
        for item in shell_commands {
          if item.has_prefix(prefix) {
            push_unique(items, item)
          }
        }
        for item in repl_meta_commands {
          if item.has_prefix(prefix) {
            push_unique(items, item)
          }
        }
      }
      CompletionContext::VibeLetName =>
        for name in vibe_names {
          if name.has_prefix(prefix) {
            push_unique(items, name)
          }
        }
      CompletionContext::VibeLetExpr | CompletionContext::VibeExpr => {
        if not(method_like) {
          for item in vibe_keywords {
            if item.has_prefix(prefix) {
              push_unique(items, item)
            }
          }
        }
        for item in vibe_builtins {
          if item.has_prefix(prefix) && accepts_receiver(item) {
            push_unique(items, item)
          }
        }
        for name in vibe_names {
          if name.has_prefix(prefix) && accepts_receiver(name) {
            push_unique(items, name)
          }
        }
      }
    }
    let response : @editor.CompletionResponse = {
      id: req.id,
      items: items.map(fn(item) {
        let insert_text = match method_info {
          Some(info) =>
            if req.prefix.contains(".") {
              info.receiver + "." + item
            } else {
              item
            }
          None => item
        }
        @editor.CompletionItem::{
          label: item,
          insert_text,
          detail: None,
          documentation: None,
        }
      }),
      is_incomplete: false,
    }
    let _ = completion_session.apply_response(response)
    if items.length() == 1 && items[0] == req.prefix {
      completion_session.hide()
    }
  }

  fn apply_completion() -> Bool {
    match completion_session.get_selected_item() {
      Some(item) => {
        input_editor.replace_current_word(item.insert_text)
        update_completion()
        true
      }
      None => false
    }
  }

  fn set_history_entry(idx : Int) -> Unit {
    let pos = history.length() - 1 - idx
    let value = history[pos]
    set_input_text(value)
  }

  fn history_prev() -> Unit {
    if history.length() == 0 {
      return
    }
    if history_idx.val == -1 {
      history_draft.val = input_editor.get_text()
    }
    if history_idx.val + 1 < history.length() {
      history_idx.val = history_idx.val + 1
      set_history_entry(history_idx.val)
    }
  }

  fn history_next() -> Unit {
    if history_idx.val <= 0 {
      if history_idx.val == 0 {
        history_idx.val = -1
        set_input_text(history_draft.val)
      }
      return
    }
    history_idx.val = history_idx.val - 1
    set_history_entry(history_idx.val)
  }

  fn handle_resize(new_width : Int, new_height : Int) -> Unit {
    width.val = new_width
    height.val = new_height
    app.resize(new_width, new_height)
    let next_rows = repl_input_rows_for_height(new_height)
    if next_rows != input_rows.val {
      input_rows.val = next_rows
      input_editor.set_height(next_rows)
    }
    do_render()
  }

  fn handle_key(input : String) -> Unit {
    if input.length() == 0 {
      return
    }
    if input.length() > 1 &&
      input[0].to_int() != 0x1b &&
      @tui.is_printable_string(input) {
      input_editor.replace_selection(input)
      history_idx.val = -1
      update_completion()
      do_render()
      return
    }
    let event = @tui.parse_input(input)
    if event.is_ctrl_c() {
      cleanup_once()
      return
    }
    match event {
      @tui.InputEvent::Resize(new_width, new_height) => {
        handle_resize(new_width, new_height)
        return
      }
      @tui.InputEvent::Key(key_event) => {
        let mut should_update_completion = false
        match key_event {
          @tui.KeyEvent::Special(@tui.SpecialKey::Up, _) =>
            if completion_visible() {
              completion_session.select_prev()
              do_render()
              return
            } else {
              history_prev()
              update_completion()
              do_render()
              return
            }
          @tui.KeyEvent::Special(@tui.SpecialKey::Down, _) =>
            if completion_visible() {
              completion_session.select_next()
              do_render()
              return
            } else {
              history_next()
              update_completion()
              do_render()
              return
            }
          @tui.KeyEvent::Special(@tui.SpecialKey::Tab, _) => {
            if completion_visible() {
              if apply_completion() {
                do_render()
                return
              }
            } else {
              update_completion()
            }
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::BackTab, _) => {
            if completion_visible() {
              completion_session.select_prev()
            }
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Enter, _) => {
            if completion_visible() && apply_completion() {
              do_render()
              return
            }
            let ok = run_command(input_editor.get_text())
            if !ok {
              cleanup_once()
              return
            }
            let input_value = input_editor.get_text().trim().to_string()
            if input_value.length() > 0 {
              history.push(input_value)
              append_history(input_value)
            }
            set_input_text("")
            history_idx.val = -1
            update_completion()
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Escape, _) => {
            completion_session.hide()
            do_render()
            return
          }
          @tui.KeyEvent::Special(@tui.SpecialKey::Backspace, _) =>
            should_update_completion = true
          @tui.KeyEvent::Char(_, @tui.KeyModifier::None)
          | @tui.KeyEvent::Char(_, @tui.KeyModifier::Shift) =>
            should_update_completion = true
          _ => ()
        }
        @editor.handle_key_event(input_editor, key_event)
        if should_update_completion {
          update_completion()
        }
        history_idx.val = -1
        do_render()
      }
      _ => ()
    }
  }

  do_render()
  push_output_line("namespace: " + namespace_name + " db=" + scratch_db_path)
  do_render()
  @tui.start_keypress_listener(handle_key)
  cleanup_once()
}

///|
fn repl_stdin_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  run_compiled_line_repl_with_prompt(
    args,
    "shell-stdin",
    "vibe> ",
    syntax_mode,
    features,
    enable_llm~,
  )
}

///|
fn resolve_repl_initial_source(
  scratch_db_path : String,
  restore_namespace : Bool,
) -> Result[String, String] {
  if restore_namespace {
    load_eval_db_source(scratch_db_path)
  } else {
    Ok("")
  }
}

///|
fn print_line_repl_tty_mode(mode : LineReplIoMode) -> Unit {
  match mode {
    LineReplIoMode::Tty =>
      println(
        "note: --tty mode is enabled (line backend; PTY is not enabled yet)",
      )
    LineReplIoMode::Plain => ()
  }
}

///|
struct CompiledReplExec {
  next_source : String
  value : WasmRunValue
  display_override : String?
  load_us : Int
  compile_us : Int
  exec_us : Int
  total_us : Int
  module_us : Int
  bundle_us : Int
  emit_us : Int
  optimize_us : Int
} derive(Show, Eq)

///|
fn compiled_repl_temp_source_path() -> String {
  "/tmp/vibe-compiled-repl-" + vibe_getpid().to_string() + ".vibe"
}

///|
fn compiled_repl_temp_wasm_path() -> String {
  "/tmp/vibe-compiled-repl-" + vibe_getpid().to_string() + ".wasm"
}

///|
fn repl_raw_output_text(text : String) -> String {
  let out = StringBuilder::new()
  let mut wrote = false
  for part in text.split("\n") {
    out.write_string("\r\n")
    out.write_string(part.to_string())
    wrote = true
  }
  if wrote {
    out.write_string("\r\n")
  }
  out.to_string()
}

///|
fn repl_print_wasm_run_value(
  value : WasmRunValue,
  print_line : (String) -> Unit,
) -> Unit {
  match value {
    WasmRunValue::Int(n) => print_line("last: " + n.to_string())
    WasmRunValue::Bool(b) => print_line("last: " + b.to_string())
  }
}

///|
fn repl_compiled_zero_result_line(line : String) -> Bool {
  let trimmed = line.trim().to_string()
  trimmed.has_prefix("fn ") ||
  trimmed.has_prefix("enum ") ||
  trimmed.has_prefix("struct ") ||
  trimmed.has_prefix("trait ") ||
  trimmed.has_prefix("impl ") ||
  trimmed.has_prefix("type ") ||
  trimmed.has_prefix("suberror ") ||
  trimmed.has_prefix("extern ") ||
  trimmed.has_prefix("import ") ||
  trimmed.has_prefix("export {")
}

///|
fn repl_compiled_result_expr(line : String) -> String {
  match extract_let_name(line) {
    Some(name) => name
    None => if repl_compiled_zero_result_line(line) { "0" } else { line }
  }
}

///|
fn repl_compiled_binding_rhs(line : String) -> String? {
  let chars = line.to_array()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '=' {
      return Some(
        line.unsafe_substring(start=i + 1, end=line.length()).trim().to_string(),
      )
    }
    i += 1
  }
  None
}

///|
fn repl_compiled_binding_display_override(line : String) -> String? {
  match extract_let_name(line) {
    Some(name) =>
      match repl_compiled_binding_rhs(line) {
        Some(rhs) =>
          if rhs.has_prefix("(") && rhs.contains("{") {
            Some("<fn " + name + ">")
          } else {
            Some("<bound " + name + ">")
          }
        None => Some("<bound " + name + ">")
      }
    None => None
  }
}

///|
let repl_node_display_runner_source : String =
  #|const fs = require("node:fs/promises");
  #|const decoder = new TextDecoder();
  #|
  #|function fail(message, code = 1) {
  #|  console.error(message);
  #|  process.exit(code);
  #|}
  #|
  #|async function main() {
  #|  const wasmPath = process.argv[2];
  #|  if (!wasmPath) {
  #|    fail("usage: wasm_repl_string_runner.js <wasm-path>", 2);
  #|  }
  #|  const bytes = await fs.readFile(wasmPath);
  #|  let memory = null;
  #|  const ignoreFdWrite = (fd, iovsPtr, iovsLen, nwrittenPtr) => {
  #|    if (!memory) {
  #|      return 1;
  #|    }
  #|    const view = new DataView(memory.buffer);
  #|    let written = 0;
  #|    for (let i = 0; i < iovsLen; i += 1) {
  #|      const base = iovsPtr + i * 8;
  #|      written += view.getUint32(base + 4, true);
  #|    }
  #|    view.setUint32(nwrittenPtr, written, true);
  #|    return 0;
  #|  };
  #|  let instance;
  #|  try {
  #|    ({ instance } = await WebAssembly.instantiate(bytes, {
  #|      wasi_snapshot_preview1: {
  #|        fd_write: ignoreFdWrite,
  #|      },
  #|    }));
  #|  } catch (error) {
  #|    fail(String(error && error.message ? error.message : error));
  #|  }
  #|  const exports = instance.exports;
  #|  memory = exports.memory;
  #|  if (!(memory instanceof WebAssembly.Memory)) {
  #|    fail("missing memory export");
  #|  }
  #|  const invoke =
  #|    typeof exports.run === "function"
  #|      ? exports.run
  #|      : typeof exports._start === "function"
  #|      ? exports._start
  #|      : null;
  #|  if (typeof invoke !== "function") {
  #|    fail("missing run or _start export");
  #|  }
  #|  let tagged;
  #|  try {
  #|    tagged = invoke.length === 0 ? invoke() : invoke(0n);
  #|  } catch (error) {
  #|    fail(String(error && error.message ? error.message : error));
  #|  }
  #|  if (typeof tagged !== "bigint") {
  #|    fail("run export did not return i64");
  #|  }
  #|  const readBytes = (ptr, len) => {
  #|    if (ptr < 0 || len < 0 || ptr + len > memory.buffer.byteLength) {
  #|      return null;
  #|    }
  #|    return new Uint8Array(memory.buffer, ptr, len);
  #|  };
  #|  const readTagged32 = (offset) => {
  #|    const view = new DataView(memory.buffer);
  #|    return BigInt.asIntN(32, BigInt(view.getUint32(offset, true)));
  #|  };
  #|  const readStringBytes = (ptr, seen = new Set()) => {
  #|    if (seen.has(ptr)) {
  #|      return null;
  #|    }
  #|    seen.add(ptr);
  #|    if (ptr < 0 || ptr + 8 > memory.buffer.byteLength) {
  #|      return null;
  #|    }
  #|    const view = new DataView(memory.buffer);
  #|    const ty = view.getUint32(ptr, true);
  #|    if (ty === 1) {
  #|      const len = view.getUint32(ptr + 4, true);
  #|      return readBytes(ptr + 8, len);
  #|    }
  #|    if (ty === 11) {
  #|      const sourcePtr = view.getUint32(ptr + 4, true);
  #|      const start = view.getUint32(ptr + 8, true);
  #|      const end = view.getUint32(ptr + 12, true);
  #|      if (end < start) {
  #|        return null;
  #|      }
  #|      const sourceBytes = readStringBytes(sourcePtr, seen);
  #|      if (!sourceBytes || end > sourceBytes.length) {
  #|        return null;
  #|      }
  #|      return sourceBytes.slice(start, end);
  #|    }
  #|    return null;
  #|  };
  #|  const decodeString = (ptr) => {
  #|    const bytesView = readStringBytes(ptr);
  #|    if (!bytesView) {
  #|      return null;
  #|    }
  #|    return decoder.decode(bytesView);
  #|  };
  #|  const renderTagged = (value, seen = new Set()) => {
  #|    const tag = Number(value & 3n);
  #|    if (tag === 0) {
  #|      return String(value >> 2n);
  #|    }
  #|    if (tag === 3) {
  #|      return value >> 2n !== 0n ? "true" : "false";
  #|    }
  #|    const ptr = Number(value & ~3n);
  #|    if (seen.has(ptr)) {
  #|      return "<cycle>";
  #|    }
  #|    const nextSeen = new Set(seen);
  #|    nextSeen.add(ptr);
  #|    if (ptr < 0 || ptr + 8 > memory.buffer.byteLength) {
  #|      return null;
  #|    }
  #|    const view = new DataView(memory.buffer);
  #|    const ty = view.getUint32(ptr, true);
  #|    if (ty === 1 || ty === 11) {
  #|      const text = decodeString(ptr);
  #|      return text == null ? null : JSON.stringify(text);
  #|    }
  #|    if (ty === 5) {
  #|      const len = view.getUint32(ptr + 4, true);
  #|      const items = [];
  #|      for (let i = 0; i < len; i += 1) {
  #|        const rendered = renderTagged(
  #|          readTagged32(ptr + 8 + i * 4),
  #|          nextSeen,
  #|        );
  #|        if (rendered == null) {
  #|          return null;
  #|        }
  #|        items.push(rendered);
  #|      }
  #|      return `[${items.join(", ")}]`;
  #|    }
  #|    if (ty === 12) {
  #|      const sourcePtr = view.getUint32(ptr + 4, true);
  #|      const start = view.getUint32(ptr + 8, true);
  #|      const end = view.getUint32(ptr + 12, true);
  #|      if (end < start) {
  #|        return null;
  #|      }
  #|      const items = [];
  #|      for (let i = start; i < end; i += 1) {
  #|        const rendered = renderTagged(
  #|          readTagged32(sourcePtr + 8 + i * 4),
  #|          nextSeen,
  #|        );
  #|        if (rendered == null) {
  #|          return null;
  #|        }
  #|        items.push(rendered);
  #|      }
  #|      return `[${items.join(", ")}]`;
  #|    }
  #|    if (ty === 6) {
  #|      const len = view.getUint32(ptr + 4, true);
  #|      const entries = [];
  #|      for (let i = 0; i < len; i += 1) {
  #|        const keyPtr = view.getUint32(ptr + 8 + i * 8, true);
  #|        const keyText = decodeString(keyPtr);
  #|        const rendered = renderTagged(
  #|          readTagged32(ptr + 12 + i * 8),
  #|          nextSeen,
  #|        );
  #|        if (keyText == null || rendered == null) {
  #|          return null;
  #|        }
  #|        entries.push(`${JSON.stringify(keyText)}: ${rendered}`);
  #|      }
  #|      return `{|${entries.join(", ")}|}`;
  #|    }
  #|    if (ty === 9) {
  #|      const f64Buf = new Float64Array(memory.buffer, ptr + 4, 1);
  #|      return String(f64Buf[0]);
  #|    }
  #|    if (ty === 10) {
  #|      const ctorTag = view.getUint32(ptr + 4, true);
  #|      const objSize = (() => {
  #|        let off = ptr + 8;
  #|        while (off + 4 <= memory.buffer.byteLength) {
  #|          const v = view.getUint32(off, true);
  #|          if (v === 0 && off > ptr + 8) break;
  #|          off += 4;
  #|          if (off > ptr + 64) break;
  #|        }
  #|        return off - ptr;
  #|      })();
  #|      const nargs = (objSize - 8) / 4;
  #|      if (nargs === 0) {
  #|        return `Ctor(${ctorTag})`;
  #|      }
  #|      const args = [];
  #|      for (let i = 0; i < nargs; i++) {
  #|        const argTagged = readTagged32(ptr + 8 + i * 4);
  #|        const rendered = renderTagged(argTagged, nextSeen);
  #|        if (rendered == null) return `Ctor(${ctorTag}, ?)`;
  #|        args.push(rendered);
  #|      }
  #|      return `Ctor(${ctorTag}, ${args.join(", ")})`;
  #|    }
  #|    if (ty === 3) {
  #|      const len = view.getUint32(ptr + 4, true);
  #|      const items = [];
  #|      for (let i = 0; i < len; i++) {
  #|        const rendered = renderTagged(readTagged32(ptr + 8 + i * 4), nextSeen);
  #|        if (rendered == null) return null;
  #|        items.push(rendered);
  #|      }
  #|      return `(${items.join(", ")})`;
  #|    }
  #|    if (ty === 4) {
  #|      const nfields = view.getUint32(ptr + 4, true);
  #|      const entries = [];
  #|      for (let i = 0; i < nfields; i++) {
  #|        const keyPtr = view.getUint32(ptr + 8 + i * 8, true);
  #|        const keyText = decodeString(keyPtr);
  #|        const val = renderTagged(readTagged32(ptr + 12 + i * 8), nextSeen);
  #|        if (keyText == null || val == null) return null;
  #|        entries.push(`${keyText}: ${val}`);
  #|      }
  #|      return `{ ${entries.join(", ")} }`;
  #|    }
  #|    return null;
  #|  };
  #|  const rendered = renderTagged(tagged);
  #|  if (rendered == null) {
  #|    process.exit(2);
  #|  }
  #|  process.stdout.write(rendered);
  #|}
  #|
  #|main().catch((error) => {
  #|  fail(String(error && error.message ? error.message : error));
  #|});

///|
fn repl_node_display_runner_path() -> String {
  "/tmp/vibe-repl-display-runner.js"
}

///|
fn ensure_repl_node_display_runner() -> Result[String, String] {
  let path = repl_node_display_runner_path()
  @os_fs.write_string_to_file(path, repl_node_display_runner_source) catch {
    e => return Err("failed to write node display runner: " + e.to_string())
  }
  Ok(path)
}

///|
fn repl_try_compiled_display(wasm_path : String) -> String? {
  let node_bin = match find_command_in_path("node") {
    Some(path) => path
    None => return None
  }
  let runner_path = match ensure_repl_node_display_runner() {
    Ok(path) => path
    Err(_) => return None
  }
  let out_path = wasm_path + ".display.out"
  let err_path = wasm_path + ".display.err"
  defer remove_file_if_exists(out_path)
  defer remove_file_if_exists(err_path)
  let cmd = shell_quote_command_arg(node_bin) +
    " " +
    shell_quote_command_arg(runner_path) +
    " " +
    shell_quote_command_arg(wasm_path) +
    " >" +
    shell_quote_command_arg(out_path) +
    " 2>" +
    shell_quote_command_arg(err_path)
  let status = c_system(system_command_bytes(cmd))
  if status != 0 {
    return None
  }
  let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
  let display = stdout.trim().to_string()
  if display.length() == 0 {
    None
  } else {
    Some(display)
  }
}

///|
fn repl_build_compiled_source(scratch_source : String, line : String) -> String {
  let buf = StringBuilder::new()
  let base = append_eval_db_source(scratch_source, line)
  buf.write_string(base)
  if not(base.has_suffix("\n")) {
    buf.write_string("\n")
  }
  let result_expr = repl_compiled_result_expr(line)
  if result_expr != line {
    buf.write_string(result_expr)
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
fn run_compiled_repl_line_with_cache(
  cache : CliEntryDbCache,
  source_path : String,
  wasm_path : String,
  scratch_source : String,
  line : String,
) -> Result[CompiledReplExec, String] {
  let source = repl_build_compiled_source(scratch_source, line)
  let total_start = @bench.monotonic_clock_start()
  let load_start = @bench.monotonic_clock_start()
  let (db, entry) = match
    load_compiled_test_case_db_with_cache(cache, source_path, source) {
    Ok(v) => v
    Err(err) => return Err("load error: " + err)
  }
  let load_us = @bench.monotonic_clock_end(load_start).to_int()
  let ast = db.ast(entry)
  let detect_ast = @runtime.bundle_for_wasm_no_dce(db, entry, ast)
  let use_fs_host = module_uses_wasm_runtime_fallback_builtins(detect_ast)
  let use_http_host = module_uses_http_builtins(detect_ast)
  let use_node_runner = use_fs_host || use_http_host
  let runner = match resolve_bench_wasm_runner(entry) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let compile_start = @bench.monotonic_clock_start()
  let (wasm_bytes, profile) = @runtime_compile.compile_module_wasm_with_opt_level_profiled(
    db,
    entry,
    no_dce=true,
    debug_errors=true,
    http_host_imports=use_node_runner,
    fs_host_imports=use_node_runner,
  ) catch {
    err => return Err("compile wasm error: " + err.user_message())
  }
  let compile_us = @bench.monotonic_clock_end(compile_start).to_int()
  @os_fs.write_bytes_to_file(wasm_path, wasm_bytes) catch {
    e => return Err("write wasm failed: " + e.to_string())
  }
  let exec_start = @bench.monotonic_clock_start()
  let run_out = if use_node_runner {
    match resolve_http_host_runner(source_path) {
      Ok(http_runner) =>
        run_http_host_invoke_run_capture(
          http_runner,
          wasm_path,
          wasm_path + ".invoke",
        )
      Err(_) =>
        run_wasmtime_invoke_run_capture(
          runner,
          wasm_path,
          wasm_path + ".invoke",
        )
    }
  } else {
    run_wasmtime_invoke_run_capture(runner, wasm_path, wasm_path + ".invoke")
  }
  let exec_us = @bench.monotonic_clock_end(exec_start).to_int()
  if run_out.status != 0 {
    return Err(wasmtime_failure_detail(run_out.stdout, run_out.stderr))
  }
  // Check for VIBE_DISPLAY: prefix from Node runner (string/complex values)
  let node_display = extract_vibe_display_line(run_out.stdout)
  let tagged = match parse_last_numeric_line_int64(run_out.stdout) {
    Some(v) => v
    None =>
      return Err(
        "compiled repl output missing numeric result: " +
        first_non_empty_line(run_out.stdout),
      )
  }
  let (value, display_override) = match node_display {
    Some(display) => (WasmRunValue::Int(0L), Some(display))
    None =>
      match decode_tagged_wasm_run_value(tagged) {
        Some(v) => (v, None)
        None =>
          match repl_try_compiled_display(wasm_path) {
            Some(display) => (WasmRunValue::Int(0L), Some(display))
            None =>
              match repl_compiled_binding_display_override(line) {
                Some(display) => (WasmRunValue::Int(0L), Some(display))
                None =>
                  return Err(
                    "compiled repl unsupported wasm return tag: " +
                    tagged.to_string(),
                  )
              }
          }
      }
  }
  let total_us = @bench.monotonic_clock_end(total_start).to_int()
  Ok({
    next_source: append_eval_db_source(scratch_source, line),
    value,
    display_override,
    load_us,
    compile_us,
    exec_us,
    total_us,
    module_us: profile.module_us,
    bundle_us: profile.bundle_us,
    emit_us: profile.emit_us,
    optimize_us: profile.optimize_us,
  })
}

///|
fn run_compiled_shell_line(
  cache : CliEntryDbCache,
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
  scratch_db_path : String,
  source_path : String,
  wasm_path : String,
  scratch_source : String,
  line_str : String,
  print_line? : (String) -> Unit = fn(s) { println(s) },
) -> String {
  match
    handle_repl_meta_command(
      line_str, scratch_db_path, scratch_source, print_line,
    ) {
    ReplMetaCommandResult::HandledExit => return scratch_source
    ReplMetaCommandResult::HandledContinue => return scratch_source
    ReplMetaCommandResult::HandledLoadSource(new_source) => return new_source
    ReplMetaCommandResult::NotMeta => ()
  }
  match
    handle_repl_vibe_shell_command(
      rt, syntax_mode, line_str, scratch_db_path, scratch_source, print_line,
    ) {
    ReplMetaCommandResult::HandledExit => return scratch_source
    ReplMetaCommandResult::HandledContinue => return scratch_source
    ReplMetaCommandResult::HandledLoadSource(_) => return scratch_source
    ReplMetaCommandResult::NotMeta => ()
  }
  // Preprocess posix-style input when in PosixMode
  let effective_line = match syntax_mode {
    @runtime.ParserMode::PosixMode | @runtime.ParserMode::PosixStrictMode =>
      @runtime.preprocess_posix_source(line_str)
    @runtime.ParserMode::VibeMode => line_str
  }
  // Handle sh_lines directly in REPL (bypass WASM compilation)
  if effective_line.has_prefix("sh_lines(\"") &&
    effective_line.has_suffix("\")") {
    let cmd = effective_line[10:effective_line.length() - 2].to_string()
    let cmd_unescaped = cmd
      .replace(old="\\\\", new="\\")
      .replace(old="\\\"", new="\"")
    let out_path = "/tmp/vibe-shell-cmd-" + @env.now().to_string() + ".out"
    let err_path = out_path + ".err"
    let shell_cmd = cmd_unescaped +
      " >" +
      shell_quote_command_arg(out_path) +
      " 2>" +
      shell_quote_command_arg(err_path)
    let status = c_system(system_command_bytes(shell_cmd))
    let stdout = @os_fs.read_file_to_string(out_path) catch { _ => "" }
    let stderr = @os_fs.read_file_to_string(err_path) catch { _ => "" }
    remove_file_if_exists(out_path)
    remove_file_if_exists(err_path)
    if status != 0 && stderr.length() > 0 {
      print_line("error: " + stderr.trim().to_string())
    } else if stdout.trim().to_string().length() > 0 {
      print_line(stdout.trim().to_string())
    }
    return scratch_source
  }
  let exec = match
    run_compiled_repl_line_with_cache(
      cache, source_path, wasm_path, scratch_source, effective_line,
    ) {
    Ok(v) => v
    Err(err) => {
      print_line("error: " + err)
      return scratch_source
    }
  }
  match exec.display_override {
    Some(display) => print_line("last: " + display)
    None => repl_print_wasm_run_value(exec.value, print_line)
  }
  let next_source = exec.next_source
  match write_eval_db_source(scratch_db_path, next_source) {
    Ok(_) => ()
    Err(err) => {
      print_line("error: failed to persist namespace db: " + err)
      return scratch_source
    }
  }
  match extract_let_name(line_str) {
    Some(name) => repl_warn_reserved_shell_binding(name, print_line)
    None => ()
  }
  next_source
}

///|
fn run_compiled_line_repl_with_prompt(
  args : Array[String],
  cmd_name : String,
  prompt : String,
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let options = match parse_line_repl_options(args, cmd_name, prompt) {
    Ok(opts) => opts
    Err(msg) =>
      if msg.has_prefix("usage: ") {
        println(msg)
        return
      } else {
        abort(msg)
      }
  }
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort(cmd_name + ": " + err)
  }
  async fn repl_loop() {
    let rt = new_cli_runtime(features, enable_llm~)
    let cache = CliEntryDbCache::new()
    let source_path = compiled_repl_temp_source_path()
    let wasm_path = compiled_repl_temp_wasm_path()
    defer remove_file_if_exists(source_path)
    defer remove_file_if_exists(wasm_path)
    let mut scratch_source = match
      resolve_repl_initial_source(scratch_db_path, options.restore_namespace) {
      Ok(v) => v
      Err(err) => {
        println("error: " + err)
        return
      }
    }
    let input = @stdio.stdin
    print_line_repl_tty_mode(options.io_mode)
    println("namespace: " + namespace_name + " db=" + scratch_db_path)
    if options.prompt_enabled {
      @stdio.stdout.write(options.prompt)
    }
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim()
      if trimmed.is_empty() {
        if options.prompt_enabled {
          @stdio.stdout.write(options.prompt)
        }
        continue
      }
      let line_str = trimmed.to_string()
      if not(handle_cd_builtin(rt, line_str, fn(s) { println(s) })) {
        scratch_source = run_compiled_shell_line(
          cache, rt, syntax_mode, scratch_db_path, source_path, wasm_path, scratch_source,
          line_str,
        )
      }
      if options.prompt_enabled {
        @stdio.stdout.write(options.prompt)
      }
    }
  }
  @async.run_async_main(repl_loop)
}

///|
/// WASM REPL: compile each expression to WASM and output to file
fn wasm_repl_stdin_cmd(args : Array[String]) -> Unit {
  let mut prompt_enabled = true
  let mut out_dir = "/tmp"
  let mut profile_enabled = false
  let mut counter = 0
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      "-o" | "--out-dir" => {
        if i + 1 >= args.length() {
          abort("wasm-shell-stdin: missing output directory after " + arg)
        }
        out_dir = args[i + 1]
        i += 2
      }
      "--profile" => {
        profile_enabled = true
        i += 1
      }
      _ => abort("wasm-shell-stdin: unknown arg " + arg)
    }
  }
  // Ensure output directory exists
  if not(@os_fs.path_exists(out_dir)) {
    @os_fs.create_dir(out_dir) catch {
      e =>
        abort("wasm-shell-stdin: failed to create output dir: " + e.to_string())
    }
  }
  async fn repl_loop() {
    let prompt = "wasm> "
    let input = @stdio.stdin
    let cache = CliEntryDbCache::new()
    let source_path = @io.current_dir_or_root() +
      "/.vibe_compiled_repl_" +
      vibe_getpid().to_string() +
      ".vibe"
    let mut scratch_source = ""
    defer remove_file_if_exists(source_path)
    if prompt_enabled {
      @stdio.stdout.write(prompt)
    }
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim()
      if trimmed.is_empty() {
        if prompt_enabled {
          @stdio.stdout.write(prompt)
        }
        continue
      }
      let line_str = trimmed.to_string()
      match line_str {
        ":q" | ":quit" | ":exit" | "exit" => break
        _ => {
          let out_path = out_dir + "/expr_" + counter.to_string() + ".wasm"
          let exec = match
            run_compiled_repl_line_with_cache(
              cache, source_path, out_path, scratch_source, line_str,
            ) {
            Ok(v) => v
            Err(err) => {
              println("error: " + err)
              if prompt_enabled {
                @stdio.stdout.write(prompt)
              }
              continue
            }
          }
          scratch_source = exec.next_source
          println(
            "wrote " +
            out_path +
            " (" +
            (@os_fs.read_file_to_bytes(out_path) catch { _ => Bytes::new(0) })
            .length()
            .to_string() +
            " bytes)",
          )
          match exec.display_override {
            Some(display) => println("last: " + display)
            None => print_wasm_run_value(exec.value)
          }
          if profile_enabled {
            println(
              "profile(us): total=" +
              exec.total_us.to_string() +
              " load=" +
              exec.load_us.to_string() +
              " compile=" +
              exec.compile_us.to_string() +
              " exec=" +
              exec.exec_us.to_string() +
              " module=" +
              exec.module_us.to_string() +
              " bundle=" +
              exec.bundle_us.to_string() +
              " emit=" +
              exec.emit_us.to_string() +
              " optimize=" +
              exec.optimize_us.to_string(),
            )
          }
          counter += 1
        }
      }
      if prompt_enabled {
        @stdio.stdout.write(prompt)
      }
    }
  }

  @async.run_async_main(repl_loop)
}

///|
fn print_ai_symbols(
  scratch_db_path : String,
  scratch_source : String,
  print_line? : (String) -> Unit = fn(s) { println(s) },
) -> Unit {
  let symbols = collect_eval_scope_symbols(scratch_db_path, scratch_source)
  if symbols.length() > 0 {
    print_line("symbols:")
    for symbol in symbols {
      print_line(
        "  " + symbol.kind + "\t" + symbol.name + "\t" + symbol.signature,
      )
    }
  }
}

///|
fn repl_ai_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let mut prompt_enabled = true
  let mut restore_namespace = false
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      "--restore" => {
        restore_namespace = true
        i += 1
      }
      _ => abort("shell --ai: unknown arg " + args[i])
    }
  }
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort("shell --ai: " + err)
  }
  async fn repl_loop() {
    let rt = new_cli_runtime(features, enable_llm~)
    let cache = CliEntryDbCache::new()
    let source_path = compiled_repl_temp_source_path()
    let wasm_path = compiled_repl_temp_wasm_path()
    defer remove_file_if_exists(source_path)
    defer remove_file_if_exists(wasm_path)
    let mut scratch_source = match
      resolve_repl_initial_source(scratch_db_path, restore_namespace) {
      Ok(v) => v
      Err(err) => {
        println("error: " + err)
        return
      }
    }
    // header
    println("cwd: " + @io.current_dir_or_root())
    println("namespace: " + namespace_name + " db=" + scratch_db_path)
    print_ai_symbols(scratch_db_path, scratch_source)
    let input = @stdio.stdin
    let prompt = "> "
    if prompt_enabled {
      @stdio.stdout.write(prompt)
    }
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim()
      if trimmed.is_empty() {
        if prompt_enabled {
          @stdio.stdout.write(prompt)
        }
        continue
      }
      let line_str = trimmed.to_string()
      match
        handle_repl_meta_command(line_str, scratch_db_path, scratch_source, fn(
          s,
        ) {
          println(s)
        }) {
        ReplMetaCommandResult::HandledExit => break
        ReplMetaCommandResult::HandledLoadSource(_) => break
        ReplMetaCommandResult::HandledContinue => {
          if prompt_enabled {
            @stdio.stdout.write(prompt)
          }
          continue
        }
        ReplMetaCommandResult::NotMeta => ()
      }
      match
        handle_repl_vibe_shell_command(
          rt,
          syntax_mode,
          line_str,
          scratch_db_path,
          scratch_source,
          fn(s) { println(s) },
        ) {
        ReplMetaCommandResult::HandledExit => break
        ReplMetaCommandResult::HandledLoadSource(_) => break
        ReplMetaCommandResult::HandledContinue => {
          if prompt_enabled {
            @stdio.stdout.write(prompt)
          }
          continue
        }
        ReplMetaCommandResult::NotMeta => ()
      }
      if handle_cd_builtin(rt, line_str, fn(s) { println(s) }) {
        if prompt_enabled {
          @stdio.stdout.write(prompt)
        }
        continue
      }
      let let_name = extract_let_name(line_str)
      let next_source = run_compiled_shell_line(
        cache, rt, syntax_mode, scratch_db_path, source_path, wasm_path, scratch_source,
        line_str,
      )
      let changed = next_source != scratch_source
      scratch_source = next_source
      if changed && let_name is Some(_) {
        print_ai_symbols(scratch_db_path, scratch_source)
      }
      if prompt_enabled {
        @stdio.stdout.write(prompt)
      }
    }
  }

  @async.run_async_main(repl_loop)
}

///|
fn repl_interactive_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let mut prompt_enabled = true
  let mut restore_namespace = false
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--no-prompt" => {
        prompt_enabled = false
        i += 1
      }
      "--restore" => {
        restore_namespace = true
        i += 1
      }
      _ => abort("shell: unknown arg " + args[i])
    }
  }
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  let rt = new_cli_runtime(features, enable_llm~)
  let scratch_source = match
    resolve_repl_initial_source(scratch_db_path, restore_namespace) {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  // header
  println("cwd: " + @io.current_dir_or_root())
  println("namespace: " + namespace_name + " db=" + scratch_db_path)
  print_ai_symbols(scratch_db_path, scratch_source)
  // Detect TTY for readline-like editing
  let use_raw = @tui_io.is_tty() && prompt_enabled
  if use_raw {
    repl_interactive_raw_loop_compiled(
      rt, syntax_mode, scratch_db_path, scratch_source, prompt_enabled,
    )
  } else {
    repl_interactive_plain_loop_compiled(
      rt, syntax_mode, scratch_db_path, scratch_source, prompt_enabled,
    )
  }
}

///|
fn repl_interactive_plain_loop_compiled(
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
  scratch_db_path : String,
  initial_source : String,
  prompt_enabled : Bool,
) -> Unit {
  async fn repl_loop() {
    let cache = CliEntryDbCache::new()
    let source_path = compiled_repl_temp_source_path()
    let wasm_path = compiled_repl_temp_wasm_path()
    defer remove_file_if_exists(source_path)
    defer remove_file_if_exists(wasm_path)
    let mut scratch_source = initial_source
    let input = @stdio.stdin
    fn get_prompt() -> String {
      @vibe_fs.basename(@io.current_dir_or_root()) + "> "
    }

    if prompt_enabled {
      @stdio.stdout.write(get_prompt())
    }
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim()
      if trimmed.is_empty() {
        if prompt_enabled {
          @stdio.stdout.write(get_prompt())
        }
        continue
      }
      let line_str = trimmed.to_string()
      match line_str {
        ":q" | ":quit" | ":exit" | "exit" => break
        _ =>
          if not(handle_cd_builtin(rt, line_str, fn(s) { println(s) })) {
            scratch_source = run_compiled_shell_line(
              cache, rt, syntax_mode, scratch_db_path, source_path, wasm_path, scratch_source,
              line_str,
            )
          }
      }
      if prompt_enabled {
        @stdio.stdout.write(get_prompt())
      }
    }
  }

  @async.run_async_main(repl_loop)
}

///|
fn repl_interactive_raw_loop_compiled(
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
  scratch_db_path : String,
  initial_source : String,
  prompt_enabled : Bool,
) -> Unit {
  let cache = CliEntryDbCache::new()
  let source_path = compiled_repl_temp_source_path()
  let wasm_path = compiled_repl_temp_wasm_path()
  defer remove_file_if_exists(source_path)
  defer remove_file_if_exists(wasm_path)
  let scratch_source_ref = Ref::new(initial_source)
  let line_buf = StringBuilder::new()
  let cursor_pos = Ref::new(0)
  let history : Array[String] = []
  load_history(history)
  let history_idx = Ref::new(-1)
  let history_draft = Ref::new("")

  fn get_prompt() -> String {
    @vibe_fs.basename(@io.current_dir_or_root()) + "> "
  }

  fn line_buf_to_string() -> String {
    line_buf.to_string()
  }

  fn line_buf_length() -> Int {
    line_buf_to_string().length()
  }

  fn raw_println(s : String) -> Unit {
    @tui.print_raw(repl_raw_output_text(s))
  }

  fn redraw_line() {
    if not(prompt_enabled) {
      return
    }
    let prompt = get_prompt()
    let text = line_buf_to_string()
    @tui.print_raw("\r")
    @tui.print_raw(@render.ansi_clear_line())
    @tui.print_raw(prompt + text)
    let suffix = line_buf_length() - cursor_pos.val
    if suffix > 0 {
      @tui.print_raw(@render.ansi_move_left(n=suffix))
    }
  }

  fn set_line(text : String) {
    line_buf.reset()
    line_buf.write_string(text)
    cursor_pos.val = text.length()
    redraw_line()
  }

  fn insert_char(ch : Char) {
    let text = line_buf_to_string()
    let chars = text.to_array()
    let next = StringBuilder::new()
    let mut idx = 0
    while idx < cursor_pos.val {
      next.write_char(chars[idx])
      idx += 1
    }
    next.write_char(ch)
    while idx < chars.length() {
      next.write_char(chars[idx])
      idx += 1
    }
    line_buf.reset()
    line_buf.write_string(next.to_string())
    cursor_pos.val += 1
    redraw_line()
  }

  fn delete_back() {
    if cursor_pos.val <= 0 {
      return
    }
    let text = line_buf_to_string()
    let chars = text.to_array()
    let next = StringBuilder::new()
    let mut idx = 0
    while idx < chars.length() {
      if idx != cursor_pos.val - 1 {
        next.write_char(chars[idx])
      }
      idx += 1
    }
    line_buf.reset()
    line_buf.write_string(next.to_string())
    cursor_pos.val -= 1
    redraw_line()
  }

  fn delete_forward() {
    if cursor_pos.val >= line_buf_length() {
      return
    }
    let text = line_buf_to_string()
    let chars = text.to_array()
    let next = StringBuilder::new()
    let mut idx = 0
    while idx < chars.length() {
      if idx != cursor_pos.val {
        next.write_char(chars[idx])
      }
      idx += 1
    }
    line_buf.reset()
    line_buf.write_string(next.to_string())
    redraw_line()
  }

  fn move_left() {
    if cursor_pos.val > 0 {
      cursor_pos.val -= 1
      @tui.print_raw(@render.ansi_move_left())
    }
  }

  fn move_right() {
    if cursor_pos.val < line_buf_length() {
      cursor_pos.val += 1
      @tui.print_raw(@render.ansi_move_right())
    }
  }

  fn move_home() {
    if cursor_pos.val > 0 {
      @tui.print_raw(@render.ansi_move_left(n=cursor_pos.val))
      cursor_pos.val = 0
    }
  }

  fn move_end() {
    let len = line_buf_length()
    if cursor_pos.val < len {
      @tui.print_raw(@render.ansi_move_right(n=len - cursor_pos.val))
      cursor_pos.val = len
    }
  }

  fn history_prev() {
    if history.length() == 0 {
      return
    }
    if history_idx.val == -1 {
      history_draft.val = line_buf_to_string()
    }
    if history_idx.val + 1 < history.length() {
      history_idx.val += 1
      let pos = history.length() - 1 - history_idx.val
      set_line(history[pos])
    }
  }

  fn history_next() {
    if history_idx.val <= 0 {
      if history_idx.val == 0 {
        history_idx.val = -1
        set_line(history_draft.val)
      }
      return
    }
    history_idx.val -= 1
    let pos = history.length() - 1 - history_idx.val
    set_line(history[pos])
  }

  fn kill_line() {
    line_buf.reset()
    cursor_pos.val = 0
    redraw_line()
  }

  fn kill_to_end() {
    let text = line_buf_to_string()
    let chars = text.to_array()
    let next = StringBuilder::new()
    let mut idx = 0
    while idx < cursor_pos.val && idx < chars.length() {
      next.write_char(chars[idx])
      idx += 1
    }
    line_buf.reset()
    line_buf.write_string(next.to_string())
    redraw_line()
  }

  let done = Ref::new(false)

  fn submit_line() {
    let text = line_buf_to_string().trim().to_string()
    @tui.print_raw("\r\n")
    line_buf.reset()
    cursor_pos.val = 0
    history_idx.val = -1
    if text.length() == 0 {
      if prompt_enabled {
        @tui.print_raw(get_prompt())
      }
      return
    }
    match text {
      ":q" | ":quit" | ":exit" | "exit" => {
        done.val = true
        @tui.stop_keypress_listener()
        return
      }
      _ => ()
    }
    if history.length() == 0 || history[history.length() - 1] != text {
      history.push(text)
      append_history(text)
    }
    if not(handle_cd_builtin(rt, text, raw_println)) {
      scratch_source_ref.val = run_compiled_shell_line(
        cache,
        rt,
        syntax_mode,
        scratch_db_path,
        source_path,
        wasm_path,
        scratch_source_ref.val,
        text,
        print_line=raw_println,
      )
    }
    if prompt_enabled {
      @tui.print_raw(get_prompt())
    }
  }

  fn handle_key(input : String) {
    if done.val {
      return
    }
    if input.length() == 0 {
      return
    }
    if input.length() > 1 &&
      input[0].to_int() != 0x1b &&
      @tui.is_printable_string(input) {
      for _, ch in input {
        insert_char(ch)
      }
      return
    }
    let event = @tui.parse_input(input)
    if event.is_ctrl_c() {
      if line_buf_length() > 0 {
        @tui.print_raw("^C\r\n")
        line_buf.reset()
        cursor_pos.val = 0
        history_idx.val = -1
        if prompt_enabled {
          @tui.print_raw(get_prompt())
        }
      } else {
        @tui.print_raw("\r\n")
        done.val = true
        @tui.stop_keypress_listener()
      }
      return
    }
    match event {
      @tui.InputEvent::Key(key_event) =>
        match key_event {
          @tui.KeyEvent::Special(@tui.SpecialKey::Enter, _) => submit_line()
          @tui.KeyEvent::Special(@tui.SpecialKey::Backspace, _) => delete_back()
          @tui.KeyEvent::Special(@tui.SpecialKey::Delete, _) => delete_forward()
          @tui.KeyEvent::Special(@tui.SpecialKey::Up, _) => history_prev()
          @tui.KeyEvent::Special(@tui.SpecialKey::Down, _) => history_next()
          @tui.KeyEvent::Special(@tui.SpecialKey::Left, _) => move_left()
          @tui.KeyEvent::Special(@tui.SpecialKey::Right, _) => move_right()
          @tui.KeyEvent::Special(@tui.SpecialKey::Home, _) => move_home()
          @tui.KeyEvent::Special(@tui.SpecialKey::End, _) => move_end()
          @tui.KeyEvent::Char('a', @tui.KeyModifier::Ctrl) => move_home()
          @tui.KeyEvent::Char('e', @tui.KeyModifier::Ctrl) => move_end()
          @tui.KeyEvent::Char('u', @tui.KeyModifier::Ctrl) => kill_line()
          @tui.KeyEvent::Char('k', @tui.KeyModifier::Ctrl) => kill_to_end()
          @tui.KeyEvent::Char('d', @tui.KeyModifier::Ctrl) =>
            if line_buf_length() == 0 {
              @tui.print_raw("\r\n")
              done.val = true
              @tui.stop_keypress_listener()
            } else {
              delete_forward()
            }
          @tui.KeyEvent::Char('l', @tui.KeyModifier::Ctrl) => {
            @tui.print_raw(@render.ansi_clear_screen())
            @tui.print_raw(@render.ansi_move_to(0, 0))
            redraw_line()
          }
          @tui.KeyEvent::Char('w', @tui.KeyModifier::Ctrl) => {
            let text = line_buf_to_string()
            let chars = text.to_array()
            let mut p = cursor_pos.val
            while p > 0 && chars[p - 1] == ' ' {
              p -= 1
            }
            while p > 0 && chars[p - 1] != ' ' {
              p -= 1
            }
            let next = StringBuilder::new()
            let mut idx = 0
            while idx < p {
              next.write_char(chars[idx])
              idx += 1
            }
            idx = cursor_pos.val
            while idx < chars.length() {
              next.write_char(chars[idx])
              idx += 1
            }
            line_buf.reset()
            line_buf.write_string(next.to_string())
            cursor_pos.val = p
            redraw_line()
          }
          @tui.KeyEvent::Char(ch, @tui.KeyModifier::None)
          | @tui.KeyEvent::Char(ch, @tui.KeyModifier::Shift) => insert_char(ch)
          _ => ()
        }
      _ => ()
    }
  }

  if prompt_enabled {
    @tui.print_raw(get_prompt())
  }
  @tui.start_keypress_listener(handle_key)
}

///|
#borrow(path)
extern "c" fn c_chdir(path : Bytes) -> Int = "chdir"

///|
fn process_chdir(dir : String) -> Bool {
  let encoded = @utf8.encode(dir[:])
  let n = encoded.length()
  let path_bytes = Bytes::makei(n + 1, fn(i) {
    if i == n {
      b'\x00'
    } else {
      encoded[i]
    }
  })
  c_chdir(path_bytes) == 0
}

///|
/// Deduplicate REPL session bindings: for same-name `let` bindings,
/// keep only the last definition. This produces a clean DAG where
/// each name has exactly one binding (the most recent one).
/// Non-let statements (test blocks, bare expressions, imports) are kept as-is.
fn repl_deduplicate_bindings(source : String) -> String {
  // Collect all statements with their binding names
  let stmts : Array[(String, String?)] = [] // (line, binding_name?)
  let buf = StringBuilder::new()
  let mut in_block = 0
  for line_view in source.split("\n") {
    let line = line_view.to_string()
    let trimmed = line.trim().to_string()
    // Track brace depth for multi-line blocks
    for ch in trimmed {
      if ch == '{' {
        in_block += 1
      } else if ch == '}' {
        in_block -= 1
      }
    }
    buf.write_string(line)
    buf.write_char('\n')
    if in_block <= 0 {
      in_block = 0
      let stmt = buf.to_string()
      buf.reset()
      let name = extract_let_binding_name(stmt.trim().to_string())
      stmts.push((stmt, name))
    }
  }
  if buf.to_string().length() > 0 {
    stmts.push((buf.to_string(), None))
  }
  // For each binding name, record the last index
  let last_index : Map[String, Int] = {}
  let mut i = 0
  while i < stmts.length() {
    match stmts[i].1 {
      Some(name) => last_index[name] = i
      None => ()
    }
    i += 1
  }
  // Output only the last binding for each name, plus all non-binding stmts
  let out = StringBuilder::new()
  i = 0
  while i < stmts.length() {
    let keep = match stmts[i].1 {
      Some(name) =>
        match last_index.get(name) {
          Some(idx) => idx == i
          None => true
        }
      None => true
    }
    if keep {
      let stmt_text = stmts[i].0
      if stmt_text.trim().to_string().length() > 0 {
        out.write_string(stmt_text)
        if not(stmt_text.has_suffix("\n")) {
          out.write_char('\n')
        }
      }
    }
    i += 1
  }
  out.to_string()
}

///|
fn extract_let_binding_name(line : String) -> String? {
  let prefixes = ["export let mut ", "export let ", "let mut ", "let "]
  let mut prefix_len = 0
  let mut found = false
  for p in prefixes {
    if line.has_prefix(p) {
      prefix_len = p.length()
      found = true
      break
    }
  }
  if not(found) {
    return None
  }
  // Extract name until = or : or space
  let chars = line.to_array()
  let mut end = prefix_len
  while end < chars.length() &&
        chars[end] != ' ' &&
        chars[end] != '=' &&
        chars[end] != ':' &&
        chars[end] != '(' {
    end += 1
  }
  if end == prefix_len {
    return None
  }
  let name = line.substring(start=prefix_len, end~)
  Some(name)
}

///|
/// Extract VIBE_DISPLAY: line from Node runner output.
fn extract_vibe_display_line(stdout : String) -> String? {
  for line_view in stdout.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("VIBE_DISPLAY:") {
      return Some(line.substring(start=13))
    }
  }
  None
}

///|
/// Handle `cd` as a REPL built-in. Returns true if the line was handled.
fn handle_cd_builtin(
  rt : @runtime.Runtime,
  line : String,
  print_line : (String) -> Unit,
) -> Bool {
  if not(line == "cd" || line.has_prefix("cd ")) {
    return false
  }
  let arg = if line == "cd" {
    match @sys.get_env_var("HOME") {
      Some(home) => home
      None => "/"
    }
  } else {
    let chars = line.to_array()
    let rest = StringBuilder::new()
    for i in 3..<chars.length() {
      rest.write_char(chars[i])
    }
    rest.to_string().trim().to_string()
  }
  // Resolve relative paths against current cwd
  let target = if arg.has_prefix("/") {
    arg
  } else {
    let cwd = @io.current_dir_or_root()
    if cwd.has_suffix("/") {
      cwd + arg
    } else {
      cwd + "/" + arg
    }
  }
  if process_chdir(target) {
    // Update runtime cwd directly
    rt.set_cwd(@io.current_dir_or_root())
  } else {
    print_line("cd: no such file or directory: " + arg)
  }
  true
}
