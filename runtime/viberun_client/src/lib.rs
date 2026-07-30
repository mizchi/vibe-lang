//! Rust client for `viberun --daemon`'s line-delimited JSON protocol.
//!
//! The daemon (added in #405) keeps a wasm Store + instance warm across
//! requests so moonbit module-level state survives, eliminating the
//! ~179ms `ensure_builtin_modules` cold-start cost on second+ requests.
//! This crate is the host-side companion: spawn a daemon, send check
//! requests, parse responses. Consumers include the eventual selfhost
//! `vibe check` wrapper (post #402 cutover), LSP servers that batch
//! checks per workspace, and any IDE plugin that wants a long-lived
//! type-check daemon without speaking the JSON protocol directly.
//!
//! # Threading model
//!
//! `Client` is `Send` but **not `Sync`** — the daemon's protocol is
//! single-threaded request/response. Multiple producers must serialize
//! through a `Mutex<Client>` (or move the client into a dedicated
//! worker task and dispatch requests through a channel).
//!
//! # Example
//!
//! ```no_run
//! use viberun_client::Client;
//!
//! let mut client = Client::spawn("/path/to/vibe_check_wasi.cwasm")?;
//! let resp = client.send(&["--check", "src/main.vibe"])?;
//! assert_eq!(resp.exit_code, 0);
//! println!("checker stdout ({} us): {}", resp.elapsed_us, resp.stdout);
//! // client is shut down when dropped — daemon receives EOF on its stdin.
//! # Ok::<(), viberun_client::ClientError>(())
//! ```

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

#[derive(Debug)]
pub enum ClientError {
    /// `viberun --daemon` failed to spawn (binary missing,
    /// non-executable, etc.).
    Spawn(std::io::Error),
    /// IO failure while talking to the daemon — usually means it
    /// exited unexpectedly.
    Io(std::io::Error),
    /// Daemon returned a response we couldn't parse as JSON. Carries
    /// the raw line for debugging.
    BadResponse {
        raw: String,
        err: serde_json::Error,
    },
    /// Daemon reported it's aborting (wasm trap on the previous
    /// request poisoned the store). Subsequent requests on this
    /// client will fail; spawn a fresh one.
    DaemonAborted { error: String, last_stdout: String },
    /// Daemon's stdin/stdout was already closed when we tried to
    /// use it (typically because the daemon process died between
    /// requests).
    DaemonClosed,
}

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ClientError::Spawn(e) => write!(f, "spawn viberun --daemon: {e}"),
            ClientError::Io(e) => write!(f, "daemon io: {e}"),
            ClientError::BadResponse { raw, err } => {
                write!(f, "daemon returned unparseable response: {err} (raw: {raw:?})")
            }
            ClientError::DaemonAborted { error, .. } => {
                write!(f, "daemon aborted: {error}")
            }
            ClientError::DaemonClosed => write!(f, "daemon stdin/stdout already closed"),
        }
    }
}

impl std::error::Error for ClientError {}

impl From<std::io::Error> for ClientError {
    fn from(e: std::io::Error) -> Self {
        ClientError::Io(e)
    }
}

/// Parsed response from a daemon `check`-style request.
///
/// Mirrors the JSON envelope the daemon writes per request:
/// `{"req_id": N, "exit_code": N, "stdout": "...", "elapsed_us": N}`
/// plus optional `error` / `daemon_aborting` fields.
#[derive(Debug, Clone)]
pub struct CheckResponse {
    /// Monotonically-incrementing per-daemon request id. Useful for
    /// matching async dispatch (when the client is wrapped in a
    /// queue) and for diagnostics.
    pub req_id: u64,
    /// Exit code the wasm `main` returned (0 = success, non-zero =
    /// checker reported errors or the wasm aborted via the
    /// `__moonbit_sys_unstable::exit` import).
    pub exit_code: i32,
    /// Whatever the wasm wrote to stdout during the request. The
    /// daemon captures it via the `print_char` import so it doesn't
    /// interleave with the protocol.
    pub stdout: String,
    /// Server-side wall-clock around `_start.call()`, excluding the
    /// stdin/stdout protocol round-trip. This is the cleanest
    /// signal of in-wasm work time.
    pub elapsed_us: u64,
    /// Set when the daemon couldn't satisfy the request (bad JSON,
    /// missing args). Distinct from non-zero `exit_code` which means
    /// the wasm itself reported an error.
    pub error: Option<String>,
}

