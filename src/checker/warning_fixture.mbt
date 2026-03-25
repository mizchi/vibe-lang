///|
pub struct WarningFixtureMismatch {
  source_path : String
  expected : String
  actual : String
} derive(Show, Eq)

///|
fn trim_trailing_newlines_warning(text : String) -> String {
  if text.length() == 0 {
    return text
  }
  if text.has_suffix("\n") || text.has_suffix("\r") {
    let next = text[:text.length() - 1].to_string()
    trim_trailing_newlines_warning(next)
  } else {
    text
  }
}

///|
fn render_warning_fixture_result(path : String, source : String) -> String {
  let ast = @parser.parse_ast(source) catch {
    e => return e.diagnostic().render(path, source)
  }
  let warnings = collect_warnings(ast)
  if warnings.length() == 0 {
    return "ok"
  }
  let sb = StringBuilder::new()
  for i in 0..<warnings.length() {
    if i > 0 {
      sb.write_string("\n\n")
    }
    sb.write_string(warnings[i].render(path, source))
  }
  sb.to_string()
}

///|
pub fn verify_warning_fixtures(
  fixture_dir : String,
) -> Result[Array[WarningFixtureMismatch], String] {
  let entries = match collect_typecheck_fixture_entries(fixture_dir) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let mismatches : Array[WarningFixtureMismatch] = []
  for entry in entries {
    let source = @os_fs.read_file_to_string(entry.source_path) catch {
      e => return Err("[\{entry.source_path}] read failed: \{e.to_string()}")
    }
    let actual = trim_trailing_newlines_warning(
      render_warning_fixture_result(entry.source_path, source),
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
    let expected = trim_trailing_newlines_warning(expected_raw)
    if expected != actual {
      mismatches.push({ source_path: entry.source_path, expected, actual })
    }
  }
  Ok(mismatches)
}

///|
pub fn update_warning_fixtures(fixture_dir : String) -> Result[Int, String] {
  let entries = match collect_typecheck_fixture_entries(fixture_dir) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let mut updated = 0
  for entry in entries {
    let source = @os_fs.read_file_to_string(entry.source_path) catch {
      e => return Err("[\{entry.source_path}] read failed: \{e.to_string()}")
    }
    let next_content = trim_trailing_newlines_warning(
        render_warning_fixture_result(entry.source_path, source),
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
