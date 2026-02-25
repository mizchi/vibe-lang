///|
pub struct EvalCmdOptions {
  db_path : String?
  export_path : String?
  include_paths : Array[String]
  inspect_scope : Bool
  assertions : Array[EvalTypeAssertion]
  test_target : String?
  test_run : Bool
  expr : String?
}

///|
pub struct EvalTypeAssertion {
  name : String
  expected_signature : String
} derive(Show, Eq)

///|
fn is_named_vbundle_alias(spec : String) -> Bool {
  if not(spec.has_suffix(".vbundle")) {
    return false
  }
  if spec.has_prefix("/") || spec.has_prefix("./") || spec.has_prefix("../") {
    return false
  }
  spec.contains("/")
}

///|
fn parse_semver_digits(text : String) -> Int? {
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
fn parse_simple_semver(text : String) -> (Int, Int, Int)? {
  let parts : Array[String] = []
  for part in text.split(".") {
    parts.push(part.to_string())
  }
  if parts.length() != 3 {
    return None
  }
  let major = match parse_semver_digits(parts[0]) {
    Some(v) => v
    None => return None
  }
  let minor = match parse_semver_digits(parts[1]) {
    Some(v) => v
    None => return None
  }
  let patch = match parse_semver_digits(parts[2]) {
    Some(v) => v
    None => return None
  }
  Some((major, minor, patch))
}

///|
fn compare_simple_semver(a : (Int, Int, Int), b : (Int, Int, Int)) -> Int {
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
fn resolve_eval_path(path : String) -> String {
  if path.has_prefix("/") {
    @vibe_fs.normalize_path(path)
  } else {
    @vibe_fs.normalize_path(@io.current_dir_or_root() + "/" + path)
  }
}

///|
fn scope_parent_and_name(scope : String) -> (String, String) {
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
fn resolve_latest_named_vbundle_alias(
  include_lib_dir : String,
  spec : String,
) -> String? {
  if spec.contains("@") || not(spec.has_suffix(".vbundle")) {
    return None
  }
  let scope = spec.unsafe_substring(start=0, end=spec.length() - 8)
  let (parent, leaf) = scope_parent_and_name(scope)
  if leaf.length() == 0 {
    return None
  }
  let dir = if parent.length() == 0 {
    include_lib_dir
  } else {
    include_lib_dir + "/" + parent
  }
  let entries = @os_fs.read_dir(dir) catch { _ => return None }
  let prefix = leaf + "@"
  let suffix = ".vbundle"
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
    match parse_simple_semver(version) {
      Some(semver) =>
        match best_semver {
          Some(prev) =>
            if compare_simple_semver(semver, prev) > 0 {
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
  match best_version {
    Some(version) =>
      Some(
        @vibe_fs.normalize_path(
          include_lib_dir + "/" + scope + "@" + version + ".vbundle",
        ),
      )
    None => None
  }
}

///|
fn parse_eval_type_assertion(
  raw : String,
  cmd_name : String,
) -> Result[EvalTypeAssertion, String] {
  let value = raw.trim().to_string()
  if value.length() == 0 {
    return Err(
      cmd_name +
      ": invalid --assert `" +
      raw +
      "` (expected <name>:<signature>)",
    )
  }
  let name_buf = StringBuilder::new()
  let sig_buf = StringBuilder::new()
  let mut found = false
  for _, ch in value {
    if not(found) && ch == ':' {
      found = true
      continue
    }
    if found {
      sig_buf.write_char(ch)
    } else {
      name_buf.write_char(ch)
    }
  }
  if not(found) {
    return Err(
      cmd_name +
      ": invalid --assert `" +
      raw +
      "` (expected <name>:<signature>)",
    )
  }
  let name = name_buf.to_string().trim().to_string()
  let expected_signature = sig_buf.to_string().trim().to_string()
  if name.length() == 0 || expected_signature.length() == 0 {
    return Err(
      cmd_name +
      ": invalid --assert `" +
      raw +
      "` (expected <name>:<signature>)",
    )
  }
  Ok({ name, expected_signature })
}

///|
pub fn resolve_vibe_lib_dir(base_dir : String) -> String {
  let lib_root = match @sys.get_env_var("VIBE_LIB_ROOT") {
    Some(path) => Some(path)
    None => @sys.get_env_var("VIBE_LIB_DIR")
  }
  match lib_root {
    Some(path) =>
      if path.has_prefix("/") {
        @vibe_fs.normalize_path(path)
      } else {
        @vibe_fs.normalize_path(base_dir + "/" + path)
      }
    None =>
      match @sys.get_env_var("HOME") {
        Some(home) => @vibe_fs.normalize_path(home + "/.vibe/lib")
        None => @vibe_fs.normalize_path(base_dir + "/.vibe/lib")
      }
  }
}

///|
pub fn resolve_eval_include_path(
  base_dir : String,
  include_spec : String,
  include_lib_dir : String,
) -> String {
  let resolved_base_dir = resolve_eval_path(base_dir)
  let spec = if include_spec.has_prefix("bit:") {
    include_spec.unsafe_substring(start=4, end=include_spec.length())
  } else {
    include_spec
  }
  if is_named_vbundle_alias(spec) {
    if spec.contains("@") {
      @vibe_fs.normalize_path(include_lib_dir + "/" + spec)
    } else {
      match resolve_latest_named_vbundle_alias(include_lib_dir, spec) {
        Some(path) => path
        None => @vibe_fs.normalize_path(include_lib_dir + "/" + spec)
      }
    }
  } else if spec.has_prefix("/") {
    @vibe_fs.normalize_path(spec)
  } else {
    @vibe_fs.normalize_path(resolved_base_dir + "/" + spec)
  }
}

///|
fn ensure_dir_recursive_for_eval(path : String) -> Result[Unit, String] {
  let normalized = @vibe_fs.normalize_path(path)
  if normalized.length() == 0 || normalized == "." || normalized == "/" {
    return Ok(())
  }
  if @os_fs.path_exists(normalized) {
    let is_dir = @os_fs.is_dir(normalized) catch { _ => false }
    if is_dir {
      return Ok(())
    }
    return Err("path exists and is not directory: " + normalized)
  }
  let parent = @vibe_fs.parent_path(normalized)
  if parent != normalized && parent.length() > 0 {
    match ensure_dir_recursive_for_eval(parent) {
      Ok(_) => ()
      Err(err) => return Err(err)
    }
  }
  match @io.create_dir(normalized) {
    Ok(_) => Ok(())
    Err(err) =>
      if @os_fs.path_exists(normalized) {
        let is_dir = @os_fs.is_dir(normalized) catch { _ => false }
        if is_dir {
          Ok(())
        } else {
          Err("mkdir failed: " + normalized + " (" + err + ")")
        }
      } else {
        Err("mkdir failed: " + normalized + " (" + err + ")")
      }
  }
}

///|
pub fn ensure_parent_dir_for_file(
  path : String,
  context : String,
) -> Result[Unit, String] {
  let resolved_path = resolve_eval_path(path)
  let parent = @vibe_fs.parent_path(resolved_path)
  if parent == "." || parent.length() == 0 {
    return Ok(())
  }
  match ensure_dir_recursive_for_eval(parent) {
    Ok(_) => Ok(())
    Err(err) => Err(context + ": " + err)
  }
}

///|
pub fn parse_eval_cmd_options(
  args : Array[String],
  cmd_name : String,
) -> Result[EvalCmdOptions, String] {
  let mut db_path : String? = None
  let mut export_path : String? = None
  let include_paths : Array[String] = []
  let assertions : Array[EvalTypeAssertion] = []
  let mut inspect_scope = false
  let mut test_target : String? = None
  let mut test_run = false
  let expr_tokens : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--run" {
      test_run = true
      i += 1
      continue
    }
    if arg == "--inspect-scope" {
      inspect_scope = true
      i += 1
      continue
    }
    if arg.has_prefix("--db=") {
      let value = arg.unsafe_substring(start=5, end=arg.length())
      if value.length() == 0 {
        return Err(cmd_name + ": missing value for --db")
      }
      db_path = Some(value)
      i += 1
      continue
    }
    if arg.has_prefix("--export=") {
      let value = arg.unsafe_substring(start=9, end=arg.length())
      if value.length() == 0 {
        return Err(cmd_name + ": missing value for --export")
      }
      export_path = Some(value)
      i += 1
      continue
    }
    if arg.has_prefix("--include=") {
      let value = arg.unsafe_substring(start=10, end=arg.length())
      if value.length() == 0 {
        return Err(cmd_name + ": missing value for --include")
      }
      include_paths.push(value)
      i += 1
      continue
    }
    if arg.has_prefix("--assert=") {
      let value = arg.unsafe_substring(start=9, end=arg.length())
      match parse_eval_type_assertion(value, cmd_name) {
        Ok(assertion) => assertions.push(assertion)
        Err(err) => return Err(err)
      }
      i += 1
      continue
    }
    if arg.has_prefix("--test-for=") {
      let value = arg
        .unsafe_substring(start=11, end=arg.length())
        .trim()
        .to_string()
      if value.length() == 0 {
        return Err(cmd_name + ": missing value for --test-for")
      }
      test_target = Some(value)
      i += 1
      continue
    }
    match arg {
      "--db" => {
        if i + 1 >= args.length() {
          return Err(cmd_name + ": missing value for --db")
        }
        db_path = Some(args[i + 1])
        i += 2
      }
      "--export" => {
        if i + 1 >= args.length() {
          return Err(cmd_name + ": missing value for --export")
        }
        export_path = Some(args[i + 1])
        i += 2
      }
      "--include" => {
        if i + 1 >= args.length() {
          return Err(cmd_name + ": missing value for --include")
        }
        include_paths.push(args[i + 1])
        i += 2
      }
      "--assert" => {
        if i + 1 >= args.length() {
          return Err(cmd_name + ": missing value for --assert")
        }
        match parse_eval_type_assertion(args[i + 1], cmd_name) {
          Ok(assertion) => assertions.push(assertion)
          Err(err) => return Err(err)
        }
        i += 2
      }
      "--test-for" => {
        if i + 1 >= args.length() {
          return Err(cmd_name + ": missing value for --test-for")
        }
        let value = args[i + 1].trim().to_string()
        if value.length() == 0 {
          return Err(cmd_name + ": missing value for --test-for")
        }
        test_target = Some(value)
        i += 2
      }
      "--run" => {
        test_run = true
        i += 1
      }
      _ => {
        expr_tokens.push(arg)
        i += 1
      }
    }
  }
  let expr = if expr_tokens.length() == 0 {
    None
  } else {
    Some(join_eval_expr_tokens(expr_tokens))
  }
  match (test_target, expr, test_run) {
    (Some(_), None, false) =>
      return Err(cmd_name + ": --test-for requires expression")
    _ => ()
  }
  match (db_path, export_path, expr) {
    (_, _, None) =>
      if test_run {
        Ok({
          db_path,
          export_path,
          include_paths,
          inspect_scope,
          assertions,
          test_target,
          test_run,
          expr: None,
        })
      } else {
        match (export_path, inspect_scope, assertions.length()) {
          (Some(_), _, _) =>
            Ok({
              db_path,
              export_path,
              include_paths,
              inspect_scope,
              assertions,
              test_target,
              test_run,
              expr: None,
            })
          (None, true, _) =>
            Ok({
              db_path,
              export_path,
              include_paths,
              inspect_scope,
              assertions,
              test_target,
              test_run,
              expr: None,
            })
          (None, false, count) =>
            if count > 0 {
              Ok({
                db_path,
                export_path,
                include_paths,
                inspect_scope,
                assertions,
                test_target,
                test_run,
                expr: None,
              })
            } else {
              Err(cmd_name + ": expected expression or --export")
            }
        }
      }
    _ =>
      Ok({
        db_path,
        export_path,
        include_paths,
        inspect_scope,
        assertions,
        test_target,
        test_run,
        expr,
      })
  }
}

///|
fn join_eval_expr_tokens(tokens : Array[String]) -> String {
  let out = StringBuilder::new()
  for i, token in tokens {
    if i > 0 {
      out.write_char(' ')
    }
    out.write_string(token)
  }
  out.to_string()
}
