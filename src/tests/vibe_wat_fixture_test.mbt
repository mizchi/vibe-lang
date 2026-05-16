///|
fn join_lines_wat(lines : Array[String]) -> String {
  let sb = StringBuilder::new()
  let mut first = true
  for line in lines {
    if first {
      first = false
    } else {
      sb.write_char('\n')
    }
    sb.write_string(line)
  }
  sb.to_string()
}

///|
fn normalize_wat(text : String) -> String {
  let lines : Array[String] = []
  for line_view in text.split("\n") {
    lines.push(line_view.trim_end().to_owned())
  }
  while lines.length() > 0 && lines[lines.length() - 1].trim().to_owned() == "" {
    ignore(lines.pop())
  }
  join_lines_wat(lines)
}

///|
fn sort_strings_wat(arr : Array[String]) -> Unit {
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
fn replace_suffix(
  path : String,
  suffix : String,
  new_suffix : String,
) -> String {
  match path.strip_suffix(suffix) {
    Some(view) => view.to_owned() + new_suffix
    None => path
  }
}

///|
test "wasm wat fixtures" {
  let fixture_dir = "fixtures/wasm"
  let update_mode = match @sys.get_env_var("VIBE_WAT_FIXTURE_UPDATE") {
    Some(v) => {
      let lowered = v.trim().to_owned().to_lower()
      lowered == "1" || lowered == "true" || lowered == "yes"
    }
    None => false
  }
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => fail("[\{fixture_dir}] read_dir failed: \{e.to_string()}")
  }
  let files : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch {
      e => fail("[\{fixture_dir}] stat failed: \{e.to_string()}")
    }
    if is_file && path.has_suffix(".vibe") {
      files.push(path)
    }
  }
  sort_strings_wat(files)
  if files.length() == 0 {
    fail("[\{fixture_dir}] no .vibe fixtures found")
  }
  for path in files {
    let wat_path = replace_suffix(path, ".vibe", ".wat")
    let source = @os_fs.read_file_to_string(path) catch {
      e => fail("[\{path}] read failed: \{e.to_string()}")
    }
    let expected = @os_fs.read_file_to_string(wat_path) catch {
      e => fail("[\{wat_path}] read failed: \{e.to_string()}")
    }
    let db = VibeDb::new()
    db.set_source("main", source)
    let wasm = try compile_module_wasm(db, "main") catch {
      e => fail("[\{path}] compile error: \{e.to_string()}")
    } noraise {
      b => b
    }
    let actual = try @codegen.wasm_to_wat(wasm) catch {
      e => fail("[\{path}] wat error: \{e.to_string()}")
    } noraise {
      s => s
    }
    let actual_norm = normalize_wat(actual)
    let expected_norm = normalize_wat(expected)
    if actual_norm != expected_norm {
      if update_mode {
        @os_fs.write_string_to_file(wat_path, actual_norm + "\n") catch {
          e => fail("[\{wat_path}] write failed: \{e.to_string()}")
        }
      } else {
        fail(
          "[\{path}] wat mismatch\n-- actual --\n\{actual_norm}\n-- expected --\n\{expected_norm}",
        )
      }
    }
  }
}
