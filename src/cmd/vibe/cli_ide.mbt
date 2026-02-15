///|
fn zero_pad_number(value : Int, width : Int) -> String {
  let raw = value.to_string()
  if raw.length() >= width {
    return raw
  }
  let buf = StringBuilder::new()
  for _ in 0..<(width - raw.length()) {
    buf.write_char('0')
  }
  buf.write_string(raw)
  buf.to_string()
}

///|
fn symbol_line_col(source : String, span : @vibe_core.Span) -> (Int, Int) {
  let (pos, _, _) = @vibe_core.line_info(source, span.start)
  (pos.line, pos.column)
}

///|
fn symbol_line_text(source : String, span : @vibe_core.Span) -> String {
  let (_, line_start, line_end) = @vibe_core.line_info(source, span.start)
  try source[line_start:line_end] catch {
    _ => ""
  } noraise {
    s => s.to_string()
  }
}

///|
fn print_ide_outline_entry(
  entry : @runtime.SymbolEntry,
  source : String,
) -> Unit {
  let (line, _) = symbol_line_col(source, entry.span)
  println(
    "L" +
    zero_pad_number(line, 3) +
    " | " +
    @runtime.symbol_kind_name(entry.kind) +
    " " +
    entry.name +
    " : " +
    entry.signature,
  )
}

///|
fn ide_outline_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("ide outline: expected <file>")
  }
  match @loader.load_db_with_paths(args[0]) {
    Ok((db, entry, _)) => {
      let index = @runtime.build_symbol_index(db, [entry])
      if index.entries.length() == 0 {
        println("No symbols found in " + entry)
        return
      }
      println("Outline: " + entry)
      for symbol in index.entries {
        match db.get_source(symbol.path) {
          Some(source) => print_ide_outline_entry(symbol, source)
          None => ()
        }
      }
    }
    Err(err) => abort("ide outline: " + err)
  }
}

///|
fn print_ide_search_entry(
  entry : @runtime.SymbolEntry,
  source : String,
) -> Unit {
  let (line, column) = symbol_line_col(source, entry.span)
  println(
    entry.path +
    ":" +
    line.to_string() +
    ":" +
    column.to_string() +
    "  " +
    @runtime.symbol_kind_name(entry.kind) +
    " " +
    entry.name +
    " : " +
    entry.signature,
  )
}

///|
fn ide_peek_def_cmd(args : Array[String]) -> Unit {
  if args.length() != 2 {
    abort("ide peek-def: expected <symbol> <entry-file>")
  }
  let symbol = args[0]
  let entry_file = args[1]
  match @loader.load_db_with_paths(entry_file) {
    Ok((db, _, paths)) => {
      let index = @runtime.build_symbol_index(db, paths)
      let matches = index.find_exact(symbol)
      if matches.length() == 0 {
        println("No symbols found matching `" + symbol + "`")
        return
      }
      println(
        "Found " +
        matches.length().to_string() +
        " symbols matching `" +
        symbol +
        "`:",
      )
      for entry in matches {
        match db.get_source(entry.path) {
          Some(source) => {
            let (line, column) = symbol_line_col(source, entry.span)
            println("")
            println(
              @runtime.symbol_kind_name(entry.kind) +
              " " +
              entry.name +
              " at " +
              entry.path +
              ":" +
              line.to_string() +
              ":" +
              column.to_string(),
            )
            let snippet = symbol_line_text(source, entry.span)
            if snippet.length() > 0 {
              println(snippet)
            }
          }
          None => ()
        }
      }
    }
    Err(err) => abort("ide peek-def: " + err)
  }
}

///|
fn ide_search_cmd(args : Array[String]) -> Unit {
  if args.length() != 2 {
    abort("ide search: expected <query> <entry-file>")
  }
  let query = args[0]
  let entry_file = args[1]
  match @loader.load_db_with_paths(entry_file) {
    Ok((db, _, paths)) => {
      let index = @runtime.build_symbol_index(db, paths)
      let matches = index.search(query)
      if matches.length() == 0 {
        println("No symbols found for query `" + query + "`")
        return
      }
      println(
        "Found " +
        matches.length().to_string() +
        " symbols for query `" +
        query +
        "`:",
      )
      for entry in matches {
        match db.get_source(entry.path) {
          Some(source) => print_ide_search_entry(entry, source)
          None => ()
        }
      }
    }
    Err(err) => abort("ide search: " + err)
  }
}

