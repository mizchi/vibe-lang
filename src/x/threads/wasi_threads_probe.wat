(module
  (import "env" "memory" (memory 1 1 shared))
  (import "wasi" "thread-spawn" (func $thread_spawn (param i32) (result i32)))

  ;; shared slots
  ;; 0: counter (i32)

  (func (export "wasi_thread_start") (param $tid i32) (param $start_arg i32)
    i32.const 0
    i32.const 1
    i32.atomic.rmw.add
    drop

    i32.const 0
    i32.const 1
    memory.atomic.notify
    drop
  )

  (func (export "_start")
    (local $seen i32)

    ;; reset counter
    i32.const 0
    i32.const 0
    i32.store

    ;; spawn 4 workers
    i32.const 0
    call $thread_spawn
    drop
    i32.const 0
    call $thread_spawn
    drop
    i32.const 0
    call $thread_spawn
    drop
    i32.const 0
    call $thread_spawn
    drop

    ;; wait until counter >= 4
    block $done
      loop $wait
        i32.const 0
        i32.atomic.load
        local.tee $seen
        i32.const 4
        i32.ge_s
        br_if $done

        i32.const 0
        local.get $seen
        i64.const -1
        memory.atomic.wait32
        drop

        br $wait
      end
    end

    ;; sanity check
    i32.const 0
    i32.atomic.load
    i32.const 4
    i32.eq
    if
    else
      unreachable
    end
  )
)
