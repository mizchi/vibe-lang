;; #3147 probe: a channel between two task instances is a `stream<u32>`.
;; Main creates the stream, passes the readable end to the Worker's async
;; `consume` export (a subtask), writes 1..5 and drops the writable end. The
;; Worker reads in rounds of two until DROPPED and returns the sum (15).
(component
  (component $Worker
    (type $s (stream u32))
    (type $consume-type (func async (param "s" $s) (result u32)))
    (core module $wcore
      (import "$root" "[stream-read]" (func $read (param i32 i32 i32) (result i32)))
      (import "$root" "[stream-drop-readable]" (func $drop_r (param i32)))
      (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
      (import "$root" "[waitable-join]" (func $join (param i32 i32)))
      (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
      (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
      (import "[export]$root" "[task-return]consume" (func $task_return (param i32)))
      (import "env" "memory" (memory 1))
      (func (export "consume") (param $h i32)
        (local $r i32) (local $sum i32) (local $ws i32) (local $ev i32) (local $n i32) (local $i i32)
        (local.set $ws (call $ws_new))
        (block $eof
          (loop $round
            ;; read at most two values into 0..8
            (local.set $r (call $read (local.get $h) (i32.const 0) (i32.const 2)))
            (if (i32.eq (local.get $r) (i32.const -1))
              (then
                (call $join (local.get $h) (local.get $ws))
                (block $got
                  (loop $w
                    (local.set $ev (call $ws_wait (local.get $ws) (i32.const 32)))
                    ;; STREAM_READ (2) on our handle
                    (br_if $got (i32.eq (local.get $ev) (i32.const 2)))
                    (br $w)))
                (local.set $r (i32.load (i32.const 36)))
                (call $join (local.get $h) (i32.const 0))))
            (local.set $n (i32.shr_u (local.get $r) (i32.const 4)))
            (local.set $i (i32.const 0))
            (block $d (loop $l
              (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
              (local.set $sum (i32.add (local.get $sum) (i32.load (i32.shl (local.get $i) (i32.const 2)))))
              (local.set $i (i32.add (local.get $i) (i32.const 1)))
              (br $l)))
            ;; DROPPED (1): the writer is gone
            (br_if $eof (i32.eq (i32.and (local.get $r) (i32.const 0xf)) (i32.const 1)))
            (br $round)))
        (call $drop_r (local.get $h))
        (call $ws_drop (local.get $ws))
        (call $task_return (local.get $sum))))
    (core module $wmem (memory (export "memory") 1))
    (core instance $wmem-i (instantiate $wmem))
    (core func $w-read (canon stream.read $s async (memory $wmem-i "memory")))
    (core func $w-drop-r (canon stream.drop-readable $s))
    (core func $w-ws-new (canon waitable-set.new))
    (core func $w-join (canon waitable.join))
    (core func $w-ws-wait (canon waitable-set.wait (memory $wmem-i "memory")))
    (core func $w-ws-drop (canon waitable-set.drop))
    (core func $w-task-return (canon task.return (result u32)))
    (core instance $wcore-i (instantiate $wcore
      (with "$root" (instance
        (export "[stream-read]" (func $w-read))
        (export "[stream-drop-readable]" (func $w-drop-r))
        (export "[waitable-set-new]" (func $w-ws-new))
        (export "[waitable-join]" (func $w-join))
        (export "[waitable-set-wait]" (func $w-ws-wait))
        (export "[waitable-set-drop]" (func $w-ws-drop))))
      (with "[export]$root" (instance (export "[task-return]consume" (func $w-task-return))))
      (with "env" (instance (export "memory" (memory $wmem-i "memory"))))))
    (func $consume (type $consume-type)
      (canon lift (core func $wcore-i "consume") async (memory $wmem-i "memory")))
    (export "consume" (func $consume)))

  (component $Main
    (type $s (stream u32))
    (type $consume-type (func async (param "s" $s) (result u32)))
    (type $run-type (func async (result u32)))
    (import "consume" (func $consume (type $consume-type)))
    (core module $mcore
      (import "$root" "[async-lower]consume" (func $consume (param i32 i32) (result i32)))
      (import "$root" "[stream-new]" (func $new (result i64)))
      (import "$root" "[stream-write]" (func $write (param i32 i32 i32) (result i32)))
      (import "$root" "[stream-drop-writable]" (func $drop_w (param i32)))
      (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
      (import "$root" "[waitable-join]" (func $join (param i32 i32)))
      (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
      (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
      (import "$root" "[subtask-drop]" (func $subtask_drop (param i32)))
      (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
      (import "env" "memory" (memory 1))
      (func (export "run")
        (local $pair i64) (local $rd i32) (local $wr i32) (local $p i32) (local $sub i32)
        (local $ws i32) (local $ev i32) (local $w i32) (local $off i32) (local $left i32)
        (local.set $pair (call $new))
        (local.set $rd (i32.wrap_i64 (local.get $pair)))
        (local.set $wr (i32.wrap_i64 (i64.shr_u (local.get $pair) (i64.const 32))))
        (local.set $ws (call $ws_new))
        ;; start the consumer task: the readable end moves to it
        (local.set $p (call $consume (local.get $rd) (i32.const 0)))
        (if (i32.ne (i32.and (local.get $p) (i32.const 0xf)) (i32.const 2))
          (then
            (local.set $sub (i32.shr_u (local.get $p) (i32.const 4)))
            (call $join (local.get $sub) (local.get $ws))))
        ;; 1..5 at 100..120
        (i32.store (i32.const 100) (i32.const 1))
        (i32.store (i32.const 104) (i32.const 2))
        (i32.store (i32.const 108) (i32.const 3))
        (i32.store (i32.const 112) (i32.const 4))
        (i32.store (i32.const 116) (i32.const 5))
        (local.set $off (i32.const 100))
        (local.set $left (i32.const 5))
        (block $sent
          (loop $more
            (br_if $sent (i32.eqz (local.get $left)))
            (local.set $w (call $write (local.get $wr) (local.get $off) (local.get $left)))
            (if (i32.eq (local.get $w) (i32.const -1))
              (then
                (call $join (local.get $wr) (local.get $ws))
                (block $got
                  (loop $wt
                    (local.set $ev (call $ws_wait (local.get $ws) (i32.const 32)))
                    ;; STREAM_WRITE (3)
                    (br_if $got (i32.eq (local.get $ev) (i32.const 3)))
                    (br $wt)))
                (local.set $w (i32.load (i32.const 36)))
                (call $join (local.get $wr) (i32.const 0))))
            (local.set $off (i32.add (local.get $off) (i32.shl (i32.shr_u (local.get $w) (i32.const 4)) (i32.const 2))))
            (local.set $left (i32.sub (local.get $left) (i32.shr_u (local.get $w) (i32.const 4))))
            (br $more)))
        (call $drop_w (local.get $wr))
        ;; join the consumer
        (if (local.get $sub)
          (then
            (block $done
              (loop $l
                (local.set $ev (call $ws_wait (local.get $ws) (i32.const 32)))
                (if (i32.eq (local.get $ev) (i32.const 1))
                  (then (br_if $done (i32.eq (i32.load (i32.const 36)) (i32.const 2)))))
                (br $l)))
            (call $subtask_drop (local.get $sub))))
        (call $ws_drop (local.get $ws))
        (call $task_return (i32.load (i32.const 0)))))
    (core module $mmem (memory (export "memory") 1))
    (core instance $mmem-i (instantiate $mmem))
    (core func $m-consume (canon lower (func $consume) async (memory $mmem-i "memory")))
    (core func $m-new (canon stream.new $s))
    (core func $m-write (canon stream.write $s async (memory $mmem-i "memory")))
    (core func $m-drop-w (canon stream.drop-writable $s))
    (core func $m-ws-new (canon waitable-set.new))
    (core func $m-join (canon waitable.join))
    (core func $m-ws-wait (canon waitable-set.wait (memory $mmem-i "memory")))
    (core func $m-ws-drop (canon waitable-set.drop))
    (core func $m-subtask-drop (canon subtask.drop))
    (core func $m-task-return (canon task.return (result u32)))
    (core instance $mcore-i (instantiate $mcore
      (with "$root" (instance
        (export "[async-lower]consume" (func $m-consume))
        (export "[stream-new]" (func $m-new))
        (export "[stream-write]" (func $m-write))
        (export "[stream-drop-writable]" (func $m-drop-w))
        (export "[waitable-set-new]" (func $m-ws-new))
        (export "[waitable-join]" (func $m-join))
        (export "[waitable-set-wait]" (func $m-ws-wait))
        (export "[waitable-set-drop]" (func $m-ws-drop))
        (export "[subtask-drop]" (func $m-subtask-drop))))
      (with "[export]$root" (instance (export "[task-return]run" (func $m-task-return))))
      (with "env" (instance (export "memory" (memory $mmem-i "memory"))))))
    (func $run (type $run-type)
      (canon lift (core func $mcore-i "run") async (memory $mmem-i "memory")))
    (export "run" (func $run)))

  (instance $w (instantiate $Worker))
  (instance $m (instantiate $Main (with "consume" (func $w "consume"))))
  (export "run" (func $m "run")))