/// Long-lived client for a `viberun --daemon` process.
///
/// Owns the child process and its stdin/stdout pipes. Dropping the
/// client closes the daemon's stdin (EOF), which makes the daemon
/// exit cleanly. To get exit-code visibility, call
/// `shutdown_and_wait` instead of relying on `Drop`.
pub struct Client {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    stdout: Option<BufReader<ChildStdout>>,
    line_buf: String,
}

impl Client {
    /// Spawn `viberun --daemon <wasm_path>` from the binary at
    /// `MOONRUN_WT_BIN` env var, falling back to a relative path
    /// for the repo layout.
    pub fn spawn(wasm_path: impl AsRef<Path>) -> Result<Self, ClientError> {
        let bin = std::env::var_os("MOONRUN_WT_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from("runtime/viberun/target/release/viberun")
            });
        Self::spawn_with(bin, wasm_path)
    }

    /// Spawn an explicit `viberun` binary against the given wasm.
    /// Use this when the caller already knows where the binary lives
    /// (e.g. a build script that just produced it).
    pub fn spawn_with(
        bin: impl AsRef<Path>,
        wasm_path: impl AsRef<Path>,
    ) -> Result<Self, ClientError> {
        let mut child = Command::new(bin.as_ref())
            .arg("--daemon")
            .arg(wasm_path.as_ref())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // Inherit stderr so the daemon's eprintln! diagnostics
            // (e.g. "daemon ready" banner, trap-abort messages) reach
            // the user's terminal. Callers that want to swallow them
            // should redirect themselves before constructing the
            // Client.
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(ClientError::Spawn)?;
        let stdin = child.stdin.take().ok_or(ClientError::DaemonClosed)?;
        let stdout = child.stdout.take().ok_or(ClientError::DaemonClosed)?;
        Ok(Self {
            child: Some(child),
            stdin: Some(stdin),
            stdout: Some(BufReader::new(stdout)),
            line_buf: String::with_capacity(8 * 1024),
        })
    }

    /// Send one request to the daemon and block until the response
    /// arrives. `args` is the argv the wasm `_start` will see (the
    /// daemon prepends `viberun` as argv[0] on its side).
    pub fn send(&mut self, args: &[&str]) -> Result<CheckResponse, ClientError> {
        let stdin = self.stdin.as_mut().ok_or(ClientError::DaemonClosed)?;
        let stdout = self.stdout.as_mut().ok_or(ClientError::DaemonClosed)?;

        // Encode request as a one-line JSON object. The daemon also
        // accepts a bare array form but we use the named-arg form for
        // forward compatibility — if the protocol ever grows new
        // request fields, a bare array can't carry them.
        let req = serde_json::json!({ "args": args });
        let mut line = serde_json::to_string(&req).map_err(|e| {
            ClientError::BadResponse {
                raw: format!("{req:?}"),
                err: e,
            }
        })?;
        line.push('\n');
        stdin.write_all(line.as_bytes())?;
        stdin.flush()?;

        self.line_buf.clear();
        let n = stdout.read_line(&mut self.line_buf)?;
        if n == 0 {
            // EOF — daemon exited without responding. Reap so the
            // caller sees a clean error rather than a zombie.
            self.reap_child();
            return Err(ClientError::DaemonClosed);
        }

        let trimmed = self.line_buf.trim_end_matches(['\n', '\r']);
        let v: serde_json::Value =
            serde_json::from_str(trimmed).map_err(|e| ClientError::BadResponse {
                raw: trimmed.to_string(),
                err: e,
            })?;

        let req_id = v.get("req_id").and_then(|x| x.as_u64()).unwrap_or(0);
        let exit_code = v.get("exit_code").and_then(|x| x.as_i64()).unwrap_or(-1) as i32;
        let stdout_str = v
            .get("stdout")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let elapsed_us = v.get("elapsed_us").and_then(|x| x.as_u64()).unwrap_or(0);
        let error = v
            .get("error")
            .and_then(|x| x.as_str())
            .map(|s| s.to_string());

        // daemon_aborting=true means a wasm trap poisoned the store;
        // every subsequent request would fail. Surface as a distinct
        // error so the caller knows to spawn a fresh client instead
        // of retrying.
        let aborting = v
            .get("daemon_aborting")
            .and_then(|x| x.as_bool())
            .unwrap_or(false);
        if aborting {
            self.reap_child();
            return Err(ClientError::DaemonAborted {
                error: error.unwrap_or_else(|| "(no error message)".to_string()),
                last_stdout: stdout_str,
            });
        }

        Ok(CheckResponse {
            req_id,
            exit_code,
            stdout: stdout_str,
            elapsed_us,
            error,
        })
    }

    /// Cleanly shut down the daemon (close its stdin → it sees EOF
    /// and exits) and wait for it. Returns the daemon process's
    /// exit status. Prefer this over relying on `Drop` if the caller
    /// wants to surface daemon-side errors.
    pub fn shutdown_and_wait(mut self) -> Result<std::process::ExitStatus, ClientError> {
        drop(self.stdin.take()); // closes daemon stdin
        drop(self.stdout.take()); // closes our read end too
        match self.child.take() {
            Some(mut child) => child.wait().map_err(ClientError::Io),
            None => Err(ClientError::DaemonClosed),
        }
    }

    fn reap_child(&mut self) {
        // Best-effort: close stdin, then wait briefly. Caller hit an
        // error path; we don't want to block forever, so try_wait
        // first and only block on `wait` if the process appears to
        // still be running.
        drop(self.stdin.take());
        if let Some(mut child) = self.child.take() {
            match child.try_wait() {
                Ok(Some(_)) => {}
                _ => {
                    let _ = child.wait();
                }
            }
        }
        self.stdout.take();
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        // Closing stdin is enough to signal EOF; the daemon's `lines()`
        // iterator returns None and it exits cleanly.
        drop(self.stdin.take());
        if let Some(mut child) = self.child.take() {
            // Wait so we don't leave a zombie. The daemon's clean-exit
            // path is fast (~ms) once it sees EOF.
            let _ = child.wait();
        }
    }
}

