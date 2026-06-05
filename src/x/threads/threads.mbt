///|
/// Execution backends that the experimental thread layer can target.
/// Keep these names stable: the Wasmtime fork milestones are mapped to this
/// semantic contract instead of to a specific low-level instruction spelling.
pub(all) enum ThreadBackend {
  SerialOnly
  LinearLocal
  WasiThreads
  ComponentModelCooperative
  ComponentModelUnsafeOsThreads
  ComponentModelShared
} derive(Debug, Eq)

///|
/// The observable scheduling contract of a backend.
pub(all) enum ThreadSpawnSemantics {
  NoSpawn
  ImmediateComplete
  Cooperative
  PreemptiveParallel
} derive(Debug, Eq)

///|
/// Concrete stateful lowering currently connected to the compiled Vibe backend.
/// This is intentionally narrower than `ThreadSpawnSemantics`: a backend may
/// have a desired semantic target before the normal compiler can lower
/// `Threads::channel_*` / `Threads::spawn` / `Threads::wait` to it.
pub(all) enum ThreadCompiledStatefulLowering {
  NoCompiledStateful
  LinearLocalStateful
} derive(Debug, Eq)

///|
/// Vibe-level terminal status code written by a generated trampoline. This is
/// deliberately independent of the canonical Component Model spawn return index.
pub(all) enum ThreadTerminalStatus {
  Completed
  Cancelled
  Failed
} derive(Debug, Eq)

///|
/// Vibe-owned task state used by the compiled linear backend and by generated
/// trampolines before they reach a terminal status.
pub(all) enum ThreadTaskState {
  Empty
  Running
  Terminal
} derive(Debug, Eq)

///|
/// Shared slot ABI used by generated Component Model thread trampolines.
/// All fields are i32-aligned offsets from the per-thread context pointer.
pub(all) struct ComponentThreadSlotAbi {
  stride : Int
  state_offset : Int
  terminal_code_offset : Int
  payload_offset : Int
  input_offset : Int
  cancel_offset : Int
  mode_offset : Int
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
/// Shared-memory channel layout for preemptive Component Model thread probes.
/// The channel is a fixed-capacity ring buffer of i32 tagged payload cells.
/// Header fields are i32-aligned so the eventual lowering can use atomic
/// operations consistently across parent and worker threads.
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
/// Local linear compiled backend task layout. The first fields intentionally
/// mirror the generated Component Model slot prefix: state, terminal code,
/// then Vibe-owned payload/context fields.
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
    SerialOnly
    | WasiThreads
    | ComponentModelCooperative
    | ComponentModelUnsafeOsThreads
    | ComponentModelShared => NoCompiledStateful
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
  }
}

///|
pub fn thread_backend_uses_trampoline_completion(
  backend : ThreadBackend,
) -> Bool {
  match backend {
    ComponentModelUnsafeOsThreads | ComponentModelShared => true
    SerialOnly | LinearLocal | WasiThreads | ComponentModelCooperative => false
  }
}

