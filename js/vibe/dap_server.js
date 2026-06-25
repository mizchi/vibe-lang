#!/usr/bin/env node
// Minimal stdio Debug Adapter Protocol (DAP) server for vibe (docs/release-
// roadmap.md テーマ3, 3-D). Bridges a DAP client (VS Code) to the existing
// function-granularity debugger exposed by the launcher:
//
//     vibe run --break <fn>[,<fn>...] <file.vibe>
//
// The runner pauses at each named function's entry and prints to stderr:
//     breakpoint hit: helper        (or "stopped at: helper" for a step pause)
//       args: [20]
//       at helper (prog.vibe:1)
//       at main (prog.vibe:2)
// then reads ONE stdin command at the pause:
//     s/step (step into), n/next (step over), o/finish, c/continue (or empty),
//     q/quit.
//
// This adapter:
//   * maps requested breakpoint LINES to the ENCLOSING top-level function NAMES
//     (vibe breakpoints are by function name, not line),
//   * spawns the runner on configurationDone with stdin piped + stderr parsed,
//   * translates each pause to a DAP `stopped` event and exposes the recorded
//     call stack (stackTrace) + decoded args (variables),
//   * drives the runner's stdin from continue/next/stepIn/stepOut.
//
// Plain Node, no external deps; the DAP wire format (Content-Length framing) is
// implemented here, mirroring js/vibe/lsp_server.js. The launcher path comes
// from the launch arg `vibeBin`, then VIBE_BIN, then `vibe` on PATH.

"use strict";

// ===========================================================================
// PURE translation logic (exported for unit tests; no I/O, no process state).
// ===========================================================================

// Enclosing top-level function spans of a vibe source.
//
// vibe top-level functions are let-bound to a lambda:
//     export? let <name> = (... ) -> <ret> { ... }
// possibly with a leading type-param list `[T: Bound]` before the `(`. The body
// `{ ... }` may span multiple lines; we find the opening brace of the lambda
// body and brace-match (ignoring braces inside string literals) to the close.
//
// Returns [{name, startLine, endLine}] with 1-based inclusive line numbers, in
// source order. A function with no detectable body brace on/after its decl is
// treated as a single-line span.
function enclosingFunctions(sourceText) {
  const text = String(sourceText == null ? "" : sourceText);
  const lines = text.split(/\r?\n/);
  // Precompute, for the brace scanner, a flat char offset of each line start.
  const lineStart = [];
  {
    let off = 0;
    for (let i = 0; i < lines.length; i++) {
      lineStart.push(off);
      off += lines[i].length + 1; // +1 for the (split-removed) newline
    }
  }
  const offsetToLine = (off) => {
    // lineStart is ascending; linear scan is fine for editor-sized files.
    let li = 0;
    for (let i = 0; i < lineStart.length; i++) {
      if (lineStart[i] <= off) li = i;
      else break;
    }
    return li; // 0-based
  };

  // Match `let <name> = (` allowing an optional `export ` and an optional
  // type-param list `[...]` between the name and the `(`.
  const declRe =
    /^\s*(?:export\s+)?let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:\[[^\]]*\]\s*)?\(/;

  const funcs = [];
  for (let i = 0; i < lines.length; i++) {
    const m = declRe.exec(lines[i]);
    if (!m) continue;
    const name = m[1];
    const startLine = i + 1; // 1-based
    // From the decl, scan forward for the FIRST `{` that opens the lambda body,
    // skipping over any `{` inside string literals. The lambda's `-> Ret {`
    // brace is the first top-level `{` after the decl on this line or later.
    const parenIdx = lines[i].indexOf("(");
    const scanFrom = lineStart[i] + (parenIdx >= 0 ? parenIdx : 0);
    const open = findBodyOpenBrace(text, scanFrom);
    if (open < 0) {
      funcs.push({ name, startLine, endLine: startLine });
      continue;
    }
    const close = matchBrace(text, open);
    const endLine = (close < 0 ? offsetToLine(text.length) : offsetToLine(close)) + 1;
    funcs.push({ name, startLine, endLine });
    // Skip ahead so a nested `let` inside this body is not mistaken for a new
    // top-level function (best-effort: advance i past the body's last line).
    if (endLine - 1 > i) i = endLine - 1;
  }
  return funcs;
}

