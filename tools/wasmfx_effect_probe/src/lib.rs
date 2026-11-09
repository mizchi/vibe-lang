#![cfg(test)]

use anyhow::Result;
use wasmtime::{Config, Engine, Instance, Module, Store};

fn run_i32(wat: &str, export: &str) -> Result<i32> {
    let mut config = Config::new();
    config
        .wasm_function_references(true)
        .wasm_exceptions(true)
        .wasm_stack_switching(true);
    let engine = Engine::new(&config)?;
    let module = Module::new(&engine, wat)?;
    let mut store = Store::new(&engine, ());
    let instance = Instance::new(&mut store, &module, &[])?;
    Ok(instance
        .get_typed_func::<(), i32>(&mut store, export)?
        .call(&mut store, ())?)
}

/// A Vibe `perform` reached through an opaque call can suspend without the
/// compiler reconstructing the caller as a CPS clone. Native Wasm frames and
/// operand-stack values are retained by the continuation.
const OPAQUE_CALL_CAPTURE: &str = r#"
(module
  (type $initial-fn (func (result i32)))
  (type $initial-cont (cont $initial-fn))
  (type $resume-fn (func (param i32) (result i32)))
  (type $resume-cont (cont $resume-fn))
  (tag $ask (result i32))

  (func $opaque (result i32)
    (i32.const 10)
    (suspend $ask)
    (i32.add)
    (i32.const 1)
    (i32.add))

  (func $body (result i32)
    (call $opaque))
  (elem declare func $body)

  (func (export "run") (result i32)
    (local $k (ref null $resume-cont))
    (block $on-ask (result (ref $resume-cont))
      (resume $initial-cont
        (on $ask $on-ask)
        (cont.new $initial-cont (ref.func $body)))
      (unreachable))
    (local.set $k)
    (resume $resume-cont (i32.const 31) (local.get $k)))
)
"#;

/// A handler may do work both before and after resuming. Vibe's current linear
/// lowering rejects the direct source form because `resume(v)` must be the
/// arm's final expression; Wasm stack switching has no such representation
/// restriction.
const NON_TAIL_HANDLER: &str = r#"
(module
  (type $initial-fn (func (result i32)))
  (type $initial-cont (cont $initial-fn))
  (type $resume-fn (func (param i32) (result i32)))
  (type $resume-cont (cont $resume-fn))
  (tag $ask (result i32))

  (func $body (result i32)
    (suspend $ask)
    (i32.const 2)
    (i32.mul))
  (elem declare func $body)

  (func (export "run") (result i32)
    (local $k (ref null $resume-cont))
    (local $handled i32)
    (block $on-ask (result (ref $resume-cont))
      (resume $initial-cont
        (on $ask $on-ask)
        (cont.new $initial-cont (ref.func $body)))
      (unreachable))
    (local.set $k)
    ;; handler pre-processing: 20 -> 21
    (resume $resume-cont (i32.const 21) (local.get $k))
    (local.set $handled)
    ;; handler post-processing after the continuation returns: 42 -> 49
    (i32.add (local.get $handled) (i32.const 7)))
)
"#;

/// A suspension that is not handled by an intermediate continuation is
/// forwarded to the dynamically enclosing handler. This removes the current
/// compiler requirement that every intervening call be statically cloned for
/// one particular effect.
const DYNAMIC_FORWARDING: &str = r#"
(module
  (type $unit-to-unit (func))
  (type $ct (cont $unit-to-unit))
  (type $returns-ct (func (result (ref $ct))))
  (type $returns-ct-cont (cont $returns-ct))
  (tag $outer)
  (tag $inner)
  (global $marker (mut i32) (i32.const 0))

  (func $mark (param $factor i32)
    (global.set $marker
      (i32.mul
        (i32.add (global.get $marker) (i32.const 1))
        (local.get $factor))))

  (func $leaf
    (call $mark (i32.const 2))
    (suspend $outer)
    (call $mark (i32.const 3)))
  (elem declare func $leaf)

  ;; This layer handles only $inner. $outer must cross it dynamically.
  (func $opaque-middle
    (block $on-inner (result (ref $ct))
      (call $mark (i32.const 5))
      (resume $ct
        (on $inner $on-inner)
        (cont.new $ct (ref.func $leaf)))
      (return))
    (unreachable))
  (elem declare func $opaque-middle)

  (func (export "run") (result i32)
    (block $on-outer (result (ref $ct))
      (call $mark (i32.const 7))
      (resume $ct
        (on $outer $on-outer)
        (cont.new $ct (ref.func $opaque-middle)))
      (unreachable))
    (call $mark (i32.const 11))
    (resume $ct)
    (global.get $marker))
)
"#;

// The cases below back docs/internal/design/wasmfx-continuation-ownership.md
// (#2221): where a stored continuation may live, and what one-shot ownership
// costs, on this pinned runtime.