///|
fn ide_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("ide: expected subcommand (outline|peek-def|search)")
  }
  let sub = args[0]
  let sub_args = args_tail(args, 1)
  match sub {
    "outline" => ide_outline_cmd(sub_args)
    "peek-def" => ide_peek_def_cmd(sub_args)
    "search" => ide_search_cmd(sub_args)
    _ => abort("ide: unknown subcommand: " + sub)
  }
}

///|
fn lsif_lines_to_text(lines : Array[String]) -> String {
  let buf = StringBuilder::new()
  for i in 0..<lines.length() {
    if i > 0 {
      buf.write_char('\n')
    }
    buf.write_string(lines[i])
  }
  buf.to_string()
}

///|
fn lsif_cmd(args : Array[String]) -> Unit {
  let entries : Array[String] = []
  let mut out_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "-o" || arg == "--out" {
      i += 1
      if i >= args.length() {
        abort("lsif: missing output path after " + arg)
      }
      out_path = Some(args[i])
      i += 1
      continue
    }
    entries.push(arg)
    i += 1
  }
  if entries.length() != 1 {
    abort("lsif: expected <entry-file>")
  }
  match @loader.load_db_with_paths(entries[0]) {
    Ok((db, _, paths)) => {
      let index = @runtime.build_symbol_index(db, paths)
      let lines = @runtime.symbol_index_to_lsif_lines(index, fn(path) {
        db.get_source(path)
      })
      match out_path {
        Some(path) => {
          let text = lsif_lines_to_text(lines)
          @os_fs.write_string_to_file(path, text) catch {
            e => abort("lsif: " + e.to_string())
          }
          println(
            "wrote " + path + " (" + lines.length().to_string() + " lines)",
          )
        }
        None =>
          for line in lines {
            println(line)
          }
      }
    }
    Err(err) => abort("lsif: " + err)
  }
}

///|
fn index_load_file(path : String) -> @x_exp.AdvancedGraphIndex {
  match @x_exp.read_advanced_graph_index(path) {
    Ok(index) => index
    Err(err) => abort("index: " + err)
  }
}

///|
enum IndexWalAction {
  Stats(String)
  Append(String, String, String)
  Replay(String, String, String)
  Compact(String, String)
}

///|
enum IndexRefAction {
  PushIndex(String, String)
  PullIndex(String, String)
  PushDelta(String, String)
  PullDelta(String, String)
}

///|
fn parse_index_wal_args(args : Array[String]) -> Result[IndexWalAction, String] {
  if args.length() == 0 {
    return Err("index wal: expected subcommand (stats|append|replay|compact)")
  }
  let sub = args[0]
  let sub_args = args_tail(args, 1)
  match sub {
    "stats" =>
      if sub_args.length() != 1 {
        Err("index wal stats: expected <wal-file>")
      } else {
        Ok(IndexWalAction::Stats(sub_args[0]))
      }
    "append" =>
      if sub_args.length() != 3 {
        Err(
          "index wal append: expected <wal-file> <base-index-file> <target-index-file>",
        )
      } else {
        Ok(IndexWalAction::Append(sub_args[0], sub_args[1], sub_args[2]))
      }
    "replay" => {
      let mut out_path = "dist/advanced-graph-index.replayed.json"
      let mut snapshot_path : String? = None
      let mut wal_path : String? = None
      let mut i = 0
      while i < sub_args.length() {
        let arg = sub_args[i]
        match arg {
          "-o" | "--out" => {
            i += 1
            if i >= sub_args.length() {
              return Err("index wal replay: missing output path after " + arg)
            }
            out_path = sub_args[i]
          }
          _ =>
            match snapshot_path {
              None => snapshot_path = Some(arg)
              Some(_) =>
                match wal_path {
                  None => wal_path = Some(arg)
                  Some(_) =>
                    return Err("index wal replay: unexpected extra arg: " + arg)
                }
            }
        }
        i += 1
      }
      let snapshot_path = match snapshot_path {
        Some(v) => v
        None =>
          return Err("index wal replay: expected <snapshot-file> <wal-file>")
      }
      let wal_path = match wal_path {
        Some(v) => v
        None =>
          return Err("index wal replay: expected <snapshot-file> <wal-file>")
      }
      Ok(IndexWalAction::Replay(snapshot_path, wal_path, out_path))
    }
    "compact" =>
      if sub_args.length() != 2 {
        Err("index wal compact: expected <snapshot-file> <wal-file>")
      } else {
        Ok(IndexWalAction::Compact(sub_args[0], sub_args[1]))
      }
    _ => Err("index wal: unknown subcommand: " + sub)
  }
}