// Find the offset of the first `{` at/after `from` that is not inside a string
// literal. Returns the offset, or -1 if none.
function findBodyOpenBrace(text, from) {
  let inStr = false;
  let quote = "";
  for (let p = Math.max(0, from); p < text.length; p++) {
    const c = text[p];
    if (inStr) {
      if (c === "\\") {
        p++;
        continue;
      }
      if (c === quote) inStr = false;
      continue;
    }
    if (c === '"' || c === "'") {
      inStr = true;
      quote = c;
      continue;
    }
    if (c === "{") return p;
  }
  return -1;
}

// Given the offset of an opening `{`, return the offset of its matching `}`
// (string-literal aware), or -1 if unbalanced.
function matchBrace(text, openOff) {
  let depth = 0;
  let inStr = false;
  let quote = "";
  for (let p = openOff; p < text.length; p++) {
    const c = text[p];
    if (inStr) {
      if (c === "\\") {
        p++;
        continue;
      }
      if (c === quote) inStr = false;
      continue;
    }
    if (c === '"' || c === "'") {
      inStr = true;
      quote = c;
      continue;
    }
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return p;
    }
  }
  return -1;
}

// Map requested breakpoint LINES (1-based) to the set of enclosing top-level
// function NAMES. A line inside a function's [startLine, endLine] span resolves
// to that function. Returns a de-duplicated array in first-seen order.
function breakpointFunctionsForLines(sourceText, lines) {
  const funcs = enclosingFunctions(sourceText);
  const seen = new Set();
  const out = [];
  for (const ln of lines || []) {
    const n = Number(ln);
    if (!Number.isFinite(n)) continue;
    // Top-level only; pick the first span containing n.
    for (const f of funcs) {
      if (n >= f.startLine && n <= f.endLine) {
        if (!seen.has(f.name)) {
          seen.add(f.name);
          out.push(f.name);
        }
        break;
      }
    }
  }
  return out;
}

// Parse a runner stack frame line: "  at helper (prog.vibe:1)".
// Returns {name, file, line} or null. The `(file:line)` suffix is optional
// (the funcmap annotation may be absent for some frames).
function parseFrame(line) {
  if (typeof line !== "string") return null;
  // With location: "  at <name> (<file>:<line>)"
  let m = /^\s*at\s+([^\s(]+)\s*\(([^)]*?):(\d+)\)\s*$/.exec(line);
  if (m) {
    return { name: m[1], file: m[2], line: parseInt(m[3], 10) };
  }
  // Without location: "  at <name>"
  m = /^\s*at\s+(\S+)\s*$/.exec(line);
  if (m) {
    return { name: m[1], file: null, line: null };
  }
  return null;
}

// Parse a runner args line: "  args: [20, 1]". Returns an array of values
// (numbers when numeric, else trimmed string tokens), or null when the line is
// not an args line. An empty list "[]" yields [].
function parseArgs(line) {
  if (typeof line !== "string") return null;
  const m = /^\s*args:\s*\[(.*)\]\s*$/.exec(line);
  if (!m) return null;
  const inner = m[1].trim();
  if (inner === "") return [];
  return splitTopLevel(inner).map((tok) => {
    const t = tok.trim();
    if (/^-?\d+$/.test(t)) return parseInt(t, 10);
    if (/^-?\d*\.\d+$/.test(t)) return parseFloat(t);
    return t;
  });
}

