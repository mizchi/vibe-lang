///|
priv struct ProfileFrame {
  name : String
  start : @bench.Timestamp
  mut children_us : Int
}

///|
pub struct ProfileEntry {
  total_us : Int
  self_us : Int
  call_count : Int
  children_names : Array[String]
} derive(Show, Eq)

///|
priv struct ProfilerState {
  stack : Array[ProfileFrame]
  entries : Map[String, ProfileEntry]
  order : Array[String]
}

///|
let profiler_enabled_ref : Ref[Bool] = @ref.new(false)

///|
let profiler_state : Ref[ProfilerState] = @ref.new({
  stack: [],
  entries: {},
  order: [],
})

///|
pub fn profiler_set_enabled(enabled : Bool) -> Unit {
  profiler_enabled_ref.val = enabled
}

///|
pub fn profiler_reset() -> Unit {
  profiler_state.val = { stack: [], entries: {}, order: [] }
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
  // Update parent's children_us
  if !state.stack.is_empty() {
    let parent = state.stack[state.stack.length() - 1]
    parent.children_us = parent.children_us + elapsed_us
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
  // Track children relationship
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
