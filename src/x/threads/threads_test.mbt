///|
test "threads backend ids parse back to semantic backend" {
  for backend in all_thread_backends() {
    match thread_backend_from_id(thread_backend_id(backend)) {
      Some(parsed) => assert_eq(parsed, backend)
      None => fail("missing backend id: " + thread_backend_id(backend))
    }
  }
  assert_eq(default_thread_backend_id(), "linear-local")
  match thread_backend_from_id("unknown-thread-backend") {
    Some(_) => fail("unexpected unknown backend parse")
    None => ()
  }
}

///|
test "threads backend semantics separate scheduler and compiled lowering" {
  assert_eq(
    thread_backend_spawn_semantics(ComponentModelUnsafeOsThreads),
    PreemptiveParallel,
  )
  assert_true(
    thread_backend_can_claim_parallel_speedup(ComponentModelUnsafeOsThreads),
  )
  assert_true(
    thread_backend_requires_unsafe_os_spawn_env(ComponentModelUnsafeOsThreads),
  )
  assert_eq(
    thread_backend_available_parallelism_semantics(
      ComponentModelUnsafeOsThreads,
    ),
    "host-available-parallelism",
  )
  assert_eq(
    thread_backend_compiled_stateful_lowering(LinearLocal),
    LinearLocalStateful,
  )
  assert_eq(
    thread_backend_compiled_stateful_lowering(ComponentModelUnsafeOsThreads),
    SharedAtomicStateful,
  )
  assert_true(
    thread_backend_has_compiled_stateful_lowering(ComponentModelUnsafeOsThreads),
  )
  assert_eq(thread_compiled_stateful_lowering_id(NoCompiledStateful), "none")
  assert_eq(
    thread_compiled_stateful_lowering_id(SharedAtomicStateful),
    "shared-atomic",
  )
}

///|
test "threads component trampoline slot abi is centralized" {
  let abi = component_thread_slot_abi()
  assert_eq(abi.stride, 32)
  assert_eq(abi.state_offset, 0)
  assert_eq(abi.terminal_code_offset, 4)
  assert_eq(abi.payload_offset, 8)
  assert_eq(abi.input_offset, 16)
  assert_eq(abi.cancel_offset, 20)
  assert_eq(abi.mode_offset, 24)
  assert_eq(abi.worker_func_offset, 28)
  assert_eq(component_thread_slot_base(0), 0)
  assert_eq(component_thread_slot_base(1), 32)
  assert_eq(component_thread_reserved_slots_bytes(4), 128)
  assert_eq(thread_terminal_status_code(Completed), 0)
  assert_eq(thread_terminal_status_code(Cancelled), 1)
  assert_eq(thread_terminal_status_code(Failed), 2)
  assert_eq(thread_task_mode_code(Normal), 0)
  assert_eq(thread_task_mode_code(AllocProbe), 1)
}

///|
test "threads shared atomic channel abi is centralized" {
  let channel = shared_thread_channel_abi()
  assert_eq(channel.size, 40)
  assert_eq(channel.lock_offset, 0)
  assert_eq(channel.capacity_offset, 4)
  assert_eq(channel.length_offset, 8)
  assert_eq(channel.head_offset, 12)
  assert_eq(channel.tail_offset, 16)
  assert_eq(channel.cells_offset, 20)
  assert_eq(channel.closed_offset, 24)
  assert_eq(channel.send_epoch_offset, 28)
  assert_eq(channel.recv_epoch_offset, 32)
  assert_eq(channel.cell_size, 8)
  assert_eq(channel.cell_value_offset, 0)
  assert_eq(shared_thread_channel_cells_base(128), 168)
  assert_eq(shared_thread_channel_alloc_size(2), 56)
  assert_true(shared_thread_channel_capacity_is_supported(1))
  assert_false(shared_thread_channel_capacity_is_supported(0))
}

///|
test "threads linear compiled runtime abi remains explicit" {
  let channel = linear_thread_channel_abi()
  assert_eq(channel.size, 16)
  assert_eq(channel.capacity_offset, 0)
  assert_eq(channel.length_offset, 4)
  assert_eq(channel.head_offset, 8)
  assert_eq(channel.tail_offset, 12)
  assert_eq(channel.node_size, 8)
  assert_eq(channel.node_next_offset, 0)
  assert_eq(channel.node_value_offset, 4)
  let task = linear_thread_task_abi()
  assert_eq(task.size, 16)
  assert_eq(task.state_offset, 0)
  assert_eq(task.terminal_code_offset, 4)
  assert_eq(task.channel_offset, 8)
  assert_eq(task.payload_offset, 12)
  assert_eq(thread_task_state_code(Empty), 0)
  assert_eq(thread_task_state_code(Running), 1)
  assert_eq(thread_task_state_code(Terminal), 2)
}

///|
test "threads backend flags describe runtime target" {
  assert_eq(flags_to_env_value(thread_backend_wasm_flags(LinearLocal)), "")
  assert_eq(
    flags_to_env_value(thread_backend_wasm_flags(WasiThreads)),
    "threads=y shared-memory=y",
  )
  assert_eq(
    flags_to_env_value(thread_backend_wasm_flags(ComponentModelUnsafeOsThreads)),
    "threads=y shared-memory=y component-model=y component-model-async=y component-model-threading=y gc=y function-references=y shared-everything-threads=y",
  )
  assert_eq(
    flags_to_env_value(thread_backend_wasi_flags(WasiThreads)),
    "threads=y",
  )
  assert_eq(
    flags_to_env_value(thread_backend_wasi_flags(ComponentModelUnsafeOsThreads)),
    "",
  )
}
