///|
enum WriteFileSelector {
  Name(String)
  NameHash(String, String)
  Hash(String)
} derive(Debug, Eq)

///|
struct WriteFileCmdOptions {
  entry_path : String?
  selector_text : String
  out_path : String
  no_deps : Bool
  dry_run : Bool
  output_json : Bool
} derive(Debug, Eq)

///|
struct WriteFileDef {
  def_id : String
  name : String
  kind : String
  signature : String
  path : String
  start : Int
  end : Int
  module_hash : String
} derive(Debug, Eq)

///|
struct WriteFileCandidate {
  def : WriteFileDef
  origin : String
} derive(Debug, Eq)

///|
fn first_char_index(text : String, target : Char) -> Int? {
  for i, c in text {
    if c == target {
      return Some(i)
    }
  }
  None
}

///|
fn parse_write_file_selector(raw : String) -> Result[WriteFileSelector, String] {
  let trimmed = raw.trim().to_owned()
  if trimmed.length() == 0 {
    return Err("write_file: selector must not be empty")
  }
  if trimmed.has_prefix("#") {
    let hash = trimmed
      .unsafe_substring(start=1, end=trimmed.length())
      .trim()
      .to_owned()
    if hash.length() == 0 {
      return Err("write_file: selector hash must not be empty")
    }
    return Ok(WriteFileSelector::Hash(hash))
  }
  match first_char_index(trimmed, '#') {
    Some(idx) => {
      let name = trimmed.unsafe_substring(start=0, end=idx).trim().to_owned()
      let hash = trimmed
        .unsafe_substring(start=idx + 1, end=trimmed.length())
        .trim()
        .to_owned()
      if name.length() == 0 {
        return Err("write_file: selector name must not be empty")
      }
      if hash.length() == 0 {
        return Err("write_file: selector hash must not be empty")
      }
      Ok(WriteFileSelector::NameHash(name, hash))
    }
    None => Ok(WriteFileSelector::Name(trimmed))
  }
}

///|
fn parse_write_file_cmd_args(
  args : Array[String],
) -> Result[WriteFileCmdOptions, String] {
  let mut entry_path : String? = None
  let mut no_deps = false
  let mut dry_run = false
  let mut output_json = false
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--entry" {
      i += 1
      if i >= args.length() {
        return Err("write_file: missing path after --entry")
      }
      entry_path = Some(args[i])
      i += 1
      continue
    }
    if arg.has_prefix("--entry=") {
      let path = arg.unsafe_substring(start=8, end=arg.length())
      if path.trim().to_owned().length() == 0 {
        return Err("write_file: --entry path must not be empty")
      }
      entry_path = Some(path)
      i += 1
      continue
    }
    if arg == "--no-deps" {
      no_deps = true
      i += 1
      continue
    }
    if arg == "--dry-run" {
      dry_run = true
      i += 1
      continue
    }
    if arg == "--json" {
      output_json = true
      i += 1
      continue
    }
    if arg.has_prefix("--") {
      return Err("write_file: unknown option: " + arg)
    }
    positional.push(arg)
    i += 1
  }
  if positional.length() != 2 {
    return Err(
      "write_file: expected [--entry file] [--no-deps] [--dry-run] [--json] <selector> <out-file>",
    )
  }
  Ok({
    entry_path,
    selector_text: positional[0],
    out_path: positional[1],
    no_deps,
    dry_run,
    output_json,
  })
}

///|
fn write_file_def_id_from_symbol_entry(entry : @frontend.SymbolEntry) -> String {
  let key = entry.path +
    "|" +
    entry.span.start.to_string() +
    "|" +
    entry.span.end.to_string() +
    "|" +
    entry.name +
    "|" +
    @frontend.symbol_kind_name(entry.kind) +
    "|" +
    entry.signature
  @vibe_core.git_blob_hash_string(key)
}

///|
fn write_file_graph_def_from_symbol_entry(
  db : @runtime.VibeDb,
  entry : @frontend.SymbolEntry,
) -> WriteFileDef {
  {
    def_id: write_file_def_id_from_symbol_entry(entry),
    name: entry.name,
    kind: @frontend.symbol_kind_name(entry.kind),
    signature: entry.signature,
    path: entry.path,
    start: entry.span.start,
    end: entry.span.end,
    module_hash: @vibe_core.hash_module(db.ast(entry.path)),
  }
}

