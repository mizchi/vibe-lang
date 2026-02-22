///|
fn repl_cmd(
  args : Array[String],
  _syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let mut tui_mode = false
  let mut ai_mode = false
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
      _ => {
        sub_args.push(args[i])
        i += 1
      }
    }
  }
  // Default shell uses VibeMode; POSIX commands via posix_fallback in TTY mode
  let syntax_mode = @runtime.ParserMode::VibeMode
  if ai_mode {
    repl_ai_cmd(sub_args, syntax_mode, features, enable_llm~)
    return
  }
  if tui_mode {
    if sub_args.length() != 0 {
      abort("shell --tui: no extra args supported")
    }
    repl_tui_cmd(syntax_mode, features, enable_llm~)
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
} derive(Show, Eq)

///|
struct ReplSymbolMatch {
  entry : @runtime.SymbolEntry
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
  [":q", ":quit", ":exit", ":view", ":outline", ":peek", ":type"]
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
      kind: @runtime.symbol_kind_name(entry.kind),
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
fn repl_symbol_key(entry : @runtime.SymbolEntry) -> String {
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
  entries : Array[@runtime.SymbolEntry],
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
  let entries : Array[@runtime.SymbolEntry] = []
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
      let entries : Array[@runtime.SymbolEntry] = []
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
      @runtime.symbol_kind_name(entry.kind) +
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
      @runtime.symbol_kind_name(entry.kind) +
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
  obj["kind"] = Json::string(@runtime.symbol_kind_name(entry.kind))
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
    let first_exists = @os_fs.path_exists(first_path) catch { _ => false }
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
fn repl_print_eval_result_for_shell(
  result : @runtime.EvalResult,
  print_line : (String) -> Unit,
) -> Unit {
  let is_shell = result.effects
    .iter()
    .any(fn(e) {
      match e {
        @runtime.Effect::ShellExec(_) => true
        _ => false
      }
    })
  if is_shell {
    match result.last {
      Some(@vibe_core.Value::Array(items)) =>
        for item in items {
          match item {
            @vibe_core.Value::String(s) => print_line(s)
            other => print_line(other.to_string())
          }
        }
      Some(value) => print_line(value.to_string())
      None => ()
    }
    for effect in result.effects {
      match effect {
        @runtime.Effect::ShellExec(_) | @runtime.Effect::PosixDesugar(_) => ()
        _ => print_line("effect: " + effect.to_string())
      }
    }
  } else {
    match result.last {
      Some(value) => print_line("last: " + value.to_string())
      None => ()
    }
    for effect in result.effects {
      match effect {
        @runtime.Effect::PosixDesugar(message) => print_line("note: " + message)
        _ => print_line("effect: " + effect.to_string())
      }
    }
  }
}

///|
fn handle_repl_vibe_shell_command(
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
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
    Some(pipe_tail) => {
      let expression = "from_json(\"" +
        escape_string_for_vibe(payload_text) +
        "\") |> " +
        pipe_tail
      let result = rt.eval_script_with_mode(expression, syntax_mode) catch {
        e => {
          print_line(format_repl_error(e, expression))
          return ReplMetaCommandResult::HandledContinue
        }
      }
      repl_print_eval_result_for_shell(result, print_line)
      ReplMetaCommandResult::HandledContinue
    }
  }
}

///|
fn repl_restore_scratch_source(
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
  scratch_db_path : String,
  source : String,
  print_line : (String) -> Unit,
) -> String {
  if source.trim().to_string().length() == 0 {
    return source
  }
  try rt.eval_script_with_mode(source, syntax_mode) |> ignore catch {
    e => {
      let err = e.to_string()
      print_line("warn: failed to restore db: " + err)
      if err.contains("DuplicateDecl") {
        match write_eval_db_source(scratch_db_path, "") {
          Ok(_) =>
            print_line(
              "warn: duplicate declarations detected; reset namespace db: " +
              scratch_db_path,
            )
          Err(write_err) =>
            print_line("warn: failed to reset namespace db: " + write_err)
        }
        return ""
      }
    }
  }
  source
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
    @runtime.symbol_kind_name(entry.kind) +
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
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let rt = new_cli_runtime(features, enable_llm~)
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  let restored_source = match load_eval_db_source(scratch_db_path) {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  let restore_logs : Array[String] = []
  let restored_source = repl_restore_scratch_source(
    rt,
    syntax_mode,
    scratch_db_path,
    restored_source,
    fn(s) { restore_logs.push(s) },
  )
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
    "let", "rec", "if", "match", "do", "record", "test", "import", "true", "false",
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
      ReplMetaCommandResult::HandledContinue => return true
      ReplMetaCommandResult::NotMeta => ()
    }
    let result = rt.eval_script_with_mode(trimmed, syntax_mode) catch {
      e => {
        // Fallback: if VibeMode fails with name resolution, retry with PosixMode desugar
        let err_str = e.to_string()
        if err_str.contains("UnknownName") || err_str.contains("BadCall") {
          let wrapped = "do {\n" + trimmed + "\n}"
          let retry = rt.eval_script_with_mode(
            wrapped,
            @runtime.ParserMode::PosixMode,
          ) catch {
            retry_err => {
              push_output_line(
                format_repl_error(retry_err, wrapped, unwrap_prefix="do {\n"),
              )
              return true
            }
          }
          match retry.last {
            Some(@vibe_core.Value::Array(items)) =>
              for item in items {
                match item {
                  @vibe_core.Value::String(s) => push_output_line(s)
                  other => push_output_line(other.to_string())
                }
              }
            Some(value) => push_output_line(value.to_string())
            None => ()
          }
          for effect in retry.effects {
            match effect {
              @runtime.Effect::ShellExec(_)
              | @runtime.Effect::PosixDesugar(_) => ()
              _ => push_output_line("effect: " + effect.to_string())
            }
          }
          return true
        }
        push_output_line(format_repl_error(e, trimmed))
        return true
      }
    }
    match result.last {
      Some(value) => push_output_line("last: " + value.to_string())
      None => ()
    }
    for effect in result.effects {
      match effect {
        @runtime.Effect::PosixDesugar(message) =>
          push_output_line("note: " + message)
        _ => push_output_line("effect: " + effect.to_string())
      }
    }
    scratch_source_ref.val = append_eval_db_source(
      scratch_source_ref.val,
      trimmed,
    )
    match write_eval_db_source(scratch_db_path, scratch_source_ref.val) {
      Ok(_) => ()
      Err(err) => {
        push_output_line("error: failed to persist namespace db: " + err)
        return true
      }
    }
    match extract_let_name(trimmed) {
      Some(name) => {
        push_unique(vibe_names, name)
        repl_warn_reserved_shell_binding(name, push_output_line)
        match rt.get_addr(name) {
          Some(addr) =>
            push_output_line("addr: " + name + "#" + short_hash(addr))
          None => ()
        }
      }
      None => ()
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
  for line in restore_logs {
    push_output_line(line)
  }
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
  run_eval_line_repl_with_prompt(
    args,
    "shell-stdin",
    "vibe> ",
    syntax_mode,
    features,
    enable_llm~,
  )
}

///|
fn repl_wasi_cmd(
  args : Array[String],
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  run_eval_line_repl_with_prompt(
    args,
    "shell-wasi",
    "wasi> ",
    syntax_mode,
    features,
    enable_llm~,
  )
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
fn run_eval_line_repl_with_prompt(
  args : Array[String],
  cmd_name : String,
  prompt : String,
  syntax_mode : @runtime.ParserMode,
  features : @runtime.RuntimeFeatureFlags,
  enable_llm~ : Bool,
) -> Unit {
  let options = match parse_line_repl_options(args, cmd_name, prompt) {
    Ok(opts) => opts
    Err(msg) => abort(msg)
  }
  let (namespace_name, scratch_db_path) = match resolve_scratch_db_path() {
    Ok(v) => v
    Err(err) => abort(cmd_name + ": " + err)
  }
  async fn repl_loop() {
    let rt = new_cli_runtime(features, enable_llm~)
    let mut scratch_source = match load_eval_db_source(scratch_db_path) {
      Ok(v) => v
      Err(err) => {
        println("error: " + err)
        return
      }
    }
    scratch_source = repl_restore_scratch_source(
      rt,
      syntax_mode,
      scratch_db_path,
      scratch_source,
      fn(s) { println(s) },
    )
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
      match
        handle_repl_meta_command(line_str, scratch_db_path, scratch_source, fn(
          s,
        ) {
          println(s)
        }) {
        ReplMetaCommandResult::HandledExit => break
        ReplMetaCommandResult::HandledContinue => {
          if options.prompt_enabled {
            @stdio.stdout.write(options.prompt)
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
        ReplMetaCommandResult::HandledContinue => {
          if options.prompt_enabled {
            @stdio.stdout.write(options.prompt)
          }
          continue
        }
        ReplMetaCommandResult::NotMeta => ()
      }
      let result = rt.eval_script_with_mode(line_str, syntax_mode) catch {
        e => {
          // Fallback: if VibeMode fails with name resolution, retry with PosixMode
          let err_str = e.to_string()
          if err_str.contains("UnknownName") || err_str.contains("BadCall") {
            let wrapped = "do {\n" + line_str + "\n}"
            let retry = rt.eval_script_with_mode(
              wrapped,
              @runtime.ParserMode::PosixMode,
            ) catch {
              retry_err => {
                println(
                  format_repl_error(retry_err, wrapped, unwrap_prefix="do {\n"),
                )
                if options.prompt_enabled {
                  @stdio.stdout.write(options.prompt)
                }
                continue
              }
            }
            print_eval_result(retry)
            if options.prompt_enabled {
              @stdio.stdout.write(options.prompt)
            }
            continue
          }
          println(format_repl_error(e, line_str))
          if options.prompt_enabled {
            @stdio.stdout.write(options.prompt)
          }
          continue
        }
      }
      print_eval_result(result)
      match extract_let_name(line_str) {
        Some(name) => {
          repl_warn_reserved_shell_binding(name, fn(s) { println(s) })
          match rt.get_addr(name) {
            Some(addr) => println("addr: " + name + "#" + short_hash(addr))
            None => ()
          }
        }
        None => ()
      }
      scratch_source = append_eval_db_source(scratch_source, line_str)
      match write_eval_db_source(scratch_db_path, scratch_source) {
        Ok(_) => ()
        Err(err) => println("error: failed to persist namespace db: " + err)
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
          // Create a temporary source for compilation
          let db = @runtime.VibeDb::new()
          let tmp_path = "/tmp/wasm_repl_" + counter.to_string() + ".vibe"
          db.set_source(tmp_path, line_str)
          // Compile to WASM
          let wasm_bytes = @runtime_compile.compile_module_wasm(db, tmp_path) catch {
            e => {
              println("error: " + e.to_string())
              if prompt_enabled {
                @stdio.stdout.write(prompt)
              }
              continue
            }
          }
          // Write WASM to file
          let out_path = out_dir + "/expr_" + counter.to_string() + ".wasm"
          @os_fs.write_bytes_to_file(out_path, wasm_bytes) catch {
            e => {
              println("error writing file: " + e.to_string())
              if prompt_enabled {
                @stdio.stdout.write(prompt)
              }
              continue
            }
          }
          println(
            "wrote " +
            out_path +
            " (" +
            wasm_bytes.length().to_string() +
            " bytes)",
          )
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
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--no-prompt" => {
        prompt_enabled = false
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
    let mut scratch_source = match load_eval_db_source(scratch_db_path) {
      Ok(v) => v
      Err(err) => {
        println("error: " + err)
        return
      }
    }
    scratch_source = repl_restore_scratch_source(
      rt,
      syntax_mode,
      scratch_db_path,
      scratch_source,
      fn(s) { println(s) },
    )
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
        ReplMetaCommandResult::HandledContinue => {
          if prompt_enabled {
            @stdio.stdout.write(prompt)
          }
          continue
        }
        ReplMetaCommandResult::NotMeta => ()
      }
      let result = rt.eval_script_with_mode(line_str, syntax_mode) catch {
        e => {
          println("error: " + e.to_string())
          if prompt_enabled {
            @stdio.stdout.write(prompt)
          }
          continue
        }
      }
      print_eval_result(result)
      let let_name = extract_let_name(line_str)
      match let_name {
        Some(name) => {
          repl_warn_reserved_shell_binding(name, fn(s) { println(s) })
          match rt.get_addr(name) {
            Some(addr) => println("addr: " + name + "#" + short_hash(addr))
            None => ()
          }
        }
        None => ()
      }
      scratch_source = append_eval_db_source(scratch_source, line_str)
      match write_eval_db_source(scratch_db_path, scratch_source) {
        Ok(_) => ()
        Err(err) => println("error: failed to persist namespace db: " + err)
      }
      if let_name is Some(_) {
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
  let mut i = 0
  while i < args.length() {
    match args[i] {
      "--no-prompt" => {
        prompt_enabled = false
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
  let scratch_source = match load_eval_db_source(scratch_db_path) {
    Ok(v) => v
    Err(err) => abort("shell: " + err)
  }
  let scratch_source = repl_restore_scratch_source(
    rt,
    syntax_mode,
    scratch_db_path,
    scratch_source,
    fn(s) { println(s) },
  )
  // header
  println("cwd: " + @io.current_dir_or_root())
  println("namespace: " + namespace_name + " db=" + scratch_db_path)
  print_ai_symbols(scratch_db_path, scratch_source)
  // Detect TTY for readline-like editing
  let use_raw = @tui_io.is_tty() && prompt_enabled
  if use_raw {
    repl_interactive_raw_loop(
      rt, syntax_mode, scratch_db_path, scratch_source, prompt_enabled,
    )
  } else {
    repl_interactive_plain_loop(
      rt, syntax_mode, scratch_db_path, scratch_source, prompt_enabled,
    )
  }
}

///|
fn repl_interactive_plain_loop(
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
  scratch_db_path : String,
  initial_source : String,
  prompt_enabled : Bool,
) -> Unit {
  async fn repl_loop() {
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
            scratch_source = run_interactive_line(
              rt,
              syntax_mode,
              scratch_db_path,
              scratch_source,
              line_str,
              posix_fallback=true,
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
fn run_interactive_line(
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
  scratch_db_path : String,
  scratch_source : String,
  line_str : String,
  posix_fallback? : Bool = false,
  print_line? : (String) -> Unit = fn(s) { println(s) },
) -> String {
  match
    handle_repl_meta_command(
      line_str, scratch_db_path, scratch_source, print_line,
    ) {
    ReplMetaCommandResult::HandledExit => return scratch_source
    ReplMetaCommandResult::HandledContinue => return scratch_source
    ReplMetaCommandResult::NotMeta => ()
  }
  match
    handle_repl_vibe_shell_command(
      rt, syntax_mode, line_str, scratch_db_path, scratch_source, print_line,
    ) {
    ReplMetaCommandResult::HandledExit => return scratch_source
    ReplMetaCommandResult::HandledContinue => return scratch_source
    ReplMetaCommandResult::NotMeta => ()
  }

  let result = rt.eval_script_with_mode(line_str, syntax_mode) catch {
    e => {
      // Fallback: if VibeMode fails with name resolution, retry with PosixMode desugar
      if posix_fallback {
        let err_str = e.to_string()
        if err_str.contains("UnknownName") || err_str.contains("BadCall") {
          let wrapped = "do {\n" + line_str + "\n}"
          let retry = rt.eval_script_with_mode(
            wrapped,
            @runtime.ParserMode::PosixMode,
          ) catch {
            retry_err => {
              // Show PosixMode error (more informative after desugar)
              print_line(
                format_repl_error(retry_err, wrapped, unwrap_prefix="do {\n"),
              )
              return scratch_source
            }
          }
          repl_print_eval_result_for_shell(retry, print_line)
          return scratch_source
        }
      }
      print_line(format_repl_error(e, line_str))
      return scratch_source
    }
  }
  repl_print_eval_result_for_shell(result, print_line)
  let let_name = extract_let_name(line_str)
  match let_name {
    Some(name) => {
      repl_warn_reserved_shell_binding(name, print_line)
      match rt.get_addr(name) {
        Some(addr) => print_line("addr: " + name + "#" + short_hash(addr))
        None => ()
      }
    }
    None => ()
  }
  let next_source = append_eval_db_source(scratch_source, line_str)
  match write_eval_db_source(scratch_db_path, next_source) {
    Ok(_) => ()
    Err(err) => {
      print_line("error: failed to persist namespace db: " + err)
      return scratch_source
    }
  }
  if let_name is Some(_) {
    print_ai_symbols(scratch_db_path, next_source, print_line~)
  }
  next_source
}

///|
fn repl_interactive_raw_loop(
  rt : @runtime.Runtime,
  syntax_mode : @runtime.ParserMode,
  scratch_db_path : String,
  initial_source : String,
  prompt_enabled : Bool,
) -> Unit {
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

  let done = Ref::new(false)
  fn raw_println(s : String) -> Unit {
    // Split multi-line strings so each line gets proper \r\n in raw terminal mode
    for part in s.split("\n") {
      @tui.print_raw(part.to_string() + "\r\n")
    }
  }

  fn line_buf_to_string() -> String {
    line_buf.to_string()
  }

  fn line_buf_length() -> Int {
    line_buf_to_string().to_array().length()
  }

  fn redraw_line() {
    let text = line_buf_to_string()
    @tui.print_raw("\r" + @render.ansi_clear_line())
    if prompt_enabled {
      @tui.print_raw(get_prompt())
    }
    @tui.print_raw(text)
    let text_len = text.to_array().length()
    let back = text_len - cursor_pos.val
    if back > 0 {
      @tui.print_raw(@render.ansi_move_left(n=back))
    }
  }

  fn set_line(text : String) {
    line_buf.reset()
    line_buf.write_string(text)
    cursor_pos.val = text.to_array().length()
    redraw_line()
  }

  fn insert_char(ch : Char) {
    let text = line_buf_to_string()
    let chars = text.to_array()
    let pos = cursor_pos.val
    let next = StringBuilder::new()
    let mut idx = 0
    while idx < pos && idx < chars.length() {
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
    cursor_pos.val = pos + 1
    redraw_line()
  }

  fn delete_back() {
    let pos = cursor_pos.val
    if pos <= 0 {
      return
    }
    let text = line_buf_to_string()
    let chars = text.to_array()
    let next = StringBuilder::new()
    let mut idx = 0
    while idx < pos - 1 {
      next.write_char(chars[idx])
      idx += 1
    }
    idx = pos
    while idx < chars.length() {
      next.write_char(chars[idx])
      idx += 1
    }
    line_buf.reset()
    line_buf.write_string(next.to_string())
    cursor_pos.val = pos - 1
    redraw_line()
  }

  fn delete_forward() {
    let pos = cursor_pos.val
    let text = line_buf_to_string()
    let chars = text.to_array()
    if pos >= chars.length() {
      return
    }
    let next = StringBuilder::new()
    let mut idx = 0
    while idx < pos {
      next.write_char(chars[idx])
      idx += 1
    }
    idx = pos + 1
    while idx < chars.length() {
      next.write_char(chars[idx])
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

  fn submit_line() {
    @tui.print_raw("\r\n")
    let text = line_buf_to_string().trim().to_string()
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
      scratch_source_ref.val = run_interactive_line(
        rt,
        syntax_mode,
        scratch_db_path,
        scratch_source_ref.val,
        text,
        posix_fallback=true,
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
    // Handle printable multi-char paste
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
    // Update runtime cwd via fs_chdir
    let new_cwd = @io.current_dir_or_root()
    let script = "fs_chdir(\"" + escape_string_for_vibe(new_cwd) + "\")"
    try rt.eval_script(script) |> ignore catch {
      _ => ()
    }
  } else {
    print_line("cd: no such file or directory: " + arg)
  }
  true
}

///|
fn format_repl_error(
  e : Error,
  source : String,
  unwrap_prefix? : String = "",
) -> String {
  @runtime.format_error_for_repl(e, source, unwrap_prefix~)
}

///|
fn escape_string_for_vibe(s : String) -> String {
  let buf = StringBuilder::new()
  for ch in s {
    match ch {
      '\\' => buf.write_string("\\\\")
      '"' => buf.write_string("\\\"")
      _ => buf.write_char(ch)
    }
  }
  buf.to_string()
}
