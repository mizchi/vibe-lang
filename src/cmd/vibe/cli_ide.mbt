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
fn graph_ir_line_col(source : String, row : @x_exp.GraphIrRow) -> (Int, Int) {
  let (pos, _, _) = @vibe_core.line_info(source, row.start)
  (pos.line, pos.column)
}

///|
fn graph_ir_line_text(source : String, row : @x_exp.GraphIrRow) -> String {
  let (_, line_start, line_end) = @vibe_core.line_info(source, row.start)
  try source[line_start:line_end] catch {
    _ => ""
  } noraise {
    s => s.to_string()
  }
}

///|
fn graph_ir_find_exact_rows(
  rows : Array[@x_exp.GraphIrRow],
  name : String,
) -> Array[@x_exp.GraphIrRow] {
  let out : Array[@x_exp.GraphIrRow] = []
  for row in rows {
    if row.name == name {
      out.push(row)
    }
  }
  out
}

///|
fn graph_ir_search_rows(
  rows : Array[@x_exp.GraphIrRow],
  query : String,
) -> Array[@x_exp.GraphIrRow] {
  let out : Array[@x_exp.GraphIrRow] = []
  for row in rows {
    if query.length() == 0 ||
      row.name.contains(query) ||
      row.signature.contains(query) {
      out.push(row)
    }
  }
  out
}

///|
fn graph_ir_rows_to_symbol_index(
  rows : Array[@x_exp.GraphIrRow],
) -> @frontend.SymbolIndex {
  let entries : Array[@frontend.SymbolEntry] = []
  for row in rows {
    entries.push(
      @frontend.symbol_entry_from_kind_name(
        row.name,
        row.kind,
        row.signature,
        row.path,
        row.start,
        row.end,
      ),
    )
  }
  @frontend.build_symbol_index_from_entries(entries)
}

///|
fn graph_ir_parse_semantic_rows_flag(
  args : Array[String],
  context : String,
) -> Result[(Array[String], String?), String] {
  let positional : Array[String] = []
  let mut semantic_rows_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--semantic-rows" {
      i += 1
      if i >= args.length() {
        return Err(context + ": missing path after --semantic-rows")
      }
      match semantic_rows_path {
        Some(_) => return Err(context + ": duplicate --semantic-rows")
        None => semantic_rows_path = Some(args[i])
      }
      i += 1
      continue
    }
    positional.push(arg)
    i += 1
  }
  Ok((positional, semantic_rows_path))
}

///|
fn graph_ir_parse_json_string_array(
  value : Json,
  context : String,
) -> Result[Array[String], String] {
  match value {
    Json::Array(items) => {
      let out : Array[String] = []
      for item in items {
        match item {
          Json::String(s) => out.push(s)
          _ => return Err(context + ": expected string array")
        }
      }
      Ok(out)
    }
    _ => Err(context + ": expected array")
  }
}

///|
fn graph_ir_parse_json_optional_string_array(
  obj : Map[String, Json],
  key : String,
  context : String,
) -> Result[Array[String], String] {
  match obj.get(key) {
    Some(value) => graph_ir_parse_json_string_array(value, context + "." + key)
    None => Ok([])
  }
}

///|
fn graph_ir_parse_json_required_string(
  obj : Map[String, Json],
  key : String,
  context : String,
) -> Result[String, String] {
  match obj.get(key) {
    Some(Json::String(s)) => Ok(s)
    Some(_) => Err(context + "." + key + ": expected string")
    None => Err(context + ": missing `" + key + "`")
  }
}

///|
fn graph_ir_parse_json_optional_string(
  obj : Map[String, Json],
  key : String,
  default_value : String,
  context : String,
) -> Result[String, String] {
  match obj.get(key) {
    Some(Json::String(s)) => Ok(s)
    Some(_) => Err(context + "." + key + ": expected string")
    None => Ok(default_value)
  }
}

///|
fn graph_ir_parse_json_required_int(
  obj : Map[String, Json],
  key : String,
  context : String,
) -> Result[Int, String] {
  match obj.get(key) {
    Some(Json::Number(n, ..)) => Ok(n.to_int())
    Some(_) => Err(context + "." + key + ": expected number")
    None => Err(context + ": missing `" + key + "`")
  }
}

