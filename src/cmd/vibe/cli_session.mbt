///|
fn make_cli_test_report_json(
  path : String,
  report : CliTestReport,
  elapsed_ms : Int,
) -> Json {
  let failures_arr : Array[Json] = []
  for failure in report.failures {
    let f : Map[String, Json] = {}
    f["name"] = Json::string(
      match failure.name {
        Some(n) => n
        None => "<unnamed>"
      },
    )
    f["error"] = Json::string(failure.error)
    failures_arr.push(Json::object(f))
  }
  let obj : Map[String, Json] = {}
  obj["file"] = Json::string(path)
  obj["total"] = Json::number(report.total.to_double())
  obj["passed"] = Json::number(report.passed.to_double())
  obj["failed"] = Json::number(report.failed.to_double())
  obj["elapsed_ms"] = Json::number(elapsed_ms.to_double())
  obj["failures"] = Json::array(failures_arr)
  Json::object(obj)
}

///|
fn make_cli_check_report_json(report : CliCheckReport) -> Json {
  let messages_arr : Array[Json] = []
  for message in report.messages {
    messages_arr.push(Json::string(message))
  }
  let obj : Map[String, Json] = {}
  obj["cmd"] = Json::string("check")
  obj["file"] = Json::string(report.file)
  obj["resolved_entry"] = Json::string(report.resolved_entry)
  obj["ok"] = Json::boolean(report.error_count == 0)
  obj["errors"] = Json::number(report.error_count.to_double())
  obj["warnings"] = Json::number(report.warning_count.to_double())
  obj["load_ms"] = Json::number(elapsed_ms_from_us(report.load_us).to_double())
  obj["type_ms"] = Json::number(elapsed_ms_from_us(report.type_us).to_double())
  obj["total_ms"] = Json::number(
    elapsed_ms_from_us(report.total_us).to_double(),
  )
  obj["messages"] = Json::array(messages_arr)
  match report.graph_head {
    Some(hash) => {
      obj["graph_head"] = Json::string(hash)
      obj["short_graph_head"] = Json::string(short_hash(hash))
    }
    None => {
      obj["graph_head"] = Json::null()
      obj["short_graph_head"] = Json::null()
    }
  }
  Json::object(obj)
}

///|
fn make_error_report_json(
  entry_path : String,
  phase : String,
  error : String,
  elapsed_ms : Int,
) -> Json {
  let f : Map[String, Json] = {}
  f["name"] = Json::string(phase)
  f["error"] = Json::string(error)
  let obj : Map[String, Json] = {}
  obj["file"] = Json::string(entry_path)
  obj["total"] = Json::number(0.0)
  obj["passed"] = Json::number(0.0)
  obj["failed"] = Json::number(1.0)
  obj["elapsed_ms"] = Json::number(elapsed_ms.to_double())
  obj["failures"] = Json::array([Json::object(f)])
  Json::object(obj)
}

///|
fn make_skipped_report_json(
  entry_path : String,
  phase : String,
  reason : String,
  elapsed_ms : Int,
) -> Json {
  let obj : Map[String, Json] = {}
  obj["file"] = Json::string(entry_path)
  obj["total"] = Json::number(0.0)
  obj["passed"] = Json::number(0.0)
  obj["failed"] = Json::number(0.0)
  obj["skipped"] = Json::number(1.0)
  obj["phase"] = Json::string(phase)
  obj["reason"] = Json::string(reason)
  obj["elapsed_ms"] = Json::number(elapsed_ms.to_double())
  obj["failures"] = Json::array([])
  Json::object(obj)
}

///|
fn make_cli_session_test_report_json(
  path : String,
  report : CliTestReport,
  elapsed_ms : Int,
) -> Json {
  let base = make_cli_test_report_json(path, report, elapsed_ms)
  match base {
    Json::Object(obj) => {
      obj["cmd"] = Json::string("test")
      Json::object(obj)
    }
    _ => base
  }
}

