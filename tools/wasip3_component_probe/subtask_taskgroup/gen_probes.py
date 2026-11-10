#!/usr/bin/env python3
# #3147 probes: can a TaskGroup child be a Component Model subtask?
#
# Writes one component per probe into OUT_DIR. In every probe a "Worker"
# component lifts an async (stackful, callback-less) export
# `child(ms) -> u32` and a "Main" component calls it through
# `canon lower ... async`, so each call is a subtask with its own handle,
# joined through `waitable-set.wait`. The child awaits viberun's `get-after`
# host import (it sleeps `ms` and echoes it) and answers ms + 1. Special
# values of `ms`: 0 returns at once, 7 spins on the CPU, 13 traps.
#
#   siblings_*  Worker and Main are separate instances inside one component
#   self_*      one component instance lowers its own lifted `child`
#
# Assemble with `wasm-tools parse`, run with runtime/viberun (the host that
# provides `get-after`). Results measured on wasmtime 47.0.2 are in
# docs/internal/design/component-subtask-taskgroup.md, which also says what
# each probe answers.
#
#   python3 gen_probes.py OUT_DIR
import sys, os

OUT = sys.argv[1]

def worker_core(cancellable_wait):
    return f'''
  (core module $wcore
    (import "$root" "[async-lower]get-after" (func $get_after (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "$root" "[subtask-drop]" (func $subtask_drop (param i32)))
    (import "$root" "[subtask-cancel]" (func $subtask_cancel (param i32) (result i32)))
    (import "[export]$root" "[task-return]child" (func $task_return (param i32)))
    (import "[export]$root" "[task-cancel]" (func $task_cancel))
    (import "env" "memory" (memory 1))
    ;; each call takes its own 16-byte scratch: +0 result, +8 wait payload
    (global $next (mut i32) (i32.const 64))
    (func (export "child") (param $ms i32)
      (local $base i32) (local $packed i32) (local $sub i32) (local $ws i32) (local $ev i32)
      (local.set $base (global.get $next))
      (global.set $next (i32.add (global.get $next) (i32.const 16)))
      ;; ms = 0: return at once (the eager path, used by the cost probe)
      (if (i32.eqz (local.get $ms)) (then (call $task_return (i32.const 7)) (return)))
      ;; ms = 7: a CPU-bound child (a counted loop), then return 7
      (if (i32.eq (local.get $ms) (i32.const 7)) (then
        (local.set $packed (i32.const 400000000))
        (block $sd (loop $sl
          (br_if $sd (i32.eqz (local.get $packed)))
          (local.set $packed (i32.sub (local.get $packed) (i32.const 1)))
          (br $sl)))
        (call $task_return (i32.const 7)) (return)))
      ;; ms = 13: a failing child
      (if (i32.eq (local.get $ms) (i32.const 13)) (then unreachable))
      (local.set $packed (call $get_after (local.get $ms) (local.get $base)))
      (if (i32.ne (i32.and (local.get $packed) (i32.const 0xf)) (i32.const 2))
        (then
          (local.set $sub (i32.shr_u (local.get $packed) (i32.const 4)))
          (local.set $ws (call $ws_new))
          (call $join (local.get $sub) (local.get $ws))
          (block $done
            (loop $l
              (local.set $ev (call $ws_wait (local.get $ws) (i32.add (local.get $base) (i32.const 8))))
              ;; TASK_CANCELLED (6): release the host wait, then acknowledge
              (if (i32.eq (local.get $ev) (i32.const 6))
                (then
                  ;; a waitable in a set cannot be cancelled synchronously: leave it first
                  (call $join (local.get $sub) (i32.const 0))
                  (drop (call $subtask_cancel (local.get $sub)))
                  (call $subtask_drop (local.get $sub))
                  (call $ws_drop (local.get $ws))
                  (call $task_cancel)
                  (return)))
              (if (i32.eq (local.get $ev) (i32.const 1))
                (then (if (i32.eq (i32.load offset=12 (local.get $base)) (i32.const 2))
                  (then (br $done)))))
              (br $l)))
          (call $subtask_drop (local.get $sub))
          (call $ws_drop (local.get $ws))))
      ;; the host echoes ms; the child answers ms + 1
      (call $task_return (i32.add (i32.load (local.get $base)) (i32.const 1))))
  )
  (core module $wmem (memory (export "memory") 1))
  (core instance $wmem-i (instantiate $wmem))
  (core func $w-get-after (canon lower (func $get-after) async (memory $wmem-i "memory")))
  (core func $w-ws-new (canon waitable-set.new))
  (core func $w-join (canon waitable.join))
  (core func $w-ws-wait (canon waitable-set.wait {"cancellable " if cancellable_wait else ""}(memory $wmem-i "memory")))
  (core func $w-ws-drop (canon waitable-set.drop))
  (core func $w-subtask-drop (canon subtask.drop))
  (core func $w-subtask-cancel (canon subtask.cancel))
  (core func $w-task-return (canon task.return (result u32)))
  (core func $w-task-cancel (canon task.cancel))
  (core instance $wcore-i (instantiate $wcore
    (with "$root" (instance
      (export "[async-lower]get-after" (func $w-get-after))
      (export "[waitable-set-new]" (func $w-ws-new))
      (export "[waitable-join]" (func $w-join))
      (export "[waitable-set-wait]" (func $w-ws-wait))
      (export "[waitable-set-drop]" (func $w-ws-drop))
      (export "[subtask-drop]" (func $w-subtask-drop))
      (export "[subtask-cancel]" (func $w-subtask-cancel))))
    (with "[export]$root" (instance
      (export "[task-return]child" (func $w-task-return))
      (export "[task-cancel]" (func $w-task-cancel))))
    (with "env" (instance (export "memory" (memory $wmem-i "memory"))))))
  (func $child-lifted (type $child-type)
    (canon lift (core func $wcore-i "child") async (memory $wmem-i "memory")))
'''

