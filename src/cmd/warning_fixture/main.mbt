///|
fn usage() -> Unit {
  println("warning-fixture [--update] [--path <path>]")
  println("  --update      rewrite fixtures/*.diag from current warning output")
  println(
    "  --path <path> fixture path or directory (default: fixtures/warnings)",
  )
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
fn parse_args(args : Array[String]) -> Result[(Bool, String), String] {
  let mut update = false
  let mut fixture_path = "fixtures/warnings"
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--update" => update = true
      "--dir" | "--path" => {
        i += 1
        if i >= args.length() {
          return Err("missing directory path after --dir")
        }
        fixture_path = args[i]
      }
      "--help" | "-h" => {
        usage()
        return Err("")
      }
      _ => return Err("unknown argument: " + arg)
    }
    i += 1
  }
  Ok((update, fixture_path))
}

///|
fn print_mismatch(mismatch : @checker.WarningFixtureMismatch) -> Unit {
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
  let (update, fixture_path) = match parse_args(args) {
    Ok(v) => v
    Err(err) =>
      if err.length() == 0 {
        return
      } else {
        abort("warning-fixture: " + err)
      }
  }
  if update {
    match @checker.update_warning_fixtures(fixture_path) {
      Ok(updated) =>
        println(
          "updated warning fixtures: " +
          updated.to_string() +
          " file(s) in " +
          fixture_path,
        )
      Err(err) => abort("warning-fixture: " + err)
    }
    return
  }
  match @checker.verify_warning_fixtures(fixture_path) {
    Ok(mismatches) => {
      if mismatches.length() == 0 {
        println("warning fixtures: ok (\{fixture_path})")
        return
      }
      for mismatch in mismatches {
        print_mismatch(mismatch)
      }
      abort(
        "warning-fixture: " + mismatches.length().to_string() + " mismatch(es)",
      )
    }
    Err(err) => abort("warning-fixture: " + err)
  }
}