///|
fn make_cli_session_run_result_json(
  path : String,
  value : WasmRunValue,
) -> Json {
  let obj : Map[String, Json] = {}
  obj["cmd"] = Json::string("run")
  obj["file"] = Json::string(path)
  obj["ok"] = Json::boolean(true)
  match value {
    WasmRunValue::Int(n) => {
      obj["value_kind"] = Json::string("int")
      obj["value"] = Json::string(n.to_string())
    }
    WasmRunValue::Bool(b) => {
      obj["value_kind"] = Json::string("bool")
      obj["value"] = Json::boolean(b)
    }
  }
  Json::object(obj)
}

///|
fn make_cli_session_error_json(
  cmd : String,
  entry_path : String,
  phase : String,
  error : String,
  elapsed_ms : Int,
) -> Json {
  let base = make_error_report_json(entry_path, phase, error, elapsed_ms)
  match base {
    Json::Object(obj) => {
      obj["cmd"] = Json::string(cmd)
      Json::object(obj)
    }
    _ => base
  }
}

///|
fn session_http_port_for_entry_with_features(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Int {
  let resolved = @loader.resolve_entry_path(entry_path)
  let (vibe_root, _cache_key) = find_vibe_cache_root(resolved)
  let mut acc = 0
  for _, ch in vibe_root {
    acc = (acc * 131 + Char::to_int(ch)) % 20000
  }
  if features.is_unstable_async_enabled() {
    acc = (acc * 131 + 17) % 20000
  }
  if features.is_unstable_threads_enabled() {
    acc = (acc * 131 + 31) % 20000
  }
  36000 + acc
}

///|
fn current_cli_binary_path() -> String? {
  let resolve_bin = fn(raw : String) -> String {
    if raw.has_prefix("/") || !raw.contains("/") {
      raw
    } else {
      @io.current_dir_or_root() + "/" + raw
    }
  }
  let argv = @env.args()
  if argv.length() > 0 {
    let argv0 = argv[0]
    if argv0.has_suffix("vibe.exe") || argv0.has_suffix("vibe") {
      return Some(resolve_bin(argv0))
    }
  }
  match @sys.get_env_var("_") {
    Some(bin) if bin.has_suffix("vibe.exe") || bin.has_suffix("vibe") =>
      Some(resolve_bin(bin))
    _ => None
  }
}

///|
fn session_http_worker_token_from_bytes(
  self_bin : String,
  bytes : Bytes,
) -> String {
  let mod1 = 2147483647
  let mod2 = 2147483629
  let step1 = 131
  let step2 = 65599
  let len = bytes.length()
  let mut h1 = 17
  let mut h2 = 29
  for i in 0..<len {
    let byte = bytes[i].to_int()
    h1 = (h1 * step1 + byte + 1) % mod1
    h2 = (h2 * step2 + byte + i + 1) % mod2
  }
  self_bin + "#" + len.to_string() + ":" + h1.to_string() + ":" + h2.to_string()
}

///|
fn session_http_worker_token_for_binary_path(self_bin : String) -> String {
  let bytes = @os_fs.read_file_to_bytes(self_bin) catch {
    _ => return self_bin + "#missing"
  }
  session_http_worker_token_from_bytes(self_bin, bytes)
}

///|
fn session_http_worker_token_env() -> String {
  match @sys.get_env_var("VIBE_SESSION_WORKER_TOKEN") {
    Some(value) => value
    None => ""
  }
}

///|
fn session_http_request_json(
  port : Int,
  request : Json,
) -> Result[Json, String] {
  let out : Ref[Result[Json, String]] = @ref.new(
    Err("session-http: request did not complete"),
  )
  let url = "http://127.0.0.1:" + port.to_string() + "/"
  @async.run_async_main(async fn() {
    let (_response, data) = @http.post(url, request.stringify(), headers={
      "content-type": "application/json",
    }) catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    let response_body = data.text() catch {
      err => {
        out.val = Err(err.to_string())
        return
      }
    }
    if response_body.length() == 0 {
      out.val = Err("empty session http response")
      return
    }
    let parsed : Json = @json.parse(response_body) catch {
      _ => {
        out.val = Err("invalid session http response json")
        return
      }
    }
    out.val = Ok(parsed)
  })
  out.val
}

///|
enum SessionHttpPingState {
  Unreachable
  Alive(String?)
} derive(Eq, Debug)

///|
impl Show for SessionHttpPingState with output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
fn parse_session_http_ping_state(json : Json) -> SessionHttpPingState {
  match json {
    Json::Object(obj) =>
      match obj.get("ok") {
        Some(Json::True) =>
          match obj.get("worker_token") {
            Some(Json::String(value)) if value.length() > 0 =>
              SessionHttpPingState::Alive(Some(value))
            _ => SessionHttpPingState::Alive(None)
          }
        _ => SessionHttpPingState::Unreachable
      }
    _ => SessionHttpPingState::Unreachable
  }
}

///|
fn session_http_ping_state(port : Int) -> SessionHttpPingState {
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("ping")
  match session_http_request_json(port, Json::object(req)) {
    Ok(json) => parse_session_http_ping_state(json)
    Err(_) => SessionHttpPingState::Unreachable
  }
}

///|
fn session_http_can_reuse_worker(
  state : SessionHttpPingState,
  expected_token : String,
) -> Bool {
  match state {
    SessionHttpPingState::Alive(Some(token)) => token == expected_token
    _ => false
  }
}

///|
fn session_http_response_ok(json : Json) -> Bool {
  match json {
    Json::Object(obj) =>
      match obj.get("ok") {
        Some(Json::True) => true
        _ => false
      }
    _ => false
  }
}

///|
fn session_http_shutdown(port : Int) -> Bool {
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("shutdown")
  match session_http_request_json(port, Json::object(req)) {
    Ok(json) => session_http_response_ok(json)
    Err(_) => false
  }
}

///|
fn session_http_wait_until_unreachable(port : Int) -> Bool {
  for _ in 0..<25 {
    @io.sleep_ms(20L)
    if session_http_ping_state(port) is SessionHttpPingState::Unreachable {
      return true
    }
  }
  false
}

///|
/// Build the shell command that launches a session-http worker as a
/// detached daemon.
///
/// The inner `sh -c '...'` preamble closes file descriptors 3..1023
/// before `exec`'ing the worker. Without this, any inheritable pipe fd
/// held by the spawning vibe process (e.g. the stdout-capture pipe of a
/// test batch worker) would be kept alive by the daemonized session-http
/// worker. The original parent would then block forever in `epoll_wait`,
/// reading from a pipe whose write end is held open by an orphan it
/// cannot see.
///
/// `VIBE_INTERNAL_PARENT_PID=<parent>` instructs the worker (in
/// `cli.mbt:run`) to install the parent-watchdog thread so it exits when
/// the spawning vibe dies, instead of lingering as a PPID=1 orphan.
fn build_session_http_spawn_command(
  self_bin : String,
  port : Int,
  features : @runtime.RuntimeFeatureFlags,
  worker_token : String,
  parent_pid : Int,
) -> String {
  // Walk the live `/proc/self/fd` view rather than blindly looping a
  // numeric range: `exec N<&-` on a non-existent fd makes dash abort
  // the script (POSIX leaves `exec`-with-redirect errors fatal), so a
  // `for i in 3..1023` loop terminates with status 127 after the first
  // gap. Globbing only enumerates fds that actually exist.
  let close_inherited_fds = "for fd in /proc/$$/fd/*; do " +
    "n=\"${fd##*/}\"; " +
    "case \"$n\" in 0|1|2) ;; " +
    "*) eval \"exec $n<&-\" 2>/dev/null ;; " +
    "esac; done"
  let exec_worker = "exec env VIBE_INTERNAL_PARENT_PID=" +
    parent_pid.to_string() +
    " VIBE_SESSION_WORKER_TOKEN=" +
    shell_quote_command_arg(worker_token) +
    " " +
    shell_quote_command_arg(self_bin) +
    (if features.is_unstable_async_enabled() {
      " --unstable-async"
    } else {
      ""
    }) +
    (if features.is_unstable_threads_enabled() {
      " --unstable-threads"
    } else {
      ""
    }) +
    " session-http --port " +
    port.to_string()
  let payload = close_inherited_fds + "; " + exec_worker
  // `shell_quote_command_arg` produces double-quoted strings, so any
  // single quotes in the binary path (e.g. /home/O'Neil/vibe.exe) pass
  // through unescaped. Wrapping the whole payload in `'…'` would split
  // mid-path on those. Splice each embedded `'` as `'\''` so the outer
  // single-quoted region survives.
  "nohup sh -c " + pose_single_quote(payload) + " >/dev/null 2>&1 &"
}

///|
/// POSIX-safe single-quote wrap: rewrites each `'` in `s` as the
/// closing-quote / escaped-quote / opening-quote sequence `'\''`, then
/// surrounds the result with `'…'`. The output is byte-identical to `s`
/// when piped through `sh -c`.
fn pose_single_quote(s : String) -> String {
  "'" + s.replace_all(old="'", new="'\\''") + "'"
}

///|
/// Choose the parent PID the session-http worker should watch.
///
/// Prefer the orchestrator pid when we are a batch worker
/// (`VIBE_INTERNAL_TEST_PARENT_PID` / `VIBE_INTERNAL_PARENT_PID`), so
/// session-http stays alive across all batch workers of a single
/// `vibe test` run; fall back to our own pid when we are the
/// orchestrator. The pid is consumed by `cli.mbt:run` on the worker
/// side, which arms the existing parent-watchdog thread.
fn session_http_effective_parent_pid() -> Int {
  match internal_parent_pid_env() {
    Some(pid) => pid
    None => vibe_getpid()
  }
}

///|
/// Number of seconds the session-http worker tolerates being idle before
/// it self-terminates. Tunable via `VIBE_SESSION_IDLE_SECONDS`; set to 0
/// to disable. The default is short enough that abnormal exits of the
/// spawning vibe don't leave the worker lingering, but long enough that
/// back-to-back `vibe test` invocations reuse the same worker.
fn session_http_idle_seconds() -> Int {
  match @sys.get_env_var("VIBE_SESSION_IDLE_SECONDS") {
    Some(raw) => @string.parse_int(raw) catch { _ => 60 }
    None => 60
  }
}

///|
/// Maximum number of `VibeDb` entries the session-http cache retains
/// before evicting the least-recently-used root. Tunable via
/// `VIBE_SESSION_CACHE_MAX`.
fn session_http_cache_capacity() -> Int {
  match @sys.get_env_var("VIBE_SESSION_CACHE_MAX") {
    Some(raw) => {
      let n = @string.parse_int(raw) catch { _ => 16 }
      if n <= 0 {
        16
      } else {
        n
      }
    }
    None => 16
  }
}

///|
fn ensure_session_http_worker(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[Int, String] {
  let port = session_http_port_for_entry_with_features(entry_path, features)
  let self_bin = match current_cli_binary_path() {
    Some(v) => v
    None =>
      return Err("session-http: failed to resolve current vibe binary path")
  }
  let worker_token = session_http_worker_token_for_binary_path(self_bin)
  let ping_state = session_http_ping_state(port)
  if session_http_can_reuse_worker(ping_state, worker_token) {
    return Ok(port)
  }
  if ping_state is SessionHttpPingState::Alive(_) {
    ignore(session_http_shutdown(port))
    if !session_http_wait_until_unreachable(port) {
      return Err("session-http: stale worker did not shut down")
    }
  }
  let cmd = build_session_http_spawn_command(
    self_bin,
    port,
    features,
    worker_token,
    session_http_effective_parent_pid(),
  )
  let status = c_system(system_command_bytes(cmd))
  if status != 0 {
    return Err("session-http: failed to spawn worker")
  }
  for _ in 0..<25 {
    @io.sleep_ms(20L)
    if session_http_can_reuse_worker(
        session_http_ping_state(port),
        worker_token,
      ) {
      return Ok(port)
    }
  }
  Err("session-http: worker did not become ready")
}

///|
fn parse_cli_check_report_json(json : Json) -> Result[CliCheckReport, String] {
  match json {
    Json::Object(obj) => {
      let file = parse_report_json_string(json, "file")
      let resolved_entry = parse_report_json_string(json, "resolved_entry")
      let error_count = parse_report_json_int(json, "errors")
      let warning_count = parse_report_json_int(json, "warnings")
      let load_ms = parse_report_json_int(json, "load_ms")
      let type_ms = parse_report_json_int(json, "type_ms")
      let total_ms = parse_report_json_int(json, "total_ms")
      let graph_head = match obj.get("graph_head") {
        Some(Json::String(value)) => Some(value)
        _ => None
      }
      let messages : Array[String] = []
      match obj.get("messages") {
        Some(Json::Array(arr)) =>
          for item in arr {
            match item {
              Json::String(value) => messages.push(value)
              _ => ()
            }
          }
        _ => ()
      }
      Ok(CliCheckReport::{
        file,
        resolved_entry,
        graph_head,
        error_count,
        warning_count,
        load_us: load_ms * 1000,
        type_us: type_ms * 1000,
        total_us: total_ms * 1000,
        messages,
      })
    }
    _ => Err("session-http: invalid check response")
  }
}

///|
fn run_check_entry_via_session(
  entry_path : String,
) -> Result[CliCheckReport, String] {
  let port = match
    ensure_session_http_worker(
      entry_path,
      @runtime.RuntimeFeatureFlags::new(false, false),
    ) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("check")
  req["path"] = Json::string(entry_path)
  let json = match session_http_request_json(port, Json::object(req)) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  parse_cli_check_report_json(json)
}

///|
fn parse_cli_run_value_json(json : Json) -> Result[WasmRunValue, String] {
  match json {
    Json::Object(obj) => {
      let kind = parse_report_json_string(json, "value_kind")
      match kind {
        "int" =>
          match obj.get("value") {
            Some(Json::String(value)) => {
              let parsed = @string.parse_int(value) catch {
                _ => return Err("session-http: invalid run int result")
              }
              Ok(WasmRunValue::Int(parsed.to_int64()))
            }
            _ => Err("session-http: invalid run int result")
          }
        "bool" =>
          match obj.get("value") {
            Some(Json::True) => Ok(WasmRunValue::Bool(true))
            Some(Json::False) => Ok(WasmRunValue::Bool(false))
            _ => Err("session-http: invalid run bool result")
          }
        _ => Err("session-http: invalid run response")
      }
    }
    _ => Err("session-http: invalid run response")
  }
}

///|
fn run_entry_via_session(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[WasmRunValue, String] {
  let port = match ensure_session_http_worker(entry_path, features) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("run")
  req["path"] = Json::string(entry_path)
  let json = match session_http_request_json(port, Json::object(req)) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  parse_cli_run_value_json(json)
}

///|
fn parse_cli_test_report_json(json : Json) -> Result[CliTestReport, String] {
  match json {
    Json::Object(obj) => {
      let failures : Array[CliTestFailure] = []
      match obj.get("failures") {
        Some(Json::Array(items)) =>
          for item in items {
            match item {
              Json::Object(failure_obj) => {
                let name = match failure_obj.get("name") {
                  Some(Json::String(value)) => Some(value)
                  _ => None
                }
                let error = match failure_obj.get("error") {
                  Some(Json::String(value)) => value
                  _ => ""
                }
                failures.push(CliTestFailure::{ name, error })
              }
              _ => ()
            }
          }
        _ => ()
      }
      Ok({
        total: parse_report_json_int(json, "total"),
        passed: parse_report_json_int(json, "passed"),
        failed: parse_report_json_int(json, "failed"),
        failures,
      })
    }
    _ => Err("session-http: invalid test response")
  }
}

///|
fn run_test_file_via_session(
  entry_path : String,
  features : @runtime.RuntimeFeatureFlags,
) -> Result[CliTestReport, String] {
  let port = match ensure_session_http_worker(entry_path, features) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  let req : Map[String, Json] = {}
  req["cmd"] = Json::string("test")
  req["path"] = Json::string(entry_path)
  let json = match session_http_request_json(port, Json::object(req)) {
    Ok(v) => v
    Err(err) => return Err(err)
  }
  parse_cli_test_report_json(json)
}

///|
fn elapsed_us_to_ms_int(elapsed_us : Double) -> Int {
  let elapsed_ms = (elapsed_us / 1000.0).to_int()
  if elapsed_ms <= 0 {
    1
  } else {
    elapsed_ms
  }
}

///|
fn test_cmd_report_json(
  entry_paths : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  vibe_worker_process_group_init()
  let worker_parent_pid = test_worker_parent_pid()
  match worker_parent_pid {
    Some(parent_pid) => vibe_worker_parent_watchdog_start(parent_pid)
    None => ()
  }
  defer vibe_worker_parent_watchdog_stop()
  let mut any_failed = false
  let cache = CliEntryDbCache::new()
  let use_session_http = cli_use_session_http()
  for entry_path in entry_paths {
    if should_exit_report_json_worker(worker_parent_pid) {
      c_exit(130)
    }
    let start = @bench.monotonic_clock_start()
    let mut elapsed_ms = 1
    let outcome = if use_session_http {
      match run_test_file_via_session(entry_path, features) {
        Ok(v) => TestFileOutcome::Done(v)
        Err(_) =>
          run_test_file_with_backend_with_cache(cache, entry_path, features)
      }
    } else {
      run_test_file_with_backend_with_cache(cache, entry_path, features)
    }
    match outcome {
      TestFileOutcome::Done(report) => {
        let elapsed_us = @bench.monotonic_clock_end(start)
        elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
        println(
          make_cli_test_report_json(entry_path, report, elapsed_ms).stringify(),
        )
        if report.failed > 0 {
          any_failed = true
        }
      }
      TestFileOutcome::Skipped(reason) => {
        let elapsed_us = @bench.monotonic_clock_end(start)
        elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
        println(
          make_skipped_report_json(entry_path, "test", reason, elapsed_ms).stringify(),
        )
      }
      TestFileOutcome::Errored(err) => {
        let elapsed_us = @bench.monotonic_clock_end(start)
        elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
        println(
          make_error_report_json(entry_path, "test", err, elapsed_ms).stringify(),
        )
        any_failed = true
      }
    }
  }
  if any_failed {
    // Use c_exit(1) instead of abort() to avoid SIGABRT + core dump on
    // Linux. See test_cmd_sequential and issue #266.
    println("test: failures detected")
    c_exit(1)
  }
}

///|
fn parse_cli_session_request(
  line : String,
) -> Result[CliSessionRequest, String] {
  let json : Json = @json.parse(line) catch {
    _ => return Err("session-json: invalid json")
  }
  match json {
    Json::Object(obj) => {
      let cmd = match obj.get("cmd") {
        Some(Json::String(value)) => value.trim().to_owned().to_lower()
        _ => return Err("session-json: missing cmd")
      }
      match cmd {
        "ping" =>
          Ok(CliSessionRequest::{
            kind: CliSessionRequestKind::Ping,
            path: None,
          })
        "run" =>
          match obj.get("path") {
            Some(Json::String(value)) => {
              let path = value.trim().to_owned()
              if path.length() == 0 {
                Err("session-json: missing path")
              } else {
                Ok(CliSessionRequest::{
                  kind: CliSessionRequestKind::Run,
                  path: Some(path),
                })
              }
            }
            _ => Err("session-json: missing path")
          }
        "check" =>
          match obj.get("path") {
            Some(Json::String(value)) => {
              let path = value.trim().to_owned()
              if path.length() == 0 {
                Err("session-json: missing path")
              } else {
                Ok(CliSessionRequest::{
                  kind: CliSessionRequestKind::Check,
                  path: Some(path),
                })
              }
            }
            _ => Err("session-json: missing path")
          }
        "test" =>
          match obj.get("path") {
            Some(Json::String(value)) => {
              let path = value.trim().to_owned()
              if path.length() == 0 {
                Err("session-json: missing path")
              } else {
                Ok(CliSessionRequest::{
                  kind: CliSessionRequestKind::Test,
                  path: Some(path),
                })
              }
            }
            _ => Err("session-json: missing path")
          }
        "shutdown" | "quit" =>
          Ok(CliSessionRequest::{
            kind: CliSessionRequestKind::Shutdown,
            path: None,
          })
        _ => Err("session-json: unsupported cmd: " + cmd)
      }
    }
    _ => Err("session-json: request must be object")
  }
}

///|
fn handle_cli_session_request(
  cache : CliEntryDbCache,
  req : CliSessionRequest,
  features : @runtime.RuntimeFeatureFlags,
  worker_token : String,
) -> (Json, Bool) {
  match req.kind {
    CliSessionRequestKind::Ping => {
      let obj : Map[String, Json] = {}
      obj["cmd"] = Json::string("ping")
      obj["ok"] = Json::boolean(true)
      if worker_token.length() > 0 {
        obj["worker_token"] = Json::string(worker_token)
      }
      (Json::object(obj), false)
    }
    CliSessionRequestKind::Shutdown => {
      let obj : Map[String, Json] = {}
      obj["cmd"] = Json::string("shutdown")
      obj["ok"] = Json::boolean(true)
      (Json::object(obj), true)
    }
    CliSessionRequestKind::Run =>
      match req.path {
        Some(path) =>
          match run_cmd_wasm_backend_with_cache(cache, path) {
            Ok(result) => {
              maybe_create_linked_cache_background(path)
              (make_cli_session_run_result_json(path, result), false)
            }
            Err(err) =>
              (make_cli_session_error_json("run", path, "run", err, 1), false)
          }
        None =>
          (
            make_cli_session_error_json(
              "run", "", "parse", "session-json: missing path", 1,
            ),
            false,
          )
      }
    CliSessionRequestKind::Check =>
      match req.path {
        Some(path) => {
          let report = run_check_entry_with_cache(cache, path, false)
          (make_cli_check_report_json(report), false)
        }
        None =>
          (
            make_cli_session_error_json(
              "check", "", "parse", "session-json: missing path", 1,
            ),
            false,
          )
      }
    CliSessionRequestKind::Test =>
      match req.path {
        Some(path) => {
          let start = @bench.monotonic_clock_start()
          match run_test_file_with_backend_with_cache(cache, path, features) {
            TestFileOutcome::Done(report) => {
              let elapsed_us = @bench.monotonic_clock_end(start)
              let elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
              (
                make_cli_session_test_report_json(path, report, elapsed_ms),
                false,
              )
            }
            TestFileOutcome::Skipped(reason) => {
              let elapsed_us = @bench.monotonic_clock_end(start)
              let elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
              (
                make_skipped_report_json(path, "test", reason, elapsed_ms),
                false,
              )
            }
            TestFileOutcome::Errored(err) => {
              let elapsed_us = @bench.monotonic_clock_end(start)
              let elapsed_ms = elapsed_us_to_ms_int(elapsed_us)
              (
                make_cli_session_error_json(
                  "test", path, "test", err, elapsed_ms,
                ),
                false,
              )
            }
          }
        }
        None =>
          (
            make_cli_session_error_json(
              "test", "", "parse", "session-json: missing path", 1,
            ),
            false,
          )
      }
  }
}

///|
fn session_json_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  if args.length() > 0 {
    abort("session-json: unexpected args")
  }
  async fn session_loop() {
    let input = @stdio.stdin
    let cache = CliEntryDbCache::new()
    while input.read_until("\n") is Some(line) {
      let trimmed = line.trim().to_owned()
      if trimmed.length() == 0 {
        continue
      }
      match parse_cli_session_request(trimmed) {
        Err(err) =>
          println(
            make_cli_session_error_json("session", "", "parse", err, 1).stringify(),
          )
        Ok(req) => {
          let (response, should_shutdown) = handle_cli_session_request(
            cache,
            req,
            features,
            session_http_worker_token_env(),
          )
          println(response.stringify())
          if should_shutdown {
            break
          }
        }
      }
    }
  }
  @async.run_async_main(session_loop)
}

///|
fn split_session_http_cmd_args(args : Array[String]) -> Result[Int, String] {
  let mut port : Int? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--port" {
      i += 1
      if i >= args.length() {
        return Err("session-http: missing value after --port")
      }
      let parsed = @string.parse_int(args[i]) catch {
        e => return Err("session-http: invalid --port: " + e.to_string())
      }
      port = Some(parsed)
    } else {
      return Err("session-http: unknown arg " + arg)
    }
    i += 1
  }
  match port {
    Some(v) if v > 0 => Ok(v)
    _ => Err("session-http: --port is required")
  }
}

