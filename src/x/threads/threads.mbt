///|
/// Execution backends that the experimental Vibe thread layer can target.
/// Keep these IDs stable: CLI/codegen should depend on this contract rather
/// than on a particular low-level Wasmtime intrinsic spelling.
pub(all) enum ThreadBackend {
  SerialOnly
  LinearLocal
  WasiThreads
  ComponentModelCooperative
  ComponentModelUnsafeOsThreads
  ComponentModelShared
} derive(Debug, Eq)

///|
/// Observable scheduling contract of a backend.
pub(all) enum ThreadSpawnSemantics {
  NoSpawn
  ImmediateComplete
  Cooperative
  PreemptiveParallel
} derive(Debug, Eq)

///|
/// Stateful lowering currently connected to the normal compiled backend.
/// This is intentionally narrower than `ThreadSpawnSemantics`: a backend may
/// be a desired target before `Threads::spawn/channel/wait` can lower to it.
pub(all) enum ThreadCompiledStatefulLowering {
  NoCompiledStateful
  LinearLocalStateful
  SharedAtomicStateful
} derive(Debug, Eq)

///|
/// Vibe-owned terminal status written by generated trampolines/tasks.
pub(all) enum ThreadTerminalStatus {
  Completed
  Cancelled
  Failed
} derive(Debug, Eq)

///|
/// Vibe-owned task state used by local tasks and generated trampolines.
pub(all) enum ThreadTaskState {
  Empty
  Running
  Terminal
} derive(Debug, Eq)

///|
/// Vibe-owned diagnostic task modes written to `ComponentThreadSlotAbi.mode`.
/// `AllocProbe` is intentionally fork-local: it validates that OS-owned
/// component threads can contend on the shared heap cursor.
pub(all) enum ThreadTaskMode {
  Normal
  AllocProbe
} derive(Debug, Eq)

///|
/// Shared slot ABI used by generated Component Model thread trampolines.
/// `payload` is an i64 tagged Vibe value. The remaining fields are i32-aligned
/// offsets from the per-thread context pointer.
pub(all) struct ComponentThreadSlotAbi {
  stride : Int
  state_offset : Int
  terminal_code_offset : Int
  payload_offset : Int
  input_offset : Int
  cancel_offset : Int
  mode_offset : Int
  worker_func_offset : Int
} derive(Debug, Eq)

///|
/// Shared-memory channel layout for preemptive Component Model thread probes.
/// The current lowering uses a fixed-capacity ring of i64 tagged payload cells,
/// preserving the full Vibe tagged value while avoiding cross-thread allocator
/// ownership during `send`.
pub(all) struct SharedThreadChannelAbi {
  size : Int
  lock_offset : Int
  capacity_offset : Int
  length_offset : Int
  head_offset : Int
  tail_offset : Int
  cells_offset : Int
  closed_offset : Int
  send_epoch_offset : Int
  recv_epoch_offset : Int
  cell_size : Int
  cell_value_offset : Int
} derive(Debug, Eq)

///|
/// Local linear compiled backend channel layout. Handles are opaque Vibe Ints
/// whose payload is the raw pointer to this record.
pub(all) struct LinearThreadChannelAbi {
  size : Int
  capacity_offset : Int
  length_offset : Int
  head_offset : Int
  tail_offset : Int
  node_size : Int
  node_next_offset : Int
  node_value_offset : Int
} derive(Debug, Eq)

///|
/// Local linear compiled backend task layout.
pub(all) struct LinearThreadTaskAbi {
  size : Int
  state_offset : Int
  terminal_code_offset : Int
  channel_offset : Int
  payload_offset : Int
} derive(Debug, Eq)

///|
pub impl Show for ThreadBackend with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub impl Show for ThreadSpawnSemantics with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub impl Show for ThreadCompiledStatefulLowering with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub impl Show for ThreadTerminalStatus with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub impl Show for ThreadTaskState with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub impl Show for ThreadTaskMode with fn output(self, logger) {
  logger.write_string(Debug::to_repr(self).to_string())
}

