#!/usr/bin/env node
"use strict";

const { createHostRuntime } = require("./wasm_vibe_host_runtime.js");
const host = createHostRuntime();
const {
  GuestExit,
  OBJ_STRING,
  REQUESTED_HOST_IMPORT_ABI,
  TAG_INT,
  TAG_MASK,
  TAG_OBJ,
  WASM_PAGE_BYTES,
  annotateTrapWithLinemap,
  atomicWriteFileSync,
  authorizePolicyRawImport,
  authorizePolicyRawPath,
  buildFsMetadataHashParts,
  capabilityWithheldStub,
  configurePolicyRawFs,
  configurePolicyStatToken,
  contentStatDigest,
  contentStatToken,
  cp,
  createPreview2CliStreamsHost,
  createPreview2FilesystemHost,
  currentGuestHeapBytes,
  decodeHostBytes,
  decodeHostInt,
  decodeStringArg,
  decodeTaggedOrRawInt,
  detectHostImportAbi,
  dumpCoverage,
  encodeHostBool,
  encodeHostBytes,
  encodeHostInt,
  encodeHostString,
  encodeTaggedStringArray,
  exitAfterDrain,
  extractProfileRequest,
  findClosureEnv,
  fs,
  httpWorkerCall,
  isPersistentArtifactCacheDisabled,
  isUnimplementedAsyncImport,
  maybeEmitEnvMemoryMark,
  parseArgs,
  parseExportFuncIndices,
  parseFuncToTableSlot,
  parseWasmMemoryLimitBytes,
  parseWithheldCapabilities,
  path,
  policyStatAttestation,
  preGrowWasmMemory,
  profileNowUs,
  projectContentStatDigest,
  publishImmutableTextSync,
  readU32LE,
  readline,
  rejectPolicyWasiModuleImports,
  requestGuestExit,
  tcpWorkerCall,
  tryDecodeExceptionString,
  unimplementedAsyncImportStub,
  unimplementedImportStub,
  usage,
  withheldCapabilities,
  writeProfileRequest,
} = host;