///|
pub fn thread_backend_requires_unsafe_os_spawn_env(
  backend : ThreadBackend,
) -> Bool {
  match backend {
    ComponentModelUnsafeOsThreads => true
    SerialOnly
    | LinearLocal
    | WasiThreads
    | ComponentModelCooperative
    | ComponentModelShared => false
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
pub fn component_thread_slot_abi() -> ComponentThreadSlotAbi {
  {
    stride: 32,
    state_offset: 0,
    terminal_code_offset: 4,
    payload_offset: 8,
    input_offset: 12,
    cancel_offset: 16,
    mode_offset: 20,
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
    cell_size: 4,
    cell_value_offset: 0,
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
pub fn component_thread_slot_base(slot : Int) -> Int {
  slot * component_thread_slot_abi().stride
}

///|
pub fn component_thread_reserved_slots_bytes(slot_count : Int) -> Int {
  slot_count * component_thread_slot_abi().stride
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
fn component_thread_slot_addr(
  abi : ComponentThreadSlotAbi,
  slot : Int,
  offset : Int,
) -> Int {
  slot * abi.stride + offset
}

///|
fn render_shared_thread_channel_abi_template(
  template : String,
  abi : SharedThreadChannelAbi,
) -> String {
  let channel0 = component_thread_reserved_slots_bytes(4)
  let cells0 = shared_thread_channel_cells_base(channel0)
  template
  .replace_all(old="@VIBE_CHANNEL_SIZE@", new=abi.size.to_string())
  .replace_all(
    old="@VIBE_CHANNEL_LOCK_OFFSET@",
    new=abi.lock_offset.to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL_CAPACITY_OFFSET@",
    new=abi.capacity_offset.to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL_LENGTH_OFFSET@",
    new=abi.length_offset.to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL_HEAD_OFFSET@",
    new=abi.head_offset.to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL_TAIL_OFFSET@",
    new=abi.tail_offset.to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL_CELLS_OFFSET@",
    new=abi.cells_offset.to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL_CLOSED_OFFSET@",
    new=abi.closed_offset.to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL_SEND_EPOCH_OFFSET@",
    new=abi.send_epoch_offset.to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL_RECV_EPOCH_OFFSET@",
    new=abi.recv_epoch_offset.to_string(),
  )
  .replace_all(old="@VIBE_CHANNEL_CELL_SIZE@", new=abi.cell_size.to_string())
  .replace_all(
    old="@VIBE_CHANNEL_CELL_VALUE_OFFSET@",
    new=abi.cell_value_offset.to_string(),
  )
  .replace_all(old="@VIBE_CHANNEL0@", new=channel0.to_string())
  .replace_all(
    old="@VIBE_CHANNEL0_LOCK@",
    new=(channel0 + abi.lock_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_CAPACITY@",
    new=(channel0 + abi.capacity_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_LENGTH@",
    new=(channel0 + abi.length_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_HEAD@",
    new=(channel0 + abi.head_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_TAIL@",
    new=(channel0 + abi.tail_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_CELLS@",
    new=(channel0 + abi.cells_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_CLOSED@",
    new=(channel0 + abi.closed_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_SEND_EPOCH@",
    new=(channel0 + abi.send_epoch_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_RECV_EPOCH@",
    new=(channel0 + abi.recv_epoch_offset).to_string(),
  )
  .replace_all(old="@VIBE_CHANNEL0_CELLS_BASE@", new=cells0.to_string())
  .replace_all(
    old="@VIBE_CHANNEL0_CELL0_VALUE@",
    new=(cells0 + abi.cell_value_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_CHANNEL0_CELL1_VALUE@",
    new=(cells0 + abi.cell_size + abi.cell_value_offset).to_string(),
  )
}

///|
fn render_component_thread_slot_abi_template(
  template : String,
  abi : ComponentThreadSlotAbi,
) -> String {
  template
  .replace_all(old="@VIBE_SLOT_STRIDE@", new=abi.stride.to_string())
  .replace_all(old="@VIBE_STATE_OFFSET@", new=abi.state_offset.to_string())
  .replace_all(
    old="@VIBE_TERMINAL_CODE_OFFSET@",
    new=abi.terminal_code_offset.to_string(),
  )
  .replace_all(old="@VIBE_PAYLOAD_OFFSET@", new=abi.payload_offset.to_string())
  .replace_all(old="@VIBE_INPUT_OFFSET@", new=abi.input_offset.to_string())
  .replace_all(old="@VIBE_CANCEL_OFFSET@", new=abi.cancel_offset.to_string())
  .replace_all(old="@VIBE_MODE_OFFSET@", new=abi.mode_offset.to_string())
  .replace_all(
    old="@VIBE_SLOT0@",
    new=component_thread_slot_addr(abi, 0, 0).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT1@",
    new=component_thread_slot_addr(abi, 1, 0).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT2@",
    new=component_thread_slot_addr(abi, 2, 0).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT3@",
    new=component_thread_slot_addr(abi, 3, 0).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT0_STATE@",
    new=component_thread_slot_addr(abi, 0, abi.state_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT0_TERMINAL_CODE@",
    new=component_thread_slot_addr(abi, 0, abi.terminal_code_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT0_PAYLOAD@",
    new=component_thread_slot_addr(abi, 0, abi.payload_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT0_INPUT@",
    new=component_thread_slot_addr(abi, 0, abi.input_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT0_CANCEL@",
    new=component_thread_slot_addr(abi, 0, abi.cancel_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT0_MODE@",
    new=component_thread_slot_addr(abi, 0, abi.mode_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT1_STATE@",
    new=component_thread_slot_addr(abi, 1, abi.state_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT1_TERMINAL_CODE@",
    new=component_thread_slot_addr(abi, 1, abi.terminal_code_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT1_PAYLOAD@",
    new=component_thread_slot_addr(abi, 1, abi.payload_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT1_INPUT@",
    new=component_thread_slot_addr(abi, 1, abi.input_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT1_CANCEL@",
    new=component_thread_slot_addr(abi, 1, abi.cancel_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT1_MODE@",
    new=component_thread_slot_addr(abi, 1, abi.mode_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT2_STATE@",
    new=component_thread_slot_addr(abi, 2, abi.state_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT2_TERMINAL_CODE@",
    new=component_thread_slot_addr(abi, 2, abi.terminal_code_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT2_PAYLOAD@",
    new=component_thread_slot_addr(abi, 2, abi.payload_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT2_INPUT@",
    new=component_thread_slot_addr(abi, 2, abi.input_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT2_CANCEL@",
    new=component_thread_slot_addr(abi, 2, abi.cancel_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT2_MODE@",
    new=component_thread_slot_addr(abi, 2, abi.mode_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT3_STATE@",
    new=component_thread_slot_addr(abi, 3, abi.state_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT3_TERMINAL_CODE@",
    new=component_thread_slot_addr(abi, 3, abi.terminal_code_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT3_PAYLOAD@",
    new=component_thread_slot_addr(abi, 3, abi.payload_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT3_INPUT@",
    new=component_thread_slot_addr(abi, 3, abi.input_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT3_CANCEL@",
    new=component_thread_slot_addr(abi, 3, abi.cancel_offset).to_string(),
  )
  .replace_all(
    old="@VIBE_SLOT3_MODE@",
    new=component_thread_slot_addr(abi, 3, abi.mode_offset).to_string(),
  )
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
pub fn thread_backend_wasm_flags(backend : ThreadBackend) -> Array[String] {
  match backend {
    SerialOnly | LinearLocal => []
    WasiThreads => recommended_wasm_flags()
    ComponentModelCooperative => component_model_threading_wasm_flags()
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
pub fn recommended_wasm_flags() -> Array[String] {
  ["threads=y", "shared-memory=y"]
}

///|
pub fn recommended_wasi_flags() -> Array[String] {
  ["threads=y"]
}

///|
pub fn shared_everything_wasm_flags() -> Array[String] {
  ["gc=y", "function-references=y", "shared-everything-threads=y"]
}

///|
pub fn shared_everything_wasi_flags() -> Array[String] {
  []
}

///|
pub fn component_model_threading_wasm_flags() -> Array[String] {
  [
    "component-model=y", "component-model-async=y", "component-model-threading=y",
  ]
}

///|
pub fn component_model_threading_wasi_flags() -> Array[String] {
  []
}

///|
pub fn shared_everything_component_wasm_flags() -> Array[String] {
  [
    "component-model=y", "component-model-async=y", "component-model-threading=y",
    "gc=y", "function-references=y", "shared-everything-threads=y",
  ]
}

///|
pub fn shared_everything_component_wasi_flags() -> Array[String] {
  []
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
    i = i + 1
  }
  out.to_string()
}

///|
/// Minimal WAT module that validates WASI Threads execution on wasmtime.
/// Runtime requirement:
/// - -S threads=y
/// - -W threads=y
/// - -W shared-memory=y
pub fn probe_wat() -> String {
  let wat =
    #|(module
    #|  (import "env" "memory" (memory 1 1 shared))
    #|  (import "wasi" "thread-spawn" (func $thread_spawn (param i32) (result i32)))
    #|
    #|  ;; shared slots
    #|  ;; 0: counter (i32)
    #|
    #|  (func (export "wasi_thread_start") (param $tid i32) (param $start_arg i32)
    #|    i32.const 0
    #|    i32.const 1
    #|    i32.atomic.rmw.add
    #|    drop
    #|
    #|    i32.const 0
    #|    i32.const 1
    #|    memory.atomic.notify
    #|    drop
    #|  )
    #|
    #|  (func (export "_start")
    #|    (local $seen i32)
    #|
    #|    ;; reset counter
    #|    i32.const 0
    #|    i32.const 0
    #|    i32.store
    #|
    #|    ;; spawn 4 workers
    #|    i32.const 0
    #|    call $thread_spawn
    #|    drop
    #|    i32.const 0
    #|    call $thread_spawn
    #|    drop
    #|    i32.const 0
    #|    call $thread_spawn
    #|    drop
    #|    i32.const 0
    #|    call $thread_spawn
    #|    drop
    #|
    #|    ;; wait until counter >= 4
    #|    block $done
    #|      loop $wait
    #|        i32.const 0
    #|        i32.atomic.load
    #|        local.tee $seen
    #|        i32.const 4
    #|        i32.ge_s
    #|        br_if $done
    #|
    #|        i32.const 0
    #|        local.get $seen
    #|        i64.const -1
    #|        memory.atomic.wait32
    #|        drop
    #|
    #|        br $wait
    #|      end
    #|    end
    #|
    #|    ;; sanity check
    #|    i32.const 0
    #|    i32.atomic.load
    #|    i32.const 4
    #|    i32.eq
    #|    if
    #|    else
    #|      unreachable
    #|    end
    #|  )
    #|)
  wat
}

///|
/// CPU-bound WASI Threads benchmark used to prove that a workload shape can
/// benefit from parallel execution. It exports `serial` and `parallel` so the
/// runner can benchmark both paths independently, and `_start` validates that
/// both paths produce the same checksum.
pub fn speedup_bench_wat() -> String {
  let wat =
    #|(module
    #|  (import "env" "memory" (memory 1 1 shared))
    #|  (import "wasi" "thread-spawn" (func $thread_spawn (param i32) (result i32)))
    #|
    #|  ;; shared slots
    #|  ;; 0: done counter (i32)
    #|  ;; 64,68,72,76: per-worker checksums (i32)
    #|
    #|  (global $iterations i32 (i32.const 60000000))
    #|
    #|  (func $compute (param $seed i32) (result i32)
    #|    (local $i i32)
    #|    (local $x i32)
    #|
    #|    local.get $seed
    #|    local.set $x
    #|
    #|    loop $loop
    #|      local.get $x
    #|      i32.const 1664525
    #|      i32.mul
    #|      i32.const 1013904223
    #|      i32.add
    #|      local.get $i
    #|      i32.add
    #|      local.set $x
    #|
    #|      local.get $i
    #|      i32.const 1
    #|      i32.add
    #|      local.tee $i
    #|      global.get $iterations
    #|      i32.lt_u
    #|      br_if $loop
    #|    end
    #|
    #|    local.get $x)
    #|
    #|  (func $reset
    #|    i32.const 0
    #|    i32.const 0
    #|    i32.store
    #|    i32.const 64
    #|    i32.const 0
    #|    i32.store
    #|    i32.const 68
    #|    i32.const 0
    #|    i32.store
    #|    i32.const 72
    #|    i32.const 0
    #|    i32.store
    #|    i32.const 76
    #|    i32.const 0
    #|    i32.store)
    #|
    #|  (func $compute_chunk (param $worker i32)
    #|    i32.const 64
    #|    local.get $worker
    #|    i32.const 4
    #|    i32.mul
    #|    i32.add
    #|    local.get $worker
    #|    i32.const 1
    #|    i32.add
    #|    call $compute
    #|    i32.store
    #|
    #|    i32.const 0
    #|    i32.const 1
    #|    i32.atomic.rmw.add
    #|    drop
    #|
    #|    i32.const 0
    #|    i32.const 1
    #|    memory.atomic.notify
    #|    drop)
    #|
    #|  (func $spawn_worker (param $worker i32)
    #|    local.get $worker
    #|    call $thread_spawn
    #|    i32.const 0
    #|    i32.lt_s
    #|    if
    #|      unreachable
    #|    end)
    #|
    #|  (func (export "wasi_thread_start") (param $tid i32) (param $start_arg i32)
    #|    local.get $start_arg
    #|    call $compute_chunk)
    #|
    #|  (func $combine (result i32)
    #|    i32.const 64
    #|    i32.load
    #|    i32.const 68
    #|    i32.load
    #|    i32.xor
    #|    i32.const 72
    #|    i32.load
    #|    i32.xor
    #|    i32.const 76
    #|    i32.load
    #|    i32.xor)
    #|
    #|  (func $serial (export "serial") (result i32)
    #|    call $reset
    #|    i32.const 0
    #|    call $compute_chunk
    #|    i32.const 1
    #|    call $compute_chunk
    #|    i32.const 2
    #|    call $compute_chunk
    #|    i32.const 3
    #|    call $compute_chunk
    #|    call $combine)
    #|
    #|  (func $parallel (export "parallel") (result i32)
    #|    (local $seen i32)
    #|
    #|    call $reset
    #|
    #|    i32.const 0
    #|    call $spawn_worker
    #|    i32.const 1
    #|    call $spawn_worker
    #|    i32.const 2
    #|    call $spawn_worker
    #|    i32.const 3
    #|    call $spawn_worker
    #|
    #|    block $done
    #|      loop $wait
    #|        i32.const 0
    #|        i32.atomic.load
    #|        local.tee $seen
    #|        i32.const 4
    #|        i32.ge_u
    #|        br_if $done
    #|
    #|        i32.const 0
    #|        local.get $seen
    #|        i64.const -1
    #|        memory.atomic.wait32
    #|        drop
    #|
    #|        br $wait
    #|      end
    #|    end
    #|
    #|    call $combine)
    #|
    #|  (func (export "_start")
    #|    (local $serial_result i32)
    #|
    #|    call $serial
    #|    local.set $serial_result
    #|    call $parallel
    #|    local.get $serial_result
    #|    i32.eq
    #|    if
    #|    else
    #|      unreachable
    #|    end)
    #|)
  wat
}

///|
/// Minimal WAST probe for Wasmtime's experimental shared-everything-threads
/// subset currently used by vibe. This intentionally starts with shared i31:
/// i31 refs are immediate values, so they exercise shared heap types without
/// requiring shared GC object allocation yet.
pub fn shared_everything_i31_probe_wast() -> String {
  let wast =
    #|(module
    #|  (global $g (ref (shared i31)) (ref.i31_shared (i32.const 77)))
    #|  (global $any (ref null (shared any)) (ref.i31_shared (i32.const 1234)))
    #|  (table $t 1 1 (ref (shared i31)) (ref.i31_shared (i32.const 88)))
    #|
    #|  (func (export "new") (param i32) (result (ref (shared i31)))
    #|    local.get 0
    #|    ref.i31_shared)
    #|
    #|  (func (export "get_u") (param i32) (result i32)
    #|    local.get 0
    #|    ref.i31_shared
    #|    i31.get_u)
    #|
    #|  (func (export "get_s") (param i32) (result i32)
    #|    local.get 0
    #|    ref.i31_shared
    #|    i31.get_s)
    #|)
    #|
    #|(assert_return (invoke "new" (i32.const 1)) (ref.i31_shared))
    #|(assert_return (invoke "get_u" (i32.const 100)) (i32.const 100))
    #|(assert_return (invoke "get_u" (i32.const -1)) (i32.const 2147483647))
    #|(assert_return (invoke "get_s" (i32.const -1)) (i32.const -1))
    #|(assert_return (invoke "get_s" (i32.const 1073741824)) (i32.const -1073741824))
  wast
}

///|
/// Minimal Component Model threading WAST probe for Wasmtime's current
/// `thread.new-indirect` builtins. This does not exercise the newer
/// shared-everything `thread.spawn-*` intrinsics yet.
pub fn component_model_threading_probe_wast() -> String {
  let wast =
    #|;;! component_model_async = true
    #|;;! component_model_threading = true
    #|
    #|(component
    #|  (core module $libc
    #|    (table (export "__indirect_function_table") 1 funcref))
    #|
    #|  (core module $m
    #|    (import "" "thread.new-indirect" (func $thread-new-indirect (param i32 i32) (result i32)))
    #|    (import "" "thread.suspend-to-suspended" (func $thread-suspend-to-suspended (param i32) (result i32)))
    #|    (import "" "thread.yield" (func $thread-yield (result i32)))
    #|    (import "" "thread.unsuspend" (func $thread-unsuspend (param i32)))
    #|    (import "" "thread.index" (func $thread-index (result i32)))
    #|    (import "libc" "__indirect_function_table" (table $indirect-function-table 1 funcref))
    #|
    #|    (global $g (mut i32) (i32.const 0))
    #|    (global $main-thread-index (mut i32) (i32.const 0))
    #|
    #|    (func $thread-start (param i32)
    #|      (global.set $g (local.get 0))
    #|      (call $thread-unsuspend (global.get $main-thread-index))
    #|      (drop (call $thread-yield)))
    #|    (export "thread-start" (func $thread-start))
    #|
    #|    (elem (table $indirect-function-table) (i32.const 0) func $thread-start)
    #|
    #|    (func (export "run") (result i32)
    #|      (global.set $main-thread-index (call $thread-index))
    #|      (drop
    #|        (call $thread-suspend-to-suspended
    #|          (call $thread-new-indirect (i32.const 0) (i32.const 7))))
    #|      (global.get $g)))
    #|
    #|  (core instance $libc (instantiate $libc))
    #|  (core type $start-func-ty (func (param i32)))
    #|  (alias core export $libc "__indirect_function_table" (core table $indirect-function-table))
    #|
    #|  (core func $thread-new-indirect
    #|    (canon thread.new-indirect $start-func-ty (table $indirect-function-table)))
    #|  (core func $thread-suspend-to-suspended (canon thread.suspend-to-suspended))
    #|  (core func $thread-yield (canon thread.yield))
    #|  (core func $thread-unsuspend (canon thread.unsuspend))
    #|  (core func $thread-index (canon thread.index))
    #|
    #|  (core instance $i
    #|    (instantiate $m
    #|      (with "" (instance
    #|        (export "thread.new-indirect" (func $thread-new-indirect))
    #|        (export "thread.suspend-to-suspended" (func $thread-suspend-to-suspended))
    #|        (export "thread.yield" (func $thread-yield))
    #|        (export "thread.unsuspend" (func $thread-unsuspend))
    #|        (export "thread.index" (func $thread-index))))
    #|      (with "libc" (instance $libc))))
    #|
    #|  (func (export "run") async (result u32) (canon lift (core func $i "run"))))
    #|
    #|(assert_return (invoke "run") (u32.const 7))
  wast
}

///|
/// Generated ComponentModelUnsafeOsThreads status probe. This mirrors the Vibe
/// trampoline completion contract and deliberately ignores canonical spawn
/// return values.
pub fn component_model_unsafe_os_threads_trampoline_status_probe_wast() -> String {
  let abi = component_thread_slot_abi()
  let wast =
    #|;;! threads = true
    #|;;! component_model_async = true
    #|;;! component_model_threading = true
    #|;;! gc = true
    #|;;! function_references = true
    #|;;! shared_everything_threads = true
    #|
    #|;; ComponentModelUnsafeOsThreads trampoline status probe.
    #|;;
    #|;; The canonical `thread.spawn-indirect` return value is a transient component
    #|;; thread-table index, not a Vibe join handle. This probe intentionally drops
    #|;; every spawn return value and models Vibe-level completion/status with
    #|;; trampoline-owned shared memory plus wait/notify.
    #|
    #|(component
    #|  (core module $libc
    #|    (memory (export "mem") 1 1 shared)
    #|    (table (export "__indirect_function_table") shared 1 1 (ref null (shared func))))
    #|
    #|  (core module $m
    #|    (type $start-func-ty (shared (func (param i32))))
    #|    (type $spawn-indirect-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $slot-addr-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $finish-ty (shared (func (param i32 i32 i32))))
    #|    (type $wait-completed-ty (func (param i32) (result i32)))
    #|    (type $run-ty (func (result i32)))
    #|    (import "" "thread.spawn-indirect"
    #|      (func $thread-spawn-indirect (type $spawn-indirect-ty)))
    #|    (import "libc" "mem" (memory $mem 1 1 shared))
    #|    (import "libc" "__indirect_function_table"
    #|      (table $indirect-function-table shared 1 1 (ref null (shared func))))
    #|
    #|    ;; Slot layout, addressed by the context argument:
    #|    ;;   +@VIBE_STATE_OFFSET@: state, 0 = empty, 1 = running, 2 = completed
    #|    ;;   +@VIBE_TERMINAL_CODE_OFFSET@: terminal code, 0 = completed, 1 = cancelled, 2 = failed
    #|    ;;   +@VIBE_PAYLOAD_OFFSET@: result payload for completed
    #|    ;;  +@VIBE_INPUT_OFFSET@: input
    #|    ;;  +@VIBE_CANCEL_OFFSET@: cancel request flag
    #|
    #|    (func $slot-addr (type $slot-addr-ty)
    #|      (i32.add (local.get 0) (local.get 1)))
    #|
    #|    (func $finish (type $finish-ty)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_TERMINAL_CODE_OFFSET@))
    #|        (local.get 1))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_PAYLOAD_OFFSET@))
    #|        (local.get 2))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 2))
    #|      (drop (memory.atomic.notify
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1))))
    #|
    #|    (func $thread-trampoline (type $start-func-ty)
    #|      (local $input i32)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1))
    #|
    #|      (if
    #|        (i32.ne
    #|          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_CANCEL_OFFSET@)))
    #|          (i32.const 0))
    #|        (then
    #|          (call $finish (local.get 0) (i32.const 1) (i32.const 0))
    #|          (return)))
    #|
    #|      (local.set $input
    #|        (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_INPUT_OFFSET@))))
    #|
    #|      ;; Model a Vibe runtime error as a value. A real Wasm trap is not caught
    #|      ;; here; traps still abort through the host/runtime path.
    #|      (if (i32.eq (local.get $input) (i32.const 13))
    #|        (then
    #|          (call $finish (local.get 0) (i32.const 2) (i32.const 0))
    #|          (return)))
    #|
    #|      (call $finish
    #|        (local.get 0)
    #|        (i32.const 0)
    #|        (i32.add
    #|          (i32.mul (local.get $input) (local.get $input))
    #|          (i32.const 7))))
    #|    (export "thread-trampoline" (func $thread-trampoline))
    #|
    #|    (elem (table $indirect-function-table) (i32.const 0)
    #|      (ref null (shared func)) (ref.func $thread-trampoline))
    #|
    #|    (func $wait-completed (type $wait-completed-ty)
    #|      (local $state i32)
    #|      (local $attempts i32)
    #|      (loop $again
    #|        (local.set $state
    #|          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))))
    #|        (if (i32.eq (local.get $state) (i32.const 2))
    #|          (then
    #|            (return (i32.const 1))))
    #|        (if (i32.ge_u (local.get $attempts) (i32.const 200))
    #|          (then
    #|            (return (i32.const 0))))
    #|        (drop (memory.atomic.wait32
    #|          (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|          (local.get $state)
    #|          (i64.const 1000000)))
    #|        (local.set $attempts (i32.add (local.get $attempts) (i32.const 1)))
    #|        (br $again))
    #|      (i32.const 0))
    #|
    #|    (func (export "run") (type $run-ty)
    #|      ;; slot 0: completed, input 11, result 128
    #|      (i32.atomic.store (i32.const @VIBE_SLOT0_STATE@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT0_TERMINAL_CODE@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT0_PAYLOAD@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT0_INPUT@) (i32.const 11))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT0_CANCEL@) (i32.const 0))
    #|
    #|      ;; slot 1: failed-as-value, input 13
    #|      (i32.atomic.store (i32.const @VIBE_SLOT1_STATE@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT1_TERMINAL_CODE@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT1_PAYLOAD@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT1_INPUT@) (i32.const 13))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT1_CANCEL@) (i32.const 0))
    #|
    #|      ;; slot 2: cooperatively cancelled before start
    #|      (i32.atomic.store (i32.const @VIBE_SLOT2_STATE@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT2_TERMINAL_CODE@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT2_PAYLOAD@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT2_INPUT@) (i32.const 17))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT2_CANCEL@) (i32.const 1))
    #|
    #|      ;; The canonical spawn return values are intentionally ignored.
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT0@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT1@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT2@)))
    #|
    #|      (if (i32.eqz (call $wait-completed (i32.const @VIBE_SLOT0@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-completed (i32.const @VIBE_SLOT1@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-completed (i32.const @VIBE_SLOT2@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|
    #|      (i32.and
    #|        (i32.and
    #|          (i32.and
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT0_TERMINAL_CODE@)) (i32.const 0))
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT0_PAYLOAD@)) (i32.const 128)))
    #|          (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT1_TERMINAL_CODE@)) (i32.const 2)))
    #|        (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT2_TERMINAL_CODE@)) (i32.const 1)))))
    #|
    #|  (core instance $libc (instantiate $libc))
    #|  (core type $start-func-ty (shared (func (param i32))))
    #|  (alias core export $libc "mem" (core memory $mem))
    #|  (alias core export $libc "__indirect_function_table" (core table $indirect-function-table))
    #|
    #|  (core func $thread-spawn-indirect
    #|    (canon thread.spawn-indirect $start-func-ty (table $indirect-function-table)))
    #|
    #|  (core instance $i
    #|    (instantiate $m
    #|      (with "" (instance
    #|        (export "thread.spawn-indirect" (func $thread-spawn-indirect))))
    #|      (with "libc" (instance
    #|        (export "mem" (memory $mem))
    #|        (export "__indirect_function_table" (table $indirect-function-table))))))
    #|
    #|  (func (export "run") async (result u32) (canon lift (core func $i "run"))))
    #|
    #|(assert_return (invoke "run") (u32.const 1))
  render_component_thread_slot_abi_template(wast, abi)
}

///|
/// Generated ComponentModelUnsafeOsThreads Vibe runtime ABI probe. This is the
/// consolidated slot protocol used before wiring real Vibe source lowering:
/// normal completion, failed-as-value, in-flight cooperative cancellation, and
/// parent-side aggregation all flow through trampoline-owned shared slots.
pub fn component_model_unsafe_os_threads_vibe_abi_probe_wast() -> String {
  let abi = component_thread_slot_abi()
  let wast =
    #|;;! threads = true
    #|;;! component_model_async = true
    #|;;! component_model_threading = true
    #|;;! gc = true
    #|;;! function_references = true
    #|;;! shared_everything_threads = true
    #|
    #|;; Fork-local unsafe OS-thread Vibe runtime ABI probe.
    #|;;
    #|;; This consolidates the separate completion/status/cancellation probes into one
    #|;; generated-trampoline shape. The parent drops every canonical
    #|;; `thread.spawn-indirect` return value and observes only trampoline-owned shared
    #|;; slots for join, terminal status, result payloads, failure-as-a-value, and
    #|;; in-flight cooperative cancellation.
    #|
    #|(component
    #|  (core module $libc
    #|    (memory (export "mem") 1 1 shared)
    #|    (table (export "__indirect_function_table") shared 1 1 (ref null (shared func))))
    #|
    #|  (core module $m
    #|    (type $start-func-ty (shared (func (param i32))))
    #|    (type $spawn-indirect-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $slot-addr-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $finish-ty (shared (func (param i32 i32 i32))))
    #|    (type $wait-cancel-ty (shared (func (param i32) (result i32))))
    #|    (type $wait-state-ty (func (param i32 i32) (result i32)))
    #|    (type $run-ty (func (result i32)))
    #|    (import "" "thread.spawn-indirect"
    #|      (func $thread-spawn-indirect (type $spawn-indirect-ty)))
    #|    (import "libc" "mem" (memory $mem 1 1 shared))
    #|    (import "libc" "__indirect_function_table"
    #|      (table $indirect-function-table shared 1 1 (ref null (shared func))))
    #|
    #|    ;; Slot layout, addressed by the context argument:
    #|    ;;   +@VIBE_STATE_OFFSET@: state, 0 = empty, 1 = running, 2 = terminal
    #|    ;;   +@VIBE_TERMINAL_CODE_OFFSET@: terminal code, 0 = completed, 1 = cancelled, 2 = failed
    #|    ;;   +@VIBE_PAYLOAD_OFFSET@: payload, result for completed or error code for failed
    #|    ;;  +@VIBE_INPUT_OFFSET@: input
    #|    ;;  +@VIBE_CANCEL_OFFSET@: cancel request flag
    #|    ;;  +@VIBE_MODE_OFFSET@: mode, 0 = compute, 1 = fail-as-value, 2 = wait-cancel
    #|
    #|    (func $slot-addr (type $slot-addr-ty)
    #|      (i32.add (local.get 0) (local.get 1)))
    #|
    #|    (func $finish (type $finish-ty)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_TERMINAL_CODE_OFFSET@))
    #|        (local.get 1))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_PAYLOAD_OFFSET@))
    #|        (local.get 2))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 2))
    #|      (drop (memory.atomic.notify
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1))))
    #|
    #|    (func $wait-cancel (type $wait-cancel-ty)
    #|      (local $flag i32)
    #|      (local $attempts i32)
    #|      (loop $again
    #|        (local.set $flag
    #|          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_CANCEL_OFFSET@))))
    #|        (if (i32.ne (local.get $flag) (i32.const 0))
    #|          (then
    #|            (return (i32.const 1))))
    #|        (if (i32.ge_u (local.get $attempts) (i32.const 200))
    #|          (then
    #|            (return (i32.const 0))))
    #|        (drop (memory.atomic.wait32
    #|          (call $slot-addr (local.get 0) (i32.const @VIBE_CANCEL_OFFSET@))
    #|          (i32.const 0)
    #|          (i64.const 1000000)))
    #|        (local.set $attempts (i32.add (local.get $attempts) (i32.const 1)))
    #|        (br $again))
    #|      (i32.const 0))
    #|
    #|    (func $thread-trampoline (type $start-func-ty)
    #|      (local $input i32)
    #|      (local $mode i32)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1))
    #|      (drop (memory.atomic.notify
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1)))
    #|
    #|      (if
    #|        (i32.ne
    #|          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_CANCEL_OFFSET@)))
    #|          (i32.const 0))
    #|        (then
    #|          (call $finish (local.get 0) (i32.const 1) (i32.const 0))
    #|          (return)))
    #|
    #|      (local.set $input
    #|        (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_INPUT_OFFSET@))))
    #|      (local.set $mode
    #|        (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_MODE_OFFSET@))))
    #|
    #|      (if (i32.eq (local.get $mode) (i32.const 1))
    #|        (then
    #|          (call $finish
    #|            (local.get 0)
    #|            (i32.const 2)
    #|            (i32.add (i32.const 1000) (local.get $input)))
    #|          (return)))
    #|
    #|      (if (i32.eq (local.get $mode) (i32.const 2))
    #|        (then
    #|          (if (i32.eqz (call $wait-cancel (local.get 0)))
    #|            (then
    #|              (call $finish (local.get 0) (i32.const 2) (i32.const 9000))
    #|              (return)))
    #|          (call $finish (local.get 0) (i32.const 1) (i32.const 0))
    #|          (return)))
    #|
    #|      (call $finish
    #|        (local.get 0)
    #|        (i32.const 0)
    #|        (i32.add
    #|          (i32.mul (local.get $input) (local.get $input))
    #|          (i32.const 7))))
    #|    (export "thread-trampoline" (func $thread-trampoline))
    #|
    #|    (elem (table $indirect-function-table) (i32.const 0)
    #|      (ref null (shared func)) (ref.func $thread-trampoline))
    #|
    #|    (func $wait-state (type $wait-state-ty)
    #|      (local $state i32)
    #|      (local $attempts i32)
    #|      (loop $again
    #|        (local.set $state
    #|          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))))
    #|        (if (i32.eq (local.get $state) (local.get 1))
    #|          (then
    #|            (return (i32.const 1))))
    #|        (if (i32.ge_u (local.get $attempts) (i32.const 200))
    #|          (then
    #|            (return (i32.const 0))))
    #|        (drop (memory.atomic.wait32
    #|          (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|          (local.get $state)
    #|          (i64.const 1000000)))
    #|        (local.set $attempts (i32.add (local.get $attempts) (i32.const 1)))
    #|        (br $again))
    #|      (i32.const 0))
    #|
    #|    (func $init-slot (param $slot i32) (param $input i32) (param $mode i32)
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_STATE_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_TERMINAL_CODE_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_PAYLOAD_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_INPUT_OFFSET@)) (local.get $input))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_CANCEL_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_MODE_OFFSET@)) (local.get $mode)))
    #|
    #|    (func (export "run") (type $run-ty)
    #|      ;; slot 0: completed, input 11, payload 128
    #|      (call $init-slot (i32.const @VIBE_SLOT0@) (i32.const 11) (i32.const 0))
    #|      ;; slot 1: completed, input 5, payload 32
    #|      (call $init-slot (i32.const @VIBE_SLOT1@) (i32.const 5) (i32.const 0))
    #|      ;; slot 2: failed-as-value, input 13, payload 1013
    #|      (call $init-slot (i32.const @VIBE_SLOT2@) (i32.const 13) (i32.const 1))
    #|      ;; slot 3: in-flight cooperative cancellation
    #|      (call $init-slot (i32.const @VIBE_SLOT3@) (i32.const 17) (i32.const 2))
    #|
    #|      ;; The canonical spawn return values are intentionally ignored. Vibe-level
    #|      ;; completion and cancellation are represented by the trampoline slots.
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT0@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT1@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT2@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT3@)))
    #|
    #|      (if (i32.eqz (call $wait-state (i32.const @VIBE_SLOT3@) (i32.const 1)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (i32.atomic.store (i32.const @VIBE_SLOT3_CANCEL@) (i32.const 1))
    #|      (drop (memory.atomic.notify (i32.const @VIBE_SLOT3_CANCEL@) (i32.const 1)))
    #|
    #|      (if (i32.eqz (call $wait-state (i32.const @VIBE_SLOT0@) (i32.const 2)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-state (i32.const @VIBE_SLOT1@) (i32.const 2)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-state (i32.const @VIBE_SLOT2@) (i32.const 2)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-state (i32.const @VIBE_SLOT3@) (i32.const 2)))
    #|        (then
    #|          (return (i32.const 0))))
    #|
    #|      (i32.and
    #|        (i32.and
    #|          (i32.and
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT0_TERMINAL_CODE@)) (i32.const 0))
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT0_PAYLOAD@)) (i32.const 128)))
    #|          (i32.and
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT1_TERMINAL_CODE@)) (i32.const 0))
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT1_PAYLOAD@)) (i32.const 32))))
    #|        (i32.and
    #|          (i32.and
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT2_TERMINAL_CODE@)) (i32.const 2))
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT2_PAYLOAD@)) (i32.const 1013)))
    #|          (i32.and
    #|            (i32.eq (i32.atomic.load (i32.const @VIBE_SLOT3_TERMINAL_CODE@)) (i32.const 1))
    #|            (i32.eq
    #|              (i32.add
    #|                (i32.atomic.load (i32.const @VIBE_SLOT0_PAYLOAD@))
    #|                (i32.atomic.load (i32.const @VIBE_SLOT1_PAYLOAD@)))
    #|              (i32.const 160)))))))
    #|
    #|  (core instance $libc (instantiate $libc))
    #|  (core type $start-func-ty (shared (func (param i32))))
    #|  (alias core export $libc "mem" (core memory $mem))
    #|  (alias core export $libc "__indirect_function_table" (core table $indirect-function-table))
    #|
    #|  (core func $thread-spawn-indirect
    #|    (canon thread.spawn-indirect $start-func-ty (table $indirect-function-table)))
    #|
    #|  (core instance $i
    #|    (instantiate $m
    #|      (with "" (instance
    #|        (export "thread.spawn-indirect" (func $thread-spawn-indirect))))
    #|      (with "libc" (instance
    #|        (export "mem" (memory $mem))
    #|        (export "__indirect_function_table" (table $indirect-function-table))))))
    #|
    #|  (func (export "run") async (result u32) (canon lift (core func $i "run"))))
    #|
    #|(assert_return (invoke "run") (u32.const 1))
  render_component_thread_slot_abi_template(wast, abi)
}