# Main bodies. Helpers: $start(ms, slot) -> subtask handle, or 0 when the call
# returned eagerly; $drain(ws, n) waits until n joined subtasks RETURNED.
MAIN_HELPERS = '''
    (func $start (param $ms i32) (param $slot i32) (result i32)
      (local $p i32)
      (local.set $p (call $child (local.get $ms) (local.get $slot)))
      (if (result i32) (i32.eq (i32.and (local.get $p) (i32.const 0xf)) (i32.const 2))
        (then (i32.const 0))
        (else (i32.shr_u (local.get $p) (i32.const 4)))))
    (func $drain (param $ws i32) (param $n i32)
      (local $ev i32)
      (block $done
        (loop $l
          (br_if $done (i32.eqz (local.get $n)))
          (local.set $ev (call $ws_wait (local.get $ws) (i32.const 32)))
          (if (i32.eq (local.get $ev) (i32.const 1))
            (then (if (i32.eq (i32.load (i32.const 36)) (i32.const 2))
              (then
                (call $subtask_drop (i32.load (i32.const 32)))
                (local.set $n (i32.sub (local.get $n) (i32.const 1)))))))
          (br $l))))
    (func $await1 (param $h i32)
      (local $ws i32)
      (if (local.get $h) (then
        (local.set $ws (call $ws_new))
        (call $join (local.get $h) (local.get $ws))
        (call $drain (local.get $ws) (i32.const 1))
        (call $ws_drop (local.get $ws)))))
'''