async function main() {
  const {
    daemon,
    invokes,
    wasmPath,
    passthroughArgs: initialPassthroughArgs,
    benchCount,
    benchWarmup,
    benchSetup,
    invokeBatchDir,
    policyStatToken,
    policyStatRoot,
    policyRawFsRoot,
    policyRawFsWriteRoot,
  } = parseArgs(process.argv.slice(2));
  host.policyStatTokenConfig = configurePolicyStatToken(policyStatToken, policyStatRoot);
  host.policyRawFsConfig = configurePolicyRawFs(policyRawFsRoot, policyRawFsWriteRoot, host.policyStatTokenConfig);
  let passthroughArgs = initialPassthroughArgs.slice();
  host.passthroughArgsGlobal = passthroughArgs;
  if (passthroughArgs.length > 0) {
    if (process.env.VIBE_INPUT === undefined && passthroughArgs.length >= 1) {
      process.env.VIBE_INPUT = passthroughArgs[0];
    }
    if (process.env.VIBE_OUTPUT === undefined && passthroughArgs.length >= 2) {
      process.env.VIBE_OUTPUT = passthroughArgs[1];
    }
    if (process.env.VIBE_ENTRY === undefined && passthroughArgs.length >= 3) {
      process.env.VIBE_ENTRY = passthroughArgs[2];
    }
  }
  const wasmBytes = fs.readFileSync(wasmPath);
  host.covWasmBytesGlobal = wasmBytes;
  rejectPolicyWasiModuleImports(wasmBytes);
  if (!REQUESTED_HOST_IMPORT_ABI) {
    const detectedAbi = detectHostImportAbi(wasmBytes);
    if (detectedAbi !== null) {
      host.HOST_IMPORT_ABI = detectedAbi;
    }
  }
  const exportFuncIndices = parseExportFuncIndices(wasmBytes);
  const funcToTableSlot = parseFuncToTableSlot(wasmBytes);
  let instanceRef = null;
  // Also store globally for error handler (see catch block)

  function throwVibeHostError(message) {
    const tag = instanceRef?.exports?.__exception_throw_tag;
    if (tag instanceof WebAssembly.Tag) {
      const payload = encodeHostString(instanceRef, message);
      throw new WebAssembly.Exception(tag, [payload]);
    }
    throw new Error(message);
  }

  // Fs::readdir's entry names, byte-sorted. Explicit byte-order comparison:
  // JS default sort is UTF-16 code-unit order, which diverges from the Rust
  // runner's byte sort for non-ASCII names. A missing directory is a
  // guest-visible host error, matching fs_read_file.
  function sortedDirEntries(dirPath) {
    try {
      const entries = fs.readdirSync(dirPath);
      entries.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
      return entries;
    } catch (e) {
      throwVibeHostError(`fs_read_dir failed for '${dirPath}': ${e.message}`);
    }
  }

  const debugImports = process.env.VIBE_DEBUG_IMPORTS === "1";
  const fallbackModule = new Proxy(
    {},
    {
      get(_target, key) {
        return (...args) => {
          if (debugImports) {
            console.error(`[fallback import] unknown.${String(key)}(${args.length} args)`);
          }
          return 0n;
        };
      },
    },
  );

  function decodeJsonHostValue(jsonTagged) {
    return JSON.parse(decodeStringArg(instanceRef, jsonTagged));
  }

  function encodeJsonHostValue(value) {
    return encodeHostString(instanceRef, JSON.stringify(value));
  }

  function persistentArtifactCacheDisabled(filePath) {
    return isPersistentArtifactCacheDisabled(filePath);
  }

  // Linear-backend stdin feed for the `vibe.stdin_*` host imports (vibe/io).
  // Same VIBE_STDIN_BYTES source as the WASI 0.2 input-stream bridge in
  // createPreview2CliStreamsHost, but with its own cursor: a program uses one
  // backend, so the two never advance the same input concurrently. Unset =>
  // null => immediate EOF, matching the empty-stdin tests.
  const vibeStdinFeed =
    process.env.VIBE_STDIN_BYTES !== undefined
      ? Buffer.from(process.env.VIBE_STDIN_BYTES, "utf8")
      : null;
  let vibeStdinCursor = 0;

  // #794: HTTP client host state for the `vibe.http_*` imports behind
  // lib/@vibe/http's `__http_*_raw` builtins. `http_request` performs the whole
  // request SYNCHRONOUSLY in a child node process running fetch() (host imports
  // cannot suspend the guest here; same execSync pattern as `sh` above) and
  // parks the {status, headers, body} result in this map until http_close.
  const httpResponses = new Map();
  let nextHttpHandle = 1;

  // #865: structured subprocess result host state for `vibe.sh_capture*`,
  // behind lib/@vibe/process's `vibe_sh_capture_*_raw` builtins. `sh_capture`
  // runs the command ONCE (execSync with stdout/stderr captured separately
  // instead of `sh`'s stdio:"inherit" / `sh_lines`'s combined+"error: "-prefix
  // encoding) and parks {exitCode, stdout, stderr} in this map until
  // sh_capture_close -- same handle-map shape as httpResponses above, so the
  // 3 accessor imports are just cheap map reads (no re-exec).
  const shCaptureResults = new Map();
  let nextShCaptureHandle = 1;

  const vibeModule = new Proxy(
    {
      http_request(methodTagged, urlTagged, headersTagged, bodyTagged) {
        const method = decodeStringArg(instanceRef, methodTagged);
        const url = decodeStringArg(instanceRef, urlTagged);
        const headersText = decodeStringArg(instanceRef, headersTagged);
        const body = decodeStringArg(instanceRef, bodyTagged);
        // Child script: read one JSON request from stdin, fetch it, print one
        // JSON response (or {error}) to stdout. Header wire format matches
        // lib/@vibe/http's headers_to_wire: "Name: value" lines, "\n"-joined.
        const script = [
          'let input = "";',
          'process.stdin.on("data", (d) => { input += d; });',
          'process.stdin.on("end", async () => {',
          "  const req = JSON.parse(input);",
          "  const headers = {};",
          '  for (const line of req.headers.split("\\n")) {',
          '    const idx = line.indexOf(":");',
          "    if (idx > 0) headers[line.slice(0, idx).trim()] = line.slice(idx + 1).trim();",
          "  }",
          "  try {",
          "    const res = await fetch(req.url, {",
          "      method: req.method,",
          "      headers,",
          '      body: req.method === "GET" || req.method === "HEAD" || req.body === "" ? undefined : req.body,',
          "    });",
          "    const text = await res.text();",
          "    const resHeaders = {};",
          "    res.headers.forEach((v, k) => { resHeaders[k] = v; });",
          "    process.stdout.write(JSON.stringify({ status: res.status, headers: resHeaders, body: text }));",
          "  } catch (e) {",
          "    process.stdout.write(JSON.stringify({ error: String((e && e.message) || e) }));",
          "  }",
          "});",
        ].join("\n");
        const out = cp.execFileSync(process.execPath, ["-e", script], {
          input: JSON.stringify({ method, url, headers: headersText, body }),
          encoding: "utf8",
          timeout: 60000,
        });
        const res = JSON.parse(out);
        if (res.error) {
          throw new Error(`http_request failed for '${url}': ${res.error}`);
        }
        const handle = nextHttpHandle;
        nextHttpHandle += 1;
        httpResponses.set(handle, res);
        if (process.env.VIBE_DEBUG_HTTP === "1") {
          console.error(
            `[http] ${method} ${url} -> handle=${handle} status=${res.status} body_len=${res.body.length}`,
          );
        }
        return encodeHostInt(handle);
      },
      http_response_status(handleTagged) {
        const entry = httpResponses.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("http_response_status: unknown response handle");
        }
        return encodeHostInt(entry.status);
      },
      http_response_header(handleTagged, nameTagged) {
        const entry = httpResponses.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("http_response_header: unknown response handle");
        }
        // fetch() lowercases header names; match case-insensitively.
        const name = decodeStringArg(instanceRef, nameTagged).toLowerCase();
        const value =
          entry.headers && entry.headers[name] !== undefined ? entry.headers[name] : "";
        return encodeHostString(instanceRef, value);
      },
      http_response_body(handleTagged) {
        const entry = httpResponses.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("http_response_body: unknown response handle");
        }
        return encodeHostString(instanceRef, entry.body);
      },
      // Tolerates unknown handles: `close` is shared by client and (future)
      // server surfaces, so a double-close must not kill the guest.
      http_close(handleTagged) {
        httpResponses.delete(decodeHostInt(handleTagged));
        return 0n;
      },
      sh(cmdTagged) {
        const cmd = decodeStringArg(instanceRef, cmdTagged);
        cp.execSync(cmd, { stdio: "inherit", shell: "/bin/bash" });
        return 0n;
      },
      sh_lines(cmdTagged) {
        const cmd = decodeStringArg(instanceRef, cmdTagged);
        try {
          const output = cp.execSync(cmd, { encoding: "utf-8", shell: "/bin/bash", stdio: ["pipe", "pipe", "pipe"] });
          return encodeHostString(instanceRef, output.trimEnd());
        } catch (e) {
          const stderr = e.stderr ? e.stderr.toString().trim() : e.message;
          return encodeHostString(instanceRef, "error: " + stderr);
        }
      },
      // #865: structured subprocess result behind lib/@vibe/process's
      // `sh_capture(cmd) -> ShResult`. Unlike `sh_lines` (combines
      // stdout+stderr into one packed string, and loses the real exit code
      // behind an "error: " string prefix on failure), this runs the command
      // ONCE via spawnSync -- which reports {status, stdout, stderr}
      // separately for BOTH the success and failure case (execSync only
      // returns stdout on success and throws on failure, so it can't give a
      // uniform success/failure shape without a try/catch that duplicates
      // the whole result plumbing) -- and parks the three fields behind a
      // handle so the 3 accessor calls below are cheap map reads, not re-execs.
      sh_capture(cmdTagged) {
        const cmd = decodeStringArg(instanceRef, cmdTagged);
        const res = cp.spawnSync(cmd, {
          shell: "/bin/bash",
          encoding: "utf-8",
          maxBuffer: 64 * 1024 * 1024,
        });
        let exitCode;
        let stderr = res.stderr || "";
        if (res.error) {
          // The shell/child itself failed to spawn (e.g. missing binary) --
          // no real exit code exists, so use the shell "command not found"
          // convention (127) and surface the spawn error on stderr.
          exitCode = 127;
          stderr = stderr || String((res.error && res.error.message) || res.error);
        } else if (res.signal) {
          // Killed by a signal rather than exiting normally; 128 is a
          // reasonable non-zero sentinel (we don't have a portable
          // signal-name -> number table here).
          exitCode = 128;
        } else {
          exitCode = res.status === null || res.status === undefined ? 1 : res.status;
        }
        const handle = nextShCaptureHandle;
        nextShCaptureHandle += 1;
        shCaptureResults.set(handle, {
          exitCode,
          stdout: res.stdout || "",
          stderr,
        });
        if (process.env.VIBE_DEBUG_SH === "1") {
          console.error(
            `[sh-capture] handle=${handle} exit=${exitCode} stdout_len=${(res.stdout || "").length} stderr_len=${stderr.length}`,
          );
        }
        return encodeHostInt(handle);
      },
      sh_capture_exit_code(handleTagged) {
        const entry = shCaptureResults.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("sh_capture_exit_code: unknown handle");
        }
        return encodeHostInt(entry.exitCode);
      },
      sh_capture_stdout(handleTagged) {
        const entry = shCaptureResults.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("sh_capture_stdout: unknown handle");
        }
        return encodeHostString(instanceRef, entry.stdout);
      },
      sh_capture_stderr(handleTagged) {
        const entry = shCaptureResults.get(decodeHostInt(handleTagged));
        if (!entry) {
          throw new Error("sh_capture_stderr: unknown handle");
        }
        return encodeHostString(instanceRef, entry.stderr);
      },
      // Tolerates unknown handles, like http_close above (a double-close
      // must not kill the guest).
      sh_capture_close(handleTagged) {
        shCaptureResults.delete(decodeHostInt(handleTagged));
        return 0n;
      },
      // #903/#865: propagate a guest-chosen exit code to the real OS exit
      // status -- unlike `main() -> Int`'s return value, which `_start`
      // only prints. #3109: the GuestExit thrown here unwinds the guest, so
      // nothing after this call in the guest runs, and the process then
      // exits with the code through the normal path (see `GuestExit`); the
      // return value below is unreachable but kept for host-import
      // type-signature consistency.
      process_exit(codeTagged) {
        requestGuestExit(Number(decodeHostInt(codeTagged)));
        return 0n;
      },
      // vibe/io host effects (linear codegen `vibe.*` module). Both stdin
      // readers draw from the SAME VIBE_STDIN_BYTES feed + cursor as the WASI
      // 0.2 input-stream bridge (preview2CliStreamsHost), so a linear-backend
      // program reading stdin sees the runner's configured input rather than a
      // hardcoded EOF. With no VIBE_STDIN_BYTES the feed is null => immediate EOF
      // (read_char -> -1, read_stream -> ""), matching the empty-stdin tests.
      // write_stream/write_char echo to process stdout and return 0 (Unit).
      // Socket::tcp_connect/tcp_read/tcp_write/tcp_close -- mirrors
      // runtime/viberun's blocking std::net::TcpStream host imports (that
      // file's comment explains the "declared, zero codegen wiring" gap
      // this closes). Node has no synchronous TCP client, so the actual
      // net.Socket work runs on a worker thread
      // (wasm_vibe_host_runner_tcp_worker.js) and this thread blocks on
      // Atomics.wait() -- same blocking-bridge trick as `sleep` below, but
      // handing off to a worker instead of just parking this thread, since
      // an actual socket op needs Node's event loop running somewhere to
      // ever complete.
      tcp_connect(hostTagged, portTagged) {
        const host = decodeStringArg(instanceRef, hostTagged);
        const tcpPort = Number(decodeHostInt(portTagged));
        const handle = tcpWorkerCall("connect", { host, tcpPort });
        return encodeHostInt(handle);
      },
      tcp_read(handleTagged, maxBytesTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const maxBytes = Number(decodeHostInt(maxBytesTagged));
        const chunk = tcpWorkerCall("read", { handle, maxBytes });
        return encodeHostString(instanceRef, chunk);
      },
      tcp_write(handleTagged, dataTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const data = decodeStringArg(instanceRef, dataTagged);
        tcpWorkerCall("write", { handle, data });
        return 0n;
      },
      // Tolerates unknown handles, like fs_remove above -- a double-close
      // must not kill the guest (the worker's "close" handler no-ops on a
      // missing handle, same convention).
      tcp_close(handleTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        tcpWorkerCall("close", { handle });
        return 0n;
      },
      // Http::request/response_status/response_header/response_body/close
      // (#1226) -- mirrors runtime/viberun's ureq-based host imports. Same
      // worker-thread + Atomics.wait bridge as tcp_* above (Node has no
      // synchronous HTTP client either), via
      // wasm_vibe_host_runner_http_worker.js.
      http_request(methodTagged, urlTagged, headersTagged, bodyTagged) {
        const method = decodeStringArg(instanceRef, methodTagged);
        const url = decodeStringArg(instanceRef, urlTagged);
        const headers = decodeStringArg(instanceRef, headersTagged);
        const body = decodeStringArg(instanceRef, bodyTagged);
        const handle = httpWorkerCall("request", { method, url, headers, body });
        return encodeHostInt(handle);
      },
      http_response_status(handleTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const status = httpWorkerCall("status", { handle });
        return encodeHostInt(status);
      },
      http_response_header(handleTagged, nameTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const name = decodeStringArg(instanceRef, nameTagged);
        const value = httpWorkerCall("header", { handle, name });
        return encodeHostString(instanceRef, value);
      },
      http_response_body(handleTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        const body = httpWorkerCall("body", { handle });
        return encodeHostString(instanceRef, body);
      },
      // Tolerates unknown handles, like tcp_close above.
      http_close(handleTagged) {
        const handle = Number(decodeHostInt(handleTagged));
        httpWorkerCall("close", { handle });
        return 0n;
      },
      // `sleep(Int) -> Unit with Async` -- mirrors runtime/viberun's
      // `vibe.sleep` host import (see that impl's comment for why this is a
      // plain blocking sleep, not a true async/wasip3 one). Atomics.wait on
      // a throwaway SharedArrayBuffer blocks this thread synchronously,
      // same trick used for synchronous sleeps elsewhere in Node CLIs --
      // there's no way to `await` inside a synchronous WebAssembly import.
      sleep(msTagged) {
        const ms = Number(decodeHostInt(msTagged));
        if (ms > 0) {
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
        }
        return 0n;
      },
      stdin_read_char() {
        if (vibeStdinFeed && vibeStdinCursor < vibeStdinFeed.length) {
          const b = vibeStdinFeed[vibeStdinCursor];
          vibeStdinCursor += 1;
          return encodeHostInt(b);
        }
        return encodeHostInt(-1);
      },
      stdin_read_stream(nTagged) {
        const n = decodeHostInt(nTagged);
        if (!vibeStdinFeed || vibeStdinCursor >= vibeStdinFeed.length || n <= 0) {
          return encodeHostString(instanceRef, "");
        }
        const end = Math.min(vibeStdinFeed.length, vibeStdinCursor + n);
        const chunk = vibeStdinFeed.slice(vibeStdinCursor, end).toString("utf8");
        vibeStdinCursor = end;
        return encodeHostString(instanceRef, chunk);
      },
      stdout_write_stream(strTagged) {
        const str = decodeStringArg(instanceRef, strTagged);
        process.stdout.write(str);
        return 0n;
      },
      stdout_write_char(codeTagged) {
        const code = decodeHostInt(codeTagged);
        process.stdout.write(String.fromCharCode(code));
        return 0n;
      },
      // #865: Stderr, same shape as the Stdout pair above but writing to fd 2.
      stderr_write_stream(strTagged) {
        const str = decodeStringArg(instanceRef, strTagged);
        process.stderr.write(str);
        return 0n;
      },
      stderr_write_char(codeTagged) {
        const code = decodeHostInt(codeTagged);
        process.stderr.write(String.fromCharCode(code));
        return 0n;
      },
      path(pathValue) {
        const input = decodeStringArg(instanceRef, pathValue);
        return encodeHostString(instanceRef, input);
      },
      ["resolve-path"](pathTagged) {
        const input = decodeStringArg(instanceRef, pathTagged);
        return encodeHostString(instanceRef, input);
      },
      // #762: Path::ref / Path::resolve host op — resolve to an absolute path
      // against the process CWD (node path.resolve). Purely lexical: it does not
      // require the path to exist.
      resolve_path(pathTagged) {
        const input = decodeStringArg(instanceRef, pathTagged);
        return encodeHostString(instanceRef, path.resolve(input));
      },
      fs_read_file(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          const content = fs.readFileSync(filePath, "utf8");
          if (process.env.VIBE_DEBUG_FS === "1") {
            console.error(`[fs-read] ${filePath} bytes=${Buffer.byteLength(content, "utf8")}`);
          }
          return encodeHostString(instanceRef, content);
        } catch (e) {
          throwVibeHostError(`fs_read_file failed for '${filePath}': ${e.message}`);
        }
      },
      // #632: read a file as raw bytes into a guest Bytes value. The exact
      // inverse of fs_write_bytes — unlike fs_read_file (utf8) it preserves
      // arbitrary binary, so the persistent artifact cache can store/load wasm
      // raw instead of hex (halving disk + dropping encode/decode).
      fs_read_bytes(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          const buf = fs.readFileSync(filePath);
          if (process.env.VIBE_DEBUG_FS === "1") {
            console.error(`[fs-read-bytes] ${filePath} bytes=${buf.length}`);
          }
          return encodeHostBytes(instanceRef, buf);
        } catch (e) {
          throwVibeHostError(`fs_read_bytes failed for '${filePath}': ${e.message}`);
        }
      },
      // #729/#730 + #2957: Fs::readdir — entry NAMES, byte-sorted, joined
      // into ONE string over the same ABI as fs_read_file (raw + tagged both
      // work; codegen splits guest-side). The legacy fs_readdir below is
      // tagged-ABI-only (host-built array) and predates the selfhost raw ABI.
      // Empty dir -> "". Missing dir -> error, matching fs_read_file.
      //
      // The separator is NUL, the one byte a POSIX name cannot contain. A name
      // MAY contain "\n", so the "\n"-joined fs_read_dir split such a name
      // into fake entries (#2957). fs_read_dir stays only for modules built
      // by a compiler from before #2957 (the committed seed and whatever it
      // compiles), which import it under that name and split on "\n"; delete
      // it once the seed emits fs_read_dir_nul. viberun carries the same pair.
      fs_read_dir_nul(pathTagged) {
        return encodeHostString(instanceRef, sortedDirEntries(decodeStringArg(instanceRef, pathTagged)).join("\0"));
      },
      fs_read_dir(pathTagged) {
        return encodeHostString(instanceRef, sortedDirEntries(decodeStringArg(instanceRef, pathTagged)).join("\n"));
      },
      fs_exists(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        if (persistentArtifactCacheDisabled(filePath)) {
          if (process.env.VIBE_DEBUG_FS === "1") {
            console.error(`[fs-exists] artifact cache disabled: ${filePath}`);
          }
          return encodeHostBool(false);
        }
        const exists = fs.existsSync(filePath);
        if (process.env.VIBE_DEBUG_FS === "1") {
          console.error(`[fs-exists] ${filePath}=${exists ? "1" : "0"}`);
        }
        return encodeHostBool(exists);
      },
      fs_stat_token(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        // A stat failure (a missing path, an unreadable directory) is a
        // guest-visible host error, the same conversion fs_read_file makes:
        // the compiler stats a source before reading it (#2386), so a path
        // that used to fail at the read must fail the same way one call
        // earlier, not escape the wasm boundary as a raw host exception.
        try {
          if (host.policyStatTokenConfig) {
            return encodeHostInt(contentStatToken(filePath));
          }
          // Module/package loading reserves -1 as a stable non-regular-source
          // witness. lstat is required here: stat would follow the link and make
          // a symlink indistinguishable from its target.
          if (fs.lstatSync(filePath).isSymbolicLink()) {
            return encodeHostInt(-1n);
          }
          const { lower, upper } = buildFsMetadataHashParts(filePath);
          return encodeHostInt(BigInt.asUintN(61, lower ^ upper));
        } catch (e) {
          throwVibeHostError(`fs_stat_token failed for '${filePath}': ${e.message}`);
        }
      },
      fs_write_file(pathTagged, contentTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const content = decodeStringArg(instanceRef, contentTagged);
        const dir = path.dirname(filePath);
        if (dir && !fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        atomicWriteFileSync(filePath, content, "utf8");
        return 0n;
      },
      fs_publish_immutable_text(pathTagged, contentTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const content = decodeStringArg(instanceRef, contentTagged);
        return encodeHostBool(publishImmutableTextSync(filePath, content));
      },
      fs_write_bytes(pathTagged, bytesTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const bytes = decodeHostBytes(instanceRef, bytesTagged);
        const dir = path.dirname(filePath);
        if (dir && !fs.existsSync(dir)) {
          fs.mkdirSync(dir, { recursive: true });
        }
        atomicWriteFileSync(filePath, bytes);
        if (process.env.VIBE_DEBUG_FS === "1") {
          console.error(`[fs-write-bytes] ${filePath} bytes=${bytes.length}`);
        }
        return 0n;
      },
      fs_readdir(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          const entries = fs.readdirSync(dirPath);
          return encodeTaggedStringArray(instanceRef, entries);
        } catch (e) {
          return encodeTaggedStringArray(instanceRef, []);
        }
      },
      fs_getcwd() {
        return encodeHostString(instanceRef, process.cwd());
      },
      fs_chdir(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          process.chdir(dirPath);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_is_dir(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          return encodeHostBool(fs.statSync(filePath).isDirectory());
        } catch (e) {
          return encodeHostBool(false);
        }
      },
      fs_is_file(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          return encodeHostBool(fs.statSync(filePath).isFile());
        } catch (e) {
          return encodeHostBool(false);
        }
      },
      fs_mkdir(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          fs.mkdirSync(dirPath);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_mkdir_p(pathTagged) {
        const dirPath = decodeStringArg(instanceRef, pathTagged);
        try {
          fs.mkdirSync(dirPath, { recursive: true });
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      // #2758: NON-recursive, and it PROPAGATES. Both halves are a change from
      // the `rmSync(.., { recursive: true, force: true })` this used to be, and
      // both exist to make one builtin mean one thing on both hosts: the Rust
      // runner's `fs_remove` has always been `fs::remove_file`, which removes a
      // file or a symlink and returns Err on a directory or a missing path. A
      // program that cleared a path which happened to name a directory
      // destroyed a tree here and trapped there.
      //
      // The three-way split the swallow/propagate axis now carries:
      //
      //   Fs::remove       a file, loudly   -- this
      //   Fs::remove_file  a file, quietly  -- #2738, swallows on both hosts
      //   Fs::remove_tree  a tree, quietly  -- below, recursive + force
      //
      // Loud is safe here because it was audited, not assumed: of 37 call sites
      // in the tree, 32 are `if Fs::exists(p)` guarded, and the 5 that are not
      // are each fine -- `gc_host_builtins` writes the file immediately before,
      // `@vibex/shell`'s `rm` SHOULD fail like POSIX `rm` does, and the three in
      // `loader_persistent_cache_test` are tree removals that moved to
      // `Fs::remove_tree`.
      fs_remove(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          fs.unlinkSync(filePath);
          return 0n;
        } catch (e) {
          throwVibeHostError(`fs_remove failed for '${filePath}': ${e.message}`);
        }
      },
      // #2758: the recursive form, which is what `fs_remove` above used to be.
      // A missing path is a no-op; every other failure propagates.
      //
      // THE EXISTENCE TEST IS OURS, not `rmSync`'s `force`. Delegating to force
      // looks equivalent and is not: WHICH errors it suppresses changed between
      // Node majors. Measured, same program, one file and `rmSync(file +
      // "/sub", { recursive: true, force: true })`:
      //
      //   node v22.22.2   throws ENOTDIR
      //   node v24.21.0   succeeds
      //
      // CI pins node 24 and this container runs 22, so a gate asserting the two
      // runners agree passed here and failed there -- the divergence #2758
      // exists to remove, reappearing as "an accident of which node version ran
      // it" instead of "which runner" (Codex on #2823).
      //
      // So the rule is stated here rather than inherited: lstat, treat ONLY
      // ENOENT as the no-op, and let everything else through. That is the same
      // rule `runtime/viberun/src/main.rs` applies via `ErrorKind::NotFound`,
      // which is what makes the two agree BY CONSTRUCTION on any node.
      //
      // lstat, not stat: a symlink is removed as a link, never followed.
      fs_remove_tree(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        let st;
        try {
          st = fs.lstatSync(filePath);
        } catch (e) {
          if (e.code === "ENOENT") {
            return 0n;
          }
          throwVibeHostError(`fs_remove_tree failed for '${filePath}': ${e.message}`);
        }
        try {
          if (st.isDirectory()) {
            fs.rmSync(filePath, { recursive: true, force: true });
          } else {
            fs.unlinkSync(filePath);
          }
          return 0n;
        } catch (e) {
          throwVibeHostError(`fs_remove_tree failed for '${filePath}': ${e.message}`);
        }
      },
      // #2738: the non-recursive sibling. `fs_remove` is a TREE remover, so a
      // "clear the stale sidecar" call whose path happens to name a directory
      // deletes it whole; every such clear now asks for this instead.
      //
      // lstat, not stat: a symlink pointing AT a directory must still be
      // unlinked, because removing the link never touches what it points to.
      // Only a real directory is refused. unlinkSync is the precise primitive
      // -- it removes a file or a symlink and cannot remove a directory -- so
      // the refusal holds even if the lstat check were ever dropped.
      fs_remove_file(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        try {
          if (fs.lstatSync(filePath).isDirectory()) {
            return 0n;
          }
          fs.unlinkSync(filePath);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_rename(srcTagged, dstTagged) {
        const src = decodeStringArg(instanceRef, srcTagged);
        const dst = decodeStringArg(instanceRef, dstTagged);
        try {
          fs.renameSync(src, dst);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_copy(srcTagged, dstTagged) {
        const src = decodeStringArg(instanceRef, srcTagged);
        const dst = decodeStringArg(instanceRef, dstTagged);
        try {
          fs.copyFileSync(src, dst);
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_append(pathTagged, contentTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const content = decodeStringArg(instanceRef, contentTagged);
        try {
          fs.appendFileSync(filePath, content, "utf8");
          return 0n;
        } catch (e) {
          return 0n;
        }
      },
      fs_open_write(pathTagged) {
        const filePath = decodeStringArg(instanceRef, pathTagged);
        const fd = fs.openSync(filePath, "w");
        return encodeHostInt(fd);
      },
      fs_write_chunk(fdTagged, strTagged) {
        const fd = decodeHostInt(fdTagged);
        const str = decodeStringArg(instanceRef, strTagged);
        fs.writeSync(fd, str);
        return 0n;
      },
      fs_close_write(fdTagged) {
        const fd = decodeHostInt(fdTagged);
        fs.closeSync(fd);
        return 0n;
      },
      json_parse(strTagged) {
        const str = decodeStringArg(instanceRef, strTagged);
        // Parse and re-stringify to validate JSON, then return as tagged string.
        // The vibe runtime treats Json values as opaque tagged strings at the
        // host boundary; higher-level Json::get etc. operate on the parsed tree
        // inside the vibe interpreter/compiled code.
        try {
          const parsed = JSON.parse(str);
          return encodeHostString(instanceRef, JSON.stringify(parsed));
        } catch (e) {
          return encodeHostString(instanceRef, "null");
        }
      },
      json_stringify(valueTagged) {
        // The value is already a tagged string containing JSON text.
        // Just pass it through (identity for string-encoded Json values).
        return valueTagged;
      },
      json_get(valueTagged, keyTagged) {
        const value = decodeJsonHostValue(valueTagged);
        const key = decodeStringArg(instanceRef, keyTagged);
        if (value === null || Array.isArray(value) || typeof value !== "object") {
          throw new Error("Json::get: not an object");
        }
        if (!Object.prototype.hasOwnProperty.call(value, key)) {
          throw new Error(`Json::get: missing key '${key}'`);
        }
        return encodeJsonHostValue(value[key]);
      },
      json_string(valueTagged) {
        const value = decodeJsonHostValue(valueTagged);
        if (typeof value !== "string") {
          throw new Error("Json::string: not a string");
        }
        return encodeHostString(instanceRef, value);
      },
      ["env-get"](nameTagged) {
        const name = decodeStringArg(instanceRef, nameTagged);
        maybeEmitEnvMemoryMark(name);
        const val = process.env[name] || "";
        if (process.env.VIBE_DEBUG_ENV === "1") {
          console.error(`[env-get] ${name}=${val}`);
        }
        return encodeHostString(instanceRef, val);
      },
      ["args-len"]() {
        return encodeHostInt(passthroughArgs.length);
      },
      ["args-get"](indexTagged) {
        const index = decodeHostInt(indexTagged);
        const val =
          index >= 0 && index < passthroughArgs.length ? passthroughArgs[index] : "";
        if (process.env.VIBE_DEBUG_ENV === "1") {
          console.error(`[args-get] ${index}=${val}`);
        }
        return encodeHostString(instanceRef, val);
      },
      ["profile-now-us"]() {
        return encodeHostInt(profileNowUs());
      },
      ["profile-heap-bytes"]() {
        return encodeHostInt(currentGuestHeapBytes());
      },
      env_get(nameTagged) {
        return this["env-get"](nameTagged);
      },
      args_len() {
        return this["args-len"]();
      },
      args_get(indexTagged) {
        return this["args-get"](indexTagged);
      },
      profile_now_us() {
        return this["profile-now-us"]();
      },
      profile_heap_bytes() {
        return this["profile-heap-bytes"]();
      },
    },
    {
      get(target, key) {
        const name = String(key);
        if (withheldCapabilities.has(name)) {
          return capabilityWithheldStub(name);
        }
        if (Object.hasOwn(target, key)) {
          const fn = target[key];
          if (!host.policyRawFsConfig || typeof fn !== "function") return fn;
          return (...args) => {
            authorizePolicyRawImport(name, args, instanceRef);
            return Reflect.apply(fn, target, args);
          };
        }
        if (host.policyRawFsConfig && (name === "sh" || name.startsWith("sh_") || name.startsWith("tcp_") || name.startsWith("http_"))) {
          return () => { throw new Error(`policy raw import denied: ${name}`); };
        }
        if (isUnimplementedAsyncImport(name)) {
          return unimplementedAsyncImportStub(name);
        }
        return unimplementedImportStub(name);
      },
    },
  );

  const wasiModule = {
    fd_write(fd, iovs, iovsLen, nwritten) {
      // WASI fd_write: write iov buffers to fd (1=stdout, 2=stderr)
      const mem = new Uint8Array(instanceRef.exports.memory.buffer);
      const view = new DataView(instanceRef.exports.memory.buffer);
      let totalWritten = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovs + i * 8, true);
        const len = view.getUint32(iovs + i * 8 + 4, true);
        const bytes = mem.slice(ptr, ptr + len);
        const text = new TextDecoder().decode(bytes);
        if (fd === 1) {
          process.stdout.write(text);
        } else {
          process.stderr.write(text);
        }
        totalWritten += len;
      }
      view.setUint32(nwritten, totalWritten, true);
      return 0;
    },
  };

  const preview2FsHost = createPreview2FilesystemHost(
    process.env.VIBE_PREOPEN_DIR || process.cwd(),
  );
  const preview2CliStreamsHost = createPreview2CliStreamsHost();

  // Selfhost-compiled WASM uses "Env" and "Fs" module names for effect imports
  const envModule = {
    ArgsLen() {
      return encodeHostInt(passthroughArgs.length);
    },
    ArgsGet(indexTagged) {
      const index = decodeHostInt(indexTagged);
      const val =
        index >= 0 && index < passthroughArgs.length ? passthroughArgs[index] : "";
      if (process.env.VIBE_DEBUG_ENV === "1") {
        console.error(`[ArgsGet] ${index}=${val}`);
      }
      return encodeHostString(instanceRef, val);
    },
    Get(nameTagged) {
      const name = decodeStringArg(instanceRef, nameTagged);
      maybeEmitEnvMemoryMark(name);
      const val = process.env[name] ?? "";
      if (process.env.VIBE_DEBUG_ENV === "1") {
        console.error(`[Get] ${name}=${val}`);
      }
      return encodeHostString(instanceRef, val);
    },
  };
  const fsModule = {
    ReadFile(pathTagged) {
      if (process.env.VIBE_DEBUG_FS === "1") {
        console.error("[fs-module] ReadFile");
      }
      return vibeModule.fs_read_file(pathTagged);
    },
    WriteFile(pathTagged, contentTagged) {
      return vibeModule.fs_write_file(pathTagged, contentTagged);
    },
    PublishImmutableText(pathTagged, contentTagged) {
      return vibeModule.fs_publish_immutable_text(pathTagged, contentTagged);
    },
    WriteBytes(pathTagged, bytesTagged) {
      return vibeModule.fs_write_bytes(pathTagged, bytesTagged);
    },
    ReadBytes(pathTagged) {
      return vibeModule.fs_read_bytes(pathTagged);
    },
    Exists(pathTagged) {
      return vibeModule.fs_exists(pathTagged);
    },
    StatToken(pathTagged) {
      return vibeModule.fs_stat_token(pathTagged);
    },
    ReadDir(pathTagged) {
      return vibeModule.fs_readdir(pathTagged);
    },
    IsDir(pathTagged) {
      return vibeModule.fs_is_dir(pathTagged);
    },
    IsFile(pathTagged) {
      return vibeModule.fs_is_file(pathTagged);
    },
    Mkdir(pathTagged) {
      return vibeModule.fs_mkdir(pathTagged);
    },
    MkdirP(pathTagged) {
      return vibeModule.fs_mkdir_p(pathTagged);
    },
    Remove(pathTagged) {
      return vibeModule.fs_remove(pathTagged);
    },
    RemoveFile(pathTagged) {
      return vibeModule.fs_remove_file(pathTagged);
    },
    RemoveTree(pathTagged) {
      return vibeModule.fs_remove_tree(pathTagged);
    },
    Rename(srcTagged, dstTagged) {
      return vibeModule.fs_rename(srcTagged, dstTagged);
    },
    Copy(srcTagged, dstTagged) {
      return vibeModule.fs_copy(srcTagged, dstTagged);
    },
    Append(pathTagged, contentTagged) {
      return vibeModule.fs_append(pathTagged, contentTagged);
    },
    Getcwd() {
      return vibeModule.fs_getcwd();
    },
    Chdir(pathTagged) {
      return vibeModule.fs_chdir(pathTagged);
    },
    OpenWrite(pathTagged) {
      return vibeModule.fs_open_write(pathTagged);
    },
    WriteChunk(fdTagged, strTagged) {
      return vibeModule.fs_write_chunk(fdTagged, strTagged);
    },
    CloseWrite(fdTagged) {
      return vibeModule.fs_close_write(fdTagged);
    },
  };
  // Stdin/Stdout effect imports for vibe/io and lib/@vibe/builtin/io helpers.
  const stdinModule = {
    ReadStream(_maxBytesTagged) {
      // tests run without a controlling TTY; return empty string.
      return encodeHostString(instanceRef, "");
    },
    ReadChar() {
      // -1 indicates EOF.
      return encodeHostInt(-1);
    },
  };
  const stdoutModule = {
    WriteStream(strTagged) {
      const str = decodeStringArg(instanceRef, strTagged);
      process.stdout.write(str);
      return 0n;
    },
    WriteChar(codeTagged) {
      const code = decodeHostInt(codeTagged);
      process.stdout.write(String.fromCharCode(code));
      return 0n;
    },
  };
  // #1460 Phase 1: `Console` is the merged tty capability that replaces
  // Stdin/Stdout/Stderr.
  //
  // This module serves the PERFORM lowering only (`perform Console::WriteStream`),
  // which does name its import module after the effect. The linear backend --
  // the default one, and the path `vibe build --release` takes -- imports
  // `vibe.stdout_write_stream` instead: module "vibe", field derived from the
  // operation, effect label absent. So merging the three effects is not an ABI
  // change for it, and `Console::*` reuses the existing imports (see the note
  // in linked_compile.vibe). The legacy Stdin/Stdout modules below stay for
  // wasm the committed seed produced.
  const consoleModule = {
    ReadStream(maxBytesTagged) {
      return stdinModule.ReadStream(maxBytesTagged);
    },
    ReadChar() {
      return stdinModule.ReadChar();
    },
    WriteStream(strTagged) {
      return stdoutModule.WriteStream(strTagged);
    },
    WriteChar(codeTagged) {
      return stdoutModule.WriteChar(codeTagged);
    },
    WriteErrStream(strTagged) {
      const str = decodeStringArg(instanceRef, strTagged);
      process.stderr.write(str);
      return 0n;
    },
    WriteErrChar(codeTagged) {
      const code = decodeHostInt(codeTagged);
      process.stderr.write(String.fromCharCode(code));
      return 0n;
    },
  };
  const profilerModule = {
    NowUs(_envTagged) {
      return encodeHostInt(profileNowUs());
    },
    HeapBytes(_envTagged) {
      return encodeHostInt(currentGuestHeapBytes());
    },
  };

  const imports = new Proxy(
    {
      vibe: vibeModule,
      Env: envModule,
      Fs: fsModule,
      Profiler: profilerModule,
      Stdin: stdinModule,
      Stdout: stdoutModule,
      Console: consoleModule,
      wasi_snapshot_preview1: wasiModule,
      "wasi:cli/stdout@0.2.0": preview2CliStreamsHost["wasi:cli/stdout@0.2.0"],
      "wasi:cli/stderr@0.2.0": preview2CliStreamsHost["wasi:cli/stderr@0.2.0"],
      "wasi:cli/stdin@0.2.0": preview2CliStreamsHost["wasi:cli/stdin@0.2.0"],
      "wasi:io/streams@0.2.0": preview2CliStreamsHost["wasi:io/streams@0.2.0"],
      "wasi:filesystem/preopens@0.2.6":
        preview2FsHost["wasi:filesystem/preopens@0.2.6"],
      "wasi:filesystem/types@0.2.6":
        preview2FsHost["wasi:filesystem/types@0.2.6"],
      "wasi:filesystem/preopens@0.3.0":
        preview2FsHost["wasi:filesystem/preopens@0.3.0"],
      "wasi:filesystem/types@0.3.0":
        preview2FsHost["wasi:filesystem/types@0.3.0"],
    },
    {
      get(target, key) {
        if (key in target) {
          return target[key];
        }
        return fallbackModule;
      },
    },
  );

  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  instanceRef = instance;
  host.instanceRefGlobal = instance;
  host.hostAllocPtrGlobal = null;
  preGrowWasmMemory(instance);
  // #2914: the same `VIBE_MEM=1` contract viberun has had since `vibe run
  // --mem`, on this runner too. It is the same measurement -- `__heap_ptr` is
  // the bump frontier and the linear backend never frees, so peak == total
  // allocated (docs/internal/design/profiling.md, tier 1) -- but until now it
  // existed only in the Rust runtime.
  //
  // That gap is why #2914 went three rounds on guesses. The CLI modes this
  // runner serves (`vibe grep`, `vibe check`, `vibe symbols`, ...) never go
  // through viberun, so "how much does a repo-wide typed sweep allocate" had
  // no answer short of watching it trap -- a BINARY oracle, at the wasm32
  // ceiling, which is why two candidate fixes read as noise.
  //
  // Same line shape as viberun's, so scripts/bench_metrics.sh parses either.
  // `grow_events` is deliberately absent rather than reported as 0: this
  // runner does not record the tier-2 timeline, and a zero would be a claim.
  const memProfile = process.env.VIBE_MEM === "1";
  const memHeapBase = memProfile ? currentGuestHeapBytes() : 0;
  if (memProfile) {
    process.on("exit", () => {
      const mem = instance.exports.memory;
      const committed = mem instanceof WebAssembly.Memory ? mem.buffer.byteLength : 0;
      const peak = currentGuestHeapBytes();
      const allocated = peak >= memHeapBase ? peak - memHeapBase : 0;
      console.error(
        `vibe::mem heap_base=${memHeapBase} heap_peak=${peak} allocated=${allocated} committed=${committed}`,
      );
    });
  }
  let didInitStart = false;
  let initHeapBeforeStart = 0;
  const resolvedEnvCache = new Map();
  const invokeExport = (invoke) => {
    const fn = instance.exports[invoke];
    if (typeof fn !== "function") {
      throw new Error(`missing export: ${invoke}`);
    }
    const prefersZeroEnvFirst =
      invoke.startsWith("probe_") ||
      invoke.startsWith("selfbuild_") ||
      process.env.VIBE_PREFER_ZERO_ENV_FIRST === "1";
    // #799/#1182 perf+correctness: `cli_main` is the selfhost CLI's exported
    // main, and `main` is the ADR-0075 entry every ordinary `.vibex` program
    // uses -- on those artifacts the WASI-convention `_start` ALSO calls the
    // entry directly (see linked_compile.vibe's `_start` synthesis: when a
    // named entry is found it emits exactly `call entry_func_idx` once, no
    // loop). The pre-invoke `_start()` below (module init for test/bench
    // modules, where `_start` instead loops over every `test_*`/`bench_*`
    // export and does NOT call the single target being invoked) therefore
    // duplicated `cli_main`'s work (findClosureEnv then scanned the ~360MB
    // post-compile heap for an env cli_main does not have, and the explicit
    // cli_main call ran AGAIN) and, more seriously, for `main` it double-runs
    // every side effect the program performs (confirmed: a `.vibex` program
    // that writes one line to stdout via `vibe_run.sh` printed it twice).
    // Outputs are byte-identical for cli_main either way (verified); skip the
    // pre-start for both known single-entry names. VIBE_FORCE_RUN_INIT=1
    // restores the old (double-invoking) behavior for debugging.
    //
    // #819: `__test_<name>` / `__bench_<name>` are the per-block exports of a
    // `__no_entry__` test/bench build, and there `_start` IS the loop over all
    // of those blocks -- pre-running it would run EVERY block before the one
    // being invoked (a failing sibling would fail every per-block invoke, and
    // a merged N-file module would run the whole battery N times). There is no
    // module init to lose: a test module's `_start` contains only that loop,
    // and top-level non-function bindings are lazily-initialized thunk globals,
    // not a start-section side effect. The Rust runner's `--bench` mode already
    // calls these exports directly with env=0 (runtime/viberun/src/main.rs);
    // this makes the JS runner's `--invoke` agree.
    const isPerBlockExport =
      invoke.startsWith("__test_") || invoke.startsWith("__bench_");
    const skipRunInit =
      process.env.VIBE_SKIP_RUN_INIT === "1" ||
      ((invoke === "cli_main" || invoke === "main" || isPerBlockExport) &&
        process.env.VIBE_FORCE_RUN_INIT !== "1");
    let resolvedEnv = 0;
    if (!skipRunInit && invoke !== "_start" && typeof instance.exports._start === "function") {
      if (!didInitStart) {
        initHeapBeforeStart =
          instance.exports.__heap_ptr instanceof WebAssembly.Global
            ? instance.exports.__heap_ptr.value
            : 0;
        try {
          instance.exports._start();
        } catch (startErr) {
          if (process.env.VIBE_DEBUG708_MEMDUMP) {
            const mem708 = new Uint8Array(instance.exports.memory.buffer);
            const hp708g = instance.exports.__heap_ptr;
            const hp708 = hp708g instanceof WebAssembly.Global ? Number(hp708g.value) : mem708.length;
            require("fs").writeFileSync(process.env.VIBE_DEBUG708_MEMDUMP, Buffer.from(mem708.slice(0, Math.min(hp708 + 4096, mem708.length))));
            console.error(`[crash708] dumped ${Math.min(hp708 + 4096, mem708.length)} bytes to ${process.env.VIBE_DEBUG708_MEMDUMP}, heap_ptr=${hp708}`);
          }
          throw startErr;
        }
        didInitStart = true;
        const fsRootDescriptor = instance.exports.__fs_root_descriptor;
        if (fsRootDescriptor instanceof WebAssembly.Global) {
          fsRootDescriptor.value = -1;
        }
      }
      if (resolvedEnvCache.has(invoke)) {
        resolvedEnv = resolvedEnvCache.get(invoke);
      } else {
        const envExport = instance.exports[`__export_env_${invoke}`];
        const funcIdx = exportFuncIndices[invoke];
        const tableSlot = funcIdx !== undefined ? funcToTableSlot[funcIdx] : undefined;
        if (envExport instanceof WebAssembly.Global) {
          const value = envExport.value;
          resolvedEnv = typeof value === "bigint" ? Number(value) : value;
        } else {
          resolvedEnv =
            tableSlot !== undefined ? findClosureEnv(instance, initHeapBeforeStart, tableSlot) : 0;
        }
        if (process.env.VIBE_DEBUG_INVOKE_ENV === "1") {
          console.error(
            `[invoke-env] ${invoke} funcIdx=${funcIdx ?? "<missing>"} tableSlot=${tableSlot ?? "<missing>"} heapStart=${initHeapBeforeStart} heapEnd=${
              instance.exports.__heap_ptr instanceof WebAssembly.Global
                ? instance.exports.__heap_ptr.value
                : "<missing>"
            } envExport=${envExport instanceof WebAssembly.Global ? envExport.value : "<missing>"} resolvedEnv=${resolvedEnv}`,
          );
        }
        resolvedEnvCache.set(invoke, resolvedEnv);
      }
    }
    let result;
    let isSelfhost = false;
    const invokeWithEnv = (envValue) => {
      if (invoke === "_start") {
        return { result: fn(), isSelfhost: false };
      }
      try {
        return { result: fn(envValue), isSelfhost: false };
      } catch (typeErr) {
        if (typeErr instanceof TypeError) {
          return { result: fn(BigInt(envValue)), isSelfhost: true };
        }
        throw typeErr;
      }
    };
    try {
      const envCandidates =
        invoke === "_start"
          ? [0]
          : resolvedEnv !== 0
            ? (prefersZeroEnvFirst ? [0, resolvedEnv] : [resolvedEnv, 0])
            : [0];
      let lastErr = null;
      for (const envValue of envCandidates) {
        try {
          ({ result, isSelfhost } = invokeWithEnv(envValue));
          lastErr = null;
          break;
        } catch (err) {
          // #3109: the guest EXITED; retrying with the other env candidate
          // would run the program a second time.
          if (err instanceof GuestExit) {
            throw err;
          }
          lastErr = err;
        }
      }
      if (lastErr !== null) {
        throw lastErr;
      }
      if (invoke === "_start") {
        didInitStart = true;
      }
      return { result, isSelfhost };
    } catch (err) {
      // #2199: this dump is COMPILER-developer diagnostics -- heap bytes, the
      // RC freelist, raw memory windows. It printed on EVERY trap, so the
      // first thing a reader saw when their `Array::get(xs, 10)` went out of
      // range was a page of hex, ahead of the message that names the index and
      // the length. Off by default; the trap and its stack still print below,
      // which is what `vibe test`'s report parser reads.
      // A GuestExit (#3109) is the program ending, not a crash.
      const crashDebug = !(err instanceof GuestExit) && (process.env.VIBE_CRASH_DEBUG === "1"
        || process.env.VIBE_DEBUG === "1"
        || !!process.env.VIBE_DEBUG708_MEMDUMP);
      if (crashDebug) {
        const heapGlobal = instance.exports.__heap_ptr;
        const mem = new Uint8Array(instance.exports.memory.buffer);
        const hpRaw = heapGlobal?.value;
        const hp = typeof hpRaw === "bigint" ? Number(hpRaw) : hpRaw;
        const hpHex =
          typeof hpRaw === "bigint"
            ? hpRaw.toString(16)
            : hpRaw !== undefined && hpRaw !== null
              ? hpRaw.toString(16)
              : "n/a";
        console.error(`[crash debug] heap_ptr=${hpRaw} (0x${hpHex}), memory_size=${mem.length} (${(mem.length / 65536)} pages) / ${err?.message || err}`);
        console.error(`[crash debug] mem[0..32]: ${Array.from(mem.slice(0, 32)).map(b => b.toString(16).padStart(2, '0')).join(' ')}`);
        if (typeof hp === "number" && hp >= 8 && hp < mem.length - 32) {
          console.error(`[crash debug] mem[heap-8..heap+24]: ${Array.from(mem.slice(hp - 8, hp + 24)).map(b => b.toString(16).padStart(2, '0')).join(' ')}`);
        }
        // #1262: walk the RC legacy free list (global 2, exported as
        // __rc_freelist) from the trap. Nodes are value pointers (block+8);
        // the size word lives at p-8 and the next link at p-4; 0 terminates.
        const flGlobal = instance.exports.__rc_freelist;
        if (flGlobal instanceof WebAssembly.Global && typeof hp === "number") {
          const dv = new DataView(instance.exports.memory.buffer);
          const heapLo = Number(process.env.VIBE_RC_HEAP_START || 58928);
          // #1262: a binary built from the size-word poison tree ORs 0x40000000
          // into the size word of every freed block. Mask it off for display —
          // leaving it in makes every healthy free-list node look corrupt.
          const poison = Number(process.env.VIBE_RC_POISON_MASK || 0);
          const rd = (a) => (a >= 0 && a + 4 <= mem.length ? dv.getUint32(a, true) : null);
          const rdsz = (a) => { const v = rd(a); return v === null ? null : (v & ~poison) >>> 0; };
          let p = flGlobal.value >>> 0;
          console.error(`[crash debug] __rc_freelist head=${p} (0x${p.toString(16)})`);
          const seen = new Set();
          let n = 0;
          let verdict = "clean (terminated at 0)";
          while (p !== 0) {
            if (p < heapLo + 8 || p > hp) {
              verdict = `OUT OF HEAP at node ${n}: p=${p} (0x${p.toString(16)}) not in [${heapLo + 8}, ${hp}]`;
              break;
            }
            if (seen.has(p)) { verdict = `CYCLE at node ${n}: p=${p} seen before`; break; }
            seen.add(p);
            const sz = rdsz(p - 8), nx = rd(p - 4);
            // __rt_arr_new asks for 84 bytes (84 & 7 == 4), so the bump pointer
            // is not always 8-aligned -- low3 != 0 is reported, not fatal.
            if (n < 24 || (p & 7)) {
              console.error(`[crash debug]   fl[${n}] p=${p} low3=${p & 7} size=${sz} next=${nx}`);
            }
            if (n < 6 && process.env.VIBE_RC_FL_WINDOW) {
              const lo = Math.max(0, p - 32), hi = Math.min(mem.length, p + 64);
              const w = Array.from(mem.slice(lo, hi));
              const hex = w.map(b => b.toString(16).padStart(2, "0")).join(" ");
              const asc = w.map(b => (b >= 32 && b < 127 ? String.fromCharCode(b) : ".")).join("");
              console.error(`[crash debug]     win[${n}] ${lo}..${hi} hex=${hex}`);
              console.error(`[crash debug]     win[${n}] ascii=${asc}`);
            }
            if (sz === null || nx === null) { verdict = `UNREADABLE header at node ${n}: p=${p}`; break; }
            p = nx >>> 0;
            n += 1;
            if (n > 4000000) { verdict = `TOO LONG (>4M nodes), last p=${p}`; break; }
          }
          console.error(`[crash debug] __rc_freelist: ${n} nodes walked -> ${verdict}`);
          if (verdict.indexOf("clean") !== 0) {
            const b = p >>> 0;
            console.error(`[crash debug] bad link raw=${b} hex=0x${b.toString(16)} low3=${b & 7} as_untagged_int=${b >> 1}`);
          }
        }
        if (process.env.VIBE_DEBUG708_MEMDUMP) {
          require("fs").writeFileSync(process.env.VIBE_DEBUG708_MEMDUMP, Buffer.from(mem.slice(0, typeof hp === "number" ? hp + 4096 : mem.length)));
          console.error(`[crash debug] full memory dumped to ${process.env.VIBE_DEBUG708_MEMDUMP} (${typeof hp === "number" ? hp + 4096 : mem.length} bytes)`);
        }
      }
      throw err;
    }
  };
  const resultToExitCode = (result, isSelfhost) => {
    if (typeof result === "bigint") {
      // Selfhost-compiled modules return untagged i64 values (same split as
      // emitResult). Treating them as tagged shifted any multiple-of-4 exit
      // code right by 2 (main returning 20 exited 5).
      if (isSelfhost) {
        return Number(result) | 0;
      }
      return decodeTaggedOrRawInt(result);
    }
    if (typeof result === "number") {
      return result | 0;
    }
    return 0;
  };

  const emitResult = (invoke, result, isSelfhost) => {
    // #819: a per-block `__test_`/`__bench_` entry is "run this block", not
    // "evaluate this and report the value" -- codegen gives every one of them
    // the same `ESeq(body, EInt(0))` shape, so the result is a constant 0 that
    // carries no information. Printing it would append a stray `0` line to the
    // block's own stdout, which the doctest harness compares against the
    // embedded ```output block. `_start` doesn't print it either.
    if (invoke.startsWith("__test_") || invoke.startsWith("__bench_")) {
      return;
    }
    // #2858: `scripts/viberun_node.sh` stands in for the Rust `viberun`, which
    // turns the invoked entry's Int into the PROCESS exit status and prints
    // nothing. `runtime/vibe` now reads that status for every verb, so the
    // printed value would be a stray `0` line appended to `vibe check` (whose
    // empty output means clean) and to every other verb's machine-readable
    // stdout. The exit code is set below regardless of this switch.
    if (process.env.VIBE_RUNNER_QUIET_RESULT === "1") {
      return;
    }
    if (typeof result === "bigint") {
      // Check if the result is a tagged object (could be Bytes from selfbuild)
      if (
        (result & TAG_MASK) === TAG_OBJ &&
        (invoke === "selfbuild_compile_stage2" ||
          invoke === "selfbuild_compile_cli_adapter")
      ) {
        // Decode result as Bytes and write to expected output path
        const bytes = decodeHostBytes(instanceRef, result);
        const outPath =
          invoke === "selfbuild_compile_cli_adapter"
            ? "_build/bench/cli_adapter/cli_stage1.wasm"
            : "_build/bench/wasi_selfbuild/index_stage2.wasm";
        const outDir = path.dirname(outPath);
        if (!fs.existsSync(outDir)) {
          fs.mkdirSync(outDir, { recursive: true });
        }
        fs.writeFileSync(outPath, bytes);
        console.log(`wrote ${outPath} (${bytes.length} bytes)`);
      } else if (isSelfhost) {
        // Selfhost-compiled modules return untagged i64 values — print as-is.
        console.log(result.toString());
      } else {
        // For string/array/record results, output display text on first line
        // then raw tagged i64 on second line. CLI checks for VIBE_DISPLAY: prefix.
        const tag = Number(result & 3n);
        if (tag === 1) {
          // Object pointer — try to render display text
          const ptr = Number(result & ~3n);
          const mem = instance.exports.memory;
          if (mem && ptr > 0 && ptr + 8 <= mem.buffer.byteLength) {
            const view = new DataView(mem.buffer);
            const ty = view.getUint32(ptr, true);
            if (ty === 1) {
              // String object
              const len = view.getUint32(ptr + 4, true);
              if (ptr + 8 + len <= mem.buffer.byteLength) {
                const bytes = new Uint8Array(mem.buffer, ptr + 8, len);
                const text = new TextDecoder().decode(bytes);
                console.log("VIBE_DISPLAY:" + JSON.stringify(text));
              }
            } else if (ty === 5) {
              // Array — show element count
              const len = view.getUint32(ptr + 4, true);
              console.log("VIBE_DISPLAY:[Array(" + len + ")]");
            }
          }
        }
        // Always output raw tagged i64 as last line
        console.log(result.toString());
      }
    } else if (result !== undefined) {
      console.log(String(result));
    }
  };

  const runInvokes = (args) => {
    passthroughArgs = args.slice();
    host.passthroughArgsGlobal = passthroughArgs;
    const profileRequest = extractProfileRequest(passthroughArgs);
    const profileStartNs = process.hrtime.bigint();
    let result;
    let isSelfhost = false;
    for (const invoke of invokes) {
      host.currentInvokeGlobal = invoke;
      ({ result, isSelfhost } = invokeExport(invoke));
    }
    const elapsedUs = Number(process.hrtime.bigint() - profileStartNs) / 1000;
    writeProfileRequest(profileRequest, elapsedUs);
    return { result, isSelfhost, elapsedUs };
  };

  // #819/#141: run EVERY `--invoke` target in one process, keeping each one's
  // output separate.
  //
  // The doctest harness compiles a doc's blocks into a single module (#819)
  // and then invoked one `__test_<block>` export per block -- one node process
  // each, ~61ms of process+instantiate overhead apiece that has nothing to do
  // with the block. `--invoke` was always repeatable, but a plain repeat
  // concatenates every target's stdout into one stream, and the harness has to
  // compare EACH block's stdout against its own ```output. So the split is the
  // whole feature: target i's stdout, stderr and status land in
  // `<dir>/<i>.{out,err,rc}`, 1-based in flag order.
  //
  // Files rather than in-band delimiters on purpose: a block's stdout is
  // arbitrary doc output, so any marker line could legitimately appear inside
  // it and there is no escaping layer to lean on.
  //
  // Sequential invokes share one instance, which is exactly what `_start` does
  // for a test module (it loops over every `test_*` export in the same
  // instance), so this is the established semantics rather than a new one. A
  // failing target does NOT stop the batch -- its `rc` is 1 and the next one
  // runs -- but a target that dies hard enough to take the process with it
  // simply leaves later `.rc` files absent, which callers read as "not run"
  // and fall back to running those alone.
  const runInvokeBatch = (args, dir) => {
    passthroughArgs = args.slice();
    host.passthroughArgsGlobal = passthroughArgs;
    fs.mkdirSync(dir, { recursive: true });
    const originalStdoutWrite = process.stdout.write;
    const originalStderrWrite = process.stderr.write;
    let anyFailed = false;
    for (let i = 0; i < invokes.length; i += 1) {
      let out = "";
      let err = "";
      const capture = (append) => (chunk, encoding, callback) => {
        if (typeof encoding === "function") {
          callback = encoding;
        }
        append(Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk));
        if (typeof callback === "function") {
          callback();
        }
        return true;
      };
      let rc = 0;
      process.stdout.write = capture((t) => {
        out += t;
      });
      process.stderr.write = capture((t) => {
        err += t;
      });
      try {
        const { result, isSelfhost } = invokeExport(invokes[i]);
        // A per-block export carries no result (emitResult returns early for
        // `__test_`/`__bench_`); for anything else this keeps batch mode's
        // stdout the same as a single-invoke run's.
        emitResult(invokes[i], result, isSelfhost);
      } catch (e) {
        if (e instanceof GuestExit) {
          // #3109: this target called `process_exit`. Its code is ITS status,
          // like any other target's; the batch's own status is `anyFailed`.
          rc = e.code;
          host.guestExitCode = null;
        } else {
          rc = 1;
          err += `${decodeExceptionMessage(e)}\n`;
        }
      } finally {
        process.stdout.write = originalStdoutWrite;
        process.stderr.write = originalStderrWrite;
      }
      const slot = String(i + 1);
      fs.writeFileSync(path.join(dir, `${slot}.out`), out);
      fs.writeFileSync(path.join(dir, `${slot}.err`), err);
      fs.writeFileSync(path.join(dir, `${slot}.rc`), `${rc}\n`);
      if (rc !== 0) {
        anyFailed = true;
      }
    }
    return anyFailed;
  };

  const decodeExceptionMessage = (err) => {
    if (!(err instanceof WebAssembly.Exception) || !host.instanceRefGlobal) {
      return err?.message || String(err);
    }
    for (const exp of Object.values(host.instanceRefGlobal.exports)) {
      if (exp instanceof WebAssembly.Tag) {
        try {
          const payload = err.getArg(exp, 0);
          const msg = tryDecodeExceptionString(host.instanceRefGlobal, payload);
          if (msg !== null) {
            return msg;
          }
        } catch (_) {}
      }
    }
    return err?.message || String(err);
  };

  const emitWasmMemoryStats = (label) => {
    if (process.env.VIBE_WASM_MEMORY_STATS !== "1") {
      return;
    }
    const statAttestation = policyStatAttestation();
    if (statAttestation) {
      console.error(
        `[policy-stat-token] mode=${statAttestation.mode} calls=${statAttestation.calls} unique=${statAttestation.unique} transcript=${statAttestation.transcript}`,
      );
    }
    if (host.HOST_IMPORT_ABI !== "raw") {
      console.error(`[wasm-memory] ${label} skipped abi=${host.HOST_IMPORT_ABI}`);
      return;
    }
    const memory = instance.exports.memory;
    if (!(memory instanceof WebAssembly.Memory)) {
      console.error(`[wasm-memory] ${label} memory=missing`);
      return;
    }
    const heapGlobal = instance.exports.__heap_ptr;
    const heapRaw = heapGlobal instanceof WebAssembly.Global ? heapGlobal.value : null;
    const heapPtr =
      typeof heapRaw === "bigint"
        ? Number(BigInt.asUintN(64, heapRaw))
        : typeof heapRaw === "number"
          ? heapRaw >>> 0
          : heapRaw;
    const memoryBytes = memory.buffer.byteLength;
    const memoryPages = memoryBytes / 65536;
    const hostAllocPtr = host.hostAllocPtrGlobal === null ? 0 : host.hostAllocPtrGlobal;
    const rss = process.memoryUsage().rss;
    console.error(
      `[wasm-memory] ${label} pages=${memoryPages} bytes=${memoryBytes} heap_ptr=${heapPtr ?? "missing"} host_alloc_ptr=${hostAllocPtr} rss=${rss}`,
    );
  };

  // Daemon responses report the bump-allocator high-water (same source as
  // emitWasmMemoryStats) so a batch driver can recycle the process before the
  // never-freed heap approaches the wasm32 4GB memory ceiling.
  const readHeapPtr = () => {
    const heapGlobal = instance.exports.__heap_ptr;
    const heapRaw = heapGlobal instanceof WebAssembly.Global ? heapGlobal.value : null;
    if (typeof heapRaw === "bigint") {
      return Number(BigInt.asUintN(64, heapRaw));
    }
    return typeof heapRaw === "number" ? heapRaw >>> 0 : 0;
  };

  const runDaemon = async () => {
    if (benchCount !== null) {
      throw new Error("--daemon cannot be combined with --bench-count");
    }
    if (invokes.length !== 1) {
      throw new Error("--daemon requires exactly one --invoke target");
    }
    // #2876: a compiler-sized compile never frees, so several in one --daemon
    // walk the bump allocator into the wasm32 ceiling. What surfaced was a bare
    // `unreachable` -- or `memory access out of bounds`, the spelling depending
    // on whether the guest faulted on the access or on its own grow check -- in
    // `elapsed_us: 1` with no `.diag`, which is exactly the shape a caller
    // reserves for "the compiler DIED" (checked_module_cache_parity.mjs:
    // `neither output nor diagnostic`).
    //
    // Measured on a stage2 at d82d821, four identical compiles of
    // fixtures/contract_conformance_test.vibe in one daemon:
    //
    //   1  ok    heap 2,386,547,336    2  ok    heap 3,733,990,304
    //   3  fail  "memory access out of bounds", 65,528 bytes left
    //   4  fail  "unreachable",                 63,456 bytes left
    //
    // The classification below is that arithmetic and nothing else: under one
    // 64 KiB page of a 4 GiB space remains, so no further allocation can be
    // served. A trap with room to spare is deliberately left alone -- calling
    // that "out of memory" would send a reader to recycle the process instead of
    // filing the compiler bug, which is the same silent-wrong the issue is about.
    //
    // A PREDICTIVE check was measured and REJECTED. Growth is not monotonic --
    // compile 1 cost 2.39 GB cold and compile 2 only 1.35 GB warm -- so a floor
    // drawn from any past request (max, min, or last) refuses compile 2, which
    // succeeds. There is no honest way to pre-judge, so the daemon judges after
    // the fact and refuses only what follows a real exhaustion.
    const daemonHeapLimit = parseWasmMemoryLimitBytes(wasmBytes);
    const daemonExhaustionMessage = () => {
      if (daemonHeapLimit === null) {
        return null;
      }
      const heapPtr = readHeapPtr();
      if (daemonHeapLimit - heapPtr >= WASM_PAGE_BYTES) {
        return null;
      }
      return `out of memory: this compiler instance has used its whole ${daemonHeapLimit}-byte wasm address space (heap at ${heapPtr}) and cannot compile again. Compile in a fresh process, or recycle the --daemon process between compiles.`;
    };
    // Same sidecar convention as the crash handler at the bottom of this file:
    // VIBE_CRASH_DIAG_OUT when a verb-protocol launcher named one, else the
    // request's own output argument. Per-request, so a daemon writes the
    // diagnostic beside the artifact the caller asked for.
    const writeDaemonDiag = (args, message) => {
      const sidecar =
        process.env.VIBE_CRASH_DIAG_OUT || (args.length >= 2 && args[1] ? `${args[1]}.diag` : "");
      if (!sidecar) {
        return;
      }
      try {
        fs.writeFileSync(sidecar, `${message}\n`);
      } catch (_) {}
    };

    // Once set, this instance can never compile again: every later request is
    // answered with the same diagnostic instead of being run into the same
    // trap. The process stays alive so a caller blocked on a response gets
    // one -- it says what is wrong rather than dying mid-protocol.
    let exhausted = null;
    const rl = readline.createInterface({
      input: process.stdin,
      crlfDelay: Infinity,
    });
    const originalStdoutWrite = process.stdout.write;
    const writeResponse = originalStdoutWrite.bind(process.stdout);
    for await (const line of rl) {
      const row = line.trim();
      if (row.length === 0) {
        continue;
      }
      let capturedStdout = "";
      let response;
      let requestArgs = [];
      process.stdout.write = (chunk, encoding, callback) => {
        if (typeof encoding === "function") {
          callback = encoding;
        }
        capturedStdout += Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
        if (typeof callback === "function") {
          callback();
        }
        return true;
      };
      try {
        const req = JSON.parse(row);
        const args = Array.isArray(req.args) ? req.args.map(String) : [];
        requestArgs = args;
        if (exhausted !== null) {
          writeDaemonDiag(args, exhausted);
          response = {
            exit_code: 1,
            elapsed_us: 1,
            stdout: capturedStdout,
            error: exhausted,
            memory_exhausted: true,
            heap_ptr: readHeapPtr(),
            heap_limit: daemonHeapLimit,
          };
        } else {
          const { result, isSelfhost, elapsedUs } = runInvokes(args);
          response = {
            exit_code: resultToExitCode(result, isSelfhost),
            elapsed_us: Math.max(1, Math.round(elapsedUs)),
            stdout: capturedStdout,
            heap_ptr: readHeapPtr(),
            heap_limit: daemonHeapLimit,
          };
        }
      } catch (err) {
        if (err instanceof GuestExit) {
          // #3109: the guest ended its own run with a code. That is this
          // request's status, not a daemon failure, and the daemon keeps
          // serving, so the code must not become the daemon's own.
          host.guestExitCode = null;
          process.exitCode = undefined;
          response = {
            exit_code: err.code,
            elapsed_us: 1,
            stdout: capturedStdout,
            heap_ptr: readHeapPtr(),
            heap_limit: daemonHeapLimit,
          };
        } else {
          const outOfMemory = daemonExhaustionMessage();
          if (outOfMemory !== null) {
            exhausted = outOfMemory;
            writeDaemonDiag(requestArgs, outOfMemory);
          }
          response = {
            exit_code: 1,
            elapsed_us: 1,
            stdout: capturedStdout,
            error: outOfMemory === null ? decodeExceptionMessage(err) : outOfMemory,
            ...(outOfMemory === null
              ? {}
              : { memory_exhausted: true, trap: decodeExceptionMessage(err) }),
            heap_ptr: readHeapPtr(),
            heap_limit: daemonHeapLimit,
          };
        }
      } finally {
        process.stdout.write = originalStdoutWrite;
      }
      writeResponse(`${JSON.stringify(response)}\n`);
    }
  };

  if (daemon) {
    if (invokeBatchDir !== null) {
      throw new Error("--daemon cannot be combined with --invoke-batch-dir");
    }
    await runDaemon();
    return;
  }

  if (invokeBatchDir !== null) {
    if (benchCount !== null) {
      throw new Error("--invoke-batch-dir cannot be combined with --bench-count");
    }
    const anyFailed = runInvokeBatch(passthroughArgs, invokeBatchDir);
    emitWasmMemoryStats("run");
    process.exitCode = anyFailed ? 1 : 0;
    return;
  }

  if (benchCount !== null) {
    if (invokes.length !== 1) {
      throw new Error("bench mode requires exactly one --invoke target");
    }
    if (benchSetup !== null) {
      invokeExport(benchSetup);
    }
    for (let i = 0; i < benchWarmup; i += 1) {
      invokeExport(invokes[0]);
    }
    const startNs = process.hrtime.bigint();
    for (let i = 0; i < benchCount; i += 1) {
      invokeExport(invokes[0]);
    }
    const elapsedUs = Number(process.hrtime.bigint() - startNs) / 1000;
    emitWasmMemoryStats("bench");
    console.log(String(elapsedUs));
    return;
  }
  const { result, isSelfhost } = runInvokes(passthroughArgs);
  emitWasmMemoryStats("run");
  // #cov: after running an instrumented build, dump the hit bitmaps.
  if (process.env.VIBE_COV_OUT) {
    if (!dumpCoverage(null)) {
      console.error("[vibe-cov] no vibe_cov section or memory; not a coverage build?");
    }
  }
  const invoke = invokes[invokes.length - 1];
  emitResult(invoke, result, isSelfhost);
  if (invoke === "cli_main" || process.env.VIBE_RUNNER_EXIT_WITH_RESULT === "1") {
    process.exitCode = resultToExitCode(result, isSelfhost);
  }
}

module.exports = {
  buildFsMetadataHashParts,
  capabilityWithheldStub,
  configurePolicyStatToken,
  configurePolicyRawFs,
  parseWithheldCapabilities,
  authorizePolicyRawImport,
  authorizePolicyRawPath,
  contentStatDigest,
  contentStatToken,
  parseArgs,
  policyStatAttestation,
  projectContentStatDigest,
  rejectPolicyWasiModuleImports,
};

if (require.main === module) {
// #3109: a guest-requested exit code is final (see `GuestExit`).
process.on("exit", () => {
  if (host.guestExitCode !== null) {
    process.exitCode = host.guestExitCode;
  }
});
main().catch((err) => {
  if (err instanceof GuestExit) {
    exitAfterDrain(err.code);
    return;
  }
  // #946(4): a pathologically deep expression (e.g. thousands of chained
  // `+`) recurses the checker (itself compiled to wasm) past the native call
  // stack. That blows up the whole wasm instance -- nothing inside the
  // compiled program's own `handle {...} with Exception {...}` can intercept a
  // host-level stack overflow, so it used to surface as a raw uncaught-
  // exception crash dump, which the `vibe check`/`vibe diagnostics` shell
  // wrappers (`>/dev/null 2>&1 || true`) silently swallowed into "clean".
  // Intercept it here instead and write the same `.diag` sidecar the
  // adapter's own error paths use (cli_adapter.vibe's
  // emit_compile_diag), so those commands can report a real (if unlocated)
  // diagnostic.
  //
  // #1007 review (Codex P2): read_arg_or_env (cli_adapter.vibe)
  // prefers the POSITIONAL arg (Env::args_get) over the env var, only
  // falling back to VIBE_OUTPUT when the arg is absent -- `runtime/vibe`
  // never unsets an inherited VIBE_OUTPUT before invoking the runner, so
  // preferring the env var here (as the first cut did) could write the
  // sidecar beside a stale inherited path while the compiled program itself
  // (and the shell script waiting on `$out.diag`) used the real positional
  // one, silently losing the diagnostic all over again. Match
  // read_arg_or_env's precedence: positional arg (host.passthroughArgsGlobal[1])
  // first.
  if (err instanceof RangeError && /call stack/i.test(err.message || "") && host.currentInvokeGlobal && host.currentInvokeGlobal !== "cli_main") {
    // #2988: the overflow happened while RUNNING the user's program, not while
    // compiling it. The compiler-side message below ("one expression nests too
    // deeply ... split the file") sent the reader to a file that was fine.
    console.error(`[vibe] stack overflow while running \`${host.currentInvokeGlobal}\`: the call depth exceeded the host stack -- usually unbounded or very deep recursion. Make the recursion iterative (a loop, or a tail call with an accumulator), or raise the host stack with VIBE_NODE_STACK_SIZE=<KB>.`);
    try {
      annotateTrapWithLinemap(err, host.covWasmBytesGlobal);
    } catch (_) {}
    exitAfterDrain(1);
    return;
  }
  if (err instanceof RangeError && /call stack/i.test(err.message || "")) {
    // #2858: under the verb protocol the positional args are the verb's own
    // words, so the launcher names the crash sidecar explicitly
    // (VIBE_CRASH_DIAG_OUT); the positional / VIBE_OUTPUT `.diag` convention
    // stays for the adapter protocol.
    const crashDiag = process.env.VIBE_CRASH_DIAG_OUT || "";
    const outputPath =
      (host.passthroughArgsGlobal && host.passthroughArgsGlobal[1]) ||
      process.env.VIBE_OUTPUT;
    const sidecar = crashDiag || (outputPath ? `${outputPath}.diag` : "");
    if (sidecar) {
      try {
        // #2134: this said only "expression too deeply nested", which sends
        // the reader to look at their expressions. The overflow is just as
        // often the TOP-LEVEL DECLARATION COUNT -- the checker recurses per
        // statement, and `x + 0` bodies overflow at ~4000 declarations on
        // node's default stack. Name both levers, and the knob.
        fs.writeFileSync(sidecar, "stack overflow while type-checking: either one expression nests too deeply, or the file has too many top-level declarations (the checker recurses once per statement). Split the file, or raise the host stack with VIBE_NODE_STACK_SIZE=<KB>.\n");
      } catch (_) {}
    }
    console.error("[vibe] stack overflow while type-checking: one expression nests too deeply, or the file has too many top-level declarations. Split the file, or raise the host stack with VIBE_NODE_STACK_SIZE=<KB>.");
    exitAfterDrain(1);
    return;
  }
  // #cov: even a failed run (parse/type error, trap) exercised many branches
  // before unwinding — capture its coverage from the still-live instance memory.
  try {
    dumpCoverage("aborted");
  } catch (_) {}
  // Try to decode WASM exception payload (tagged string)
  if (err instanceof WebAssembly.Exception) {
    try {
      // The exception tag exports a single i64 payload
      const tag = host.instanceRefGlobal?.exports?.__error_tag;
      if (tag) {
        const payload = err.getArg(tag, 0);
        const msg = tryDecodeExceptionString(host.instanceRefGlobal, payload);
        if (msg !== null) {
          console.error(`Error string: ${msg}`);
          exitAfterDrain(1);
          return;
        }
      }
    } catch (_) {}
    // Fallback: try all exported tags
    try {
      if (host.instanceRefGlobal) {
        for (const [name, exp] of Object.entries(host.instanceRefGlobal.exports)) {
          if (exp instanceof WebAssembly.Tag) {
            try {
              const payload = err.getArg(exp, 0);
              const msg = tryDecodeExceptionString(host.instanceRefGlobal, payload);
              if (msg !== null) {
                console.error(`Error string (tag=${name}): ${msg}`);
                exitAfterDrain(1);
                return;
              }
              // Try to decode as tagged int
              if (typeof payload === "bigint" && (payload & TAG_MASK) === TAG_INT) {
                const intVal = Number(payload >> 2n);
                console.error(`Exception payload (tag=${name}): tagged int ${intVal} (raw=${payload})`);
              } else {
                console.error(`Exception payload (tag=${name}): ${payload}`);
              }
              // Also try to brute-force decode nearby memory as string
              if (typeof payload === "bigint" && host.instanceRefGlobal?.exports?.memory) {
                const mem = new Uint8Array(host.instanceRefGlobal.exports.memory.buffer);
                for (const tryPtr of [Number(payload), Number(payload & ~TAG_MASK), Number(payload >> 2n)]) {
                  if (tryPtr > 0 && tryPtr + 8 < mem.length) {
                    const ty = readU32LE(mem, tryPtr);
                    if (ty === OBJ_STRING) {
                      const len = readU32LE(mem, tryPtr + 4);
                      if (len > 0 && len < 10000 && tryPtr + 8 + len <= mem.length) {
                        const str = new TextDecoder().decode(mem.subarray(tryPtr + 8, tryPtr + 8 + len));
                        console.error(`  -> string at ptr=${tryPtr}: "${str}"`);
                      }
                    }
                  }
                }
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }
  // usage() is only relevant for argument-parsing errors. Runtime errors
  // (wasm traps, exceptions, etc.) drop straight to the stack trace so the
  // failing test output points at the real cause.
  if (host.instanceRefGlobal === null) {
    usage();
  }
  console.error(err && err.stack ? err.stack : String(err));
  // #2199: production trap provenance. Same compact vibe.linemap the
  // wasmtime runner already reads. Missing mapping => no extra location.
  try {
    annotateTrapWithLinemap(err, host.covWasmBytesGlobal);
  } catch (_) {}
  exitAfterDrain(1);
  return;
});
}

module.exports.publishImmutableTextSync = publishImmutableTextSync;