///|
fn session_http_cmd(
  args : Array[String],
  features : @runtime.RuntimeFeatureFlags,
) -> Unit {
  let port = match split_session_http_cmd_args(args) {
    Ok(v) => v
    Err(err) => abort(err)
  }
  let cache = CliEntryDbCache::with_capacity(session_http_cache_capacity())
  vibe_session_idle_monitor_start(session_http_idle_seconds())
  async fn session_http_loop() {
    let addr = @socket.Addr::parse("127.0.0.1:\{port}") catch {
      err => abort("session-http: invalid listen addr: " + err.to_string())
    }
    let server = @http.Server::new(addr) catch {
      err => abort("session-http: listen failed: " + err.to_string())
    }
    server.run_forever(
      (_request, body, conn) => {
        // Bracket the whole request with begin/end so the idle monitor
        // doesn't shoot the worker mid-response when a check or test
        // legitimately runs longer than VIBE_SESSION_IDLE_SECONDS.
        vibe_session_idle_monitor_begin()
        defer vibe_session_idle_monitor_end()
        let request_buf = StringBuilder::new()
        try {
          while body.read_some() is Some(chunk) {
            request_buf.write_string(@utf8.decode(chunk))
          }
        } catch {
          _ => ()
        }
        let request_body = request_buf.to_string()
        let (response, should_shutdown) = match
          parse_cli_session_request(request_body) {
          Ok(req) =>
            handle_cli_session_request(
              cache,
              req,
              features,
              session_http_worker_token_env(),
            )
          Err(err) =>
            (make_cli_session_error_json("session", "", "parse", err, 1), false)
        }
        conn.send_response(200, "OK", extra_headers={
          "content-type": "application/json",
        })
        conn..write(response.stringify()).end_response()
        if should_shutdown {
          server.close()
          c_exit(0)
        }
      },
      allow_failure=true,
      max_connections=1,
    )
  }
  @async.run_async_main(session_http_loop)
}

