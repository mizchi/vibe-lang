///|
/// One frame currently on the live call stack. `start` records the
/// monotonic timestamp at enter; `children_us` accumulates the elapsed
/// time of fully-popped child frames so we can compute self-time on
/// leave.
priv struct ProfileFrame {
  name : String
  start : @bench.Timestamp
  mut children_us : Int
}

///|
/// Per-name aggregate exposed via the TSV report. `children_names`
/// preserves child ordering for human inspection but does not include
/// per-callsite breakdown — for that use `profiler_report_folded` or
/// `profiler_report_pprof`, which key by full stack.
pub struct ProfileEntry {
  total_us : Int
  self_us : Int
  call_count : Int
  children_names : Array[String]
} derive(Debug, Eq)

///|
/// Per-stack sample for pprof / folded-stack output. `frames` is the
/// stack root-first (i.e. `frames[0]` is the outermost enter, last is
/// the leaf). `self_us` is the cumulative self-time of the leaf
/// observed at that stack — same value that flame-graphs would render
/// as a stack column.
pub struct StackSample {
  frames : Array[String]
  self_us : Int
}

///|
priv struct ProfilerState {
  stack : Array[ProfileFrame]
  entries : Map[String, ProfileEntry]
  order : Array[String]
  // Full-stack samples keyed by frames joined with `\x00` (the
  // separator is intentionally a byte that cannot appear in vibe
  // identifiers / our enter names, so split-back is unambiguous).
  stack_self_us : Map[String, Int]
  stack_order : Array[String]
  // Wall-clock window for pprof's time_nanos / duration_nanos fields.
  // Both expressed as microseconds since `profiler_set_enabled(true)`
  // or `profiler_reset()` — pprof's spec wants nanoseconds, the
  // encoder multiplies on output.
  mut session_start : @bench.Timestamp
  mut session_elapsed_us : Int
}

///|
let profiler_enabled_ref : Ref[Bool] = @ref.new(false)

///|
let profiler_state : Ref[ProfilerState] = @ref.new({
  stack: [],
  entries: {},
  order: [],
  stack_self_us: {},
  stack_order: [],
  session_start: @bench.monotonic_clock_start(),
  session_elapsed_us: 0,
})

///|
const STACK_SEP : Char = '\u0001'

///|
pub fn profiler_set_enabled(enabled : Bool) -> Unit {
  profiler_enabled_ref.val = enabled
  if enabled {
    profiler_state.val.session_start = @bench.monotonic_clock_start()
    profiler_state.val.session_elapsed_us = 0
  }
}

///|
pub fn profiler_reset() -> Unit {
  profiler_state.val = {
    stack: [],
    entries: {},
    order: [],
    stack_self_us: {},
    stack_order: [],
    session_start: @bench.monotonic_clock_start(),
    session_elapsed_us: 0,
  }
}

///|
pub fn profiler_enter(name : String) -> Unit {
  if !profiler_enabled_ref.val {
    return
  }
  let state = profiler_state.val
  let start = @bench.monotonic_clock_start()
  state.stack.push({ name, start, children_us: 0 })
}

///|
/// Build the `\x00`-joined stack key for the current live stack
/// (including the frame currently being popped, passed in by name).
/// Used internally for both the pprof sample bucket and the folded
/// output. The separator (NUL) cannot appear in our enter names.
fn current_stack_key(state : ProfilerState, leaf_name : String) -> String {
  let buf = StringBuilder::new()
  let mut first = true
  for frame in state.stack {
    if !first {
      buf.write_char(STACK_SEP)
    }
    buf.write_string(frame.name)
    first = false
  }
  if !first {
    buf.write_char(STACK_SEP)
  }
  buf.write_string(leaf_name)
  buf.to_string()
}

