///|
fn normalize_collect_decl_or_conflict(
  seen : Map[String, String],
  kind : String,
  name : String,
  source_path : String,
) -> Result[Unit, String] {
  let key = kind + ":" + name
  match seen.get(key) {
    Some(prev_path) =>
      if prev_path == source_path {
        Ok(())
      } else {
        Err(
          "normalize: duplicate " +
          kind +
          " `" +
          name +
          "` across files: " +
          prev_path +
          " and " +
          source_path,
        )
      }
    None => {
      seen[key] = source_path
      Ok(())
    }
  }
}

///|
fn normalize_collect_top_level_decls(
  seen : Map[String, String],
  source_path : String,
  source : String,
) -> Result[Unit, String] {
  let ast = @parser.parse_ast(source) catch {
    e =>
      return Err(
        "normalize: parse failed for `" + source_path + "`: " + e.to_string(),
      )
  }
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::Let(name~, ..)
      | @vibe_core.Stmt::ExportLet(name~, ..)
      | @vibe_core.Stmt::LetMut(name~, ..) =>
        match
          normalize_collect_decl_or_conflict(seen, "value", name, source_path) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      @vibe_core.Stmt::EnumDef(name~, ..)
      | @vibe_core.Stmt::ExportEnumDef(name~, ..)
      | @vibe_core.Stmt::TypeAlias(name~, ..)
      | @vibe_core.Stmt::ExportTypeAlias(name~, ..)
      | @vibe_core.Stmt::StructDef(name~, ..)
      | @vibe_core.Stmt::ExportStructDef(name~, ..) =>
        match
          normalize_collect_decl_or_conflict(seen, "type", name, source_path) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      @vibe_core.Stmt::TraitDef(name~, ..) =>
        match
          normalize_collect_decl_or_conflict(seen, "trait", name, source_path) {
          Ok(_) => ()
          Err(err) => return Err(err)
        }
      _ => ()
    }
  }
  Ok(())
}

///|
fn normalize_is_simple_semver(text : String) -> Bool {
  let parts : Array[String] = []
  for part in text.split(".") {
    let normalized = part.to_string()
    if normalized.length() == 0 {
      return false
    }
    for c in normalized {
      if c < '0' || c > '9' {
        return false
      }
    }
    parts.push(normalized)
  }
  parts.length() == 3
}

