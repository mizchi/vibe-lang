///|
/// Execution backends that the experimental thread layer can target.
/// Keep these names stable: the Wasmtime fork milestones are mapped to this
/// semantic contract instead of to a specific low-level instruction spelling.
pub(all) enum ThreadBackend {
  SerialOnly
  WasiThreads
  ComponentModelCooperative
  ComponentModelShared
} derive(Debug, Eq)

///|
/// The observable scheduling contract of a backend.
pub(all) enum ThreadSpawnSemantics {
  NoSpawn
  Cooperative
  PreemptiveParallel
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
pub fn all_thread_backends() -> Array[ThreadBackend] {
  [
    SerialOnly,
    WasiThreads,
    ComponentModelCooperative,
    ComponentModelShared,
  ]
}

///|
pub fn thread_backend_id(backend : ThreadBackend) -> String {
  match backend {
    SerialOnly => "serial"
    WasiThreads => "wasi-threads"
    ComponentModelCooperative => "component-cooperative"
    ComponentModelShared => "component-shared"
  }
}

///|
pub fn thread_backend_spawn_semantics(
  backend : ThreadBackend
) -> ThreadSpawnSemantics {
  match backend {
    SerialOnly => NoSpawn
    ComponentModelCooperative => Cooperative
    WasiThreads | ComponentModelShared => PreemptiveParallel
  }
}

///|
pub fn thread_backend_can_claim_parallel_speedup(
  backend : ThreadBackend
) -> Bool {
  thread_backend_spawn_semantics(backend) == PreemptiveParallel
}

///|
pub fn thread_backend_available_parallelism_semantics(
  backend : ThreadBackend
) -> String {
  match backend {
    SerialOnly | ComponentModelCooperative => "always-one"
    WasiThreads | ComponentModelShared => "host-available-parallelism"
  }
}

///|
pub fn thread_backend_wasm_flags(backend : ThreadBackend) -> Array[String] {
  match backend {
    SerialOnly => []
    WasiThreads => recommended_wasm_flags()
    ComponentModelCooperative => component_model_threading_wasm_flags()
    ComponentModelShared => shared_everything_component_wasm_flags()
  }
}

///|
pub fn thread_backend_wasi_flags(backend : ThreadBackend) -> Array[String] {
  match backend {
    SerialOnly | ComponentModelCooperative | ComponentModelShared => []
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
  ["component-model=y", "component-model-async=y", "component-model-threading=y"]
}

///|
pub fn component_model_threading_wasi_flags() -> Array[String] {
  []
}

///|
pub fn shared_everything_component_wasm_flags() -> Array[String] {
  [
    "component-model=y",
    "component-model-async=y",
    "component-model-threading=y",
    "gc=y",
    "function-references=y",
    "shared-everything-threads=y",
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