// Split on top-level commas (so nested brackets/parens don't over-split).
function splitTopLevel(s) {
  const parts = [];
  let depth = 0;
  let inStr = false;
  let quote = "";
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (inStr) {
      if (c === "\\") {
        i++;
        continue;
      }
      if (c === quote) inStr = false;
      continue;
    }
    if (c === '"' || c === "'") {
      inStr = true;
      quote = c;
      continue;
    }
    if (c === "[" || c === "(" || c === "{") depth++;
    else if (c === "]" || c === ")" || c === "}") depth--;
    else if (c === "," && depth === 0) {
      parts.push(s.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(s.slice(start));
  return parts;
}

// Classify a pause-announcing stderr line.
//   "breakpoint hit: <fn>" -> {reason: "breakpoint", fn}
//   "stopped at: <fn>"     -> {reason: "step", fn}
// else null.
function parsePauseLine(line) {
  if (typeof line !== "string") return null;
  let m = /^breakpoint hit:\s*(\S+)\s*$/.exec(line);
  if (m) return { reason: "breakpoint", fn: m[1] };
  m = /^stopped at:\s*(\S+)\s*$/.exec(line);
  if (m) return { reason: "step", fn: m[1] };
  return null;
}

// ===========================================================================
// DAP server (only runs when invoked as a program, not when require()d).
// ===========================================================================

function main() {
  const { spawn } = require("child_process");

  const VIBE_ENV_BIN = process.env.VIBE_BIN || "vibe";

  // ---- DAP wire framing (Content-Length, like LSP) ----------------------
  let buffer = Buffer.alloc(0);
  let seq = 1;

  function send(msg) {
    msg.seq = seq++;
    const json = JSON.stringify(msg);
    const data = Buffer.from(json, "utf8");
    process.stdout.write(`Content-Length: ${data.length}\r\n\r\n`);
    process.stdout.write(data);
  }

  function respond(request, body, success) {
    send({
      type: "response",
      request_seq: request.seq,
      success: success === undefined ? true : success,
      command: request.command,
      body: body || {},
    });
  }

  function event(eventName, body) {
    send({ type: "event", event: eventName, body: body || {} });
  }

  // ---- session state -----------------------------------------------------
  const state = {
    program: null, // resolved program path
    vibeBin: VIBE_ENV_BIN, // launcher path
    sourceText: "", // program source (for line->function mapping)
    breakFns: [], // function names to break on
    proc: null, // spawned runner ChildProcess
    // The most recent recorded pause:
    frames: [], // [{name, file, line}] (top frame first)
    args: [], // decoded argument values at the current pause
    terminated: false,
  };

  function readProgramSource() {
    const fs = require("fs");
    try {
      state.sourceText = fs.readFileSync(state.program, "utf8");
    } catch {
      state.sourceText = "";
    }
  }

  // ---- runner lifecycle --------------------------------------------------
  function spawnRunner() {
    const args = ["run"];
    if (state.breakFns.length) {
      args.push("--break", state.breakFns.join(","));
    }
    args.push(state.program);

    let proc;
    try {
      proc = spawn(state.vibeBin, args, {
        stdio: ["pipe", "pipe", "pipe"],
        // Do NOT set VIBE_BREAK_AUTO; we drive stdin ourselves.
      });
    } catch (err) {
      event("output", {
        category: "stderr",
        output: `failed to spawn ${state.vibeBin}: ${err.message}\n`,
      });
      event("terminated", {});
      event("exited", { exitCode: 1 });
      return;
    }
    state.proc = proc;

    event("process", {
      name: state.program,
      systemProcessId: proc.pid,
      isLocalProcess: true,
      startMethod: "launch",
    });

    // ---- stderr: pause/frame/args parsing + passthrough ----
    let errBuf = "";
    // Pending pause being assembled across the frame/args lines that follow a
    // "breakpoint hit"/"stopped at" header.
    let pending = null;

    function flushPending() {
      if (!pending) return;
      state.frames = pending.frames;
      state.args = pending.args;
      const reason = pending.reason;
      pending = null;
      event("stopped", {
        reason,
        threadId: 1,
        allThreadsStopped: true,
      });
    }

    function handleErrLine(line) {
      const pause = parsePauseLine(line);
      if (pause) {
        // A new pause header: flush any prior (defensive) and start collecting.
        flushPending();
        pending = { reason: pause.reason, fn: pause.fn, frames: [], args: [] };
        return;
      }
      if (pending) {
        const frame = parseFrame(line);
        if (frame) {
          pending.frames.push(frame);
          return;
        }
        const a = parseArgs(line);
        if (a) {
          pending.args = a;
          return;
        }
        // A non-frame, non-args line ends the pause block; emit the stopped
        // event now, then forward this line as ordinary output.
        flushPending();
      }
      // Ordinary stderr output (trace lines, program stderr, runner notices).
      if (line.length) {
        event("output", { category: "stderr", output: line + "\n" });
      }
    }

    proc.stderr.on("data", (chunk) => {
      errBuf += chunk.toString("utf8");
      let nl;
      while ((nl = errBuf.indexOf("\n")) >= 0) {
        const line = errBuf.slice(0, nl).replace(/\r$/, "");
        errBuf = errBuf.slice(nl + 1);
        try {
          handleErrLine(line);
        } catch {
          // Never crash on unexpected output.
        }
      }
    });

    // ---- stdout: program result passthrough ----
    proc.stdout.on("data", (chunk) => {
      event("output", { category: "stdout", output: chunk.toString("utf8") });
    });

    proc.on("error", (err) => {
      event("output", {
        category: "stderr",
        output: `runner error: ${err.message}\n`,
      });
    });

    proc.on("exit", (code, signal) => {
      // Flush any trailing buffered stderr line.
      if (errBuf.length) {
        try {
          handleErrLine(errBuf.replace(/\r$/, ""));
        } catch {}
        errBuf = "";
      }
      flushPending();
      if (state.terminated) return;
      state.terminated = true;
      const exitCode = code == null ? (signal ? 1 : 0) : code;
      event("output", { category: "console", output: `\nprogram exited (code ${exitCode})\n` });
      event("terminated", {});
      event("exited", { exitCode });
    });
  }

  // Write a step command to the runner stdin (a single char + newline).
  function drive(cmd) {
    if (state.proc && state.proc.stdin && state.proc.stdin.writable) {
      try {
        state.proc.stdin.write(cmd + "\n");
      } catch {}
    }
  }

  function killRunner() {
    if (state.proc && !state.proc.killed) {
      try {
        state.proc.kill();
      } catch {}
    }
  }

  // ---- request dispatch --------------------------------------------------
  function handle(msg) {
    if (msg.type !== "request") return;
    const cmd = msg.command;
    const args = msg.arguments || {};
    switch (cmd) {
      case "initialize":
        respond(msg, {
          supportsConfigurationDoneRequest: true,
          supportsTerminateRequest: true,
        });
        // Tell the client we are ready to accept breakpoint configuration.
        event("initialized", {});
        break;

      case "launch":
        state.program = args.program || null;
        if (args.vibeBin) state.vibeBin = args.vibeBin;
        if (state.program) readProgramSource();
        respond(msg, {});
        break;

      case "attach":
        // Not supported; reply success so the client doesn't hang.
        respond(msg, {});
        break;

      case "setBreakpoints": {
        const reqBps = (args.breakpoints || []).map((b) => b.line);
        const fns = breakpointFunctionsForLines(state.sourceText, reqBps);
        // Accumulate (union) across multiple setBreakpoints calls for the file.
        for (const f of fns) if (!state.breakFns.includes(f)) state.breakFns.push(f);
        // Verify each requested breakpoint, resolving it to its function's start
        // line when it falls inside a known function span.
        const funcs = enclosingFunctions(state.sourceText);
        const verified = (args.breakpoints || []).map((b) => {
          const span = funcs.find((f) => b.line >= f.startLine && b.line <= f.endLine);
          if (span) {
            return { verified: true, line: span.startLine };
          }
          return { verified: false, line: b.line, message: "no enclosing function" };
        });
        respond(msg, { breakpoints: verified });
        break;
      }

      case "setExceptionBreakpoints":
        respond(msg, {});
        break;

      case "configurationDone":
        respond(msg, {});
        if (!state.program) {
          event("output", { category: "stderr", output: "no program to launch\n" });
          event("terminated", {});
          event("exited", { exitCode: 1 });
          break;
        }
        spawnRunner();
        break;

      case "threads":
        respond(msg, { threads: [{ id: 1, name: "main" }] });
        break;

      case "stackTrace": {
        const stackFrames = state.frames.map((f, i) => {
          const frame = {
            id: i + 1,
            name: f.name,
            line: f.line || 0,
            column: 1,
          };
          if (f.file) {
            frame.source = { name: f.file, path: resolveSourcePath(f.file) };
          } else if (state.program) {
            frame.source = { name: require("path").basename(state.program), path: state.program };
          }
          return frame;
        });
        respond(msg, { stackFrames, totalFrames: stackFrames.length });
        break;
      }

      case "scopes":
        respond(msg, {
          scopes: [
            {
              name: "Locals",
              variablesReference: 1,
              expensive: false,
            },
          ],
        });
        break;

      case "variables": {
        const variables = state.args.map((v, i) => ({
          name: `arg${i}`,
          value: String(v),
          variablesReference: 0,
        }));
        respond(msg, { variables });
        break;
      }

      case "continue":
        drive("c");
        respond(msg, { allThreadsContinued: true });
        break;

      case "next":
        drive("n");
        respond(msg, {});
        break;

      case "stepIn":
        drive("s");
        respond(msg, {});
        break;

      case "stepOut":
        drive("o");
        respond(msg, {});
        break;

      case "pause":
        // The runner has no async-pause; acknowledge without action.
        respond(msg, {});
        break;

      case "terminate":
        drive("q");
        respond(msg, {});
        break;

      case "disconnect":
        respond(msg, {});
        killRunner();
        // Give the kill a tick to land, then exit.
        setTimeout(() => process.exit(0), 10);
        break;

      default:
        // Unknown request: empty success response so the client doesn't hang.
        respond(msg, {});
    }
  }

  // Resolve a frame's source file (basename emitted by the funcmap) to an
  // absolute path next to the program when possible.
  function resolveSourcePath(file) {
    const path = require("path");
    if (path.isAbsolute(file)) return file;
    if (state.program) {
      return path.join(path.dirname(state.program), path.basename(file));
    }
    return file;
  }

  // ---- stdin reader (DAP framing) ----------------------------------------
  process.stdin.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      const headerEnd = buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const header = buffer.slice(0, headerEnd).toString("ascii");
      const m = /Content-Length:\s*(\d+)/i.exec(header);
      if (!m) {
        buffer = buffer.slice(headerEnd + 4);
        continue;
      }
      const len = parseInt(m[1], 10);
      const start = headerEnd + 4;
      if (buffer.length < start + len) return;
      const body = buffer.slice(start, start + len).toString("utf8");
      buffer = buffer.slice(start + len);
      let parsed;
      try {
        parsed = JSON.parse(body);
      } catch {
        continue;
      }
      try {
        handle(parsed);
      } catch {
        // Never crash on a malformed/unexpected request.
      }
    }
  });

  process.stdin.on("end", () => {
    killRunner();
    process.exit(0);
  });
}

// ===========================================================================
// Exports / entrypoint.
// ===========================================================================

module.exports = {
  enclosingFunctions,
  breakpointFunctionsForLines,
  parseFrame,
  parseArgs,
  parsePauseLine,
  matchBrace,
  findBodyOpenBrace,
  splitTopLevel,
};

if (require.main === module) {
  main();
}