///|
fn index_wal_cmd(args : Array[String]) -> Unit {
  let action = match parse_index_wal_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  match action {
    IndexWalAction::Stats(wal_path) => {
      let stats = match @x_exp.advanced_graph_wal_stats(wal_path) {
        Ok(v) => v
        Err(err) => abort("index wal stats: " + err)
      }
      println(
        "index wal stats: records=" +
        stats.record_count.to_string() +
        " bytes=" +
        stats.byte_size.to_string(),
      )
    }
    IndexWalAction::Append(wal_path, base_path, target_path) => {
      let base = index_load_file(base_path)
      let target = index_load_file(target_path)
      let delta = @x_exp.advanced_graph_diff(base, target)
      match @x_exp.append_advanced_graph_delta_jsonl(wal_path, delta) {
        Ok(_) =>
          println(
            "index wal append: wrote 1 record to " +
            wal_path +
            " (upsert_defs=" +
            delta.upsert_defs.length().to_string() +
            ", removed_defs=" +
            delta.removed_def_ids.length().to_string() +
            ")",
          )
        Err(err) => abort("index wal append: " + err)
      }
    }
    IndexWalAction::Replay(snapshot_path, wal_path, out_path) => {
      if out_path.has_prefix("dist/") {
        ensure_dist_dir()
      }
      let index = match
        @x_exp.load_advanced_graph_index_with_wal(snapshot_path, wal_path) {
        Ok(v) => v
        Err(err) => abort("index wal replay: " + err)
      }
      match @x_exp.write_advanced_graph_index(out_path, index) {
        Ok(_) =>
          println(
            "index wal replay: wrote " +
            out_path +
            " (" +
            index.defs.length().to_string() +
            " defs)",
          )
        Err(err) => abort("index wal replay: " + err)
      }
    }
    IndexWalAction::Compact(snapshot_path, wal_path) => {
      let latest = match
        @x_exp.compact_advanced_graph_snapshot_wal(snapshot_path, wal_path) {
        Ok(v) => v
        Err(err) => abort("index wal compact: " + err)
      }
      println(
        "index wal compact: wrote " +
        snapshot_path +
        " (" +
        latest.defs.length().to_string() +
        " defs), cleared " +
        wal_path,
      )
    }
  }
}

///|
fn parse_index_ref_args(args : Array[String]) -> Result[IndexRefAction, String] {
  if args.length() != 3 {
    return Err(
      "index ref: expected <push|pull|push-delta|pull-delta> <scope> <file>",
    )
  }
  let action = args[0]
  let scope = args[1]
  let path = args[2]
  match action {
    "push" => Ok(IndexRefAction::PushIndex(scope, path))
    "pull" => Ok(IndexRefAction::PullIndex(scope, path))
    "push-delta" => Ok(IndexRefAction::PushDelta(scope, path))
    "pull-delta" => Ok(IndexRefAction::PullDelta(scope, path))
    _ =>
      Err(
        "index ref: unknown action: " +
        action +
        " (expected push|pull|push-delta|pull-delta)",
      )
  }
}

///|
fn read_advanced_graph_delta_file(path : String) -> @x_exp.AdvancedGraphDelta {
  let content = @os_fs.read_file_to_string(path) catch {
    e => abort("index ref: read delta file: " + e.to_string())
  }
  let json = @json.parse(content) catch {
    e => abort("index ref: parse delta json: " + e.to_string())
  }
  match @x_exp.advanced_graph_delta_from_json(json) {
    Ok(v) => v
    Err(err) => abort("index ref: decode delta: " + err)
  }
}

///|
fn write_advanced_graph_delta_file(
  path : String,
  delta : @x_exp.AdvancedGraphDelta,
) -> Unit {
  @os_fs.write_string_to_file(path, delta.to_json().stringify()) catch {
    e => abort("index ref: write delta file: " + e.to_string())
  }
}

