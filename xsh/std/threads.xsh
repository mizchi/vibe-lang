// Experimental threads helpers.
// `probe_wat` / `runtime_hints` runtime execution requires `--unstable-threads`.

// High-level contract layer (pure, test-safe).
// Keep this layer free from unstable runtime calls so `xsh test` can run
// without `--unstable-threads`.

export let task_spec = (name: String, entry_symbol: String) {
  record {
    kind: "task",
    name: name,
    entry_symbol: entry_symbol
  }
}

export let channel_spec = (name: String, capacity: Int) {
  let normalized = if capacity < 0 { 0 } else { capacity }
  record {
    kind: "channel",
    name: name,
    capacity: normalized
  }
}

export let actor_spec = (name: String, mailbox: String, handler_symbol: String) {
  record {
    kind: "actor",
    name: name,
    mailbox: mailbox,
    handler_symbol: handler_symbol
  }
}

export let probe_wat = () -> String {
  threads_probe_wat()
}

export let runtime_hints = () {
  threads_runtime_hints()
}

export let channel_new = (capacity: Int) -> Int {
  threads_channel_new(capacity)
}

export let spawn = (name: String, mailbox: Int) -> Int {
  threads_spawn(name, mailbox)
}

export let send = (channel: Int, message: String) -> Bool {
  threads_send(channel, message)
}

export let recv = (channel: Int) -> String {
  threads_recv(channel)
}

export let wait = (task: Int) -> Int {
  threads_wait(task)
}

export let recommended_wasm_flags = () -> Array[String] {
  ["threads=y", "shared-memory=y"]
}

export let recommended_wasi_flags = () -> Array[String] {
  ["threads=y"]
}

export let recommended_wasm_env = () -> String {
  "threads=y shared-memory=y"
}

export let recommended_wasi_env = () -> String {
  "threads=y"
}

export let deployment_plan = [Task, Channel, Actor](
  task: Task,
  channel: Channel,
  actor: Actor
) {
  record {
    task: task,
    channel: channel,
    actor: actor,
    wasm_flags: recommended_wasm_flags(),
    wasi_flags: recommended_wasi_flags(),
    wasm_env: recommended_wasm_env(),
    wasi_env: recommended_wasi_env(),
    unstable_flag: "--unstable-threads"
  }
}