///|
fn write_file_def_from_index_def(def : @x_exp.AdvancedGraphDef) -> WriteFileDef {
  {
    def_id: def.def_id,
    name: def.name,
    kind: def.kind,
    signature: def.signature,
    path: def.path,
    start: def.start,
    end: def.end,
    module_hash: def.module_hash,
  }
}

///|
fn write_file_candidates_from_index(
  index : @x_exp.AdvancedGraphIndex,
) -> Array[WriteFileCandidate] {
  let out : Array[WriteFileCandidate] = []
  for _, def in index.defs {
    out.push({ def: write_file_def_from_index_def(def), origin: "index" })
  }
  out
}

///|
fn write_file_candidate_label(candidate : WriteFileCandidate) -> String {
  candidate.origin +
  ":" +
  candidate.def.name +
  "\t" +
  candidate.def.path +
  "#" +
  short_hash(candidate.def.def_id)
}

///|
fn write_file_result_json(
  candidate : WriteFileCandidate,
  out_path : String,
  no_deps : Bool,
  dry_run : Bool,
) -> Json {
  let obj : Map[String, Json] = {}
  obj["status"] = Json::string("ok")
  obj["dry_run"] = Json::boolean(dry_run)
  obj["origin"] = Json::string(candidate.origin)
  obj["kind"] = Json::string(candidate.def.kind)
  obj["name"] = Json::string(candidate.def.name)
  obj["path"] = Json::string(candidate.def.path)
  obj["hash"] = Json::string(candidate.def.def_id)
  obj["short_hash"] = Json::string(short_hash(candidate.def.def_id))
  obj["signature"] = Json::string(candidate.def.signature)
  obj["module_hash"] = Json::string(candidate.def.module_hash)
  obj["out_path"] = Json::string(out_path)
  obj["no_deps"] = Json::boolean(no_deps)
  Json::object(obj)
}

///|
fn write_file_ambiguous_error(
  prefix : String,
  matches : Array[WriteFileCandidate],
) -> String {
  let labels : Array[String] = []
  for candidate in matches {
    labels.push(write_file_candidate_label(candidate))
  }
  labels.sort()
  let buf = StringBuilder::new()
  buf.write_string(prefix)
  buf.write_string("\nUse `name#hash` or `#hash` selector.")
  for label in labels {
    buf.write_string("\n  - " + label)
  }
  buf.to_string()
}

///|
fn write_file_filter_name(
  candidates : Array[WriteFileCandidate],
  name : String,
) -> Array[WriteFileCandidate] {
  let out : Array[WriteFileCandidate] = []
  for candidate in candidates {
    if candidate.def.name == name {
      out.push(candidate)
    }
  }
  out
}

///|
fn write_file_filter_hash(
  candidates : Array[WriteFileCandidate],
  hash_prefix : String,
  name? : String = "",
) -> Array[WriteFileCandidate] {
  let out : Array[WriteFileCandidate] = []
  for candidate in candidates {
    if !candidate.def.def_id.has_prefix(hash_prefix) {
      continue
    }
    if name.length() > 0 && candidate.def.name != name {
      continue
    }
    out.push(candidate)
  }
  out
}

///|
fn write_file_resolve_single(
  matches : Array[WriteFileCandidate],
  not_found_message : String,
  ambiguous_message : String,
) -> Result[WriteFileCandidate, String] {
  if matches.length() == 0 {
    return Err(not_found_message)
  }
  if matches.length() > 1 {
    return Err(write_file_ambiguous_error(ambiguous_message, matches))
  }
  Ok(matches[0])
}

