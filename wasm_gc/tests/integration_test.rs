//! Integration tests for WebAssembly GC code generation

use wasm_gc::{generate_module, WasmInstr, WasmType};
use xs_core::ir::IrExpr;
use xs_core::Literal;

#[test]
fn test_simple_literal() {
    let ir = IrExpr::Literal(Literal::Int(42));
    let module = generate_module(&ir).unwrap();
    
    assert_eq!(module.functions.len(), 1);
    let main_func = &module.functions[0];
    assert_eq!(main_func.name, "main");
    assert_eq!(main_func.results, vec![WasmType::I32]);
    
    // Should generate: i64.const 42, i32.const 0
    assert!(matches!(main_func.body[0], WasmInstr::I64Const(42)));
    assert!(matches!(main_func.body[1], WasmInstr::I32Const(0)));
}

#[test]
fn test_let_binding() {
    let ir = IrExpr::Let {
        name: "x".to_string(),
        value: Box::new(IrExpr::Literal(Literal::Int(10))),
        body: Box::new(IrExpr::Var("x".to_string())),
    };
    
    let module = generate_module(&ir).unwrap();
    let main_func = &module.functions[0];
    
    // Should have local variable
    assert!(!main_func.locals.is_empty());
    
    // Should generate: i64.const 10, local.set 0, local.get 0, i32.const 0
    let mut has_const = false;
    let mut has_set = false;
    let mut has_get = false;
    
    for instr in &main_func.body {
        match instr {
            WasmInstr::I64Const(10) => has_const = true,
            WasmInstr::LocalSet(0) => has_set = true,
            WasmInstr::LocalGet(0) => has_get = true,
            _ => {}
        }
    }
    
    assert!(has_const);
    assert!(has_set);
    assert!(has_get);
}

#[test]
fn test_if_expression() {
    let ir = IrExpr::If {
        cond: Box::new(IrExpr::Literal(Literal::Bool(true))),
        then_expr: Box::new(IrExpr::Literal(Literal::Int(1))),
        else_expr: Box::new(IrExpr::Literal(Literal::Int(2))),
    };
    
    let module = generate_module(&ir).unwrap();
    let main_func = &module.functions[0];
    
    // Should have if instruction
    let mut has_if = false;
    for instr in &main_func.body {
        if matches!(instr, WasmInstr::If { .. }) {
            has_if = true;
            break;
        }
    }
    assert!(has_if);
}

#[test]
fn test_perceus_drop() {
    let ir = IrExpr::Let {
        name: "x".to_string(),
        value: Box::new(IrExpr::Literal(Literal::Int(5))),
        body: Box::new(IrExpr::Drop("x".to_string())),
    };
    
    let module = generate_module(&ir).unwrap();
    let main_func = &module.functions[0];
    
    // Should have drop instruction
    let mut has_drop = false;
    for instr in &main_func.body {
        if matches!(instr, WasmInstr::Drop) {
            has_drop = true;
            break;
        }
    }
    assert!(has_drop);
}