///|
fn normalize_parse_digits(text : String) -> Int? {
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
fn normalize_parse_semver(text : String) -> (Int, Int, Int)? {
  let parts : Array[String] = []
  for part in text.split(".") {
    parts.push(part.to_string())
  }
  if parts.length() != 3 {
    return None
  }
  let major = match normalize_parse_digits(parts[0]) {
    Some(v) => v
    None => return None
  }
  let minor = match normalize_parse_digits(parts[1]) {
    Some(v) => v
    None => return None
  }
  let patch = match normalize_parse_digits(parts[2]) {
    Some(v) => v
    None => return None
  }
  Some((major, minor, patch))
}

///|
fn normalize_compare_semver(a : (Int, Int, Int), b : (Int, Int, Int)) -> Int {
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
fn normalize_scope_parent_and_name(scope : String) -> (String, String) {
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
fn normalize_resolve_latest_scope_version(
  lib_root : String,
  scope : String,
) -> String? {
  let (parent, leaf) = normalize_scope_parent_and_name(scope)
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
  let suffix = ".lock"
  let mut best_version : String? = None
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
    match normalize_parse_semver(version) {
      Some(semver) =>
        match best_semver {
          Some(prev) =>
            if normalize_compare_semver(semver, prev) > 0 {
              best_semver = Some(semver)
              best_version = Some(version)
            }
          None => {
            best_semver = Some(semver)
            best_version = Some(version)
          }
        }
      None => ()
    }
  }
  best_version
}

///|
fn normalize_line_leading_ws_len(line : String) -> Int {
  let mut i = 0
  while i < line.length() {
    let c = line[i].to_int().unsafe_to_char()
    if c == ' ' || c == '\t' {
      i += 1
      continue
    }
    break
  }
  i
}

///|
fn normalize_split_ws_tokens(text : String) -> Array[String] {
  let out : Array[String] = []
  let mut i = 0
  while i < text.length() {
    while i < text.length() {
      let c = text[i].to_int().unsafe_to_char()
      if c == ' ' || c == '\t' {
        i += 1
        continue
      }
      break
    }
    let start = i
    while i < text.length() {
      let c = text[i].to_int().unsafe_to_char()
      if c == ' ' || c == '\t' {
        break
      }
      i += 1
    }
    if i > start {
      out.push(text.unsafe_substring(start~, end=i))
    }
  }
  out
}

///|
fn normalize_is_unversioned_scope_import_target(scope : String) -> Bool {
  if scope.contains("@") ||
    scope.has_prefix("./") ||
    scope.has_prefix("../") ||
    scope.has_prefix("/") ||
    scope.has_suffix(".vibe") ||
    scope.has_suffix(".xm") ||
    scope.has_suffix(".wasm") ||
    not(scope.contains("/")) {
    false
  } else {
    true
  }
}

///|
fn normalize_resolve_index_import_line(
  line : String,
  lib_root : String,
) -> Result[String, String] {
  let trimmed = line.trim().to_string()
  let head = if trimmed.has_prefix("import ") {
    "import "
  } else {
    return Ok(line)
  }
  let leading_ws = normalize_line_leading_ws_len(line)
  let import_head_end = leading_ws + head.length()
  if import_head_end >= line.length() {
    return Ok(line)
  }
  let rest = line.unsafe_substring(start=import_head_end, end=line.length())
  let prefix = if leading_ws == 0 {
    ""
  } else {
    line.unsafe_substring(start=0, end=leading_ws)
  }
  // Resolve `import <scope> { ... }` declarations.
  match rest.find("{") {
    Some(brace_pos) => {
      let scope_head = rest
        .unsafe_substring(start=0, end=brace_pos)
        .trim()
        .to_string()
      let scope_tokens = normalize_split_ws_tokens(scope_head)
      let scope_buf = StringBuilder::new()
      for token in scope_tokens {
        scope_buf.write_string(token)
      }
      let scope = scope_buf.to_string()
      if scope.length() == 0 ||
        not(normalize_is_unversioned_scope_import_target(scope)) {
        return Ok(line)
      }
      let version = match
        normalize_resolve_latest_scope_version(lib_root, scope) {
        Some(v) => v
        None =>
          return Err(
            "normalize: import `" +
            scope +
            "` missing version; no local alias found under " +
            lib_root,
          )
      }
      let suffix = rest
        .unsafe_substring(start=brace_pos, end=rest.length())
        .trim()
        .to_string()
      let out = StringBuilder::new()
      out.write_string(prefix)
      out.write_string(head)
      out.write_string(scope)
      out.write_char('@')
      out.write_string(version)
      out.write_char(' ')
      out.write_string(suffix)
      return Ok(out.to_string())
    }
    None => ()
  }
  // Resolve legacy bare `import <scope>` declarations.
  let mut rest_trimmed = rest.trim().to_string()
  let has_semicolon = rest_trimmed.has_suffix(";")
  if has_semicolon && rest_trimmed.length() > 0 {
    rest_trimmed = rest_trimmed
      .unsafe_substring(start=0, end=rest_trimmed.length() - 1)
      .trim()
      .to_string()
  }
  let tokens = normalize_split_ws_tokens(rest_trimmed)
  if tokens.length() == 0 {
    return Ok(line)
  }
  let scope_buf = StringBuilder::new()
  let mut alias_name : String? = None
  let mut i = 0
  while i < tokens.length() {
    let token = tokens[i]
    if token == "as" {
      if i + 1 < tokens.length() {
        alias_name = Some(tokens[i + 1])
      }
      break
    }
    scope_buf.write_string(token)
    i += 1
  }
  let scope = scope_buf.to_string()
  if scope.length() == 0 {
    return Ok(line)
  }
  if not(normalize_is_unversioned_scope_import_target(scope)) {
    return Ok(line)
  }
  let version = match normalize_resolve_latest_scope_version(lib_root, scope) {
    Some(v) => v
    None =>
      return Err(
        "normalize: import `" +
        scope +
        "` missing version; no local alias found under " +
        lib_root,
      )
  }
  let out = StringBuilder::new()
  out.write_string(prefix)
  out.write_string(head)
  out.write_string(scope)
  out.write_char('@')
  out.write_string(version)
  match alias_name {
    Some(alias_name2) => {
      out.write_string(" as ")
      out.write_string(alias_name2)
    }
    None => ()
  }
  if has_semicolon {
    out.write_char(';')
  }
  Ok(out.to_string())
}

///|
fn normalize_resolve_index_import_versions(
  source : String,
  lib_root : String,
) -> Result[String, String] {
  let lines : Array[String] = []
  for part in source.split("\n") {
    lines.push(part.to_string())
  }
  let out = StringBuilder::new()
  for i, line in lines {
    let resolved = match normalize_resolve_index_import_line(line, lib_root) {
      Ok(v) => v
      Err(err) => return Err(err)
    }
    if i > 0 {
      out.write_char('\n')
    }
    out.write_string(resolved)
  }
  Ok(out.to_string())
}

///|
fn normalize_ensure_index_version_export(
  source : String,
) -> Result[String, String] {
  let ast = @parser.parse_ast(source) catch {
    e => return Err("normalize: merged parse failed: " + e.to_string())
  }
  for stmt in ast.stmts {
    match stmt {
      @vibe_core.Stmt::ExportLet(name~, expr~, ..) =>
        if name == "version" {
          match expr {
            @vibe_core.Expr::String(value~, ..) =>
              if normalize_is_simple_semver(value) {
                return Ok(source)
              } else {
                return Err(
                  "normalize: index.vibe `export let version` must be semver like \"0.1.0\"",
                )
              }
            _ =>
              return Err(
                "normalize: index.vibe `export let version` must be a string literal",
              )
          }
        }
      _ => ()
    }
  }
  if source.trim().to_string().length() == 0 {
    Ok("export let version = \"0.1.0\"\n")
  } else {
    Ok("export let version = \"0.1.0\"\n\n" + source)
  }
}

///|
fn normalize_directory_vibe_files(
  dir : String,
) -> Result[Array[String], String] {
  let files : Array[String] = []
  let entries = @os_fs.read_dir(dir) catch {
    e =>
      return Err(
        "normalize: read dir failed: " + dir + " (" + e.to_string() + ")",
      )
  }
  for name in entries {
    if name == "." || name == ".." {
      continue
    }
    if not(name.has_suffix(".vibe")) {
      continue
    }
    let path = @vibe_fs.normalize_path(dir + "/" + name)
    let is_file = @os_fs.is_file(path) catch { _ => false }
    if is_file {
      files.push(path)
    }
  }
  files.sort()
  Ok(files)
}

///|
fn normalize_directory_to_index_source(
  dir : String,
  library_mode : Bool,
) -> Result[(String, String), String] {
  let files = match normalize_directory_vibe_files(dir) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let index_path = @vibe_fs.normalize_path(dir + "/index.vibe")
  let source_paths : Array[String] = []
  for path in files {
    source_paths.push(path)
  }
  if source_paths.length() == 0 {
    return Err("normalize: no .vibe files found in directory: " + dir)
  }
  let seen : Map[String, String] = {}
  let normalized_sources : Array[String] = []
  for path in source_paths {
    let source = @os_fs.read_file_to_string(path) catch {
      e => return Err("normalize: " + e.to_string())
    }
    let layering_violations = std_layering_violations_for_source(path, source)
    if layering_violations.length() > 0 {
      for violation in layering_violations {
        println("normalize: \{path}: \{violation}")
      }
      return Err("normalize: std layering violation(s) found")
    }
    let railway_notes = railway_boundary_notes_for_source(source)
    for note in railway_notes {
      println("normalize: \{path}: \{note}")
    }
    match normalize_collect_top_level_decls(seen, path, source) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
    let normalized = match normalize_format_file_source(path) {
      Ok(v) => v
      Err(err) => return Err("normalize: " + err)
    }
    normalized_sources.push(normalized)
  }
  let merged = match normalize_merge_sources(normalized_sources, library_mode) {
    Ok(v) => v
    Err(err) => return Err("normalize: " + err)
  }
  let lib_root = resolve_vibe_lib_dir(@io.current_dir_or_root())
  let resolved_imports = match
    normalize_resolve_index_import_versions(merged, lib_root) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let with_version = match
    normalize_ensure_index_version_export(resolved_imports) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  Ok((with_version, index_path))
}

///|
fn normalize_cmd(args : Array[String]) -> Unit {
  if has_help_flag(args) {
    print_normalize_help()
    return
  }
  let options = match parse_normalize_cmd_options(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  if options.merge {
    normalize_merge_cmd(
      options.files,
      options.library_mode,
      options.output_path,
    )
    return
  }
  let write = options.write
  let check = options.check
  let skip_unchanged = options.skip_unchanged
  let files = options.files
  let mut skipped = 0
  let mut written = 0
  let mut changed = 0
  for path in files {
    let absolute_input = if path.has_prefix("/") {
      @vibe_fs.normalize_path(path)
    } else {
      @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
    }
    let is_dir_input = @os_fs.is_dir(absolute_input) catch { _ => false }
    if is_dir_input {
      let (normalized_dir, index_path) = match
        normalize_directory_to_index_source(
          absolute_input,
          options.library_mode,
        ) {
        Ok(v) => v
        Err(err) => abort(err)
      }
      let existing = if @os_fs.path_exists(index_path) {
        @os_fs.read_file_to_string(index_path) catch {
          _ => ""
        }
      } else {
        ""
      }
      let output = if write || check {
        apply_lock_annotations_for_format(index_path, normalized_dir)
      } else {
        normalized_dir
      }
      if check {
        if output != existing {
          changed += 1
          println("normalize: not normalized: \{index_path}")
        }
        continue
      }
      if write {
        if skip_unchanged && output == existing {
          skipped += 1
          continue
        }
        @os_fs.write_string_to_file(index_path, output) catch {
          e => abort("normalize: " + e.to_string())
        }
        written += 1
      } else {
        println(output)
      }
      continue
    }
    let resolved = @loader.resolve_entry_path(path)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("normalize: " + e.to_string())
    }
    let layering_violations = std_layering_violations_for_source(
      resolved, source,
    )
    if layering_violations.length() > 0 {
      for violation in layering_violations {
        println("normalize: \{path}: \{violation}")
      }
      abort("normalize: std layering violation(s) found")
    }
    let railway_notes = railway_boundary_notes_for_source(source)
    for note in railway_notes {
      println("normalize: \{path}: \{note}")
    }
    let normalized = match normalize_format_file_source(resolved) {
      Ok(v) => v
      Err(err) => abort("normalize: " + err)
    }
    let output = if write || check {
      apply_lock_annotations_for_format(resolved, normalized)
    } else {
      normalized
    }
    if check {
      if output != source {
        changed += 1
        println("normalize: not normalized: \{path}")
      }
      continue
    }
    if write {
      if skip_unchanged && output == source {
        skipped += 1
        continue
      }
      @os_fs.write_string_to_file(resolved, output) catch {
        e => abort("normalize: " + e.to_string())
      }
      written += 1
    } else {
      println(output)
    }
  }
  if check {
    if changed > 0 {
      abort("normalize: \{changed} file(s) are not normalized")
    }
    println("normalize: \{files.length()} files already normalized")
    return
  }
  if skip_unchanged && write {
    println("normalize: \{written} written, \{skipped} skipped (unchanged)")
  }
}

///|
struct NormalizeCmdOptions {
  write : Bool
  check : Bool
  skip_unchanged : Bool
  merge : Bool
  library_mode : Bool
  output_path : String?
  files : Array[String]
}

///|
fn parse_normalize_cmd_options(
  args : Array[String],
) -> Result[NormalizeCmdOptions, String] {
  if args.length() == 0 {
    return Err("normalize: expected <file...>")
  }
  let mut write = false
  let mut check = false
  let mut skip_unchanged = false
  let mut merge = false
  let mut library_mode = false
  let mut output_path : String? = None
  let mut positional_only = false
  let files : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if positional_only {
      files.push(arg)
      i += 1
      continue
    }
    if arg == "--" {
      positional_only = true
      i += 1
      continue
    }
    match arg {
      "--write" | "-w" => {
        write = true
        i += 1
        continue
      }
      "--check" => {
        check = true
        i += 1
        continue
      }
      "--skip-unchanged" => {
        skip_unchanged = true
        i += 1
        continue
      }
      "--merge" => {
        merge = true
        i += 1
        continue
      }
      "--library" => {
        library_mode = true
        i += 1
        continue
      }
      "-o" => {
        i += 1
        if i >= args.length() {
          return Err("normalize: -o requires a path argument")
        }
        output_path = Some(args[i])
        i += 1
        continue
      }
      _ => {
        if arg.has_prefix("-") {
          return Err("normalize: unknown option " + arg)
        }
        files.push(arg)
        i += 1
        continue
      }
    }
  }
  if files.length() == 0 {
    return Err("normalize: expected <file...>")
  }
  if output_path is Some(_) && not(merge) {
    return Err("normalize: -o is only valid with --merge")
  }
  if check && write {
    return Err("normalize: --check cannot be combined with --write")
  }
  if check && skip_unchanged {
    return Err("normalize: --check cannot be combined with --skip-unchanged")
  }
  if check && merge {
    return Err("normalize: --check cannot be combined with --merge")
  }
  if not(write) && not(check) && files.length() > 1 && not(merge) {
    return Err("normalize: use --write or --check for multiple files")
  }
  Ok({ write, check, skip_unchanged, merge, library_mode, output_path, files })
}

///|
fn normalize_merge_cmd(
  files : Array[String],
  library_mode : Bool,
  output_path : String?,
) -> Unit {
  let sources : Array[String] = []
  for path in files {
    let resolved = @loader.resolve_entry_path(path)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("normalize --merge: " + e.to_string())
    }
    sources.push(source)
  }
  let result = match normalize_merge_sources(sources, library_mode) {
    Ok(v) => v
    Err(err) => abort("normalize --merge: " + err)
  }
  match output_path {
    Some(path) => {
      @os_fs.write_string_to_file(path, result) catch {
        e => abort("normalize --merge: " + e.to_string())
      }
      println("normalize --merge: written to \{path}")
    }
    None => println(result)
  }
}