///|
/// Generated fixed-capacity shared channel ABI probe. This is the channel side
/// of the Vibe runtime ABI: parent and worker threads can agree on one
/// atomic ring-buffer layout before normal source lowering is connected.
pub fn component_model_unsafe_os_threads_channel_abi_probe_wast() -> String {
  let abi = shared_thread_channel_abi()
  let wast =
    #|;;! threads = true
    #|;;! component_model_async = true
    #|;;! component_model_threading = true
    #|;;! gc = true
    #|;;! function_references = true
    #|;;! shared_everything_threads = true
    #|
    #|;; Fork-local unsafe OS-thread channel ABI probe.
    #|;;
    #|;; Shared channel layout:
    #|;;  +@VIBE_CHANNEL_LOCK_OFFSET@: lock word, 0 = unlocked, 1 = locked
    #|;;  +@VIBE_CHANNEL_CAPACITY_OFFSET@: fixed ring capacity
    #|;;  +@VIBE_CHANNEL_LENGTH_OFFSET@: current queued payload count
    #|;;  +@VIBE_CHANNEL_HEAD_OFFSET@: next receive index
    #|;;  +@VIBE_CHANNEL_TAIL_OFFSET@: next send index
    #|;;  +@VIBE_CHANNEL_CELLS_OFFSET@: cell buffer base pointer
    #|;;  +@VIBE_CHANNEL_CLOSED_OFFSET@: closed flag
    #|;;  +@VIBE_CHANNEL_SEND_EPOCH_OFFSET@: send epoch
    #|;;  +@VIBE_CHANNEL_RECV_EPOCH_OFFSET@: recv epoch
    #|;; Cell layout:
    #|;;  stride @VIBE_CHANNEL_CELL_SIZE@
    #|;;  +@VIBE_CHANNEL_CELL_VALUE_OFFSET@: i32 tagged Vibe payload
    #|
    #|(component
    #|  (core module $libc
    #|    (memory (export "mem") 1 1 shared))
    #|
    #|  (core module $m
    #|    (type $channel-lock-ty (func (param i32) (result i32)))
    #|    (type $channel-unlock-ty (func (param i32)))
    #|    (type $cell-addr-ty (func (param i32 i32) (result i32)))
    #|    (type $channel-send-ty (func (param i32 i32) (result i32)))
    #|    (type $channel-recv-ty (func (param i32) (result i32)))
    #|    (type $run-ty (func (result i32)))
    #|    (import "libc" "mem" (memory $mem 1 1 shared))
    #|
    #|    (func $channel-lock (type $channel-lock-ty)
    #|      (i32.eqz
    #|        (i32.atomic.rmw.cmpxchg
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LOCK_OFFSET@))
    #|          (i32.const 0)
    #|          (i32.const 1))))
    #|
    #|    (func $channel-unlock (type $channel-unlock-ty)
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LOCK_OFFSET@))
    #|        (i32.const 0))
    #|      (drop (memory.atomic.notify
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LOCK_OFFSET@))
    #|        (i32.const 1))))
    #|
    #|    (func $cell-addr (type $cell-addr-ty)
    #|      (i32.add
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_CELLS_OFFSET@)))
    #|        (i32.add
    #|          (i32.mul (local.get 1) (i32.const @VIBE_CHANNEL_CELL_SIZE@))
    #|          (i32.const @VIBE_CHANNEL_CELL_VALUE_OFFSET@))))
    #|
    #|    (func $channel-send (type $channel-send-ty)
    #|      (local $len i32)
    #|      (local $capacity i32)
    #|      (local $tail i32)
    #|      (if (i32.eqz (call $channel-lock (local.get 0)))
    #|        (then (return (i32.const 0))))
    #|      (local.set $len
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@))))
    #|      (local.set $capacity
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_CAPACITY_OFFSET@))))
    #|      (if (i32.ge_u (local.get $len) (local.get $capacity))
    #|        (then
    #|          (call $channel-unlock (local.get 0))
    #|          (return (i32.const 0))))
    #|      (local.set $tail
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_TAIL_OFFSET@))))
    #|      (i32.atomic.store
    #|        (call $cell-addr (local.get 0) (local.get $tail))
    #|        (local.get 1))
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_TAIL_OFFSET@))
    #|        (i32.rem_u
    #|          (i32.add (local.get $tail) (i32.const 1))
    #|          (local.get $capacity)))
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@))
    #|        (i32.add (local.get $len) (i32.const 1)))
    #|      (drop (i32.atomic.rmw.add
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_SEND_EPOCH_OFFSET@))
    #|        (i32.const 1)))
    #|      (drop (memory.atomic.notify
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_SEND_EPOCH_OFFSET@))
    #|        (i32.const 1)))
    #|      (call $channel-unlock (local.get 0))
    #|      (i32.const 1))
    #|
    #|    (func $channel-recv (type $channel-recv-ty)
    #|      (local $len i32)
    #|      (local $capacity i32)
    #|      (local $head i32)
    #|      (local $value i32)
    #|      (if (i32.eqz (call $channel-lock (local.get 0)))
    #|        (then (return (i32.const 0))))
    #|      (local.set $len
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@))))
    #|      (if (i32.eqz (local.get $len))
    #|        (then
    #|          (call $channel-unlock (local.get 0))
    #|          (return (i32.const 0))))
    #|      (local.set $capacity
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_CAPACITY_OFFSET@))))
    #|      (local.set $head
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_HEAD_OFFSET@))))
    #|      (local.set $value
    #|        (i32.atomic.load (call $cell-addr (local.get 0) (local.get $head))))
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_HEAD_OFFSET@))
    #|        (i32.rem_u
    #|          (i32.add (local.get $head) (i32.const 1))
    #|          (local.get $capacity)))
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@))
    #|        (i32.sub (local.get $len) (i32.const 1)))
    #|      (drop (i32.atomic.rmw.add
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_RECV_EPOCH_OFFSET@))
    #|        (i32.const 1)))
    #|      (drop (memory.atomic.notify
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_RECV_EPOCH_OFFSET@))
    #|        (i32.const 1)))
    #|      (call $channel-unlock (local.get 0))
    #|      (local.get $value))
    #|
    #|    (func (export "run") (type $run-ty)
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_LOCK@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_CAPACITY@) (i32.const 2))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_LENGTH@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_HEAD@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_TAIL@) (i32.const 0))
    #|      (i32.atomic.store
    #|        (i32.const @VIBE_CHANNEL0_CELLS@)
    #|        (i32.const @VIBE_CHANNEL0_CELLS_BASE@))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_CLOSED@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_SEND_EPOCH@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_RECV_EPOCH@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_CELL0_VALUE@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_CELL1_VALUE@) (i32.const 0))
    #|
    #|      (if (i32.eqz (call $channel-send (i32.const @VIBE_CHANNEL0@) (i32.const 11)))
    #|        (then (return (i32.const 0))))
    #|      (if (i32.eqz (call $channel-send (i32.const @VIBE_CHANNEL0@) (i32.const 22)))
    #|        (then (return (i32.const 0))))
    #|      (if (call $channel-send (i32.const @VIBE_CHANNEL0@) (i32.const 33))
    #|        (then (return (i32.const 0))))
    #|      (if (i32.ne (call $channel-recv (i32.const @VIBE_CHANNEL0@)) (i32.const 11))
    #|        (then (return (i32.const 0))))
    #|      (if (i32.eqz (call $channel-send (i32.const @VIBE_CHANNEL0@) (i32.const 33)))
    #|        (then (return (i32.const 0))))
    #|      (if (i32.ne (call $channel-recv (i32.const @VIBE_CHANNEL0@)) (i32.const 22))
    #|        (then (return (i32.const 0))))
    #|      (if (i32.ne (call $channel-recv (i32.const @VIBE_CHANNEL0@)) (i32.const 33))
    #|        (then (return (i32.const 0))))
    #|      (if (call $channel-recv (i32.const @VIBE_CHANNEL0@))
    #|        (then (return (i32.const 0))))
    #|      (i32.const 1)))
    #|
    #|  (core instance $libc (instantiate $libc))
    #|  (alias core export $libc "mem" (core memory $mem))
    #|  (core instance $i
    #|    (instantiate $m
    #|      (with "libc" (instance
    #|        (export "mem" (memory $mem))))))
    #|
    #|  (func (export "run") async (result u32) (canon lift (core func $i "run"))))
    #|
    #|(assert_return (invoke "run") (u32.const 1))
  render_shared_thread_channel_abi_template(wast, abi)
}

