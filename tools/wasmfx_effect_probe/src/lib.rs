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
}