///|
fn write_file_resolve_candidate(
  selector : WriteFileSelector,
  scratch_candidates : Array[WriteFileCandidate],
  index_candidates : Array[WriteFileCandidate],
) -> Result[WriteFileCandidate, String] {
  match selector {
    WriteFileSelector::Name(name) => {
      let scratch_matches = write_file_filter_name(scratch_candidates, name)
      if scratch_matches.length() > 1 {
        return Err(
          write_file_ambiguous_error(
            "write_file: scratch selector is ambiguous for `" + name + "`",
            scratch_matches,
          ),
        )
      }
      if scratch_matches.length() == 1 {
        return Ok(scratch_matches[0])
      }
      let index_matches = write_file_filter_name(index_candidates, name)
      write_file_resolve_single(
        index_matches,
        "write_file: selector not found: `" + name + "`",
        "write_file: selector is ambiguous for `" + name + "`",
      )
    }
    WriteFileSelector::NameHash(name, hash_prefix) => {
      let combined : Array[WriteFileCandidate] = []
      for candidate in scratch_candidates {
        combined.push(candidate)
      }
      for candidate in index_candidates {
        combined.push(candidate)
      }
      let matches = write_file_filter_hash(combined, hash_prefix, name~)
      write_file_resolve_single(
        matches,
        "write_file: selector not found: `" + name + "#" + hash_prefix + "`",
        "write_file: selector is ambiguous for `" +
        name +
        "#" +
        hash_prefix +
        "`",
      )
    }
    WriteFileSelector::Hash(hash_prefix) => {
      let combined : Array[WriteFileCandidate] = []
      for candidate in scratch_candidates {
        combined.push(candidate)
      }
      for candidate in index_candidates {
        combined.push(candidate)
      }
      let matches = write_file_filter_hash(combined, hash_prefix)
      write_file_resolve_single(
        matches,
        "write_file: selector not found: `#" + hash_prefix + "`",
        "write_file: selector is ambiguous for `#" + hash_prefix + "`",
      )
    }
  }
}

///|
fn graph_head_from_cache(cache : Map[String, Json]) -> String? {
  match cache.get("graph_head") {
    Some(Json::String(hash)) => {
      let normalized = hash.trim().to_owned()
      if normalized.length() == 0 {
        None
      } else {
        Some(normalized)
      }
    }
    _ => None
  }
}

///|
fn load_graph_index_from_index_root(
  index_root : String,
) -> Result[@x_exp.AdvancedGraphIndex?, String] {
  let cache = load_vibe_cache_object(index_root)
  let graph_head = match graph_head_from_cache(cache) {
    Some(hash) => hash
    None => return Ok(None)
  }
  let vibe_dir = find_vibe_dir(index_root + "/index.vibe")
  let codebase = @codebase.Codebase::new(vibe_dir)
  let graph_source = match codebase.read_object(graph_head) {
    Some(source) => source
    None =>
      return Err(
        "write_file: graph head object not found: " +
        graph_head +
        " in " +
        vibe_dir,
      )
  }
  let graph_json : Json = @json.parse(graph_source) catch {
    e => return Err("write_file: graph head parse failed: " + e.to_string())
  }
  match @x_exp.advanced_graph_index_from_json(graph_json) {
    Ok(index) => Ok(Some(index))
    Err(err) => Err("write_file: graph head decode failed: " + err)
  }
}

///|
fn load_scratch_write_file_candidates(
  index_root : String,
) -> Result[Array[WriteFileCandidate], String] {
  let (_, scratch_db_path) = match
    resolve_scratch_db_path_for_index_root(index_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if not(@os_fs.path_exists(scratch_db_path)) {
    return Ok([])
  }
  let source = match load_scratch_db_source(scratch_db_path) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  if source.trim().to_owned().length() == 0 {
    return Ok([])
  }
  let _ = @parser.parse_ast(source) catch {
    e => return Err("write_file: scratch db parse failed: " + e.to_string())
  }
  let db = @runtime.VibeDb::new()
  db.set_source(scratch_db_path, source)
  let symbol_index = @runtime_compile.build_symbol_index(db, [scratch_db_path])
  let out : Array[WriteFileCandidate] = []
  for entry in symbol_index.entries {
    let def = write_file_graph_def_from_symbol_entry(db, entry)
    out.push({ def, origin: "scratch" })
  }
  Ok(out)
}

///|
fn read_write_file_source(path : String) -> Result[String, String] {
  let resolved = @loader.resolve_entry_path(path)
  if !@os_fs.path_exists(resolved) {
    return Err("write_file: source path not found: " + resolved)
  }
  let is_file = @os_fs.is_file(resolved) catch { _ => false }
  if !is_file {
    return Err("write_file: source path is not a file: " + resolved)
  }
  let source = @os_fs.read_file_to_string(resolved) catch {
    e =>
      return Err(
        "write_file: failed to read `" + resolved + "`: " + e.to_string(),
      )
  }
  Ok(source)
}

///|
fn write_file_source_exports_name(source : String, name : String) -> Bool {
  let ast = @parser.parse_ast(source) catch {
    _ =>
      return source.contains("export { " + name + " }") ||
        source.contains("export {" + name + "}")
  }
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(name=export_name, ..) =>
        if export_name == name {
          return true
        }
      @vibe_core.Stmt::ExportEnumDef(name=export_name, ..) =>
        if export_name == name {
          return true
        }
      @vibe_core.Stmt::ExportTypeAlias(name=export_name, ..) =>
        if export_name == name {
          return true
        }
      @vibe_core.Stmt::ExportStructDef(name=export_name, ..) =>
        if export_name == name {
          return true
        }
      @vibe_core.Stmt::TraitDef(name=trait_name, exported~, ..) =>
        if exported && trait_name == name {
          return true
        }
      @vibe_core.Stmt::Export(names~, ..) =>
        for export_name in names {
          if export_name == name {
            return true
          }
        }
      @vibe_core.Stmt::ReExport(spec~, ..) =>
        for item in spec.items {
          let export_name = @vibe_core.import_item_local_name(item)
          if export_name == name {
            return true
          }
        }
      _ => ()
    }
  }
  false
}