fn instantiate(wat: &str) -> Result<(Store<()>, Instance)> {
    let mut config = Config::new();
    config
        .wasm_function_references(true)
        .wasm_exceptions(true)
        .wasm_gc(true)
        .wasm_stack_switching(true);
    let engine = Engine::new(&config)?;
    let module = Module::new(&engine, wat)?;
    let mut store = Store::new(&engine, ());
    let instance = Instance::new(&mut store, &module, &[])?;
    Ok((store, instance))
}

/// The engine's own one-shot check: resuming a consumed contref traps.
const RESUME_CONSUMED: &str = r#"
(module
  (type $f0 (func (result i32)))
  (type $c0 (cont $f0))
  (type $f1 (func (param i32) (result i32)))
  (type $c1 (cont $f1))
  (tag $ask (result i32))
  (func $body (result i32) (i32.add (suspend $ask) (i32.const 1)))
  (elem declare func $body)
  (func (export "run") (result i32)
    (local $k (ref null $c1))
    (block $on (result (ref $c1))
      (resume $c0 (on $ask $on) (cont.new $c0 (ref.func $body)))
      (unreachable))
    (local.set $k)
    (drop (resume $c1 (i32.const 1) (local.get $k)))
    (resume $c1 (i32.const 2) (local.get $k)))
)
"#;