///|
fn index_ref_cmd(args : Array[String]) -> Unit {
  let action = match parse_index_ref_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let git_dir = find_git_dir()
  match action {
    IndexRefAction::PushIndex(scope, index_path) => {
      let index = index_load_file(index_path)
      let hash = match
        @x_exp.write_advanced_graph_index_to_git_ref(git_dir, scope, index) {
        Ok(v) => v
        Err(err) => abort("index ref push: " + err)
      }
      println(
        "index ref push: refs/bit/index/" +
        scope +
        "/graph/head -> " +
        short_hash(hash),
      )
    }
    IndexRefAction::PullIndex(scope, out_path) => {
      let index = match
        @x_exp.read_advanced_graph_index_from_git_ref(git_dir, scope) {
        Ok(v) => v
        Err(err) => abort("index ref pull: " + err)
      }
      if out_path.has_prefix("dist/") {
        ensure_dist_dir()
      }
      match @x_exp.write_advanced_graph_index(out_path, index) {
        Ok(_) =>
          println(
            "index ref pull: wrote " +
            out_path +
            " (" +
            index.defs.length().to_string() +
            " defs)",
          )
        Err(err) => abort("index ref pull: " + err)
      }
    }
    IndexRefAction::PushDelta(scope, delta_path) => {
      let delta = read_advanced_graph_delta_file(delta_path)
      let hash = match
        @x_exp.write_advanced_graph_delta_to_git_ref(git_dir, scope, delta) {
        Ok(v) => v
        Err(err) => abort("index ref push-delta: " + err)
      }
      println(
        "index ref push-delta: refs/bit/index/" +
        scope +
        "/graph/wal_head -> " +
        short_hash(hash),
      )
    }
    IndexRefAction::PullDelta(scope, out_path) => {
      let delta = match
        @x_exp.read_advanced_graph_delta_from_git_ref(git_dir, scope) {
        Ok(v) => v
        Err(err) => abort("index ref pull-delta: " + err)
      }
      if out_path.has_prefix("dist/") {
        ensure_dist_dir()
      }
      write_advanced_graph_delta_file(out_path, delta)
      println("index ref pull-delta: wrote " + out_path)
    }
  }
}

///|
fn print_graph_def_entry(def : @x_exp.AdvancedGraphDef) -> Unit {
  println(
    def.path +
    "@" +
    def.start.to_string() +
    ".." +
    def.end.to_string() +
    "  " +
    def.kind +
    " " +
    def.name +
    " : " +
    def.signature +
    "  #" +
    short_hash(def.def_id),
  )
}

///|
fn write_index_vdb_graph_head(
  index_root : String,
  graph_head : String,
  function_tracking : Json,
) -> Result[Unit, String] {
  let index_vdb_path = index_root + "/index.vdb"
  let vdb_obj = load_index_vdb_object(index_vdb_path)
  vdb_obj["graph_head"] = Json::string(graph_head)
  vdb_obj["function_tracking"] = function_tracking
  write_index_vdb_object(index_vdb_path, vdb_obj)
}

///|
fn sync_graph_head_for_loaded_db(
  db : @runtime.VibeDb,
  entry : String,
  paths : Array[String],
  base_commit : String,
) -> Result[(@x_exp.AdvancedGraphIndex, String), String] {
  let index = @x_exp.build_advanced_graph_index(
    db,
    paths,
    base_commit~,
    created_at=@env.now().to_string(),
  )
  let index_json = index.to_json().stringify()
  let graph_head = @vibe_core.git_blob_hash_string(index_json)
  let index_root = @codebase.resolve_index_root(entry)
  let vibe_dir = find_vibe_dir(index_root + "/index.vibe")
  let codebase = @codebase.Codebase::new(vibe_dir)
  let _ = codebase.write_object(graph_head, index_json) catch {
    e => return Err("sync graph snapshot object: " + e.to_string())
  }
  let index_vdb_path = index_root + "/index.vdb"
  let vdb_obj = load_index_vdb_object(index_vdb_path)
  let function_tracking = compute_function_tracking_json(
    db, paths, index, vdb_obj,
  )
  match write_index_vdb_graph_head(index_root, graph_head, function_tracking) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok((index, graph_head))
}

///|
fn resolve_entry_artifacts(
  entry_path : String,
) -> Result[
  (
    @runtime.VibeDb,
    String,
    @codebase.LockData,
    @x_exp.AdvancedGraphIndex,
    String,
  ),
  String,
] {
  let resolved = @loader.resolve_entry_path(entry_path)
  let lock = match @codebase.update_lock_path_refs(resolved) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let synced_lock = sync_prelude_to_codebase(resolved, lock)
  let (db, entry, paths) = match @loader.load_db_with_paths(resolved) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let (index, graph_head) = match
    sync_graph_head_for_loaded_db(db, entry, paths, "") {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok((db, entry, synced_lock, index, graph_head))
}

///|
fn index_build_cmd(args : Array[String]) -> Unit {
  let mut out_path = "dist/advanced-graph-index.json"
  let mut base_commit = ""
  let mut entry : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-o" | "--out" => {
        i += 1
        if i >= args.length() {
          abort("index build: missing output path after " + arg)
        }
        out_path = args[i]
      }
      "--base-commit" => {
        i += 1
        if i >= args.length() {
          abort("index build: missing value after --base-commit")
        }
        base_commit = args[i]
      }
      _ =>
        match entry {
          Some(_) => abort("index build: unexpected extra arg: " + arg)
          None => entry = Some(arg)
        }
    }
    i += 1
  }
  let entry_path = match entry {
    Some(path) => path
    None => abort("index build: expected <entry-file>")
  }
  if out_path.has_prefix("dist/") {
    ensure_dist_dir()
  }
  match @loader.load_db_with_paths(entry_path) {
    Ok((db, entry, paths)) => {
      let (index, graph_head) = match
        sync_graph_head_for_loaded_db(db, entry, paths, base_commit) {
        Ok(v) => v
        Err(err) => abort("index build: " + err)
      }
      match @x_exp.write_advanced_graph_index(out_path, index) {
        Ok(_) =>
          println(
            "index build: wrote " +
            out_path +
            " (" +
            index.defs.length().to_string() +
            " defs), index.vdb graph_head=" +
            short_hash(graph_head),
          )
        Err(err) => abort("index build: " + err)
      }
    }
    Err(err) => abort("index build: " + err)
  }
}