///|
pub fn all_thread_backends() -> Array[ThreadBackend] {
  [
    SerialOnly,
    LinearLocal,
    WasiThreads,
    ComponentModelCooperative,
    ComponentModelUnsafeOsThreads,
    ComponentModelShared,
  ]
}

///|
pub fn thread_backend_id(backend : ThreadBackend) -> String {
  match backend {
    SerialOnly => "serial"
    LinearLocal => "linear-local"
    WasiThreads => "wasi-threads"
    ComponentModelCooperative => "component-cooperative"
    ComponentModelUnsafeOsThreads => "component-unsafe-os-threads"
    ComponentModelShared => "component-shared"
  }
}

///|
pub fn default_thread_backend_id() -> String {
  thread_backend_id(LinearLocal)
}

///|
pub fn thread_backend_from_id(id : String) -> ThreadBackend? {
  match id {
    "serial" => Some(SerialOnly)
    "linear-local" => Some(LinearLocal)
    "wasi-threads" => Some(WasiThreads)
    "component-cooperative" => Some(ComponentModelCooperative)
    "component-unsafe-os-threads" => Some(ComponentModelUnsafeOsThreads)
    "component-shared" => Some(ComponentModelShared)
    _ => None
  }
}

///|
pub fn thread_backend_spawn_semantics(
  backend : ThreadBackend,
) -> ThreadSpawnSemantics {
  match backend {
    SerialOnly => NoSpawn
    LinearLocal => ImmediateComplete
    ComponentModelCooperative => Cooperative
    WasiThreads | ComponentModelUnsafeOsThreads | ComponentModelShared =>
      PreemptiveParallel
  }
}

///|
pub fn thread_backend_can_claim_parallel_speedup(
  backend : ThreadBackend,
) -> Bool {
  thread_backend_spawn_semantics(backend) == PreemptiveParallel
}

///|
pub fn thread_backend_compiled_stateful_lowering(
  backend : ThreadBackend,
) -> ThreadCompiledStatefulLowering {
  match backend {
    LinearLocal => LinearLocalStateful
    ComponentModelUnsafeOsThreads | ComponentModelShared => SharedAtomicStateful
    SerialOnly | WasiThreads | ComponentModelCooperative => NoCompiledStateful
  }
}

///|
pub fn thread_backend_has_compiled_stateful_lowering(
  backend : ThreadBackend,
) -> Bool {
  thread_backend_compiled_stateful_lowering(backend) != NoCompiledStateful
}

///|
pub fn thread_compiled_stateful_lowering_id(
  lowering : ThreadCompiledStatefulLowering,
) -> String {
  match lowering {
    NoCompiledStateful => "none"
    LinearLocalStateful => "linear-local"
    SharedAtomicStateful => "shared-atomic"
  }
}

///|
pub fn thread_backend_requires_shared_linear_memory(
  backend : ThreadBackend,
) -> Bool {
  thread_backend_compiled_stateful_lowering(backend) == SharedAtomicStateful
}

///|
pub fn thread_backend_requires_unsafe_os_spawn_env(
  backend : ThreadBackend,
) -> Bool {
  backend == ComponentModelUnsafeOsThreads
}

///|
pub fn thread_backend_available_parallelism_semantics(
  backend : ThreadBackend,
) -> String {
  match backend {
    SerialOnly | LinearLocal | ComponentModelCooperative => "always-one"
    WasiThreads | ComponentModelUnsafeOsThreads | ComponentModelShared =>
      "host-available-parallelism"
  }
}

///|
pub fn thread_terminal_status_code(status : ThreadTerminalStatus) -> Int {
  match status {
    Completed => 0
    Cancelled => 1
    Failed => 2
  }
}

///|
pub fn thread_task_state_code(state : ThreadTaskState) -> Int {
  match state {
    Empty => 0
    Running => 1
    Terminal => 2
  }
}

