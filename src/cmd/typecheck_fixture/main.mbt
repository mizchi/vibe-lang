///|
fn usage() -> Unit {
  println(
    "typecheck-fixture [--update] [--path <path>] [--offset <n>] [--limit <n>] [--file <path> ...]",
  )
  println(
    "  --update      rewrite fixtures/*.diag from current typecheck output",
  )
  println(
    "  --dir/--path <path> fixture path or directory (default: fixtures/typecheck)",
  )
  println("  --offset <n>  start index in sorted fixture list")
  println("  --limit <n>   max number of fixtures to verify")
  println("  --file <path> verify specific fixture file(s)")
}

///|
fn collect_cli_args() -> Array[String] {
  let args = @env.args()
  let out : Array[String] = []
  for i, arg in args {
    if i == 0 {
      continue
    }
    if i == 1 && arg.has_suffix(".js") {
      continue
    }
    out.push(arg)
  }
  out
}

///|
fn parse_decimal_int_arg(raw : String) -> Result[Int, String] {
  if raw.length() == 0 {
    return Err("empty integer")
  }
  let chars = raw.to_array()
  let mut sign = 1
  let mut start = 0
  if chars[0] == '-' {
    sign = -1
    start = 1
  }
  if start >= chars.length() {
    return Err("empty integer")
  }
  let mut value = 0
  for i in start..<chars.length() {
    let ch = chars[i]
    if ch < '0' || ch > '9' {
      return Err("invalid integer: " + raw)
    }
    value = value * 10 + (ch.to_int() - '0'.to_int())
  }
  Ok(value * sign)
}

///|
fn parse_args(
  args : Array[String],
) -> Result[(Bool, String, Int, Int?, Array[String]), String] {
  let mut update = false
  let mut fixture_path = "fixtures/typecheck"
  let mut offset = 0
  let mut limit : Int? = None
  let files : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--update" => update = true
      "--dir" | "--path" => {
        i += 1
        if i >= args.length() {
          return Err("missing fixture path after --dir/--path")
        }
        fixture_path = args[i]
      }
      "--offset" => {
        i += 1
        if i >= args.length() {
          return Err("missing number after --offset")
        }
        offset = match parse_decimal_int_arg(args[i]) {
          Ok(v) => v
          Err(_) => return Err("invalid --offset: " + args[i])
        }
      }
      "--limit" => {
        i += 1
        if i >= args.length() {
          return Err("missing number after --limit")
        }
        let parsed = match parse_decimal_int_arg(args[i]) {
          Ok(v) => v
          Err(_) => return Err("invalid --limit: " + args[i])
        }
        limit = Some(parsed)
      }
      "--file" => {
        i += 1
        if i >= args.length() {
          return Err("missing path after --file")
        }
        files.push(args[i])
      }
      "--help" | "-h" => {
        usage()
        return Err("")
      }
      _ => return Err("unknown argument: " + arg)
    }
    i += 1
  }
  Ok((update, fixture_path, offset, limit, files))
}

///|
fn print_mismatch(mismatch : @checker.TypecheckFixtureMismatch) -> Unit {
  println("[\{mismatch.source_path}]")
  println("expected:")
  println(mismatch.expected)
  println("")
  println("actual:")
  println(mismatch.actual)
  println("")
}

///|
fn main {
  let args = collect_cli_args()
  let (update, fixture_path, offset, limit, files) = match parse_args(args) {
    Ok(v) => v
    Err(err) =>
      if err.length() == 0 {
        return
      } else {
        abort("typecheck-fixture: " + err)
      }
  }
  if update && files.length() > 0 {
    abort("typecheck-fixture: --update does not support --file")
  }
  if update {
    match @checker.update_typecheck_fixtures(fixture_path) {
      Ok(updated) =>
        println(
          "updated typecheck fixtures: " +
          updated.to_string() +
          " file(s) in " +
          fixture_path,
        )
      Err(err) => abort("typecheck-fixture: " + err)
    }
    return
  }
  let verify_result = if files.length() > 0 {
    @checker.verify_typecheck_fixture_paths(files)
  } else {
    @checker.verify_typecheck_fixtures_range(fixture_path, offset, limit)
  }
  match verify_result {
    Ok(mismatches) => {
      if mismatches.length() == 0 {
        if files.length() > 0 {
          println(
            "typecheck fixtures: ok (" +
            files.length().to_string() +
            " file(s))",
          )
        } else {
          println("typecheck fixtures: ok (\{fixture_path})")
        }
        return
      }
      for mismatch in mismatches {
        print_mismatch(mismatch)
      }
      println(
        "typecheck-fixture: " +
        mismatches.length().to_string() +
        " mismatch(es)",
      )
      @sys.exit(1)
    }
    Err(err) => {
      println("typecheck-fixture: " + err)
      @sys.exit(1)
    }
  }
}