/// The recommended storage: a module-private table of contrefs, addressed by
/// an i64 handle `generation << 32 | slot`. Taking a continuation nulls the
/// slot and bumps the generation, so every copy of the handle is refused in
/// the guest (-1) before the engine is asked to resume anything.
const HANDLE_TABLE: &str = r#"
(module
  (type $f0 (func (result i32)))
  (type $c0 (cont $f0))
  (type $f1 (func (param i32) (result i32)))
  (type $c1 (cont $f1))
  (tag $ask (result i32))
  (table $conts 8 (ref null $c1))
  (memory 1)
  (func $body (result i32) (i32.add (suspend $ask) (i32.const 1)))
  (elem declare func $body)
  (func $bump (param $slot i32) (result i32)
    (local $g i32)
    (local.set $g (i32.add (i32.load (i32.shl (local.get $slot) (i32.const 2))) (i32.const 1)))
    (i32.store (i32.shl (local.get $slot) (i32.const 2)) (local.get $g))
    (local.get $g))
  (func (export "park") (result i64)
    (local $k (ref null $c1)) (local $slot i32) (local $gen i32)
    (block $on (result (ref $c1))
      (resume $c0 (on $ask $on) (cont.new $c0 (ref.func $body)))
      (unreachable))
    (local.set $k)
    (block $found (loop $scan
      (br_if $found (ref.is_null (table.get $conts (local.get $slot))))
      (local.set $slot (i32.add (local.get $slot) (i32.const 1)))
      (br $scan)))
    (table.set $conts (local.get $slot) (local.get $k))
    (local.set $gen (call $bump (local.get $slot)))
    (i64.or (i64.shl (i64.extend_i32_u (local.get $gen)) (i64.const 32))
            (i64.extend_i32_u (local.get $slot))))
  (func $take (param $h i64) (result (ref null $c1))
    (local $slot i32) (local $k (ref null $c1))
    (local.set $slot (i32.wrap_i64 (local.get $h)))
    (if (i32.ne (i32.load (i32.shl (local.get $slot) (i32.const 2)))
                (i32.wrap_i64 (i64.shr_u (local.get $h) (i64.const 32))))
      (then (return (ref.null $c1))))
    (local.set $k (table.get $conts (local.get $slot)))
    (table.set $conts (local.get $slot) (ref.null $c1))
    (drop (call $bump (local.get $slot)))
    (local.get $k))
  (func (export "resume_handle") (param $h i64) (param $v i32) (result i32)
    (local $k (ref null $c1))
    (local.set $k (call $take (local.get $h)))
    (if (ref.is_null (local.get $k)) (then (return (i32.const -1))))
    (resume $c1 (local.get $v) (local.get $k)))
  (func (export "release") (param $h i64) (result i32)
    (if (result i32) (ref.is_null (call $take (local.get $h)))
      (then (i32.const -1)) (else (i32.const 0))))
  (func (export "live") (result i32)
    (local $i i32) (local $n i32)
    (loop $l
      (if (i32.eqz (ref.is_null (table.get $conts (local.get $i))))
        (then (local.set $n (i32.add (local.get $n) (i32.const 1)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $l (i32.lt_u (local.get $i) (table.size $conts))))
    (local.get $n))
)
"#;

/// Cancellation: `resume_throw` raises a private tag at the suspension
/// point, so the parked frame's landing pad runs (where a lowering would
/// release what the frame owns) before the continuation is gone.
const RESUME_THROW_CANCEL: &str = r#"
(module
  (type $f0 (func (result i32)))
  (type $c0 (cont $f0))
  (type $f1 (func (param i32) (result i32)))
  (type $c1 (cont $f1))
  (tag $ask (result i32))
  (tag $cancel)
  (global $unwound (mut i32) (i32.const 0))
  (func $body (result i32)
    (block $caught
      (try_table (catch $cancel $caught)
        (return (i32.add (suspend $ask) (i32.const 1)))))
    (global.set $unwound (i32.const 1))
    (i32.const -7))
  (elem declare func $body)
  (func (export "run") (result i32)
    (local $k (ref null $c1))
    (block $on (result (ref $c1))
      (resume $c0 (on $ask $on) (cont.new $c0 (ref.func $body)))
      (unreachable))
    (local.set $k)
    (drop (resume_throw $c1 $cancel (local.get $k)))
    (global.get $unwound))
)
"#;

/// Typed storage positions other than locals and tables.
const CONTREF_IN_GLOBAL: &str = r#"
(module
  (type $f1 (func (param i32) (result i32)))
  (type $c1 (cont $f1))
  (global $g (mut (ref null $c1)) (ref.null $c1))
  (func (export "run") (result i32) (i32.const 0)))
"#;

const CONTREF_IN_GC_STRUCT: &str = r#"
(module
  (type $f1 (func (param i32) (result i32)))
  (type $c1 (cont $f1))
  (type $box (struct (field (mut (ref null $c1)))))
  (func (export "run") (result i32)
    (drop (struct.new $box (ref.null $c1)))
    (i32.const 0)))
"#;

const CONTREF_AS_ANYREF: &str = r#"
(module
  (type $f1 (func (param i32) (result i32)))
  (type $c1 (cont $f1))
  (func (export "run") (result i32)
    (drop (ref.cast (ref null any) (ref.null $c1)))
    (i32.const 0)))
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn captures_an_opaque_call_stack() -> Result<()> {
        assert_eq!(run_i32(OPAQUE_CALL_CAPTURE, "run")?, 42);
        Ok(())
    }

    #[test]
    fn permits_handler_postprocessing_after_resume() -> Result<()> {
        assert_eq!(run_i32(NON_TAIL_HANDLER, "run")?, 49);
        Ok(())
    }

    #[test]
    fn forwards_effects_through_an_opaque_intermediate_handler() -> Result<()> {
        assert_eq!(run_i32(DYNAMIC_FORWARDING, "run")?, 2742);
        Ok(())
    }

    #[test]
    fn a_consumed_continuation_traps_on_a_second_resume() {
        let err = run_i32(RESUME_CONSUMED, "run").unwrap_err();
        assert!(format!("{err:?}").contains("continuation already consumed"), "{err:?}");
    }

    #[test]
    fn a_handle_table_refuses_aliased_stale_and_released_handles() -> Result<()> {
        let (mut store, inst) = instantiate(HANDLE_TABLE)?;
        let park = inst.get_typed_func::<(), i64>(&mut store, "park")?;
        let resume = inst.get_typed_func::<(i64, i32), i32>(&mut store, "resume_handle")?;
        let release = inst.get_typed_func::<i64, i32>(&mut store, "release")?;
        let live = inst.get_typed_func::<(), i32>(&mut store, "live")?;
        let h = park.call(&mut store, ())?;
        let alias = h;
        assert_eq!(resume.call(&mut store, (h, 41))?, 42);
        assert_eq!(resume.call(&mut store, (alias, 1))?, -1);
        // The slot is reused; the old handle must not reach the new tenant.
        let h2 = park.call(&mut store, ())?;
        assert_eq!(h2 as u32, h as u32);
        assert_eq!(resume.call(&mut store, (h, 1))?, -1);
        assert_eq!(resume.call(&mut store, (h2, 9))?, 10);
        // Released without resuming: the slot is empty and the handle dead.
        let h3 = park.call(&mut store, ())?;
        assert_eq!(live.call(&mut store, ())?, 1);
        assert_eq!(release.call(&mut store, h3)?, 0);
        assert_eq!(live.call(&mut store, ())?, 0);
        assert_eq!(resume.call(&mut store, (h3, 1))?, -1);
        Ok(())
    }

    #[test]
    fn resume_throw_unwinds_a_parked_continuation() -> Result<()> {
        assert_eq!(run_i32(RESUME_THROW_CANCEL, "run")?, 1);
        Ok(())
    }

    #[test]
    fn a_contref_lives_in_locals_tables_and_globals_only() {
        assert!(instantiate(CONTREF_IN_GLOBAL).is_ok());
        let gc = instantiate(CONTREF_IN_GC_STRUCT).map(|_| ()).unwrap_err();
        assert!(format!("{gc:?}").contains("not compatible with GC"), "{gc:?}");
        let any = instantiate(CONTREF_AS_ANYREF).map(|_| ()).unwrap_err();
        assert!(format!("{any:?}").contains("expected anyref"), "{any:?}");
    }
}
