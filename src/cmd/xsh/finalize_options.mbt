///|
struct FinalizeCmdOptions {
  db_path : String?
  export_path : String?
  library_mode : Bool
  print_source : Bool
  dry_run : Bool
} derive(Show, Eq)

///|
fn parse_finalize_cmd_args(
  args : Array[String],
) -> Result[FinalizeCmdOptions, String] {
  let mut db_path : String? = None
  let mut export_path : String? = None
  let mut library_mode = false
  let mut print_source = false
  let mut dry_run = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--library" {
      library_mode = true
      i += 1
      continue
    }
    if arg == "--print" {
      print_source = true
      i += 1
      continue
    }
    if arg == "--dry-run" {
      dry_run = true
      i += 1
      continue
    }
    if arg == "--db" {
      if i + 1 >= args.length() {
        return Err("finalize: missing path after --db")
      }
      db_path = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--db=") {
      let path = arg.unsafe_substring(start=5, end=arg.length())
      if path.trim().to_string().length() == 0 {
        return Err("finalize: --db path must not be empty")
      }
      db_path = Some(path)
      i += 1
      continue
    }
    if arg == "--export" {
      if i + 1 >= args.length() {
        return Err("finalize: missing path after --export")
      }
      export_path = Some(args[i + 1])
      i += 2
      continue
    }
    if arg.has_prefix("--export=") {
      let path = arg.unsafe_substring(start=9, end=arg.length())
      if path.trim().to_string().length() == 0 {
        return Err("finalize: --export path must not be empty")
      }
      export_path = Some(path)
      i += 1
      continue
    }
    if arg.has_prefix("--") {
      return Err("finalize: unknown option " + arg)
    }
    return Err("finalize: unexpected arg " + arg)
  }
  Ok({ db_path, export_path, library_mode, print_source, dry_run })
}
