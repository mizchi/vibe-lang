(module
  (import "env" "memory" (memory 1 1 shared))
  (import "wasi" "thread-spawn" (func $thread_spawn (param i32) (result i32)))

  ;; shared slots
  ;; 0: done counter (i32)
  ;; 64,68,72,76: per-worker checksums (i32)

  (global $iterations i32 (i32.const 60000000))

  (func $compute (param $seed i32) (result i32)
    (local $i i32)
    (local $x i32)

    local.get $seed
    local.set $x

    loop $loop
      local.get $x
      i32.const 1664525
      i32.mul
      i32.const 1013904223
      i32.add
      local.get $i
      i32.add
      local.set $x

      local.get $i
      i32.const 1
      i32.add
      local.tee $i
      global.get $iterations
      i32.lt_u
      br_if $loop
    end

    local.get $x)

  (func $reset
    i32.const 0
    i32.const 0
    i32.store
    i32.const 64
    i32.const 0
    i32.store
    i32.const 68
    i32.const 0
    i32.store
    i32.const 72
    i32.const 0
    i32.store
    i32.const 76
    i32.const 0
    i32.store)

  (func $compute_chunk (param $worker i32)
    i32.const 64
    local.get $worker
    i32.const 4
    i32.mul
    i32.add
    local.get $worker
    i32.const 1
    i32.add
    call $compute
    i32.store

    i32.const 0
    i32.const 1
    i32.atomic.rmw.add
    drop

    i32.const 0
    i32.const 1
    memory.atomic.notify
    drop)

  (func $spawn_worker (param $worker i32)
    local.get $worker
    call $thread_spawn
    i32.const 0
    i32.lt_s
    if
      unreachable
    end)

  (func (export "wasi_thread_start") (param $tid i32) (param $start_arg i32)
    local.get $start_arg
    call $compute_chunk)

  (func $combine (result i32)
    i32.const 64
    i32.load
    i32.const 68
    i32.load
    i32.xor
    i32.const 72
    i32.load
    i32.xor
    i32.const 76
    i32.load
    i32.xor)

  (func $serial (export "serial") (result i32)
    call $reset
    i32.const 0
    call $compute_chunk
    i32.const 1
    call $compute_chunk
    i32.const 2
    call $compute_chunk
    i32.const 3
    call $compute_chunk
    call $combine)

  (func $parallel (export "parallel") (result i32)
    (local $seen i32)

    call $reset

    i32.const 0
    call $spawn_worker
    i32.const 1
    call $spawn_worker
    i32.const 2
    call $spawn_worker
    i32.const 3
    call $spawn_worker

    block $done
      loop $wait
        i32.const 0
        i32.atomic.load
        local.tee $seen
        i32.const 4
        i32.ge_u
        br_if $done

        i32.const 0
        local.get $seen
        i64.const -1
        memory.atomic.wait32
        drop

        br $wait
      end
    end

    call $combine)

  (func (export "_start")
    (local $serial_result i32)

    call $serial
    local.set $serial_result
    call $parallel
    local.get $serial_result
    i32.eq
    if
    else
      unreachable
    end)
)
