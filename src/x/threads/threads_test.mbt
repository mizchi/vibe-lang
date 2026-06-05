///|
test "threads recommended wasm flags" {
  let flags = recommended_wasm_flags()
  assert_eq(flags.length(), 2)
  assert_eq(flags[0], "threads=y")
  assert_eq(flags[1], "shared-memory=y")
}

///|
test "threads recommended wasi flags" {
  let flags = recommended_wasi_flags()
  assert_eq(flags.length(), 1)
  assert_eq(flags[0], "threads=y")
}

///|
test "threads shared-everything recommended wasm flags" {
  let flags = shared_everything_wasm_flags()
  assert_eq(flags.length(), 3)
  assert_eq(flags[0], "gc=y")
  assert_eq(flags[1], "function-references=y")
  assert_eq(flags[2], "shared-everything-threads=y")
  assert_eq(
    flags_to_env_value(flags),
    "gc=y function-references=y shared-everything-threads=y",
  )
}

///|
test "threads shared-everything recommended wasi flags are empty" {
  let flags = shared_everything_wasi_flags()
  assert_eq(flags.length(), 0)
  assert_eq(flags_to_env_value(flags), "")
}

///|
test "threads component model threading recommended wasm flags" {
  let flags = component_model_threading_wasm_flags()
  assert_eq(flags.length(), 3)
  assert_eq(flags[0], "component-model=y")
  assert_eq(flags[1], "component-model-async=y")
  assert_eq(flags[2], "component-model-threading=y")
  assert_eq(
    flags_to_env_value(flags),
    "component-model=y component-model-async=y component-model-threading=y",
  )
}

///|
test "threads shared-everything component recommended wasm flags" {
  let flags = shared_everything_component_wasm_flags()
  assert_eq(flags.length(), 6)
  assert_eq(flags[0], "component-model=y")
  assert_eq(flags[1], "component-model-async=y")
  assert_eq(flags[2], "component-model-threading=y")
  assert_eq(flags[3], "gc=y")
  assert_eq(flags[4], "function-references=y")
  assert_eq(flags[5], "shared-everything-threads=y")
}

///|
test "threads flags env formatting" {
  let wasm_env = flags_to_env_value(recommended_wasm_flags())
  let wasi_env = flags_to_env_value(recommended_wasi_flags())
  assert_eq(wasm_env, "threads=y shared-memory=y")
  assert_eq(wasi_env, "threads=y")
  assert_eq(flags_to_env_value([]), "")
}

///|
test "threads backend contracts keep cooperative and parallel semantics separate" {
  let backends = all_thread_backends()
  assert_eq(backends.length(), 6)
  assert_eq(backends[1], ThreadBackend::LinearLocal)
  assert_eq(backends[4], ThreadBackend::ComponentModelUnsafeOsThreads)
  assert_eq(backends[5], ThreadBackend::ComponentModelShared)
  assert_eq(
    thread_backend_spawn_semantics(ThreadBackend::SerialOnly),
    ThreadSpawnSemantics::NoSpawn,
  )
  assert_eq(
    thread_backend_spawn_semantics(ThreadBackend::LinearLocal),
    ThreadSpawnSemantics::ImmediateComplete,
  )
  assert_eq(
    thread_backend_spawn_semantics(ThreadBackend::ComponentModelCooperative),
    ThreadSpawnSemantics::Cooperative,
  )
  assert_eq(
    thread_backend_spawn_semantics(ThreadBackend::WasiThreads),
    ThreadSpawnSemantics::PreemptiveParallel,
  )
  assert_eq(
    thread_backend_spawn_semantics(ThreadBackend::ComponentModelUnsafeOsThreads),
    ThreadSpawnSemantics::PreemptiveParallel,
  )
  assert_false(
    thread_backend_can_claim_parallel_speedup(
      ThreadBackend::ComponentModelCooperative,
    ),
  )
  assert_false(
    thread_backend_can_claim_parallel_speedup(ThreadBackend::LinearLocal),
  )
  assert_true(
    thread_backend_can_claim_parallel_speedup(
      ThreadBackend::ComponentModelUnsafeOsThreads,
    ),
  )
  assert_false(
    thread_backend_uses_trampoline_completion(
      ThreadBackend::ComponentModelCooperative,
    ),
  )
  assert_true(
    thread_backend_uses_trampoline_completion(
      ThreadBackend::ComponentModelUnsafeOsThreads,
    ),
  )
  assert_true(
    thread_backend_requires_unsafe_os_spawn_env(
      ThreadBackend::ComponentModelUnsafeOsThreads,
    ),
  )
  assert_false(
    thread_backend_requires_unsafe_os_spawn_env(
      ThreadBackend::ComponentModelShared,
    ),
  )
}

///|
test "threads terminal status codes are stable" {
  assert_eq(thread_terminal_status_code(ThreadTerminalStatus::Completed), 0)
  assert_eq(thread_terminal_status_code(ThreadTerminalStatus::Cancelled), 1)
  assert_eq(thread_terminal_status_code(ThreadTerminalStatus::Failed), 2)
}