///|
fn fmt_cmd(args : Array[String]) -> Unit {
  if has_help_flag(args) {
    print_fmt_help()
    return
  }
  let options = match parse_fmt_cmd_options(args) {
    Ok(v) => v
    Err(msg) => abort(msg)
  }
  for path in options.files {
    let resolved = @loader.resolve_entry_path(path)
    let source = @os_fs.read_file_to_string(resolved) catch {
      e => abort("fmt: " + e.to_string())
    }
    let formatted = match normalize_format_file_source(resolved) {
      Ok(v) => v
      Err(err) => abort("fmt: " + err)
    }
    let output = apply_lock_annotations_for_format(resolved, formatted)
    if options.dry_run {
      let diff = render_fmt_dry_run_diff(path, source, output)
      if diff.length() > 0 {
        println(diff)
      }
    } else {
      @os_fs.write_string_to_file(resolved, output) catch {
        e => abort("fmt: " + e.to_string())
      }
    }
  }
}

///|
fn apply_lock_annotations_for_format(path : String, source : String) -> String {
  let lock_path = @codebase.lock_file_path(path)
  let lock = match @codebase.load_lock_data(lock_path) {
    Ok(v) => v
    Err(err) => abort("fmt: " + err)
  }
  match @codebase.apply_annotations_to_source(path, source, lock.annotations) {
    Ok(v) => v
    Err(err) => abort("fmt: " + err)
  }
}
