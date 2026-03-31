///|
struct TypecheckFixtureEntry {
  source_path : String
  diag_path : String
} derive(Show, Eq)

///|
pub struct TypecheckFixtureMismatch {
  source_path : String
  expected : String
  actual : String
} derive(Show, Eq)

///|
fn sort_strings_typecheck_fixture(arr : Array[String]) -> Unit {
  let n = arr.length()
  if n < 2 {
    return
  }
  for i in 0..<(n - 1) {
    let mut min_index = i
    for j in (i + 1)..<n {
      if arr[j].compare(arr[min_index]) < 0 {
        min_index = j
      }
    }
    if min_index != i {
      let tmp = arr[i]
      arr[i] = arr[min_index]
      arr[min_index] = tmp
    }
  }
}

///|
fn diag_path_for_fixture(path : String) -> String {
  if path.has_suffix(".vibe") {
    let stem = path[:path.length() - 5].to_string()
    stem + ".diag"
  } else {
    path + ".diag"
  }
}

///|
fn trim_trailing_newlines(text : String) -> String {
  if text.length() == 0 {
    return text
  }
  if text.has_suffix("\n") || text.has_suffix("\r") {
    let next = text[:text.length() - 1].to_string()
    trim_trailing_newlines(next)
  } else {
    text
  }
}

///|
fn render_typecheck_fixture_result(path : String, source : String) -> String {
  let ast = @parser.parse_ast(source) catch {
    e => return e.diagnostic().render(path, source)
  }
  let typed : Result[TypeEnv, TypeError] = try? type_check(ast)
  match typed {
    Ok(_) => "ok"
    Err(e) => e.diagnostic().render(path, source)
  }
}

///|
fn collect_typecheck_fixture_entries(
  fixture_dir : String,
) -> Result[Array[TypecheckFixtureEntry], String] {
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => return Err("[\{fixture_dir}] read_dir failed: \{e.to_string()}")
  }
  let files : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch {
      e => return Err("[\{fixture_dir}] stat failed: \{e.to_string()}")
    }
    if is_file && path.has_suffix(".vibe") {
      files.push(path)
    }
  }
  sort_strings_typecheck_fixture(files)
  if files.length() == 0 {
    return Err("[\{fixture_dir}] no .vibe fixtures found")
  }
  let out : Array[TypecheckFixtureEntry] = []
  for source_path in files {
    out.push({ source_path, diag_path: diag_path_for_fixture(source_path) })
  }
  Ok(out)
}

///|
fn collect_typecheck_fixture_entries_from_paths(
  paths : Array[String],
) -> Result[Array[TypecheckFixtureEntry], String] {
  if paths.length() == 0 {
    return Err("no typecheck fixture paths provided")
  }
  let files = paths.copy()
  sort_strings_typecheck_fixture(files)
  let out : Array[TypecheckFixtureEntry] = []
  for source_path in files {
    if !source_path.has_suffix(".vibe") {
      return Err("[\{source_path}] fixture path must end with .vibe")
    }
    let is_file = @os_fs.is_file(source_path) catch {
      e => return Err("[\{source_path}] stat failed: \{e.to_string()}")
    }
    if !is_file {
      return Err("[\{source_path}] fixture file not found")
    }
    out.push({ source_path, diag_path: diag_path_for_fixture(source_path) })
  }
  Ok(out)
}

///|
fn slice_typecheck_fixture_entries(
  entries : Array[TypecheckFixtureEntry],
  offset : Int,
  limit : Int?,
) -> Array[TypecheckFixtureEntry] {
  let start = if offset < 0 { 0 } else { offset }
  if start >= entries.length() {
    return []
  }
  let end = match limit {
    Some(n) => {
      let requested = if n < 0 { 0 } else { n }
      let next = start + requested
      if next > entries.length() { entries.length() } else { next }
    }
    None => entries.length()
  }
  let out : Array[TypecheckFixtureEntry] = []
  for i in start..<end {
    out.push(entries[i])
  }
  out
}

///|
fn verify_typecheck_fixture_entries(
  entries : Array[TypecheckFixtureEntry],
) -> Result[Array[TypecheckFixtureMismatch], String] {
  let mismatches : Array[TypecheckFixtureMismatch] = []
  for entry in entries {
    let source = @os_fs.read_file_to_string(entry.source_path) catch {
      e => return Err("[\{entry.source_path}] read failed: \{e.to_string()}")
    }
    let actual = trim_trailing_newlines(
      render_typecheck_fixture_result(entry.source_path, source),
    )
    let has_diag = @os_fs.is_file(entry.diag_path) catch {
      e => return Err("[\{entry.diag_path}] stat failed: \{e.to_string()}")
    }
    if !has_diag {
      mismatches.push({
        source_path: entry.source_path,
        expected: "<missing diagnostic file: \{entry.diag_path}>",
        actual,
      })
      continue
    }
    let expected_raw = @os_fs.read_file_to_string(entry.diag_path) catch {
      e => return Err("[\{entry.diag_path}] read failed: \{e.to_string()}")
    }
    let expected = trim_trailing_newlines(expected_raw)
    if expected != actual {
      mismatches.push({ source_path: entry.source_path, expected, actual })
    }
  }
  Ok(mismatches)
}

///|
pub fn verify_typecheck_fixtures(
  fixture_dir : String,
) -> Result[Array[TypecheckFixtureMismatch], String] {
  let entries = match collect_typecheck_fixture_entries(fixture_dir) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  verify_typecheck_fixture_entries(entries)
}

///|
pub fn verify_typecheck_fixtures_range(
  fixture_dir : String,
  offset : Int,
  limit : Int?,
) -> Result[Array[TypecheckFixtureMismatch], String] {
  let entries = match collect_typecheck_fixture_entries(fixture_dir) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  verify_typecheck_fixture_entries(
    slice_typecheck_fixture_entries(entries, offset, limit),
  )
}

///|
pub fn verify_typecheck_fixture_paths(
  paths : Array[String],
) -> Result[Array[TypecheckFixtureMismatch], String] {
  let entries = match collect_typecheck_fixture_entries_from_paths(paths) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  verify_typecheck_fixture_entries(entries)
}

///|
pub fn update_typecheck_fixtures(fixture_dir : String) -> Result[Int, String] {
  let entries = match collect_typecheck_fixture_entries(fixture_dir) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let mut updated = 0
  for entry in entries {
    let source = @os_fs.read_file_to_string(entry.source_path) catch {
      e => return Err("[\{entry.source_path}] read failed: \{e.to_string()}")
    }
    let next_content = trim_trailing_newlines(
        render_typecheck_fixture_result(entry.source_path, source),
      ) +
      "\n"
    let current_content = @os_fs.read_file_to_string(entry.diag_path) catch {
      _ => ""
    }
    if current_content != next_content {
      @os_fs.write_string_to_file(entry.diag_path, next_content) catch {
        e => return Err("[\{entry.diag_path}] write failed: \{e.to_string()}")
      }
      updated += 1
    }
  }
  Ok(updated)
}
