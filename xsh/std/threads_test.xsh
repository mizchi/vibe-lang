use ./threads.xsh {
  probe_wat,
  runtime_hints,
  task_spec,
  channel_spec,
  actor_spec,
  deployment_plan,
  recommended_wasm_flags,
  recommended_wasi_flags,
  recommended_wasm_env,
  recommended_wasi_env,
  channel_new,
  spawn,
  send,
  recv,
  wait
}test "threads probe helper typecheck" {
  let _ = probe_wat
  assert(true)
}

test "threads runtime hints helper typecheck" {
  let _ = runtime_hints
  assert(true)
}

test "threads stable recommendation helpers run without unstable flag" {
  let wasm_flags = recommended_wasm_flags()
  let wasi_flags = recommended_wasi_flags()
  assert(array_length(wasm_flags) == 2)
  assert(array_get(wasm_flags, 0) == "threads=y")
  assert(array_get(wasm_flags, 1) == "shared-memory=y")
  assert(array_length(wasi_flags) == 1)
  assert(array_get(wasi_flags, 0) == "threads=y")
  assert(recommended_wasm_env() == "threads=y shared-memory=y")
  assert(recommended_wasi_env() == "threads=y")
}

test "threads task/channel/actor spec shape" {
  let task = task_spec("worker", "worker_entry")
  let channel = channel_spec("jobs", 8)
  let actor = actor_spec("pool", "jobs", "handle_job")
  assert(task.kind == "task")
  assert(task.entry_symbol == "worker_entry")
  assert(channel.kind == "channel")
  assert(channel.capacity == 8)
  assert(actor.kind == "actor")
  assert(actor.mailbox == "jobs")
}

test "threads channel capacity is clamped at zero" {
  let channel = channel_spec("jobs", -1)
  assert(channel.capacity == 0)
}

test "threads deployment plan uses stable recommendations" {
  let task = task_spec("worker", "worker_entry")
  let channel = channel_spec("jobs", 4)
  let actor = actor_spec("pool", "jobs", "handle_job")
  let plan = deployment_plan(task, channel, actor)
  assert(plan.wasm_env == "threads=y shared-memory=y")
  assert(plan.wasi_env == "threads=y")
  assert(plan.unstable_flag == "--unstable-threads")
}

test "threads unstable runtime APIs stay thunk-only in std tests" {
  let probe_fn = () -> String { probe_wat() }
  let runtime_hints_fn = () { runtime_hints() }
  let channel_new_fn = () -> Int { channel_new(1) }
  let spawn_fn = (ch: Int) -> Int { spawn("worker", ch) }
  let send_fn = (ch: Int) -> Bool { send(ch, "msg") }
  let recv_fn = (ch: Int) -> String { recv(ch) }
  let wait_fn = (task: Int) -> Int { wait(task) }
  assert(true)
}
