// Shared `--profile <path>` flag handling for all vibe subcommands.
//
// The profiler is enabled for the lifetime of the wrapper; on exit
// the output format is picked by file extension:
//
//   .pprof    → Google pprof protobuf (binary). View with
//               `go tool pprof <file>` or pprof's web UI.
//   .folded   → folded-stack text. Pipe through Brendan Gregg's
//               `flamegraph.pl` to get an SVG flame graph.
//   .tsv      → flat TSV aggregate (legacy, by-name only). Useful
//               for quick spreadsheet inspection.
//   anything else → default to .pprof.
//
// All four `vibe` subcommands (`build`, `test`, `run`, `check`,
// `bench`, `compile-lite`) thread their args through
// `extract_profile_flag` before parsing their own options; if a
// non-None path comes back, they wrap the command body with
// `with_profile`.

///|
/// Strip `--profile <path>` from `args`. Returns the remaining args
/// plus the (optional) path. If the flag appears multiple times the
/// last one wins.
pub fn extract_profile_flag(
  args : Array[String],
) -> Result[(Array[String], String?), String] {
  let filtered : Array[String] = []
  let mut path : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--profile" {
      i += 1
      if i >= args.length() {
        return Err("missing path after --profile")
      }
      path = Some(args[i])
    } else {
      filtered.push(arg)
    }
    i += 1
  }
  Ok((filtered, path))
}

///|
/// Run `body` with the profiler enabled and write the recorded data
/// to `path` after `body` returns. Format is chosen from `path`'s
/// extension. Errors writing the file are reported to stdout but do
/// not abort the command.
pub fn with_profile(path : String?, body : () -> Unit) -> Unit {
  match path {
    None => body()
    Some(out_path) => {
      @profiler.profiler_set_enabled(true)
      @profiler.profiler_reset()
      body()
      let fs = @io.default_fs_adapter()
      let result = if out_path.has_suffix(".tsv") {
        @io.write_string_with(fs, out_path, @profiler.profiler_report_tsv())
      } else if out_path.has_suffix(".folded") {
        @io.write_string_with(fs, out_path, @profiler.profiler_report_folded())
      } else {
        // .pprof or anything else → protobuf binary.
        @io.write_bytes_with(fs, out_path, @profiler.profiler_report_pprof())
      }
      match result {
        Ok(_) => println("profile: wrote " + out_path)
        Err(err) => println("profile: failed to write " + out_path + ": " + err)
      }
      @profiler.profiler_set_enabled(false)
    }
  }
}