///|
fn index_query_cmd(args : Array[String]) -> Unit {
  if args.length() != 3 {
    abort("index query: expected <symbol|type> <query> <index-file>")
  }
  let lane = args[0]
  let query = args[1]
  let index_path = args[2]
  let index = index_load_file(index_path)
  let matches = match lane {
    "symbol" => index.query_symbol(query)
    "type" => index.query_type(query)
    _ => abort("index query: unknown lane: " + lane)
  }
  if matches.length() == 0 {
    println("index query: no matches")
    return
  }
  println(
    "index query: " +
    matches.length().to_string() +
    " matches for `" +
    query +
    "`",
  )
  for def in matches {
    print_graph_def_entry(def)
  }
}

///|
fn index_verify_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("index verify: expected <index-file>")
  }
  let index = index_load_file(args[0])
  let issues = index.verify()
  if issues.length() == 0 {
    println("index verify: ok (" + index.defs.length().to_string() + " defs)")
    return
  }
  for issue in issues {
    println("index verify: " + issue)
  }
  abort("index verify: failed (" + issues.length().to_string() + " issues)")
}

///|
fn index_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("index: expected subcommand (build|query|verify|wal|ref)")
  }
  let sub = args[0]
  let sub_args = args_tail(args, 1)
  match sub {
    "build" => index_build_cmd(sub_args)
    "query" => index_query_cmd(sub_args)
    "verify" => index_verify_cmd(sub_args)
    "wal" => index_wal_cmd(sub_args)
    "ref" => index_ref_cmd(sub_args)
    _ => abort("index: unknown subcommand: " + sub)
  }
}

///|
/// LSP server command - reads JSON-RPC from stdin, writes to stdout
fn lsp_cmd(_args : Array[String]) -> Unit {
  // Run LSP server asynchronously
  @async.run_async_main(lsp_main_loop)
}

///|
/// Main LSP loop - reads Content-Length framed messages from stdin
async fn lsp_main_loop() -> Unit {
  let server = @lsp.LspServer::new()
  let stdin = @stdio.stdin
  let stdout = @stdio.stdout

  // Simple Content-Length based message reader
  while true {
    // Read Content-Length header
    match stdin.read_until("\n") {
      None => break
      Some(header_line) => {
        let header_str = header_line.to_string()
        if not(header_str.has_prefix("Content-Length:")) {
          continue
        }
        // Parse content length
        let len_part = header_str[15:].to_string()
        let len_str = trim_whitespace(len_part)
        let content_length = @strconv.parse_int(len_str) catch { _ => continue }

        // Skip empty line after headers
        let _ = stdin.read_until("\n")

        // Read content bytes
        let content = stdin.read_exactly(content_length)
        let json : Json = @json.parse(content.to_string()) catch {
          _ => continue
        }

        // Handle message
        let (response, notifications) = server.handle_message(json)

        // Send notifications first
        for notif in notifications {
          let msg = notif.stringify()
          let header = "Content-Length: " +
            msg.length().to_string() +
            "\r\n\r\n"
          stdout.write(header)
          stdout.write(msg)
        }

        // Send response
        match response {
          Some(resp) => {
            let json_str = @lsp.response_to_json(resp).stringify()
            let header = "Content-Length: " +
              json_str.length().to_string() +
              "\r\n\r\n"
            stdout.write(header)
            stdout.write(json_str)
          }
          None => ()
        }

        // Check for exit
        if server.is_exit_requested() {
          break
        }
      }
    }
  }
}

///|
fn trim_whitespace(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
      buf.write_char(c)
    }
  }
  buf.to_string()
}