///|
/// Generated shared channel ABI probe connected to actual unsafe OS-thread
/// workers. The parent still joins through Vibe-owned slots, while worker
/// trampolines publish their payloads through the fixed-capacity shared channel.
pub fn component_model_unsafe_os_threads_channel_spawn_abi_probe_wast() -> String {
  let slot_abi = component_thread_slot_abi()
  let channel_abi = shared_thread_channel_abi()
  let wast =
    #|;;! threads = true
    #|;;! component_model_async = true
    #|;;! component_model_threading = true
    #|;;! gc = true
    #|;;! function_references = true
    #|;;! shared_everything_threads = true
    #|
    #|;; Fork-local unsafe OS-thread channel spawn ABI probe.
    #|;;
    #|;; This connects the Vibe slot ABI and fixed-capacity shared channel ABI:
    #|;; worker trampolines are spawned with `thread.spawn-indirect`, publish one
    #|;; payload through the shared channel, then complete their Vibe-owned slot.
    #|;; The parent ignores canonical spawn return values, waits for terminal slots,
    #|;; and receives the worker payloads from the channel.
    #|
    #|(component
    #|  (core module $libc
    #|    (memory (export "mem") 1 1 shared)
    #|    (table (export "__indirect_function_table") shared 1 1 (ref null (shared func))))
    #|
    #|  (core module $m
    #|    (type $start-func-ty (shared (func (param i32))))
    #|    (type $spawn-indirect-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $slot-addr-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $finish-ty (shared (func (param i32 i32 i32))))
    #|    (type $channel-lock-ty (shared (func (param i32) (result i32))))
    #|    (type $channel-unlock-ty (shared (func (param i32))))
    #|    (type $cell-addr-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $channel-send-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $channel-recv-ty (shared (func (param i32) (result i32))))
    #|    (type $wait-terminal-ty (func (param i32) (result i32)))
    #|    (type $run-ty (func (result i32)))
    #|    (import "" "thread.spawn-indirect"
    #|      (func $thread-spawn-indirect (type $spawn-indirect-ty)))
    #|    (import "libc" "mem" (memory $mem 1 1 shared))
    #|    (import "libc" "__indirect_function_table"
    #|      (table $indirect-function-table shared 1 1 (ref null (shared func))))
    #|
    #|    ;; Slot layout:
    #|    ;;   +@VIBE_STATE_OFFSET@: state, 0 = empty, 1 = running, 2 = terminal
    #|    ;;   +@VIBE_TERMINAL_CODE_OFFSET@: terminal code, 0 = completed, 1 = cancelled, 2 = failed
    #|    ;;   +@VIBE_PAYLOAD_OFFSET@: payload
    #|    ;;  +@VIBE_INPUT_OFFSET@: input
    #|    ;;  +@VIBE_CANCEL_OFFSET@: cancel request flag
    #|    ;;  +@VIBE_MODE_OFFSET@: mode
    #|
    #|    ;; Shared channel layout:
    #|    ;;  +@VIBE_CHANNEL_LOCK_OFFSET@: lock word, 0 = unlocked, 1 = locked
    #|    ;;  +@VIBE_CHANNEL_CAPACITY_OFFSET@: fixed ring capacity
    #|    ;;  +@VIBE_CHANNEL_LENGTH_OFFSET@: current queued payload count
    #|    ;;  +@VIBE_CHANNEL_HEAD_OFFSET@: next receive index
    #|    ;;  +@VIBE_CHANNEL_TAIL_OFFSET@: next send index
    #|    ;;  +@VIBE_CHANNEL_CELLS_OFFSET@: cell buffer base pointer
    #|    ;;  +@VIBE_CHANNEL_SEND_EPOCH_OFFSET@: send epoch
    #|    ;;  +@VIBE_CHANNEL_RECV_EPOCH_OFFSET@: recv epoch
    #|
    #|    (func $slot-addr (type $slot-addr-ty)
    #|      (i32.add (local.get 0) (local.get 1)))
    #|
    #|    (func $finish (type $finish-ty)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_TERMINAL_CODE_OFFSET@))
    #|        (local.get 1))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_PAYLOAD_OFFSET@))
    #|        (local.get 2))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 2))
    #|      (drop (memory.atomic.notify
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1))))
    #|
    #|    (func $channel-lock (type $channel-lock-ty)
    #|      (i32.eqz
    #|        (i32.atomic.rmw.cmpxchg
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LOCK_OFFSET@))
    #|          (i32.const 0)
    #|          (i32.const 1))))
    #|
    #|    (func $channel-unlock (type $channel-unlock-ty)
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LOCK_OFFSET@))
    #|        (i32.const 0))
    #|      (drop (memory.atomic.notify
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LOCK_OFFSET@))
    #|        (i32.const 1))))
    #|
    #|    (func $cell-addr (type $cell-addr-ty)
    #|      (i32.add
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_CELLS_OFFSET@)))
    #|        (i32.add
    #|          (i32.mul (local.get 1) (i32.const @VIBE_CHANNEL_CELL_SIZE@))
    #|          (i32.const @VIBE_CHANNEL_CELL_VALUE_OFFSET@))))
    #|
    #|    (func $channel-send (type $channel-send-ty)
    #|      (local $len i32)
    #|      (local $capacity i32)
    #|      (local $tail i32)
    #|      (if (i32.eqz (call $channel-lock (local.get 0)))
    #|        (then (return (i32.const 0))))
    #|      (local.set $len
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@))))
    #|      (local.set $capacity
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_CAPACITY_OFFSET@))))
    #|      (if (i32.ge_u (local.get $len) (local.get $capacity))
    #|        (then
    #|          (call $channel-unlock (local.get 0))
    #|          (return (i32.const 0))))
    #|      (local.set $tail
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_TAIL_OFFSET@))))
    #|      (i32.atomic.store
    #|        (call $cell-addr (local.get 0) (local.get $tail))
    #|        (local.get 1))
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_TAIL_OFFSET@))
    #|        (i32.rem_u
    #|          (i32.add (local.get $tail) (i32.const 1))
    #|          (local.get $capacity)))
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@))
    #|        (i32.add (local.get $len) (i32.const 1)))
    #|      (drop (i32.atomic.rmw.add
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_SEND_EPOCH_OFFSET@))
    #|        (i32.const 1)))
    #|      (drop (memory.atomic.notify
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_SEND_EPOCH_OFFSET@))
    #|        (i32.const 1)))
    #|      (call $channel-unlock (local.get 0))
    #|      (i32.const 1))
    #|
    #|    (func $channel-recv (type $channel-recv-ty)
    #|      (local $len i32)
    #|      (local $capacity i32)
    #|      (local $head i32)
    #|      (local $value i32)
    #|      (if (i32.eqz (call $channel-lock (local.get 0)))
    #|        (then (return (i32.const 0))))
    #|      (local.set $len
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@))))
    #|      (if (i32.eqz (local.get $len))
    #|        (then
    #|          (call $channel-unlock (local.get 0))
    #|          (return (i32.const 0))))
    #|      (local.set $capacity
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_CAPACITY_OFFSET@))))
    #|      (local.set $head
    #|        (i32.atomic.load
    #|          (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_HEAD_OFFSET@))))
    #|      (local.set $value
    #|        (i32.atomic.load (call $cell-addr (local.get 0) (local.get $head))))
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_HEAD_OFFSET@))
    #|        (i32.rem_u
    #|          (i32.add (local.get $head) (i32.const 1))
    #|          (local.get $capacity)))
    #|      (i32.atomic.store
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@))
    #|        (i32.sub (local.get $len) (i32.const 1)))
    #|      (drop (i32.atomic.rmw.add
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_RECV_EPOCH_OFFSET@))
    #|        (i32.const 1)))
    #|      (drop (memory.atomic.notify
    #|        (i32.add (local.get 0) (i32.const @VIBE_CHANNEL_RECV_EPOCH_OFFSET@))
    #|        (i32.const 1)))
    #|      (call $channel-unlock (local.get 0))
    #|      (local.get $value))
    #|
    #|    (func $thread-trampoline (type $start-func-ty)
    #|      (local $input i32)
    #|      (local $payload i32)
    #|      (local $attempts i32)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1))
    #|      (drop (memory.atomic.notify
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1)))
    #|      (local.set $input
    #|        (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_INPUT_OFFSET@))))
    #|      (local.set $payload
    #|        (i32.add
    #|          (i32.mul (local.get $input) (i32.const 10))
    #|          (i32.const 7)))
    #|      (loop $retry-send
    #|        (if (call $channel-send (i32.const @VIBE_CHANNEL0@) (local.get $payload))
    #|          (then
    #|            (call $finish (local.get 0) (i32.const 0) (local.get $payload))
    #|            (return)))
    #|        (if (i32.ge_u (local.get $attempts) (i32.const 200))
    #|          (then
    #|            (call $finish (local.get 0) (i32.const 2) (i32.const 9000))
    #|            (return)))
    #|        (drop (memory.atomic.wait32
    #|          (i32.const @VIBE_CHANNEL0_LOCK@)
    #|          (i32.const 1)
    #|          (i64.const 1000000)))
    #|        (local.set $attempts (i32.add (local.get $attempts) (i32.const 1)))
    #|        (br $retry-send)))
    #|    (export "thread-trampoline" (func $thread-trampoline))
    #|
    #|    (elem (table $indirect-function-table) (i32.const 0)
    #|      (ref null (shared func)) (ref.func $thread-trampoline))
    #|
    #|    (func $init-slot (param $slot i32) (param $input i32)
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_STATE_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_TERMINAL_CODE_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_PAYLOAD_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_INPUT_OFFSET@)) (local.get $input))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_CANCEL_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_MODE_OFFSET@)) (i32.const 0)))
    #|
    #|    (func $init-channel (param $channel i32) (param $cells i32) (param $capacity i32)
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_LOCK_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_CAPACITY_OFFSET@)) (local.get $capacity))
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_LENGTH_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_HEAD_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_TAIL_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_CELLS_OFFSET@)) (local.get $cells))
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_CLOSED_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_SEND_EPOCH_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (i32.add (local.get $channel) (i32.const @VIBE_CHANNEL_RECV_EPOCH_OFFSET@)) (i32.const 0)))
    #|
    #|    (func $wait-terminal (type $wait-terminal-ty)
    #|      (local $state i32)
    #|      (local $attempts i32)
    #|      (loop $again
    #|        (local.set $state
    #|          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))))
    #|        (if (i32.eq (local.get $state) (i32.const 2))
    #|          (then
    #|            (return (i32.const 1))))
    #|        (if (i32.ge_u (local.get $attempts) (i32.const 1000))
    #|          (then
    #|            (return (i32.const 0))))
    #|        (drop (memory.atomic.wait32
    #|          (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|          (local.get $state)
    #|          (i64.const 1000000)))
    #|        (local.set $attempts (i32.add (local.get $attempts) (i32.const 1)))
    #|        (br $again))
    #|      (i32.const 0))
    #|
    #|    (func (export "run") (type $run-ty)
    #|      (local $a i32)
    #|      (local $b i32)
    #|      (call $init-slot (i32.const @VIBE_SLOT0@) (i32.const 1))
    #|      (call $init-slot (i32.const @VIBE_SLOT1@) (i32.const 2))
    #|      (call $init-channel
    #|        (i32.const @VIBE_CHANNEL0@)
    #|        (i32.const @VIBE_CHANNEL0_CELLS_BASE@)
    #|        (i32.const 2))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_CELL0_VALUE@) (i32.const 0))
    #|      (i32.atomic.store (i32.const @VIBE_CHANNEL0_CELL1_VALUE@) (i32.const 0))
    #|
    #|      ;; The canonical spawn return values are intentionally ignored.
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT0@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT1@)))
    #|
    #|      (if (i32.eqz (call $wait-terminal (i32.const @VIBE_SLOT0@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-terminal (i32.const @VIBE_SLOT1@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if
    #|        (i32.or
    #|          (i32.atomic.load (i32.const @VIBE_SLOT0_TERMINAL_CODE@))
    #|          (i32.atomic.load (i32.const @VIBE_SLOT1_TERMINAL_CODE@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if
    #|        (i32.ne
    #|          (i32.add
    #|            (i32.atomic.load (i32.const @VIBE_SLOT0_PAYLOAD@))
    #|            (i32.atomic.load (i32.const @VIBE_SLOT1_PAYLOAD@)))
    #|          (i32.const 44))
    #|        (then
    #|          (return (i32.const 0))))
    #|
    #|      (local.set $a (call $channel-recv (i32.const @VIBE_CHANNEL0@)))
    #|      (local.set $b (call $channel-recv (i32.const @VIBE_CHANNEL0@)))
    #|      (if (i32.ne (i32.add (local.get $a) (local.get $b)) (i32.const 44))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (call $channel-recv (i32.const @VIBE_CHANNEL0@))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (i32.const 1)))
    #|
    #|  (core instance $libc (instantiate $libc))
    #|  (core type $start-func-ty (shared (func (param i32))))
    #|  (alias core export $libc "mem" (core memory $mem))
    #|  (alias core export $libc "__indirect_function_table" (core table $indirect-function-table))
    #|
    #|  (core func $thread-spawn-indirect
    #|    (canon thread.spawn-indirect $start-func-ty (table $indirect-function-table)))
    #|
    #|  (core instance $i
    #|    (instantiate $m
    #|      (with "" (instance
    #|        (export "thread.spawn-indirect" (func $thread-spawn-indirect))))
    #|      (with "libc" (instance
    #|        (export "mem" (memory $mem))
    #|        (export "__indirect_function_table" (table $indirect-function-table))))))
    #|
    #|  (func (export "run") async (result u32) (canon lift (core func $i "run"))))
    #|
    #|(assert_return (invoke "run") (u32.const 1))
  render_shared_thread_channel_abi_template(
    render_component_thread_slot_abi_template(wast, slot_abi),
    channel_abi,
  )
}