BODIES = {
    # both children started before either is waited on
    'concurrent': '''
      (local $a i32) (local $b i32) (local $ws i32) (local $n i32)
      (local.set $a (call $start (i32.const 300) (i32.const 0)))
      (local.set $b (call $start (i32.const 300) (i32.const 4)))
      (local.set $ws (call $ws_new))
      (if (local.get $a) (then (call $join (local.get $a) (local.get $ws)) (local.set $n (i32.add (local.get $n) (i32.const 1)))))
      (if (local.get $b) (then (call $join (local.get $b) (local.get $ws)) (local.set $n (i32.add (local.get $n) (i32.const 1)))))
      (call $drain (local.get $ws) (local.get $n))
      (call $ws_drop (local.get $ws))
      (call $task_return (i32.add (i32.load (i32.const 0)) (i32.load (i32.const 4))))''',
    # the control: the second child starts only after the first returned
    'serial': '''
      (call $await1 (call $start (i32.const 300) (i32.const 0)))
      (call $await1 (call $start (i32.const 300) (i32.const 4)))
      (call $task_return (i32.add (i32.load (i32.const 0)) (i32.load (i32.const 4))))''',
    # child b (3000 ms) is cancelled once child a (300 ms) returned;
    # answer = a's result * 10 + subtask.cancel's status
    'cancel': '''
      (local $a i32) (local $b i32) (local $st i32)
      (local.set $a (call $start (i32.const 300) (i32.const 0)))
      (local.set $b (call $start (i32.const 3000) (i32.const 4)))
      (call $await1 (local.get $a))
      (local.set $st (call $subtask_cancel (local.get $b)))
      (call $subtask_drop (local.get $b))
      (call $task_return (i32.add (i32.mul (i32.load (i32.const 0)) (i32.const 10)) (local.get $st)))''',
    # COSTN eager child calls (ms = 0): the cost of one subtask round trip
    'cost': '''
      (local $i i32) (local $sum i32) (local $h i32)
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (i32.const COSTN)))
        (local.set $h (call $start (i32.const 0) (i32.const 0)))
        (if (local.get $h) (then unreachable))
        (local.set $sum (i32.add (local.get $sum) (i32.load (i32.const 0))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $task_return (local.get $sum))''',
    # FANN children of 50 ms each in flight at once, drained from one set
    'fanout': '''
      (local $i i32) (local $h i32) (local $ws i32) (local $n i32) (local $sum i32)
      (local.set $ws (call $ws_new))
      (block $done (loop $l
        (br_if $done (i32.ge_u (local.get $i) (i32.const FANN)))
        (local.set $h (call $start (i32.const 50) (i32.add (i32.const 64) (i32.shl (local.get $i) (i32.const 2)))))
        (if (local.get $h) (then (call $join (local.get $h) (local.get $ws)) (local.set $n (i32.add (local.get $n) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $drain (local.get $ws) (local.get $n))
      (call $ws_drop (local.get $ws))
      (local.set $i (i32.const 0))
      (block $d2 (loop $l2
        (br_if $d2 (i32.ge_u (local.get $i) (i32.const FANN)))
        (local.set $sum (i32.add (local.get $sum) (i32.load (i32.add (i32.const 64) (i32.shl (local.get $i) (i32.const 2))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l2)))
      (call $task_return (local.get $sum))''',
    # two CPU-bound children; answer = status of a * 10 + status of b
    'spin2': '''
      (local $pa i32) (local $pb i32)
      (local.set $pa (call $child (i32.const 7) (i32.const 0)))
      (local.set $pb (call $child (i32.const 7) (i32.const 4)))
      (call $task_return (i32.add (i32.mul (i32.and (local.get $pa) (i32.const 0xf)) (i32.const 10)) (i32.and (local.get $pb) (i32.const 0xf))))''',
    'spin1': '''
      (local $pa i32)
      (local.set $pa (call $child (i32.const 7) (i32.const 0)))
      (call $task_return (i32.and (local.get $pa) (i32.const 0xf)))''',
    # a child traps while a sibling is in flight
    'trap': '''
      (local $a i32) (local $b i32)
      (local.set $a (call $start (i32.const 300) (i32.const 0)))
      (local.set $b (call $start (i32.const 13) (i32.const 4)))
      (call $await1 (local.get $a))
      (call $await1 (local.get $b))
      (call $task_return (i32.const 1))''',
}