///|
test "threads component trampoline slot abi is centralized" {
  let abi = component_thread_slot_abi()
  assert_eq(abi.stride, 32)
  assert_eq(abi.state_offset, 0)
  assert_eq(abi.terminal_code_offset, 4)
  assert_eq(abi.payload_offset, 8)
  assert_eq(abi.input_offset, 12)
  assert_eq(abi.cancel_offset, 16)
  assert_eq(abi.mode_offset, 20)
  assert_eq(component_thread_slot_base(0), 0)
  assert_eq(component_thread_slot_base(1), 32)
  assert_eq(component_thread_slot_base(2), 64)
  assert_eq(component_thread_slot_base(3), 96)
}

///|
test "threads linear compiled runtime abi is centralized" {
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
  assert_eq(thread_task_state_code(ThreadTaskState::Empty), 0)
  assert_eq(thread_task_state_code(ThreadTaskState::Running), 1)
  assert_eq(thread_task_state_code(ThreadTaskState::Terminal), 2)
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
  assert_eq(channel.cell_size, 4)
  assert_eq(channel.cell_value_offset, 0)
  assert_eq(component_thread_reserved_slots_bytes(4), 128)
  assert_eq(shared_thread_channel_cells_base(128), 168)
  assert_eq(shared_thread_channel_alloc_size(2), 48)
  assert_true(shared_thread_channel_capacity_is_supported(1))
  assert_false(shared_thread_channel_capacity_is_supported(0))
}

///|
test "threads backend flags describe the intended runtime target" {
  assert_eq(thread_backend_id(ThreadBackend::LinearLocal), "linear-local")
  assert_eq(
    thread_backend_id(ThreadBackend::ComponentModelUnsafeOsThreads),
    "component-unsafe-os-threads",
  )
  assert_eq(
    flags_to_env_value(
      thread_backend_wasm_flags(ThreadBackend::ComponentModelUnsafeOsThreads),
    ),
    "component-model=y component-model-async=y component-model-threading=y gc=y function-references=y shared-everything-threads=y",
  )
  assert_eq(
    flags_to_env_value(
      thread_backend_wasi_flags(ThreadBackend::ComponentModelUnsafeOsThreads),
    ),
    "",
  )
  assert_eq(
    thread_backend_available_parallelism_semantics(
      ThreadBackend::ComponentModelCooperative,
    ),
    "always-one",
  )
  assert_eq(
    thread_backend_available_parallelism_semantics(
      ThreadBackend::ComponentModelUnsafeOsThreads,
    ),
    "host-available-parallelism",
  )
  assert_eq(
    thread_backend_id(ThreadBackend::ComponentModelShared),
    "component-shared",
  )
  assert_false(
    thread_backend_requires_unsafe_os_spawn_env(
      ThreadBackend::ComponentModelShared,
    ),
  )
}

///|
test "threads backend stateful compiled lowering is explicit" {
  assert_eq(
    thread_backend_compiled_stateful_lowering(ThreadBackend::LinearLocal),
    ThreadCompiledStatefulLowering::LinearLocalStateful,
  )
  assert_true(
    thread_backend_has_compiled_stateful_lowering(ThreadBackend::LinearLocal),
  )
  assert_eq(
    thread_backend_compiled_stateful_lowering(
      ThreadBackend::ComponentModelUnsafeOsThreads,
    ),
    ThreadCompiledStatefulLowering::NoCompiledStateful,
  )
  assert_false(
    thread_backend_has_compiled_stateful_lowering(
      ThreadBackend::ComponentModelUnsafeOsThreads,
    ),
  )
  assert_eq(
    thread_compiled_stateful_lowering_id(
      ThreadCompiledStatefulLowering::LinearLocalStateful,
    ),
    "linear-local",
  )
  assert_eq(
    thread_compiled_stateful_lowering_id(
      ThreadCompiledStatefulLowering::NoCompiledStateful,
    ),
    "none",
  )
}

///|
test "threads backend ids parse back to semantic backend" {
  for backend in all_thread_backends() {
    match thread_backend_from_id(thread_backend_id(backend)) {
      Some(parsed) => assert_eq(parsed, backend)
      None => fail("missing backend id: " + thread_backend_id(backend))
    }
  }
  match thread_backend_from_id("unknown-thread-backend") {
    Some(_) => fail("unexpected unknown backend parse")
    None => ()
  }
}

///|
test "threads probe wat contains wasi-threads primitives" {
  let wat = probe_wat()
  assert_true(wat.contains("(import \"env\" \"memory\" (memory 1 1 shared))"))
  assert_true(wat.contains("(import \"wasi\" \"thread-spawn\""))
  assert_true(wat.contains("(export \"wasi_thread_start\")"))
  assert_true(wat.contains("memory.atomic.wait32"))
  assert_true(wat.contains("memory.atomic.notify"))
}

///|
test "threads speedup bench wat contains serial and parallel entry points" {
  let wat = speedup_bench_wat()
  assert_true(wat.contains("(export \"serial\")"))
  assert_true(wat.contains("(export \"parallel\")"))
  assert_true(wat.contains("(export \"wasi_thread_start\")"))
  assert_true(wat.contains("memory.atomic.wait32"))
  assert_true(wat.contains("memory.atomic.notify"))
}