#[cfg(test)]
mod tests {
    // Integration-style smoke test: spawns the actual viberun
    // binary and checks an actual wasm. Gated on env vars so the
    // crate's bare `cargo test` doesn't require the whole repo
    // build chain.
    //
    // Required env (test no-ops if absent so `cargo test` from the
    // crate dir doesn't fail without the full build):
    //   MOONRUN_WT_TEST_WASM   absolute path to a vibe_check_wasi
    //                          .cwasm (or .wasm). Test skips when unset.
    //   MOONRUN_WT_BIN         optional. If unset the default rel
    //                          path is used; only works when cwd is
    //                          the repo root.
    //   MOONRUN_WT_TEST_CASE   optional. Absolute path to a .vibe
    //                          file to check. Defaults to a fixed
    //                          repo-relative path which only works
    //                          if cwd is the repo root.
    use super::*;

    #[test]
    fn end_to_end_check_via_daemon() {
        let wasm = match std::env::var("MOONRUN_WT_TEST_WASM") {
            Ok(p) => p,
            Err(_) => {
                eprintln!("(skipping: set MOONRUN_WT_TEST_WASM to a cwasm path)");
                return;
            }
        };
        let case = std::env::var("MOONRUN_WT_TEST_CASE")
            .unwrap_or_else(|_| "examples/basics.vibe".to_string());

        let mut client = Client::spawn(&wasm).expect("spawn");
        let resp = client
            .send(&["--check", &case])
            .expect("first request");
        assert_eq!(resp.req_id, 1, "first request id should be 1");
        assert!(resp.elapsed_us > 0, "should report nonzero elapsed_us");
        assert_eq!(
            resp.exit_code, 0,
            "first check should succeed; stdout was: {}",
            resp.stdout
        );

        // Warm pass: subsequent requests should be 3× faster than
        // the cold first one. (Cold ~150-300ms includes
        // ensure_builtin_modules; warm ~5-20ms is the pure check
        // work for a small case.)
        let cold = resp.elapsed_us;
        let warm = client.send(&["--check", &case]).expect("warm").elapsed_us;
        assert!(
            warm * 3 < cold,
            "expected warm ≪ cold, got cold={cold}us warm={warm}us"
        );
    }
}