def main_core(body):
    return f'''
  (core module $mcore
    (import "$root" "[async-lower]child" (func $child (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-new]" (func $ws_new (result i32)))
    (import "$root" "[waitable-join]" (func $join (param i32 i32)))
    (import "$root" "[waitable-set-wait]" (func $ws_wait (param i32 i32) (result i32)))
    (import "$root" "[waitable-set-drop]" (func $ws_drop (param i32)))
    (import "$root" "[subtask-drop]" (func $subtask_drop (param i32)))
    (import "$root" "[subtask-cancel]" (func $subtask_cancel (param i32) (result i32)))
    (import "[export]$root" "[task-return]run" (func $task_return (param i32)))
    (import "env" "memory" (memory 1))
{MAIN_HELPERS}
    (func (export "run"){body})
  )
  (core module $mmem (memory (export "memory") 1))
  (core instance $mmem-i (instantiate $mmem))
  (core func $m-child (canon lower (func $child-for-main) async (memory $mmem-i "memory")))
  (core func $m-ws-new (canon waitable-set.new))
  (core func $m-join (canon waitable.join))
  (core func $m-ws-wait (canon waitable-set.wait (memory $mmem-i "memory")))
  (core func $m-ws-drop (canon waitable-set.drop))
  (core func $m-subtask-drop (canon subtask.drop))
  (core func $m-subtask-cancel (canon subtask.cancel))
  (core func $m-task-return (canon task.return (result u32)))
  (core instance $mcore-i (instantiate $mcore
    (with "$root" (instance
      (export "[async-lower]child" (func $m-child))
      (export "[waitable-set-new]" (func $m-ws-new))
      (export "[waitable-join]" (func $m-join))
      (export "[waitable-set-wait]" (func $m-ws-wait))
      (export "[waitable-set-drop]" (func $m-ws-drop))
      (export "[subtask-drop]" (func $m-subtask-drop))
      (export "[subtask-cancel]" (func $m-subtask-cancel))))
    (with "[export]$root" (instance (export "[task-return]run" (func $m-task-return))))
    (with "env" (instance (export "memory" (memory $mmem-i "memory"))))))
  (func $run-lifted (type $run-type)
    (canon lift (core func $mcore-i "run") async (memory $mmem-i "memory")))
'''

TYPES = '''
  (type $get-after-type (func async (param "ms" u32) (result u32)))
  (type $child-type (func async (param "ms" u32) (result u32)))
  (type $run-type (func async (result u32)))'''

def siblings(body, cancellable_wait=True):
    return f'''(component
  (type $get-after-type (func async (param "ms" u32) (result u32)))
  (import "get-after" (func $host-get-after (type $get-after-type)))
  (component $Worker
{TYPES}
    (import "get-after" (func $get-after (type $get-after-type)))
{worker_core(cancellable_wait)}
    (export "child" (func $child-lifted)))
  (component $Main
{TYPES}
    (import "child" (func $child-for-main (type $child-type)))
{main_core(body)}
    (export "run" (func $run-lifted)))
  (instance $w (instantiate $Worker (with "get-after" (func $host-get-after))))
  (instance $m (instantiate $Main (with "child" (func $w "child"))))
  (export "run" (func $m "run")))
'''

def selfcall(body):
    # one component instance: the core module that runs `run` lowers the
    # component's own lifted `child`
    return f'''(component
{TYPES}
  (import "get-after" (func $get-after (type $get-after-type)))
{worker_core(True)}
  (func $child-for-main (type $child-type)
    (canon lift (core func $wcore-i "child") async (memory $wmem-i "memory")))
{main_core(body)}
  (export "child" (func $child-lifted))
  (export "run" (func $run-lifted)))
'''

COUNTS = {'COSTN': '200000', 'FANN': '1000'}
os.makedirs(OUT, exist_ok=True)
for name, body in BODIES.items():
    for k, v in COUNTS.items():
        body = body.replace(k, v)
    open(f'{OUT}/siblings_{name}.wat', 'w').write(siblings(body))
open(f'{OUT}/siblings_cancel_unobserved.wat', 'w').write(siblings(BODIES['cancel'], cancellable_wait=False))
open(f'{OUT}/self_concurrent.wat', 'w').write(selfcall(BODIES['concurrent']))