///|
fn graph_ir_parse_semantic_row_json(
  item : Json,
  index : Int,
  default_language : String,
  default_path : String,
  default_module_hash : String,
) -> Result[@x_exp.GraphIrRow, String] {
  let context = "semantic_rows[" + index.to_string() + "]"
  match item {
    Json::Object(obj) => {
      let language_id = match
        graph_ir_parse_json_optional_string(
          obj, "language_id", default_language, context,
        ) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let path = match
        graph_ir_parse_json_optional_string(obj, "path", default_path, context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let name = match
        graph_ir_parse_json_required_string(obj, "name", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let kind = match
        graph_ir_parse_json_required_string(obj, "kind", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let signature = match
        graph_ir_parse_json_required_string(obj, "signature", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let start = match
        graph_ir_parse_json_required_int(obj, "start", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let end = match graph_ir_parse_json_required_int(obj, "end", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let module_hash = match
        graph_ir_parse_json_optional_string(
          obj, "module_hash", default_module_hash, context,
        ) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let type_terms = match
        graph_ir_parse_json_optional_string_array(obj, "type_terms", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let refs = match
        graph_ir_parse_json_optional_string_array(obj, "refs", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let calls = match
        graph_ir_parse_json_optional_string_array(obj, "calls", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      let imports = match
        graph_ir_parse_json_optional_string_array(obj, "imports", context) {
        Ok(v) => v
        Err(err) => return Err(err)
      }
      Ok(
        @x_exp.new_graph_ir_row(
          language_id, path, name, kind, signature, start, end, module_hash, type_terms,
          refs, calls, imports,
        ),
      )
    }
    _ => Err(context + ": expected object")
  }
}

///|
fn graph_ir_parse_semantic_rows_json(
  json : Json,
  default_language : String,
  default_path : String,
  default_module_hash : String,
) -> Result[Array[@x_exp.GraphIrRow], String] {
  let items = match json {
    Json::Array(rows) => rows
    Json::Object(obj) =>
      match obj.get("rows") {
        Some(Json::Array(rows)) => rows
        Some(_) => return Err("semantic rows: `rows` must be array")
        None =>
          return Err(
            "semantic rows: expected top-level array or object with `rows`",
          )
      }
    _ =>
      return Err(
        "semantic rows: expected top-level array or object with `rows`",
      )
  }
  let out : Array[@x_exp.GraphIrRow] = []
  for i in 0..<items.length() {
    let row = match
      graph_ir_parse_semantic_row_json(
        items[i],
        i,
        default_language,
        default_path,
        default_module_hash,
      ) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    out.push(row)
  }
  Ok(out)
}

///|
fn graph_ir_load_semantic_rows_file(
  semantic_rows_path : String,
  path : String,
  source : String,
) -> Result[Array[@x_exp.GraphIrRow], String] {
  let content = @os_fs.read_file_to_string(semantic_rows_path) catch {
    e => return Err("read semantic rows: " + e.to_string())
  }
  let parsed : Json = @json.parse(content) catch {
    e => return Err("parse semantic rows JSON: " + e.to_string())
  }
  let default_language = match @x_exp.detect_language_id(path) {
    Some(id) => id
    None => "unknown"
  }
  let default_module_hash = @vibe_core.content_address_hash_string(source)
  graph_ir_parse_semantic_rows_json(
    parsed, default_language, path, default_module_hash,
  )
}

///|
fn graph_ir_semantic_rows_provider(
  semantic_rows_path : String?,
) -> ((String, String, Array[@x_exp.GraphIrRow]) -> Result[
  Array[@x_exp.GraphIrRow],
  String,
])? {
  match semantic_rows_path {
    Some(path) =>
      Some(fn(entry_path, source, baseline_rows) {
        let _ = baseline_rows
        graph_ir_load_semantic_rows_file(path, entry_path, source)
      })
    None => None
  }
}

///|
fn print_ide_outline_entry(
  entry : @frontend.SymbolEntry,
  source : String,
) -> Unit {
  let (line, _) = symbol_line_col(source, entry.span)
  println(
    "L" +
    zero_pad_number(line, 3) +
    " | " +
    @frontend.symbol_kind_name(entry.kind) +
    " " +
    entry.name +
    " : " +
    entry.signature,
  )
}

///|
fn print_graph_ir_outline_entry(row : @x_exp.GraphIrRow) -> Unit {
  println(row.kind + " " + row.name + " : " + row.signature)
}

///|
fn ide_outline_cmd(args : Array[String]) -> Unit {
  let (positionals, semantic_rows_path) = match
    graph_ir_parse_semantic_rows_flag(args, "ide outline") {
    Ok(v) => v
    Err(err) => abort(err)
  }
  if positionals.length() != 1 {
    abort("ide outline: expected <file>")
  }
  let path = positionals[0]
  // For non-.vibe files, use multi-language extractor
  match @x_exp.detect_language_id(path) {
    Some("vibe") | None =>
      if semantic_rows_path is Some(_) {
        abort(
          "ide outline: --semantic-rows is only supported for non-vibe files",
        )
      }
    Some(_) => {
      let source = @os_fs.read_file_to_string(path) catch {
        e => abort("ide outline: " + e.to_string())
      }
      let provider = graph_ir_semantic_rows_provider(semantic_rows_path)
      match
        @x_exp.extract_graph_ir_rows_with_semantic_provider(
          path,
          source,
          provider~,
        ) {
        Ok(rows) => {
          if rows.length() == 0 {
            println("No symbols found in " + path)
            return
          }
          println("Outline: " + path)
          for row in rows {
            print_graph_ir_outline_entry(row)
          }
        }
        Err(err) => abort("ide outline: " + err)
      }
      return
    }
  }
  match @loader.load_db_with_paths(path) {
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
  entry : @frontend.SymbolEntry,
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
    @frontend.symbol_kind_name(entry.kind) +
    " " +
    entry.name +
    " : " +
    entry.signature,
  )
}

///|
fn print_graph_ir_peek_def_entry(
  row : @x_exp.GraphIrRow,
  source : String,
) -> Unit {
  let (line, column) = graph_ir_line_col(source, row)
  println("")
  println(
    row.kind +
    " " +
    row.name +
    " at " +
    row.path +
    ":" +
    line.to_string() +
    ":" +
    column.to_string(),
  )
  let snippet = graph_ir_line_text(source, row)
  if snippet.length() > 0 {
    println(snippet)
  }
}

///|
fn print_graph_ir_search_entry(
  row : @x_exp.GraphIrRow,
  source : String,
) -> Unit {
  let (line, column) = graph_ir_line_col(source, row)
  println(
    row.path +
    ":" +
    line.to_string() +
    ":" +
    column.to_string() +
    "  " +
    row.kind +
    " " +
    row.name +
    " : " +
    row.signature,
  )
}

///|
fn ide_peek_def_cmd(args : Array[String]) -> Unit {
  let (positionals, semantic_rows_path) = match
    graph_ir_parse_semantic_rows_flag(args, "ide peek-def") {
    Ok(v) => v
    Err(err) => abort(err)
  }
  if positionals.length() != 2 {
    abort("ide peek-def: expected <symbol> <entry-file>")
  }
  let symbol = positionals[0]
  let entry_file = positionals[1]
  match @x_exp.detect_language_id(entry_file) {
    Some("vibe") | None =>
      if semantic_rows_path is Some(_) {
        abort(
          "ide peek-def: --semantic-rows is only supported for non-vibe files",
        )
      }
    Some(_) => {
      let source = @os_fs.read_file_to_string(entry_file) catch {
        e => abort("ide peek-def: " + e.to_string())
      }
      let provider = graph_ir_semantic_rows_provider(semantic_rows_path)
      match
        @x_exp.extract_graph_ir_rows_with_semantic_provider(
          entry_file,
          source,
          provider~,
        ) {
        Ok(rows) => {
          let matches = graph_ir_find_exact_rows(rows, symbol)
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
          for row in matches {
            print_graph_ir_peek_def_entry(row, source)
          }
        }
        Err(err) => abort("ide peek-def: " + err)
      }
      return
    }
  }
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
              @frontend.symbol_kind_name(entry.kind) +
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
  let (positionals, semantic_rows_path) = match
    graph_ir_parse_semantic_rows_flag(args, "ide search") {
    Ok(v) => v
    Err(err) => abort(err)
  }
  if positionals.length() != 2 {
    abort("ide search: expected <query> <entry-file>")
  }
  let query = positionals[0]
  let entry_file = positionals[1]
  match @x_exp.detect_language_id(entry_file) {
    Some("vibe") | None =>
      if semantic_rows_path is Some(_) {
        abort(
          "ide search: --semantic-rows is only supported for non-vibe files",
        )
      }
    Some(_) => {
      let source = @os_fs.read_file_to_string(entry_file) catch {
        e => abort("ide search: " + e.to_string())
      }
      let provider = graph_ir_semantic_rows_provider(semantic_rows_path)
      match
        @x_exp.extract_graph_ir_rows_with_semantic_provider(
          entry_file,
          source,
          provider~,
        ) {
        Ok(rows) => {
          let matches = graph_ir_search_rows(rows, query)
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
          for row in matches {
            print_graph_ir_search_entry(row, source)
          }
        }
        Err(err) => abort("ide search: " + err)
      }
      return
    }
  }
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
  let mut semantic_rows_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--semantic-rows" {
      i += 1
      if i >= args.length() {
        abort("lsif: missing path after --semantic-rows")
      }
      if semantic_rows_path is Some(_) {
        abort("lsif: duplicate --semantic-rows")
      }
      semantic_rows_path = Some(args[i])
      i += 1
      continue
    }
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
  match @x_exp.detect_language_id(entries[0]) {
    Some("vibe") | None =>
      if semantic_rows_path is Some(_) {
        abort("lsif: --semantic-rows is only supported for non-vibe files")
      }
    Some(_) => {
      let source = @os_fs.read_file_to_string(entries[0]) catch {
        e => abort("lsif: " + e.to_string())
      }
      let provider = graph_ir_semantic_rows_provider(semantic_rows_path)
      match
        @x_exp.extract_graph_ir_rows_with_semantic_provider(
          entries[0],
          source,
          provider~,
        ) {
        Ok(rows) => {
          let index = graph_ir_rows_to_symbol_index(rows)
          let lines = @frontend.symbol_index_to_lsif_lines(index, fn(path) {
            if path == entries[0] {
              Some(source)
            } else {
              None
            }
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
      return
    }
  }
  match @loader.load_db_with_paths(entries[0]) {
    Ok((db, _, paths)) => {
      let index = @runtime.build_symbol_index(db, paths)
      let lines = @frontend.symbol_index_to_lsif_lines(index, fn(path) {
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
fn write_cache_graph_head(
  index_root : String,
  graph_head : String,
  function_tracking : Json,
) -> Result[Unit, String] {
  let cache_obj = load_vibe_cache_object(index_root)
  cache_obj["graph_head"] = Json::string(graph_head)
  cache_obj["function_tracking"] = function_tracking
  write_vibe_cache_object(index_root, cache_obj)
}

///|
fn sync_graph_head_for_loaded_db(
  db : @runtime.VibeDb,
  entry : String,
  paths : Array[String],
  base_commit : String,
  skip_types? : Bool = false,
) -> Result[(@x_exp.AdvancedGraphIndex, String), String] {
  let index = @x_exp.build_advanced_graph_index(
    db,
    paths,
    base_commit~,
    created_at=@env.now().to_string(),
    skip_types~,
  )
  let index_json = index.to_json().stringify()
  let graph_head = @vibe_core.git_blob_hash_string(index_json)
  let index_root = @codebase.resolve_index_root(entry)
  let vibe_dir = find_vibe_dir(index_root + "/index.vibe")
  let codebase = @codebase.Codebase::new(vibe_dir)
  let _ = codebase.write_object(graph_head, index_json) catch {
    e => return Err("sync graph snapshot object: " + e.to_string())
  }
  let cache_obj = load_vibe_cache_object(index_root)
  let function_tracking = if skip_types {
    let empty : Map[String, Json] = {}
    Json::object(empty)
  } else {
    compute_function_tracking_json(db, paths, index, cache_obj)
  }
  match
    write_cache_graph_head(index_root, graph_head, function_tracking) {
    Ok(_) => ()
    Err(err) => return Err(err)
  }
  Ok((index, graph_head))
}

///|
fn resolve_entry_artifacts(
  entry_path : String,
  skip_types? : Bool = false,
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
    sync_graph_head_for_loaded_db(db, entry, paths, "", skip_types~) {
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
            " defs), index.vbundle graph_head=" +
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
fn bundle_normalize_hash(hash : String) -> String {
  if hash.has_prefix("#") && hash.length() > 1 {
    hash.unsafe_substring(start=1, end=hash.length())
  } else {
    hash
  }
}

///|
fn bundle_read_json_file(path : String) -> Result[Map[String, Json], String] {
  let source = @os_fs.read_file_to_string(path) catch {
    e => return Err("bundle: read failed: " + path + " (" + e.to_string() + ")")
  }
  let parsed : Json = @json.parse(source) catch {
    e => return Err("bundle: invalid JSON: " + e.to_string())
  }
  match parsed {
    Json::Object(obj) => Ok(obj)
    _ => Err("bundle: top-level JSON must be an object")
  }
}

///|
fn bundle_collect_lock_hashes(lock_obj : Map[String, Json]) -> Array[String] {
  let hashes : Array[String] = []
  let push_hash = fn(raw : String) {
    let normalized = bundle_normalize_hash(raw.trim().to_string())
    if normalized.length() == 0 {
      return
    }
    for existing in hashes {
      if existing == normalized {
        return
      }
    }
    hashes.push(normalized)
  }
  let collect_map = fn(field : String) {
    match lock_obj.get(field) {
      Some(Json::Object(entries)) =>
        for _, value in entries {
          match value {
            Json::String(hash) => push_hash(hash)
            _ => ()
          }
        }
      _ => ()
    }
  }
  collect_map("path")
  collect_map("version")
  collect_map("symbol")
  hashes
}

///|
struct BundleSyncCmdOptions {
  target_path : String
  base_path : String?
  lib_root : String?
  scope : String?
  bundle_version : String?
} derive(Show, Eq)

///|
struct BundleSyncPlan {
  total_objects : Int
  skipped_base_objects : Int
  entries : Array[(String, String)]
} derive(Show, Eq)

///|
fn bundle_sync_parse_semver_digits(text : String) -> Int? {
  if text.length() == 0 {
    return None
  }
  let mut value = 0
  for _, c in text {
    if c < '0' || c > '9' {
      return None
    }
    value = value * 10 + c.to_int() - '0'.to_int()
  }
  Some(value)
}

///|
fn bundle_sync_parse_semver(text : String) -> (Int, Int, Int)? {
  let parts : Array[String] = []
  for part in text.split(".") {
    parts.push(part.to_string())
  }
  if parts.length() != 3 {
    return None
  }
  let major = match bundle_sync_parse_semver_digits(parts[0]) {
    Some(v) => v
    None => return None
  }
  let minor = match bundle_sync_parse_semver_digits(parts[1]) {
    Some(v) => v
    None => return None
  }
  let patch = match bundle_sync_parse_semver_digits(parts[2]) {
    Some(v) => v
    None => return None
  }
  Some((major, minor, patch))
}

///|
fn bundle_sync_compare_semver(a : (Int, Int, Int), b : (Int, Int, Int)) -> Int {
  let (a_major, a_minor, a_patch) = a
  let (b_major, b_minor, b_patch) = b
  if a_major < b_major {
    -1
  } else if a_major > b_major {
    1
  } else if a_minor < b_minor {
    -1
  } else if a_minor > b_minor {
    1
  } else if a_patch < b_patch {
    -1
  } else if a_patch > b_patch {
    1
  } else {
    0
  }
}

///|
fn bundle_scope_parent_and_name(scope : String) -> (String, String) {
  let mut last_slash : Int? = None
  for i, c in scope {
    if c == '/' {
      last_slash = Some(i)
    }
  }
  match last_slash {
    Some(i) =>
      (
        scope.unsafe_substring(start=0, end=i),
        scope.unsafe_substring(start=i + 1, end=scope.length()),
      )
    None => ("", scope)
  }
}

///|
fn bundle_sync_find_previous_alias_path(
  lib_root : String,
  scope : String,
  target_version : String,
) -> String? {
  let target_semver = match bundle_sync_parse_semver(target_version) {
    Some(v) => v
    None => return None
  }
  let (parent, leaf) = bundle_scope_parent_and_name(scope)
  if leaf.length() == 0 {
    return None
  }
  let dir = if parent.length() == 0 {
    @vibe_fs.normalize_path(lib_root)
  } else {
    @vibe_fs.normalize_path(lib_root + "/" + parent)
  }
  let entries = @os_fs.read_dir(dir) catch { _ => return None }
  let prefix = leaf + "@"
  let suffix = ".vbundle"
  let mut best_name : String? = None
  let mut best_semver : (Int, Int, Int)? = None
  for entry in entries {
    if not(entry.has_prefix(prefix)) || not(entry.has_suffix(suffix)) {
      continue
    }
    let ver_start = prefix.length()
    let ver_end = entry.length() - suffix.length()
    if ver_end <= ver_start {
      continue
    }
    let version = entry.unsafe_substring(start=ver_start, end=ver_end)
    match bundle_sync_parse_semver(version) {
      Some(semver) =>
        if bundle_sync_compare_semver(semver, target_semver) < 0 {
          match best_semver {
            Some(prev) =>
              if bundle_sync_compare_semver(semver, prev) > 0 {
                best_semver = Some(semver)
                best_name = Some(entry)
              }
            None => {
              best_semver = Some(semver)
              best_name = Some(entry)
            }
          }
        }
      None => ()
    }
  }
  match best_name {
    Some(name) => Some(@vibe_fs.normalize_path(dir + "/" + name))
    None => None
  }
}

///|
fn bundle_sync_resolve_input_path(input : String, lib_root : String) -> String {
  if input.has_prefix("/") {
    return @vibe_fs.normalize_path(input)
  }
  let cwd = @io.current_dir_or_root()
  let direct = @vibe_fs.normalize_path(cwd + "/" + input)
  if @os_fs.path_exists(direct) {
    return direct
  }
  @vibe_fs.normalize_path(lib_root + "/" + input)
}

///|
fn bundle_sync_load_source(
  path : String,
  lib_root : String,
) -> Result[(String, String?), String] {
  if not(@os_fs.path_exists(path)) {
    return Err("bundle sync: bundle not found: " + path)
  }
  let is_file = @os_fs.is_file(path) catch { _ => false }
  if not(is_file) {
    return Err("bundle sync: bundle path is not a file: " + path)
  }
  let source = @os_fs.read_file_to_string(path) catch {
    e =>
      return Err(
        "bundle sync: read failed: " + path + " (" + e.to_string() + ")",
      )
  }
  match parse_include_hash_alias(source) {
    Some(hash) => {
      let roots : Array[String] = []
      let include_parent = @vibe_fs.parent_path(path)
      if path_last_segment(include_parent) == "vibe" {
        roots.push(@vibe_fs.parent_path(include_parent))
      }
      if roots.length() == 0 || roots[0] != lib_root {
        roots.push(lib_root)
      }
      for root in roots {
        match try_load_hash_source_from_root(root, hash) {
          Some(content) => return Ok((content, Some(hash)))
          None => ()
        }
      }
      Err(
        "bundle sync: hash alias unresolved: " +
        path +
        " -> " +
        hash +
        " (not found in local stores)",
      )
    }
    None => Ok((source, None))
  }
}

///|
fn bundle_sync_parse_root(
  source : String,
  context : String,
) -> Result[Map[String, Json], String] {
  let parsed : Json = @json.parse(source) catch {
    e => return Err(context + ": invalid JSON: " + e.to_string())
  }
  match parsed {
    Json::Object(obj) => Ok(obj)
    _ => Err(context + ": top-level JSON must be an object")
  }
}

///|
fn bundle_sync_extract_objects(
  root : Map[String, Json],
  context : String,
) -> Result[Map[String, Json], String] {
  match root.get("objects") {
    Some(Json::Object(obj)) => Ok(obj)
    _ => Err(context + ": missing `objects` object")
  }
}

///|
fn bundle_sync_extract_meta_value(
  root : Map[String, Json],
  key : String,
) -> String? {
  match root.get("meta") {
    Some(Json::Object(meta)) =>
      match meta.get(key) {
        Some(Json::String(value)) => {
          let trimmed = value.trim().to_string()
          if trimmed.length() == 0 {
            None
          } else {
            Some(trimmed)
          }
        }
        _ => None
      }
    _ => None
  }
}

///|
fn bundle_hash_set_from_objects_obj(
  objects : Map[String, Json],
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  for raw_hash, _ in objects {
    let normalized = bundle_normalize_hash(raw_hash)
    if normalized.length() > 0 {
      out[normalized] = true
    }
  }
  out
}

///|
fn bundle_sync_collect_plan(
  target_objects : Map[String, Json],
  base_hashes : Map[String, Bool],
) -> Result[BundleSyncPlan, String] {
  let entries : Array[(String, String)] = []
  let mut total_objects = 0
  let mut skipped_base_objects = 0
  for raw_hash, value in target_objects {
    total_objects += 1
    let normalized = bundle_normalize_hash(raw_hash)
    if normalized.length() == 0 {
      continue
    }
    if base_hashes.contains(normalized) {
      skipped_base_objects += 1
      continue
    }
    match value {
      Json::String(content) => entries.push((normalized, content))
      _ =>
        return Err(
          "bundle sync: object payload must be string for hash " + normalized,
        )
    }
  }
  Ok({ total_objects, skipped_base_objects, entries })
}

///|
fn parse_bundle_sync_cmd_options(
  args : Array[String],
) -> Result[BundleSyncCmdOptions, String] {
  let mut base_path : String? = None
  let mut lib_root : String? = None
  let mut scope : String? = None
  let mut bundle_version : String? = None
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--base" => {
        i += 1
        if i >= args.length() {
          return Err("bundle sync: missing value after --base")
        }
        base_path = Some(args[i])
      }
      "--lib-root" => {
        i += 1
        if i >= args.length() {
          return Err("bundle sync: missing value after --lib-root")
        }
        lib_root = Some(args[i])
      }
      "--scope" => {
        i += 1
        if i >= args.length() {
          return Err("bundle sync: missing value after --scope")
        }
        scope = Some(args[i])
      }
      "--version" => {
        i += 1
        if i >= args.length() {
          return Err("bundle sync: missing value after --version")
        }
        bundle_version = Some(args[i])
      }
      _ => {
        if arg.has_prefix("--") {
          return Err("bundle sync: unknown arg " + arg)
        }
        positional.push(arg)
      }
    }
    i += 1
  }
  if positional.length() != 1 {
    return Err(
      "bundle sync: expected [--base <old.vbundle>] [--lib-root <dir>] [--scope <scope>] [--version <version>] <new.vbundle>",
    )
  }
  Ok({ target_path: positional[0], base_path, lib_root, scope, bundle_version })
}

///|
fn bundle_sync_cmd(args : Array[String]) -> Unit {
  let opts = match parse_bundle_sync_cmd_options(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let cwd = @io.current_dir_or_root()
  let lib_root = match opts.lib_root {
    Some(path) =>
      if path.has_prefix("/") {
        @vibe_fs.normalize_path(path)
      } else {
        @vibe_fs.normalize_path(cwd + "/" + path)
      }
    None => resolve_vibe_lib_dir(cwd)
  }
  match ensure_dir_recursive_for_eval(lib_root) {
    Ok(_) => ()
    Err(err) => abort("bundle sync: " + err)
  }
  let target_path = bundle_sync_resolve_input_path(opts.target_path, lib_root)
  let (target_source, target_alias_hash) = match
    bundle_sync_load_source(target_path, lib_root) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let target_root = match
    bundle_sync_parse_root(
      target_source,
      "bundle sync: target `" + target_path + "`",
    ) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  match target_root.get("format") {
    Some(Json::String(format)) =>
      if format != "vbundle-1" {
        abort("bundle sync: target is not vbundle-1: " + target_path)
      }
    _ => abort("bundle sync: target missing `format`")
  }
  let target_objects = match
    bundle_sync_extract_objects(
      target_root,
      "bundle sync: target `" + target_path + "`",
    ) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let target_scope = match opts.scope {
    Some(v) => Some(v)
    None => bundle_sync_extract_meta_value(target_root, "scope")
  }
  let target_version = match opts.bundle_version {
    Some(v) => Some(v)
    None => bundle_sync_extract_meta_value(target_root, "version")
  }
  let base_path = match opts.base_path {
    Some(path) => Some(bundle_sync_resolve_input_path(path, lib_root))
    None =>
      match (target_scope, target_version) {
        (Some(scope), Some(version)) =>
          bundle_sync_find_previous_alias_path(lib_root, scope, version)
        _ => None
      }
  }
  let mut base_hashes : Map[String, Bool] = {}
  let mut base_label : String? = None
  match base_path {
    Some(path) =>
      if path != target_path {
        let (base_source, _) = match bundle_sync_load_source(path, lib_root) {
          Ok(v) => v
          Err(err) => abort(err)
        }
        let base_root = match
          bundle_sync_parse_root(
            base_source,
            "bundle sync: base `" + path + "`",
          ) {
          Ok(v) => v
          Err(err) => abort(err)
        }
        let base_objects = match
          bundle_sync_extract_objects(
            base_root,
            "bundle sync: base `" + path + "`",
          ) {
          Ok(v) => v
          Err(err) => abort(err)
        }
        base_hashes = bundle_hash_set_from_objects_obj(base_objects)
        base_label = Some(path)
      }
    None => ()
  }
  let cache_codebase = @codebase.Codebase::new(lib_root)
  let cached_base_hashes : Map[String, Bool] = {}
  for hash, _ in base_hashes {
    if @io.path_exists(cache_codebase.object_path(hash)) {
      cached_base_hashes[hash] = true
    }
  }
  let plan = match
    bundle_sync_collect_plan(target_objects, cached_base_hashes) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let mut wrote_objects = 0
  let mut skipped_existing = 0
  for entry in plan.entries {
    let (hash, content) = entry
    let object_path = cache_codebase.object_path(hash)
    if @io.path_exists(object_path) {
      skipped_existing += 1
      continue
    }
    let actual = @vibe_core.git_blob_hash_string(content)
    if actual != hash {
      abort(
        "bundle sync: object hash mismatch: expected " +
        hash +
        ", got " +
        actual,
      )
    }
    let _ = cache_codebase.write_object(hash, content) catch {
      e => abort("bundle sync: write object failed: " + e.to_string())
    }
    wrote_objects += 1
  }
  let computed_hash = @vibe_core.git_blob_hash_string(target_source)
  let bundle_hash = match target_alias_hash {
    Some(hash) => {
      let normalized = bundle_normalize_hash(hash)
      if normalized != computed_hash {
        abort(
          "bundle sync: alias hash mismatch: expected " +
          normalized +
          ", got " +
          computed_hash,
        )
      }
      normalized
    }
    None => computed_hash
  }
  let bundle_object_path = cache_codebase.object_path(bundle_hash)
  let mut wrote_bundle_object = false
  if not(@io.path_exists(bundle_object_path)) {
    let _ = cache_codebase.write_object(bundle_hash, target_source) catch {
      e => abort("bundle sync: write bundle object failed: " + e.to_string())
    }
    wrote_bundle_object = true
  }
  let mut alias_path : String? = None
  match (target_scope, target_version) {
    (Some(scope), Some(version)) =>
      if scope.length() > 0 && version.length() > 0 {
        let path = @vibe_fs.normalize_path(
          lib_root + "/" + scope + "@" + version + ".vbundle",
        )
        match ensure_parent_dir_for_file(path, "bundle sync") {
          Ok(_) => ()
          Err(err) => abort("bundle sync: " + err)
        }
        @os_fs.write_string_to_file(path, "hash:" + bundle_hash + "\n") catch {
          e => abort("bundle sync: write alias failed: " + e.to_string())
        }
        alias_path = Some(path)
      }
    _ => ()
  }
  let base_info = match base_label {
    Some(path) => path
    None => "<none>"
  }
  let alias_info = match alias_path {
    Some(path) => path
    None => "<none>"
  }
  println(
    "bundle sync: target=" +
    target_path +
    " base=" +
    base_info +
    " objects=" +
    plan.total_objects.to_string() +
    " delta=" +
    plan.entries.length().to_string() +
    " wrote=" +
    wrote_objects.to_string() +
    " skipped_base=" +
    plan.skipped_base_objects.to_string() +
    " skipped_existing=" +
    skipped_existing.to_string() +
    " bundle_cache=" +
    bundle_hash +
    " bundle_cache_write=" +
    wrote_bundle_object.to_string() +
    " alias=" +
    alias_info,
  )
}

///|
fn bundle_pack_cmd(args : Array[String]) -> Unit {
  let mut scope : String? = None
  let mut version : String? = None
  let mut entry_path : String? = None
  let mut out_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--scope" => {
        i += 1
        if i >= args.length() {
          abort("bundle pack: missing value after --scope")
        }
        scope = Some(args[i])
      }
      "--version" => {
        i += 1
        if i >= args.length() {
          abort("bundle pack: missing value after --version")
        }
        version = Some(args[i])
      }
      "--entry" => {
        i += 1
        if i >= args.length() {
          abort("bundle pack: missing value after --entry")
        }
        entry_path = Some(args[i])
      }
      "-o" | "--out" => {
        i += 1
        if i >= args.length() {
          abort("bundle pack: missing value after " + arg)
        }
        out_path = Some(args[i])
      }
      _ => abort("bundle pack: unknown arg " + arg)
    }
    i += 1
  }
  let scope_value = match scope {
    Some(v) => v
    None => abort("bundle pack: required --scope <scope>")
  }
  let version_value = match version {
    Some(v) => v
    None => abort("bundle pack: required --version <version>")
  }
  let entry_arg = match entry_path {
    Some(v) => v
    None => "."
  }
  let output_path = match out_path {
    Some(v) => v
    None => scope_value + "@" + version_value + ".vbundle"
  }
  let (_db, entry, lock, _index, _graph_head) = match
    resolve_entry_artifacts(entry_arg) {
    Ok(v) => v
    Err(err) => abort("bundle pack: " + err)
  }
  let index_root = @codebase.resolve_index_root(entry)
  let lock_obj : Map[String, Json] = {}
  let path_hash_contents : Map[String, String] = {}
  for path, hash in lock.path_refs {
    let source = @os_fs.read_file_to_string(path) catch { _ => continue }
    let normalized_hash = bundle_normalize_hash(hash)
    let actual_hash = @vibe_core.git_blob_hash_string(source)
    if normalized_hash == actual_hash {
      path_hash_contents[normalized_hash] = source
    }
  }
  let object_hashes : Array[String] = []
  let push_hash = fn(hash : String) {
    let normalized = bundle_normalize_hash(hash)
    if normalized.length() == 0 {
      return
    }
    for existing in object_hashes {
      if existing == normalized {
        return
      }
    }
    object_hashes.push(normalized)
  }
  for hash in bundle_collect_lock_hashes(lock_obj) {
    push_hash(hash)
  }
  for _, hash in lock.path_refs {
    push_hash(hash)
  }
  for _, hash in lock.version_refs {
    push_hash(hash)
  }
  for _, hash in lock.symbol_refs {
    push_hash(hash)
  }
  for _, hash in lock.module_refs {
    push_hash(hash)
  }
  match refs_obj.get("graph_head") {
    Some(Json::String(hash)) => push_hash(hash)
    _ => ()
  }
  object_hashes.sort()
  let vibe_dir = find_vibe_dir(index_root + "/index.vibe")
  let codebase = @codebase.Codebase::new(vibe_dir)
  let objects_obj : Map[String, Json] = {}
  for hash in object_hashes {
    match codebase.read_object(hash) {
      Some(content) => objects_obj[hash] = Json::string(content)
      None =>
        match path_hash_contents.get(hash) {
          Some(content) => objects_obj[hash] = Json::string(content)
          None => ()
        }
    }
  }
  let meta_obj : Map[String, Json] = {}
  meta_obj["scope"] = Json::string(scope_value)
  meta_obj["version"] = Json::string(version_value)
  meta_obj["entry"] = Json::string(entry)
  match lock.path_refs.get(entry) {
    Some(hash) =>
      meta_obj["entry_hash"] = Json::string(bundle_normalize_hash(hash))
    None => ()
  }
  meta_obj["created_at"] = Json::string(@env.now().to_string())
  let root_obj : Map[String, Json] = {}
  root_obj["format"] = Json::string("vbundle-1")
  root_obj["meta"] = Json::object(meta_obj)
  root_obj["refs"] = Json::object(refs_obj)
  root_obj["objects"] = Json::object(objects_obj)
  if output_path.has_prefix("dist/") {
    ensure_dist_dir()
  }
  let bundle_source = Json::object(root_obj).stringify()
  match ensure_parent_dir_for_file(output_path, "bundle pack") {
    Ok(_) => ()
    Err(err) => abort("bundle pack: " + err)
  }
  @os_fs.write_string_to_file(output_path, bundle_source + "\n") catch {
    e => abort("bundle pack: write failed: " + e.to_string())
  }
  let lib_root = resolve_vibe_lib_dir(@io.current_dir_or_root())
  match ensure_dir_recursive_for_eval(lib_root) {
    Ok(_) => ()
    Err(err) => abort("bundle pack: " + err)
  }
  let cache_codebase = @codebase.Codebase::new(lib_root)
  let bundle_hash = @vibe_core.git_blob_hash_string(bundle_source)
  let _ = cache_codebase.write_object(bundle_hash, bundle_source) catch {
    e => abort("bundle pack: write cache object failed: " + e.to_string())
  }
  let alias_path = @vibe_fs.normalize_path(
    lib_root + "/" + scope_value + "@" + version_value + ".vbundle",
  )
  let output_norm = if output_path.has_prefix("/") {
    @vibe_fs.normalize_path(output_path)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + output_path)
  }
  if alias_path != output_norm {
    match ensure_parent_dir_for_file(alias_path, "bundle pack") {
      Ok(_) => ()
      Err(err) => abort("bundle pack: " + err)
    }
    @os_fs.write_string_to_file(alias_path, "hash:" + bundle_hash + "\n") catch {
      e => abort("bundle pack: write alias failed: " + e.to_string())
    }
  }
  println(
    "bundle pack: wrote " +
    output_path +
    " scope=" +
    scope_value +
    " version=" +
    version_value +
    " objects=" +
    objects_obj.length().to_string() +
    " cache=" +
    bundle_hash,
  )
}

///|
fn bundle_verify_cmd(args : Array[String]) -> Unit {
  if args.length() != 1 {
    abort("bundle verify: expected <file.vbundle>")
  }
  let path = args[0]
  let root = match bundle_read_json_file(path) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let refs_obj = match root.get("refs") {
    Some(Json::Object(obj)) => obj
    _ => abort("bundle verify: missing `refs` object")
  }
  let objects_obj = match root.get("objects") {
    Some(Json::Object(obj)) => obj
    _ => abort("bundle verify: missing `objects` object")
  }
  let issues : Array[String] = []
  for hash, value in objects_obj {
    match value {
      Json::String(content) => {
        let actual = @vibe_core.git_blob_hash_string(content)
        if actual != hash {
          issues.push(
            "object hash mismatch: expected " + hash + ", got " + actual,
          )
        }
      }
      _ => issues.push("object payload must be string for hash " + hash)
    }
  }
  let lock_obj = match refs_obj.get("lock") {
    Some(Json::Object(obj)) => obj
    _ => refs_obj
  }
  for hash in bundle_collect_lock_hashes(lock_obj) {
    if not(objects_obj.contains(hash)) {
      issues.push("lock ref hash missing in objects: " + hash)
    }
  }
  match refs_obj.get("graph_head") {
    Some(Json::String(hash)) => {
      let normalized = bundle_normalize_hash(hash)
      if normalized.length() > 0 && not(objects_obj.contains(normalized)) {
        issues.push("graph_head missing in objects: " + normalized)
      }
    }
    _ => ()
  }
  if issues.length() > 0 {
    for issue in issues {
      println("bundle verify: " + issue)
    }
    abort("bundle verify: failed (" + issues.length().to_string() + " issues)")
  }
  println(
    "bundle verify: ok (" + objects_obj.length().to_string() + " objects)",
  )
}

///|
fn bundle_inspect_cmd(args : Array[String]) -> Unit {
  let mut output_json = false
  let mut path : String? = None
  for arg in args {
    if arg == "--json" {
      output_json = true
      continue
    }
    match path {
      Some(_) => abort("bundle inspect: unexpected extra arg: " + arg)
      None => path = Some(arg)
    }
  }
  let bundle_path = match path {
    Some(v) => v
    None => abort("bundle inspect: expected <file.vbundle>")
  }
  if output_json {
    let source = @os_fs.read_file_to_string(bundle_path) catch {
      e => abort("bundle inspect: read failed: " + e.to_string())
    }
    println(source)
    return
  }
  let root = match bundle_read_json_file(bundle_path) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let meta_obj = match root.get("meta") {
    Some(Json::Object(obj)) => obj
    _ => {}
  }
  let scope = match meta_obj.get("scope") {
    Some(Json::String(v)) => v
    _ => ""
  }
  let version = match meta_obj.get("version") {
    Some(Json::String(v)) => v
    _ => ""
  }
  let refs_obj = match root.get("refs") {
    Some(Json::Object(obj)) => obj
    _ => {}
  }
  let objects_obj = match root.get("objects") {
    Some(Json::Object(obj)) => obj
    _ => {}
  }
  println("bundle inspect: " + bundle_path)
  println("  scope: " + scope)
  println("  version: " + version)
  println("  refs keys: " + refs_obj.length().to_string())
  println("  objects: " + objects_obj.length().to_string())
}

///|
fn bundle_cat_cmd(args : Array[String]) -> Unit {
  if args.length() < 3 {
    abort("bundle cat: expected <file.vbundle> --hash <sha1>")
  }
  let bundle_path = args[0]
  let mut hash : String? = None
  let mut i = 1
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--hash" => {
        i += 1
        if i >= args.length() {
          abort("bundle cat: missing value after --hash")
        }
        hash = Some(bundle_normalize_hash(args[i]))
      }
      _ => abort("bundle cat: unknown arg " + arg)
    }
    i += 1
  }
  let hash_value = match hash {
    Some(v) => v
    None => abort("bundle cat: required --hash <sha1>")
  }
  let root = match bundle_read_json_file(bundle_path) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let objects_obj = match root.get("objects") {
    Some(Json::Object(obj)) => obj
    _ => abort("bundle cat: missing `objects`")
  }
  match objects_obj.get(hash_value) {
    Some(Json::String(content)) => println(content)
    Some(_) => abort("bundle cat: object payload is not string: " + hash_value)
    None => abort("bundle cat: hash not found: " + hash_value)
  }
}

///|
fn bundle_migrate_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("bundle migrate: expected <index.vdb> [-o out.vbundle]")
  }
  let mut input_path : String? = None
  let mut out_path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-o" | "--out" => {
        i += 1
        if i >= args.length() {
          abort("bundle migrate: missing value after " + arg)
        }
        out_path = Some(args[i])
      }
      _ =>
        match input_path {
          Some(_) => abort("bundle migrate: unexpected extra arg: " + arg)
          None => input_path = Some(arg)
        }
    }
    i += 1
  }
  let input = match input_path {
    Some(v) => v
    None => abort("bundle migrate: expected <index.vdb>")
  }
  let output = match out_path {
    Some(v) => v
    None =>
      if input.has_suffix(".vdb") {
        input.unsafe_substring(start=0, end=input.length() - 4) + ".vbundle"
      } else {
        input + ".vbundle"
      }
  }
  let source = @os_fs.read_file_to_string(input) catch {
    e => abort("bundle migrate: read failed: " + e.to_string())
  }
  let _ : Json = @json.parse(source) catch {
    e => abort("bundle migrate: invalid JSON input: " + e.to_string())
  }
  match ensure_parent_dir_for_file(output, "bundle migrate") {
    Ok(_) => ()
    Err(err) => abort("bundle migrate: " + err)
  }
  @os_fs.write_string_to_file(output, source) catch {
    e => abort("bundle migrate: write failed: " + e.to_string())
  }
  println("bundle migrate: wrote " + output)
}

///|
fn bundle_cmd(args : Array[String]) -> Unit {
  if args.length() == 0 {
    abort("bundle: expected subcommand (pack|verify|inspect|cat|migrate|sync)")
  }
  let sub = args[0]
  let sub_args = args_tail(args, 1)
  match sub {
    "pack" => bundle_pack_cmd(sub_args)
    "verify" => bundle_verify_cmd(sub_args)
    "inspect" => bundle_inspect_cmd(sub_args)
    "cat" => bundle_cat_cmd(sub_args)
    "migrate" => bundle_migrate_cmd(sub_args)
    "sync" => bundle_sync_cmd(sub_args)
    _ => abort("bundle: unknown subcommand: " + sub)
  }
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