///|
test "threads shared-everything i31 probe wast contains current primitives" {
  let wast = shared_everything_i31_probe_wast()
  assert_true(wast.contains("(ref (shared i31))"))
  assert_true(wast.contains("(ref null (shared any))"))
  assert_true(wast.contains("ref.i31_shared"))
  assert_true(wast.contains("i31.get_u"))
  assert_true(wast.contains("(assert_return (invoke \"new\""))
}

///|
test "threads component model threading probe wast contains current intrinsics" {
  let wast = component_model_threading_probe_wast()
  assert_true(wast.contains("(component"))
  assert_true(wast.contains("canon thread.new-indirect"))
  assert_true(wast.contains("canon thread.suspend-to-suspended"))
  assert_true(wast.contains("canon thread.yield"))
  assert_true(wast.contains("canon thread.unsuspend"))
  assert_true(wast.contains("(assert_return (invoke \"run\")"))
}

///|
test "threads unsafe os trampoline probe is generated from slot abi" {
  let wast = component_model_unsafe_os_threads_trampoline_status_probe_wast()
  assert_true(
    wast.contains("ComponentModelUnsafeOsThreads trampoline status probe"),
  )
  assert_true(wast.contains("(canon thread.spawn-indirect"))
  assert_true(wast.contains(";;   +0: state"))
  assert_true(wast.contains(";;   +4: terminal code"))
  assert_true(wast.contains(";;   +8: result payload"))
  assert_true(wast.contains("memory.atomic.wait32"))
  assert_true(wast.contains("memory.atomic.notify"))
  assert_true(wast.contains("(assert_return (invoke \"run\") (u32.const 1))"))
  assert_false(wast.contains("@VIBE_"))
}

///|
test "threads unsafe os vibe abi probe is generated from slot abi" {
  let wast = component_model_unsafe_os_threads_vibe_abi_probe_wast()
  assert_true(
    wast.contains("Fork-local unsafe OS-thread Vibe runtime ABI probe"),
  )
  assert_true(wast.contains("(canon thread.spawn-indirect"))
  assert_true(wast.contains(";;  +20: mode"))
  assert_true(wast.contains("slot 3: in-flight cooperative cancellation"))
  assert_true(wast.contains("(drop (memory.atomic.notify (i32.const 112)"))
  assert_true(wast.contains("(assert_return (invoke \"run\") (u32.const 1))"))
  assert_false(wast.contains("@VIBE_"))
}

///|
test "threads unsafe os channel abi probe is generated from shared channel abi" {
  let wast = component_model_unsafe_os_threads_channel_abi_probe_wast()
  assert_true(wast.contains("Fork-local unsafe OS-thread channel ABI probe"))
  assert_true(wast.contains(";; Shared channel layout"))
  assert_true(wast.contains(";;  +28: send epoch"))
  assert_true(wast.contains(";;  +32: recv epoch"))
  assert_true(wast.contains("i32.atomic.rmw.cmpxchg"))
  assert_true(wast.contains("memory.atomic.notify"))
  assert_true(wast.contains("(assert_return (invoke \"run\") (u32.const 1))"))
  assert_false(wast.contains("@VIBE_"))
}

///|
test "threads unsafe os channel spawn abi probe connects workers to shared channel" {
  let wast = component_model_unsafe_os_threads_channel_spawn_abi_probe_wast()
  assert_true(
    wast.contains("Fork-local unsafe OS-thread channel spawn ABI probe"),
  )
  assert_true(wast.contains("(canon thread.spawn-indirect"))
  assert_true(wast.contains("call $channel-send"))
  assert_true(wast.contains("call $channel-recv"))
  assert_true(wast.contains("i32.atomic.rmw.cmpxchg"))
  assert_true(wast.contains("(assert_return (invoke \"run\") (u32.const 1))"))
  assert_false(wast.contains("@VIBE_"))
}

///|
test "threads unsafe os speedup probes are generated as serial and parallel variants" {
  let serial = component_model_unsafe_os_threads_vibe_abi_speedup_serial_wast()
  let parallel = component_model_unsafe_os_threads_vibe_abi_speedup_parallel_wast()
  assert_true(
    serial.contains("Fork-local Vibe runtime ABI serial speedup baseline"),
  )
  assert_true(
    parallel.contains(
      "Fork-local unsafe OS-thread Vibe runtime ABI parallel speedup probe",
    ),
  )
  assert_true(serial.contains(";;  +20: mode"))
  assert_true(parallel.contains(";;  +20: mode"))
  assert_false(serial.contains("(drop (call $thread-spawn-indirect"))
  assert_true(parallel.contains("(drop (call $thread-spawn-indirect"))
  assert_true(serial.contains("(assert_return (invoke \"serial\")"))
  assert_true(parallel.contains("(assert_return (invoke \"parallel\")"))
  assert_false(serial.contains("@VIBE_"))
  assert_false(parallel.contains("@VIBE_"))
}