///|
fn ensure_write_file_export(source : String, name : String) -> String {
  if write_file_source_exports_name(source, name) {
    return source
  }
  let buf = StringBuilder::new()
  buf.write_string(source)
  if source.length() > 0 && !source.has_suffix("\n") {
    buf.write_char('\n')
  }
  buf.write_string("export { " + name + " }\n")
  buf.to_string()
}

///|
fn materialize_write_file_source(
  source : String,
  def : WriteFileDef,
  no_deps : Bool,
) -> Result[String, String] {
  if !no_deps {
    return Ok(source)
  }
  let snippet = source_slice_by_span(source, def.start, def.end)
  if snippet.trim().to_owned().length() == 0 {
    return Err(
      "write_file: empty selector span for " + def.path + "#" + def.name,
    )
  }
  if snippet.has_suffix("\n") {
    Ok(snippet)
  } else {
    Ok(snippet + "\n")
  }
}

///|
fn write_file_cmd(args : Array[String]) -> Unit {
  let options = match parse_write_file_cmd_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let selector = match parse_write_file_selector(options.selector_text) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let (index_root, index_candidates) = match options.entry_path {
    Some(entry_path) => {
      let resolved_entry = @loader.resolve_entry_path(entry_path)
      let index = match resolve_entry_artifacts(resolved_entry) {
        Ok((_, _, _, index, _)) => index
        Err(err) => abort("write_file: " + err)
      }
      (
        @codebase.resolve_index_root(resolved_entry),
        write_file_candidates_from_index(index),
      )
    }
    None => {
      let root = current_workspace_index_root()
      let candidates = match load_graph_index_from_index_root(root) {
        Ok(Some(index)) => write_file_candidates_from_index(index)
        Ok(None) => []
        Err(err) => abort(err)
      }
      (root, candidates)
    }
  }
  let scratch_candidates = match
    load_scratch_write_file_candidates(index_root) {
    Ok(v) => v
    Err(err) => abort("write_file: " + err)
  }
  let selected = match
    write_file_resolve_candidate(selector, scratch_candidates, index_candidates) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let source = match read_write_file_source(selected.def.path) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let materialized = match
    materialize_write_file_source(source, selected.def, options.no_deps) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let out_source = ensure_write_file_export(materialized, selected.def.name)
  if options.dry_run {
    if options.output_json {
      println(
        write_file_result_json(
          selected,
          options.out_path,
          options.no_deps,
          true,
        ).stringify(),
      )
    } else {
      println(
        "write_file(dry-run): " +
        write_file_candidate_label(selected) +
        " -> " +
        options.out_path +
        " no_deps=" +
        options.no_deps.to_string(),
      )
    }
    return
  }
  match write_output_source(options.out_path, out_source) {
    Ok(_) => ()
    Err(err) => abort("write_file: " + err)
  }
  if options.output_json {
    println(
      write_file_result_json(selected, options.out_path, options.no_deps, false).stringify(),
    )
  } else {
    println(
      "write_file: " +
      write_file_candidate_label(selected) +
      " -> " +
      options.out_path +
      " no_deps=" +
      options.no_deps.to_string(),
    )
  }
}
