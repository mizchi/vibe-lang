///|
struct FixtureSpec {
  last : String?
  effects : Array[String]?
  error_contains : String?
  todo : Bool
  skip : Bool
}

///|
fn join_lines(lines : Array[String]) -> String {
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
fn sort_strings(arr : Array[String]) -> Unit {
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
fn split_fixture(source : String, path : String) -> (String, String) raise {
  let script_lines : Array[String] = []
  let data_lines : Array[String] = []
  let mut in_data = false
  for line_view in source.split("\n") {
    let line = line_view.to_string()
    if line.trim().to_string() == "__DATA__" {
      in_data = true
      continue
    }
    if in_data {
      data_lines.push(line)
    } else {
      script_lines.push(line)
    }
  }
  if !in_data {
    fail("[\{path}] missing __DATA__ section")
  }
  (join_lines(script_lines), join_lines(data_lines))
}

///|
fn json_string_field(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> String? raise {
  match obj.get(key) {
    Some(Json::String(value)) => Some(value)
    Some(Json::Null) => None
    Some(_) => fail("[\{path}] __DATA__.{key} must be a string")
    None => None
  }
}

///|
fn json_bool_field(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> Bool raise {
  match obj.get(key) {
    Some(Json::True) => true
    Some(Json::False) => false
    Some(Json::Null) => false
    Some(_) => fail("[\{path}] __DATA__.{key} must be a boolean")
    None => false
  }
}

///|
fn json_string_array_field(
  obj : Map[String, Json],
  key : String,
  path : String,
) -> Array[String]? raise {
  match obj.get(key) {
    Some(Json::Null) => None
    Some(Json::Array(values)) => {
      let out : Array[String] = []
      for item in values {
        match item {
          Json::String(value) => out.push(value)
          _ => fail("[\{path}] __DATA__.{key} must be an array of strings")
        }
      }
      Some(out)
    }
    Some(_) => fail("[\{path}] __DATA__.{key} must be an array of strings")
    None => None
  }
}

///|
fn parse_spec(data : String, path : String) -> FixtureSpec raise {
  let json = @json.parse(data) catch {
    e => fail("[\{path}] invalid __DATA__ JSON: \{e.to_string()}")
  }
  match json {
    Json::Object(obj) => {
      let last = json_string_field(obj, "last", path)
      let effects = json_string_array_field(obj, "effects", path)
      let error_contains = match
        json_string_field(obj, "error_contains", path) {
        Some(value) => Some(value)
        None => json_string_field(obj, "compile_error", path)
      }
      let todo = json_bool_field(obj, "TODO", path) ||
        json_bool_field(obj, "todo", path)
      let skip = json_bool_field(obj, "skip", path)
      { last, effects, error_contains, todo, skip }
    }
    _ => fail("[\{path}] __DATA__ must be a JSON object")
  }
}

///|
fn eval_fixture(script : String) -> Result[EvalResult, String] {
  let rt = Runtime::new(@capability.CapabilitySet::developer())
  Ok(rt.eval_script(script)) catch {
    e => Err(e.to_string())
  }
}

///|
fn run_fixture(path : String) -> Unit raise {
  let source = @os_fs.read_file_to_string(path) catch {
    e => fail("[\{path}] read failed: \{e.to_string()}")
  }
  let (script, data) = split_fixture(source, path)
  let spec = parse_spec(data, path)
  if spec.skip {
    println("[\{path}] skipped")
    return
  }
  let result = eval_fixture(script)
  if spec.todo {
    match result {
      Ok(_) => fail("[\{path}] TODO fixture passed (remove TODO flag)")
      Err(_) => return
    }
  }
  match result {
    Ok(eval_result) => {
      match spec.error_contains {
        Some(expect) => fail("[\{path}] expected error containing '\{expect}'")
        None => ()
      }
      match spec.last {
        Some(expect) =>
          match eval_result.last {
            Some(value) => {
              let actual = value.to_string()
              if actual != expect {
                fail(
                  "[\{path}] last mismatch: expected \{expect}, got \{actual}",
                )
              }
            }
            None =>
              fail("[\{path}] last mismatch: expected \{expect}, got None")
          }
        None => ()
      }
      match spec.effects {
        Some(expected) => {
          let actual : Array[String] = []
          for effect in eval_result.effects {
            actual.push(effect.to_string())
          }
          if actual != expected {
            fail(
              "[\{path}] effects mismatch: expected \{expected.to_string()}, got \{actual.to_string()}",
            )
          }
        }
        None => ()
      }
    }
    Err(err) =>
      match spec.error_contains {
        Some(expect) =>
          if !err.contains(expect) {
            fail(
              "[\{path}] error mismatch: expected to contain '\{expect}', got '\{err}'",
            )
          }
        None => fail("[\{path}] unexpected error: \{err}")
      }
  }
}

///|
test "fixtures" {
  let fixture_dir = "fixtures"
  let entries = @os_fs.read_dir(fixture_dir) catch {
    e => fail("[fixtures] read_dir failed: \{e.to_string()}")
  }
  let files : Array[String] = []
  for entry in entries {
    let path = if entry.has_prefix(fixture_dir) {
      entry
    } else {
      fixture_dir + "/" + entry
    }
    let is_file = @os_fs.is_file(path) catch {
      e => fail("[fixtures] stat failed: \{e.to_string()}")
    }
    if is_file && path.has_suffix(".xsh") {
      files.push(path)
    }
  }
  sort_strings(files)
  if files.length() == 0 {
    fail("[fixtures] no .xsh fixtures found")
  }
  for path in files {
    run_fixture(path)
  }
}
