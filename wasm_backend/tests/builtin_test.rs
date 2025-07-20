//! Test builtin function WASM generation

use parser::parse;
use perceus::transform_to_ir;
use wasm_backend::WasmInstr;
use wasm_backend::codegen::CodeGenerator;

#[test]
fn test_arithmetic_builtin_wasm() {
    let expr = parse("(+ 10 20)").unwrap();
    let ir = transform_to_ir(&expr);
    
    let mut codegen = CodeGenerator::new();
    let module = codegen.generate(&ir).unwrap();
    
    // Check that main function exists
    assert!(!module.functions.is_empty());
    let main_func = &module.functions[0];
    assert_eq!(main_func.name, "main");
    
    // Should contain i64.add instruction
    let has_add = main_func.body.iter().any(|instr| {
        matches!(instr, WasmInstr::I64Add)
    });
    assert!(has_add, "Should contain i64.add instruction");
    
    // Should contain the constants
    let has_10 = main_func.body.iter().any(|instr| {
        matches!(instr, WasmInstr::I64Const(10))
    });
    assert!(has_10, "Should contain i64.const 10");
    
    let has_20 = main_func.body.iter().any(|instr| {
        matches!(instr, WasmInstr::I64Const(20))
    });
    assert!(has_20, "Should contain i64.const 20");
}

#[test]
fn test_comparison_builtin_wasm() {
    let expr = parse("(< 5 10)").unwrap();
    let ir = transform_to_ir(&expr);
    
    let mut codegen = CodeGenerator::new();
    let module = codegen.generate(&ir).unwrap();
    
    let main_func = &module.functions[0];
    
    // Should contain i64.lt_s instruction
    let has_lt = main_func.body.iter().any(|instr| {
        matches!(instr, WasmInstr::I64LtS)
    });
    assert!(has_lt, "Should contain i64.lt_s instruction");
    
    // Should convert result to i64
    let has_extend = main_func.body.iter().any(|instr| {
        matches!(instr, WasmInstr::I64ExtendI32S)
    });
    assert!(has_extend, "Should contain i64.extend_i32_s for bool conversion");
}

#[test]
fn test_nested_arithmetic_wasm() {
    let expr = parse("(* (+ 1 2) 3)").unwrap();
    let ir = transform_to_ir(&expr);
    
    let mut codegen = CodeGenerator::new();
    let module = codegen.generate(&ir).unwrap();
    
    let main_func = &module.functions[0];
    
    // Should contain both add and mul instructions
    let has_add = main_func.body.iter().any(|instr| {
        matches!(instr, WasmInstr::I64Add)
    });
    assert!(has_add, "Should contain i64.add instruction");
    
    let has_mul = main_func.body.iter().any(|instr| {
        matches!(instr, WasmInstr::I64Mul)
    });
    assert!(has_mul, "Should contain i64.mul instruction");
}

#[test]
fn test_division_builtin_wasm() {
    let expr = parse("(/ 20 4)").unwrap();
    let ir = transform_to_ir(&expr);
    
    let mut codegen = CodeGenerator::new();
    let module = codegen.generate(&ir).unwrap();
    
    let main_func = &module.functions[0];
    
    let has_div = main_func.body.iter().any(|instr| {
        matches!(instr, WasmInstr::I64DivS)
    });
    assert!(has_div, "Should contain i64.div_s instruction");
}