///|
pub fn thread_task_mode_code(mode : ThreadTaskMode) -> Int {
  match mode {
    Normal => 0
    AllocProbe => 1
  }
}

///|
pub fn component_thread_slot_abi() -> ComponentThreadSlotAbi {
  {
    stride: 32,
    state_offset: 0,
    terminal_code_offset: 4,
    payload_offset: 8,
    input_offset: 16,
    cancel_offset: 20,
    mode_offset: 24,
    worker_func_offset: 28,
  }
}

///|
pub fn component_thread_slot_base(slot : Int) -> Int {
  slot * component_thread_slot_abi().stride
}

///|
pub fn component_thread_reserved_slots_bytes(slot_count : Int) -> Int {
  slot_count * component_thread_slot_abi().stride
}

///|
pub fn shared_thread_channel_abi() -> SharedThreadChannelAbi {
  {
    size: 40,
    lock_offset: 0,
    capacity_offset: 4,
    length_offset: 8,
    head_offset: 12,
    tail_offset: 16,
    cells_offset: 20,
    closed_offset: 24,
    send_epoch_offset: 28,
    recv_epoch_offset: 32,
    cell_size: 8,
    cell_value_offset: 0,
  }
}

///|
pub fn shared_thread_channel_cells_base(channel_base : Int) -> Int {
  channel_base + shared_thread_channel_abi().size
}

///|
pub fn shared_thread_channel_capacity_is_supported(capacity : Int) -> Bool {
  capacity > 0
}

///|
pub fn shared_thread_channel_alloc_size(capacity : Int) -> Int {
  let abi = shared_thread_channel_abi()
  if capacity <= 0 {
    abi.size
  } else {
    abi.size + capacity * abi.cell_size
  }
}

///|
pub fn linear_thread_channel_abi() -> LinearThreadChannelAbi {
  {
    size: 16,
    capacity_offset: 0,
    length_offset: 4,
    head_offset: 8,
    tail_offset: 12,
    node_size: 8,
    node_next_offset: 0,
    node_value_offset: 4,
  }
}

///|
pub fn linear_thread_task_abi() -> LinearThreadTaskAbi {
  {
    size: 16,
    state_offset: 0,
    terminal_code_offset: 4,
    channel_offset: 8,
    payload_offset: 12,
  }
}

///|
pub fn recommended_wasm_flags() -> Array[String] {
  ["threads=y", "shared-memory=y"]
}

///|
pub fn recommended_wasi_flags() -> Array[String] {
  ["threads=y"]
}

///|
pub fn shared_everything_component_wasm_flags() -> Array[String] {
  [
    "threads=y", "shared-memory=y", "component-model=y", "component-model-async=y",
    "component-model-threading=y", "gc=y", "function-references=y", "shared-everything-threads=y",
  ]
}

///|
pub fn thread_backend_wasm_flags(backend : ThreadBackend) -> Array[String] {
  match backend {
    SerialOnly | LinearLocal => []
    WasiThreads => recommended_wasm_flags()
    ComponentModelCooperative =>
      [
        "component-model=y", "component-model-async=y", "component-model-threading=y",
      ]
    ComponentModelUnsafeOsThreads | ComponentModelShared =>
      shared_everything_component_wasm_flags()
  }
}

///|
pub fn thread_backend_wasi_flags(backend : ThreadBackend) -> Array[String] {
  match backend {
    SerialOnly
    | LinearLocal
    | ComponentModelCooperative
    | ComponentModelUnsafeOsThreads
    | ComponentModelShared => []
    WasiThreads => recommended_wasi_flags()
  }
}

///|
pub fn flags_to_env_value(flags : Array[String]) -> String {
  if flags.length() == 0 {
    return ""
  }
  let out = StringBuilder::new()
  let mut i = 0
  while i < flags.length() {
    if i > 0 {
      out.write_string(" ")
    }
    out.write_string(flags[i])
    i += 1
  }
  out.to_string()
}