///|
fn parse_report_json_int(json : Json, key : String) -> Int {
  match json {
    Json::Object(obj) =>
      match obj.get(key) {
        Some(Json::Number(n, ..)) => n.to_int()
        _ => 0
      }
    _ => 0
  }
}

///|
fn parse_internal_parent_pid_env(env_name : String) -> Int? {
  match @sys.get_env_var(env_name) {
    Some(raw) => {
      let pid = @string.parse_int(raw) catch { _ => 0 }
      if pid > 1 {
        Some(pid)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn internal_parent_pid_env() -> Int? {
  match parse_internal_parent_pid_env("VIBE_INTERNAL_PARENT_PID") {
    Some(pid) => Some(pid)
    None => parse_internal_parent_pid_env("VIBE_INTERNAL_TEST_PARENT_PID")
  }
}

///|
fn test_worker_parent_pid() -> Int? {
  internal_parent_pid_env()
}

///|
fn should_exit_report_json_worker(parent_pid : Int?) -> Bool {
  match parent_pid {
    Some(pid) => vibe_process_exists(pid) == 0
    None => false
  }
}

///|
fn parse_report_json_string(json : Json, key : String) -> String {
  match json {
    Json::Object(obj) =>
      match obj.get(key) {
        Some(Json::String(s)) => s
        _ => ""
      }
    _ => ""
  }
}

///|
fn find_json_lines(text : String) -> Array[String] {
  let lines = text.split("\n")
  let out : Array[String] = []
  for line in lines {
    let trimmed = line.to_owned().trim().to_owned()
    if trimmed.length() > 0 && trimmed.has_prefix("{") {
      out.push(trimmed)
    }
  }
  out
}

///|
fn decode_process_output_lossy(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes[:])
}