///|
pub fn component_model_unsafe_os_threads_vibe_abi_speedup_serial_wast() -> String {
  let abi = component_thread_slot_abi()
  let wast =
    #|;;! threads = true
    #|;;! component_model_async = true
    #|;;! component_model_threading = true
    #|;;! gc = true
    #|;;! function_references = true
    #|;;! shared_everything_threads = true
    #|
    #|;; Fork-local Vibe runtime ABI serial speedup baseline.
    #|;;
    #|;; This uses the same slot ABI as the parallel trampoline probe but executes the
    #|;; CPU work sequentially in the parent component thread. It is the baseline for
    #|;; the ABI-shaped OS-thread speedup probe.
    #|
    #|(component
    #|  (core module $libc
    #|    (memory (export "mem") 1 1 shared)
    #|    (table (export "__indirect_function_table") shared 1 1 (ref null (shared func))))
    #|
    #|  (core module $m
    #|    (type $start-func-ty (shared (func (param i32))))
    #|    (type $spawn-indirect-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $slot-addr-ty (func (param i32 i32) (result i32)))
    #|    (type $finish-ty (func (param i32 i32 i32)))
    #|    (type $work-ty (func (param i32) (result i32)))
    #|    (type $sum-payloads-ty (func (result i32)))
    #|    (type $run-ty (func (result i32)))
    #|    (import "" "thread.spawn-indirect"
    #|      (func $thread-spawn-indirect (type $spawn-indirect-ty)))
    #|    (import "libc" "mem" (memory $mem 1 1 shared))
    #|    (import "libc" "__indirect_function_table"
    #|      (table $indirect-function-table shared 1 1 (ref null (shared func))))
    #|
    #|    ;; Slot layout:
    #|    ;;   +@VIBE_STATE_OFFSET@: state, 0 = empty, 1 = running, 2 = terminal
    #|    ;;   +@VIBE_TERMINAL_CODE_OFFSET@: terminal code, 0 = completed, 1 = cancelled, 2 = failed
    #|    ;;   +@VIBE_PAYLOAD_OFFSET@: payload
    #|    ;;  +@VIBE_INPUT_OFFSET@: input
    #|    ;;  +@VIBE_CANCEL_OFFSET@: cancel request flag
    #|    ;;  +@VIBE_MODE_OFFSET@: mode
    #|
    #|    (func $slot-addr (type $slot-addr-ty)
    #|      (i32.add (local.get 0) (local.get 1)))
    #|
    #|    (func $finish (type $finish-ty)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_TERMINAL_CODE_OFFSET@))
    #|        (local.get 1))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_PAYLOAD_OFFSET@))
    #|        (local.get 2))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 2)))
    #|
    #|    (func $work (type $work-ty)
    #|      (local $i i32)
    #|      (local $x i32)
    #|      (local.set $x (i32.add (local.get 0) (i32.const 1)))
    #|      (loop $again
    #|        (local.set $x
    #|          (i32.add
    #|            (i32.mul
    #|              (local.get $x)
    #|              (i32.const 1664525))
    #|            (i32.const 1013904223)))
    #|        (local.set $i (i32.add (local.get $i) (i32.const 1)))
    #|        (br_if $again (i32.lt_u (local.get $i) (i32.const 50000000))))
    #|      (local.get $x))
    #|
    #|    (func $thread-start (type $start-func-ty)
    #|      unreachable)
    #|    (export "thread-start" (func $thread-start))
    #|
    #|    (elem (table $indirect-function-table) (i32.const 0)
    #|      (ref null (shared func)) (ref.func $thread-start))
    #|
    #|    (func $init-slot (param $slot i32) (param $input i32)
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_STATE_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_TERMINAL_CODE_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_PAYLOAD_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_INPUT_OFFSET@)) (local.get $input))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_CANCEL_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_MODE_OFFSET@)) (i32.const 0)))
    #|
    #|    (func $sum-payloads (type $sum-payloads-ty)
    #|      (i32.add
    #|        (i32.add
    #|          (i32.atomic.load (i32.const @VIBE_SLOT0_PAYLOAD@))
    #|          (i32.atomic.load (i32.const @VIBE_SLOT1_PAYLOAD@)))
    #|        (i32.add
    #|          (i32.atomic.load (i32.const @VIBE_SLOT2_PAYLOAD@))
    #|          (i32.atomic.load (i32.const @VIBE_SLOT3_PAYLOAD@)))))
    #|
    #|    (func (export "serial") (type $run-ty)
    #|      (call $init-slot (i32.const @VIBE_SLOT0@) (i32.const 0))
    #|      (call $init-slot (i32.const @VIBE_SLOT1@) (i32.const 1))
    #|      (call $init-slot (i32.const @VIBE_SLOT2@) (i32.const 2))
    #|      (call $init-slot (i32.const @VIBE_SLOT3@) (i32.const 3))
    #|
    #|      (call $finish (i32.const @VIBE_SLOT0@) (i32.const 0) (call $work (i32.const 0)))
    #|      (call $finish (i32.const @VIBE_SLOT1@) (i32.const 0) (call $work (i32.const 1)))
    #|      (call $finish (i32.const @VIBE_SLOT2@) (i32.const 0) (call $work (i32.const 2)))
    #|      (call $finish (i32.const @VIBE_SLOT3@) (i32.const 0) (call $work (i32.const 3)))
    #|      (call $sum-payloads)))
    #|
    #|  (core instance $libc (instantiate $libc))
    #|  (core type $start-func-ty (shared (func (param i32))))
    #|  (alias core export $libc "mem" (core memory $mem))
    #|  (alias core export $libc "__indirect_function_table" (core table $indirect-function-table))
    #|
    #|  (core func $thread-spawn-indirect
    #|    (canon thread.spawn-indirect $start-func-ty (table $indirect-function-table)))
    #|
    #|  (core instance $i
    #|    (instantiate $m
    #|      (with "" (instance
    #|        (export "thread.spawn-indirect" (func $thread-spawn-indirect))))
    #|      (with "libc" (instance
    #|        (export "mem" (memory $mem))
    #|        (export "__indirect_function_table" (table $indirect-function-table))))))
    #|
    #|  (func (export "serial") async (result u32) (canon lift (core func $i "serial"))))
    #|
    #|(assert_return (invoke "serial") (u32.const 1106140682))
  render_component_thread_slot_abi_template(wast, abi)
}