///|
pub fn profiler_leave() -> Unit {
  if !profiler_enabled_ref.val {
    return
  }
  let state = profiler_state.val
  if state.stack.is_empty() {
    return
  }
  let frame = state.stack.pop().unwrap()
  let elapsed_raw = @bench.monotonic_clock_end(frame.start)
  let elapsed_us = if elapsed_raw.to_int() <= 0 {
    1
  } else {
    elapsed_raw.to_int()
  }
  let self_us = if elapsed_us > frame.children_us {
    elapsed_us - frame.children_us
  } else {
    0
  }
  // Push this frame's full elapsed time up to the parent so the
  // parent's self_us subtracts it later.
  if !state.stack.is_empty() {
    let parent = state.stack[state.stack.length() - 1]
    parent.children_us = parent.children_us + elapsed_us
  }
  // Record stack sample — for pprof / folded output we want the full
  // call chain at the moment this frame ends, with the *self* time
  // attributed to this leaf. Same convention as Linux perf / pprof:
  // each sample's value is exclusive (self), aggregation across stacks
  // gives inclusive (total) per function.
  let stack_key = current_stack_key(state, frame.name)
  match state.stack_self_us.get(stack_key) {
    Some(prev) => state.stack_self_us[stack_key] = prev + self_us
    None => {
      state.stack_self_us[stack_key] = self_us
      state.stack_order.push(stack_key)
    }
  }
  match state.entries.get(frame.name) {
    Some(entry) =>
      state.entries[frame.name] = {
        total_us: entry.total_us + elapsed_us,
        self_us: entry.self_us + self_us,
        call_count: entry.call_count + 1,
        children_names: entry.children_names,
      }
    None => {
      state.entries[frame.name] = {
        total_us: elapsed_us,
        self_us,
        call_count: 1,
        children_names: [],
      }
      state.order.push(frame.name)
    }
  }
  if !state.stack.is_empty() {
    let parent_name = state.stack[state.stack.length() - 1].name
    match state.entries.get(parent_name) {
      Some(parent_entry) => {
        let mut found = false
        for child in parent_entry.children_names {
          if child == frame.name {
            found = true
            break
          }
        }
        if !found {
          parent_entry.children_names.push(frame.name)
        }
      }
      None => ()
    }
  }
  // Bump session-elapsed window for pprof time_nanos/duration_nanos.
  state.session_elapsed_us = @bench
    .monotonic_clock_end(state.session_start)
    .to_int()
}

///|
pub fn profiler_report_tsv() -> String {
  let state = profiler_state.val
  let buf = StringBuilder::new()
  buf.write_string("name\ttotal_us\tself_us\tcall_count\tchildren\n")
  for name in state.order {
    match state.entries.get(name) {
      Some(entry) => {
        buf.write_string(name)
        buf.write_string("\t")
        buf.write_string(entry.total_us.to_string())
        buf.write_string("\t")
        buf.write_string(entry.self_us.to_string())
        buf.write_string("\t")
        buf.write_string(entry.call_count.to_string())
        buf.write_string("\t")
        let mut first = true
        for child in entry.children_names {
          if !first {
            buf.write_string(",")
          }
          buf.write_string(child)
          first = false
        }
        buf.write_string("\n")
      }
      None => ()
    }
  }
  buf.to_string()
}

///|
/// Brendan Gregg's "folded stack" format: one line per unique stack,
/// frames joined with `;`, followed by a space and the self_us count.
/// Pipe through `flamegraph.pl` to render a flame graph SVG.
pub fn profiler_report_folded() -> String {
  let state = profiler_state.val
  let buf = StringBuilder::new()
  for key in state.stack_order {
    let self_us = state.stack_self_us.get(key).unwrap()
    if self_us <= 0 {
      continue
    }
    let mut first = true
    for ch in key {
      if ch == STACK_SEP {
        buf.write_char(';')
      } else {
        // flamegraph.pl uses `;` as separator and `\n` as line break —
        // both are forbidden in our enter names, so a raw copy is safe.
        buf.write_char(ch)
      }
      first = false
    }
    let _ = first
    buf.write_string(" ")
    buf.write_string(self_us.to_string())
    buf.write_string("\n")
  }
  buf.to_string()
}

///|
/// Iterate live stack samples for the pprof encoder. Returns
/// (frames-root-first, self_us) tuples skipping zero-time stacks.
pub fn profiler_stack_samples() -> Array[StackSample] {
  let state = profiler_state.val
  let out : Array[StackSample] = []
  for key in state.stack_order {
    let self_us = state.stack_self_us.get(key).unwrap()
    if self_us <= 0 {
      continue
    }
    let frames : Array[String] = []
    let buf = StringBuilder::new()
    for ch in key {
      if ch == STACK_SEP {
        frames.push(buf.to_string())
        buf.reset()
      } else {
        buf.write_char(ch)
      }
    }
    let tail = buf.to_string()
    if tail.length() > 0 || frames.length() == 0 {
      frames.push(tail)
    }
    out.push({ frames, self_us })
  }
  out
}

///|
/// Total wall-clock window covered by the profile, in microseconds.
/// 0 if profiling hasn't been started. The pprof encoder converts to
/// nanoseconds before emitting.
pub fn profiler_duration_us() -> Int {
  profiler_state.val.session_elapsed_us
}