///|
pub fn component_model_unsafe_os_threads_vibe_abi_speedup_parallel_wast() -> String {
  let abi = component_thread_slot_abi()
  let wast =
    #|;;! threads = true
    #|;;! component_model_async = true
    #|;;! component_model_threading = true
    #|;;! gc = true
    #|;;! function_references = true
    #|;;! shared_everything_threads = true
    #|
    #|;; Fork-local unsafe OS-thread Vibe runtime ABI parallel speedup probe.
    #|;;
    #|;; This uses the consolidated Vibe slot ABI while splitting the same four-slot
    #|;; CPU workload across `thread.spawn-indirect` children.
    #|
    #|(component
    #|  (core module $libc
    #|    (memory (export "mem") 1 1 shared)
    #|    (table (export "__indirect_function_table") shared 1 1 (ref null (shared func))))
    #|
    #|  (core module $m
    #|    (type $start-func-ty (shared (func (param i32))))
    #|    (type $spawn-indirect-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $available-parallelism-ty (shared (func (result i32))))
    #|    (type $slot-addr-ty (shared (func (param i32 i32) (result i32))))
    #|    (type $finish-ty (shared (func (param i32 i32 i32))))
    #|    (type $work-ty (shared (func (param i32) (result i32))))
    #|    (type $wait-terminal-ty (func (param i32) (result i32)))
    #|    (type $sum-payloads-ty (func (result i32)))
    #|    (type $run-ty (func (result i32)))
    #|    (import "" "thread.spawn-indirect"
    #|      (func $thread-spawn-indirect (type $spawn-indirect-ty)))
    #|    (import "" "thread.available-parallelism"
    #|      (func $thread-available-parallelism (type $available-parallelism-ty)))
    #|    (import "libc" "mem" (memory $mem 1 1 shared))
    #|    (import "libc" "__indirect_function_table"
    #|      (table $indirect-function-table shared 1 1 (ref null (shared func))))
    #|
    #|    ;; Slot layout:
    #|    ;;   +@VIBE_STATE_OFFSET@: state, 0 = empty, 1 = running, 2 = terminal
    #|    ;;   +@VIBE_TERMINAL_CODE_OFFSET@: terminal code, 0 = completed, 1 = cancelled, 2 = failed
    #|    ;;   +@VIBE_PAYLOAD_OFFSET@: payload
    #|    ;;  +@VIBE_INPUT_OFFSET@: input
    #|    ;;  +@VIBE_CANCEL_OFFSET@: cancel request flag
    #|    ;;  +@VIBE_MODE_OFFSET@: mode
    #|
    #|    (func $slot-addr (type $slot-addr-ty)
    #|      (i32.add (local.get 0) (local.get 1)))
    #|
    #|    (func $finish (type $finish-ty)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_TERMINAL_CODE_OFFSET@))
    #|        (local.get 1))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_PAYLOAD_OFFSET@))
    #|        (local.get 2))
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 2))
    #|      (drop (memory.atomic.notify
    #|        (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|        (i32.const 1))))
    #|
    #|    (func $work (type $work-ty)
    #|      (local $i i32)
    #|      (local $x i32)
    #|      (local.set $x (i32.add (local.get 0) (i32.const 1)))
    #|      (loop $again
    #|        (local.set $x
    #|          (i32.add
    #|            (i32.mul
    #|              (local.get $x)
    #|              (i32.const 1664525))
    #|            (i32.const 1013904223)))
    #|        (local.set $i (i32.add (local.get $i) (i32.const 1)))
    #|        (br_if $again (i32.lt_u (local.get $i) (i32.const 50000000))))
    #|      (local.get $x))
    #|
    #|    (func $thread-trampoline (type $start-func-ty)
    #|      (local $input i32)
    #|      (i32.atomic.store
    #|        (call $slot-addr (local.get 0) (i32.const 0))
    #|        (i32.const 1))
    #|      (local.set $input
    #|        (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_INPUT_OFFSET@))))
    #|      (call $finish
    #|        (local.get 0)
    #|        (i32.const 0)
    #|        (call $work (local.get $input))))
    #|    (export "thread-trampoline" (func $thread-trampoline))
    #|
    #|    (elem (table $indirect-function-table) (i32.const 0)
    #|      (ref null (shared func)) (ref.func $thread-trampoline))
    #|
    #|    (func $init-slot (param $slot i32) (param $input i32)
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_STATE_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_TERMINAL_CODE_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_PAYLOAD_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_INPUT_OFFSET@)) (local.get $input))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_CANCEL_OFFSET@)) (i32.const 0))
    #|      (i32.atomic.store (call $slot-addr (local.get $slot) (i32.const @VIBE_MODE_OFFSET@)) (i32.const 0)))
    #|
    #|    (func $wait-terminal (type $wait-terminal-ty)
    #|      (local $state i32)
    #|      (local $attempts i32)
    #|      (loop $again
    #|        (local.set $state
    #|          (i32.atomic.load (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))))
    #|        (if (i32.eq (local.get $state) (i32.const 2))
    #|          (then
    #|            (return (i32.const 1))))
    #|        (if (i32.ge_u (local.get $attempts) (i32.const 1000))
    #|          (then
    #|            (return (i32.const 0))))
    #|        (drop (memory.atomic.wait32
    #|          (call $slot-addr (local.get 0) (i32.const @VIBE_STATE_OFFSET@))
    #|          (local.get $state)
    #|          (i64.const 1000000)))
    #|        (local.set $attempts (i32.add (local.get $attempts) (i32.const 1)))
    #|        (br $again))
    #|      (i32.const 0))
    #|
    #|    (func $sum-payloads (type $sum-payloads-ty)
    #|      (i32.add
    #|        (i32.add
    #|          (i32.atomic.load (i32.const @VIBE_SLOT0_PAYLOAD@))
    #|          (i32.atomic.load (i32.const @VIBE_SLOT1_PAYLOAD@)))
    #|        (i32.add
    #|          (i32.atomic.load (i32.const @VIBE_SLOT2_PAYLOAD@))
    #|          (i32.atomic.load (i32.const @VIBE_SLOT3_PAYLOAD@)))))
    #|
    #|    (func (export "available-positive") (type $run-ty)
    #|      (i32.gt_u (call $thread-available-parallelism) (i32.const 0)))
    #|
    #|    (func (export "parallel") (type $run-ty)
    #|      (call $init-slot (i32.const @VIBE_SLOT0@) (i32.const 0))
    #|      (call $init-slot (i32.const @VIBE_SLOT1@) (i32.const 1))
    #|      (call $init-slot (i32.const @VIBE_SLOT2@) (i32.const 2))
    #|      (call $init-slot (i32.const @VIBE_SLOT3@) (i32.const 3))
    #|
    #|      ;; The canonical spawn return values are intentionally ignored.
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT0@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT1@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT2@)))
    #|      (drop (call $thread-spawn-indirect (i32.const 0) (i32.const @VIBE_SLOT3@)))
    #|
    #|      (if (i32.eqz (call $wait-terminal (i32.const @VIBE_SLOT0@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-terminal (i32.const @VIBE_SLOT1@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-terminal (i32.const @VIBE_SLOT2@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|      (if (i32.eqz (call $wait-terminal (i32.const @VIBE_SLOT3@)))
    #|        (then
    #|          (return (i32.const 0))))
    #|
    #|      (if
    #|        (i32.or
    #|          (i32.or
    #|            (i32.atomic.load (i32.const @VIBE_SLOT0_TERMINAL_CODE@))
    #|            (i32.atomic.load (i32.const @VIBE_SLOT1_TERMINAL_CODE@)))
    #|          (i32.or
    #|            (i32.atomic.load (i32.const @VIBE_SLOT2_TERMINAL_CODE@))
    #|            (i32.atomic.load (i32.const @VIBE_SLOT3_TERMINAL_CODE@))))
    #|        (then
    #|          (return (i32.const 0))))
    #|
    #|      (call $sum-payloads)))
    #|
    #|  (core instance $libc (instantiate $libc))
    #|  (core type $start-func-ty (shared (func (param i32))))
    #|  (alias core export $libc "mem" (core memory $mem))
    #|  (alias core export $libc "__indirect_function_table" (core table $indirect-function-table))
    #|
    #|  (core func $thread-spawn-indirect
    #|    (canon thread.spawn-indirect $start-func-ty (table $indirect-function-table)))
    #|  (core func $thread-available-parallelism
    #|    (canon thread.available_parallelism))
    #|
    #|  (core instance $i
    #|    (instantiate $m
    #|      (with "" (instance
    #|        (export "thread.spawn-indirect" (func $thread-spawn-indirect))
    #|        (export "thread.available-parallelism" (func $thread-available-parallelism))))
    #|      (with "libc" (instance
    #|        (export "mem" (memory $mem))
    #|        (export "__indirect_function_table" (table $indirect-function-table))))))
    #|
    #|  (func (export "available-positive") async (result u32)
    #|    (canon lift (core func $i "available-positive")))
    #|  (func (export "parallel") async (result u32)
    #|    (canon lift (core func $i "parallel"))))
    #|
    #|(assert_return (invoke "available-positive") (u32.const 1))
    #|(assert_return (invoke "parallel") (u32.const 1106140682))
  render_component_thread_slot_abi_template(wast, abi)
}
