//! WebAssembly Text Format (WAT) emission
//!
//! This module converts our WebAssembly IR into WAT format,
//! which can then be compiled and executed by Wasmtime.

use crate::{WasmFunction, WasmInstr, WasmModule, WasmType};
use std::fmt::Write;

/// Emit a WebAssembly module as WAT text
pub fn emit_wat(module: &WasmModule) -> Result<String, std::fmt::Error> {
    let mut output = String::new();

    writeln!(output, "(module")?;

    // Emit type definitions
    emit_types(&mut output, module)?;

    // Emit memory if present
    if let Some(memory) = &module.memory {
        writeln!(
            output,
            "  (memory {} {})",
            memory.min_pages,
            memory.max_pages.map_or("".to_string(), |m| m.to_string())
        )?;
    }

    // Emit globals
    for global in &module.globals {
        emit_global(&mut output, global)?;
    }

    // Emit functions
    for (idx, func) in module.functions.iter().enumerate() {
        emit_function(&mut output, func, idx as u32)?;
    }

    // Emit start function if present
    if let Some(start_idx) = module.start {
        writeln!(output, "  (start $func{start_idx})")?;
    }

    // Export main function (only if not already exported in function definition)
    // Note: We already export functions inline, so this is not needed
    // if !module.functions.is_empty() {
    //     writeln!(output, "  (export \"main\" (func $func0))")?;
    // }

    writeln!(output, ")")?;

    Ok(output)
}

/// Emit type definitions
fn emit_types(output: &mut String, _module: &WasmModule) -> Result<(), std::fmt::Error> {
    // For now, we'll define standard types inline
    // In a full implementation, this would emit actual type definitions

    // Define basic struct types for runtime
    writeln!(output, "  ;; Type definitions")?;
    writeln!(output, "  ;; TODO: Add GC struct and array types")?;

    Ok(())
}

/// Emit a global variable
fn emit_global(output: &mut String, global: &crate::WasmGlobal) -> Result<(), std::fmt::Error> {
    write!(output, "  (global ${} ", global.name)?;
    if global.mutable {
        write!(output, "(mut ")?;
    }
    emit_type(output, &global.ty)?;
    if global.mutable {
        write!(output, ")")?;
    }
    write!(output, " ")?;
    emit_instruction(output, &global.init, 0)?;
    writeln!(output, ")")?;
    Ok(())
}

/// Emit a function
fn emit_function(
    output: &mut String,
    func: &WasmFunction,
    idx: u32,
) -> Result<(), std::fmt::Error> {
    write!(output, "  (func $func{} (export \"{}\")", idx, func.name)?;

    // Emit parameters
    for (i, param) in func.params.iter().enumerate() {
        write!(output, " (param $p{i} ")?;
        emit_type(output, param)?;
        write!(output, ")")?;
    }

    // Emit results
    for result in &func.results {
        write!(output, " (result ")?;
        emit_type(output, result)?;
        write!(output, ")")?;
    }

    writeln!(output)?;

    // Emit locals
    for (i, local) in func.locals.iter().enumerate() {
        write!(output, "    (local $l{i} ")?;
        emit_type(output, local)?;
        writeln!(output, ")")?;
    }

    // Emit body
    for instr in &func.body {
        write!(output, "    ")?;
        emit_instruction(output, instr, 2)?;
        writeln!(output)?;
    }

    writeln!(output, "  )")?;
    Ok(())
}

/// Emit a type
fn emit_type(output: &mut String, ty: &WasmType) -> Result<(), std::fmt::Error> {
    match ty {
        WasmType::I32 => write!(output, "i32"),
        WasmType::I64 => write!(output, "i64"),
        WasmType::F32 => write!(output, "f32"),
        WasmType::F64 => write!(output, "f64"),
        WasmType::StructRef(idx) => write!(output, "(ref $struct{idx})"),
        WasmType::ArrayRef(idx) => write!(output, "(ref $array{idx})"),
        WasmType::FuncRef(idx) => write!(output, "(ref $func{idx})"),
        WasmType::AnyRef => write!(output, "anyref"),
        WasmType::Ref(inner) => {
            write!(output, "(ref ")?;
            emit_type(output, inner)?;
            write!(output, ")")
        }
    }
}

/// Emit an instruction
fn emit_instruction(
    output: &mut String,
    instr: &WasmInstr,
    indent: usize,
) -> Result<(), std::fmt::Error> {
    match instr {
        // Constants
        WasmInstr::I32Const(n) => write!(output, "i32.const {n}"),
        WasmInstr::I64Const(n) => write!(output, "i64.const {n}"),
        WasmInstr::F32Const(f) => write!(output, "f32.const {f}"),
        WasmInstr::F64Const(f) => write!(output, "f64.const {f}"),

        // Local operations
        WasmInstr::LocalGet(idx) => write!(output, "local.get $l{idx}"),
        WasmInstr::LocalSet(idx) => write!(output, "local.set $l{idx}"),
        WasmInstr::LocalTee(idx) => write!(output, "local.tee $l{idx}"),

        // Global operations
        WasmInstr::GlobalGet(idx) => write!(output, "global.get {idx}"),
        WasmInstr::GlobalSet(idx) => write!(output, "global.set {idx}"),

        // Control flow
        WasmInstr::Block(instrs) => {
            writeln!(output, "block")?;
            for instr in instrs {
                write!(output, "{}", " ".repeat(indent + 2))?;
                emit_instruction(output, instr, indent + 2)?;
                writeln!(output)?;
            }
            write!(output, "{}end", " ".repeat(indent))
        }
        WasmInstr::Loop(instrs) => {
            writeln!(output, "loop")?;
            for instr in instrs {
                write!(output, "{}", " ".repeat(indent + 2))?;
                emit_instruction(output, instr, indent + 2)?;
                writeln!(output)?;
            }
            write!(output, "{}end", " ".repeat(indent))
        }
        WasmInstr::If {
            result_type,
            then_instrs,
            else_instrs,
        } => {
            write!(output, "if")?;
            if let Some(ty) = result_type {
                write!(output, " (result ")?;
                emit_type(output, ty)?;
                write!(output, ")")?;
            }
            if !then_instrs.is_empty() {
                writeln!(output)?;
                for instr in then_instrs {
                    write!(output, "{}", " ".repeat(indent + 2))?;
                    emit_instruction(output, instr, indent + 2)?;
                    writeln!(output)?;
                }
                write!(output, "{}", " ".repeat(indent))?;
            } else {
                write!(output, " ")?;
            }
            if !else_instrs.is_empty() {
                writeln!(output, "else")?;
                for instr in else_instrs {
                    write!(output, "{}", " ".repeat(indent + 2))?;
                    emit_instruction(output, instr, indent + 2)?;
                    writeln!(output)?;
                }
                write!(output, "{}", " ".repeat(indent))?;
            }
            write!(output, "end")
        }
        WasmInstr::Br(label) => write!(output, "br {label}"),
        WasmInstr::BrIf(label) => write!(output, "br_if {label}"),
        WasmInstr::Return => write!(output, "return"),
        WasmInstr::Call(idx) => write!(output, "call $func{idx}"),
        WasmInstr::CallIndirect(idx) => write!(output, "call_indirect {idx}"),

        // Memory operations
        WasmInstr::I32Load => write!(output, "i32.load"),
        WasmInstr::I64Load => write!(output, "i64.load"),
        WasmInstr::I32Store => write!(output, "i32.store"),
        WasmInstr::I64Store => write!(output, "i64.store"),

        // Arithmetic
        WasmInstr::I32Add => write!(output, "i32.add"),
        WasmInstr::I32Sub => write!(output, "i32.sub"),
        WasmInstr::I32Mul => write!(output, "i32.mul"),
        WasmInstr::I32DivS => write!(output, "i32.div_s"),
        WasmInstr::I32RemS => write!(output, "i32.rem_s"),
        WasmInstr::I64Add => write!(output, "i64.add"),
        WasmInstr::I64Sub => write!(output, "i64.sub"),
        WasmInstr::I64Mul => write!(output, "i64.mul"),
        WasmInstr::I64DivS => write!(output, "i64.div_s"),
        WasmInstr::I64RemS => write!(output, "i64.rem_s"),

        // Comparisons
        WasmInstr::I32Eq => write!(output, "i32.eq"),
        WasmInstr::I32Ne => write!(output, "i32.ne"),
        WasmInstr::I32LtS => write!(output, "i32.lt_s"),
        WasmInstr::I32LeS => write!(output, "i32.le_s"),
        WasmInstr::I32GtS => write!(output, "i32.gt_s"),
        WasmInstr::I32GeS => write!(output, "i32.ge_s"),
        WasmInstr::I64Eq => write!(output, "i64.eq"),
        WasmInstr::I64Ne => write!(output, "i64.ne"),
        WasmInstr::I64LtS => write!(output, "i64.lt_s"),
        WasmInstr::I64LeS => write!(output, "i64.le_s"),
        WasmInstr::I64GtS => write!(output, "i64.gt_s"),
        WasmInstr::I64GeS => write!(output, "i64.ge_s"),

        // Conversions
        WasmInstr::I32ExtendI64S => write!(output, "i64.extend32_s"),
        WasmInstr::I64ExtendI32S => write!(output, "i64.extend_i32_s"),

        // Stack operations
        WasmInstr::Drop => write!(output, "drop"),
        WasmInstr::Dup => write!(output, "unreachable"), // No direct dup in wasm

        // GC operations (not yet in standard WAT)
        WasmInstr::StructNew(idx) => write!(output, "struct.new {idx}"),
        WasmInstr::StructGet(type_idx, field_idx) => {
            write!(output, "struct.get {type_idx} {field_idx}")
        }
        WasmInstr::StructSet(type_idx, field_idx) => {
            write!(output, "struct.set {type_idx} {field_idx}")
        }
        WasmInstr::ArrayNew(idx) => write!(output, "array.new {idx}"),
        WasmInstr::ArrayGet(idx) => write!(output, "array.get {idx}"),
        WasmInstr::ArraySet(idx) => write!(output, "array.set {idx}"),
        WasmInstr::ArrayLen => write!(output, "array.len"),
        WasmInstr::RefNull(ty) => {
            write!(output, "ref.null ")?;
            emit_type(output, ty)
        }
        WasmInstr::RefIsNull => write!(output, "ref.is_null"),
        WasmInstr::RefCast(ty) => {
            write!(output, "ref.cast ")?;
            emit_type(output, ty)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_emit_simple_module() {
        let module = WasmModule {
            functions: vec![WasmFunction {
                name: "main".to_string(),
                params: vec![],
                results: vec![WasmType::I32],
                locals: vec![],
                body: vec![WasmInstr::I32Const(42)],
            }],
            types: vec![],
            globals: vec![],
            memory: None,
            start: Some(0),
        };

        let wat = emit_wat(&module).unwrap();
        assert!(wat.contains("(module"));
        assert!(wat.contains("(func $func0"));
        assert!(wat.contains("i32.const 42"));
        assert!(wat.contains("(export \"main\""));
    }

    #[test]
    fn test_emit_with_locals() {
        let module = WasmModule {
            functions: vec![WasmFunction {
                name: "add".to_string(),
                params: vec![WasmType::I64, WasmType::I64],
                results: vec![WasmType::I64],
                locals: vec![WasmType::I64],
                body: vec![
                    WasmInstr::LocalGet(0),
                    WasmInstr::LocalGet(1),
                    WasmInstr::I64Add,
                    WasmInstr::LocalSet(2),
                    WasmInstr::LocalGet(2),
                ],
            }],
            types: vec![],
            globals: vec![],
            memory: None,
            start: None,
        };

        let wat = emit_wat(&module).unwrap();
        assert!(wat.contains("(param $p0 i64)"));
        assert!(wat.contains("(param $p1 i64)"));
        assert!(wat.contains("(result i64)"));
        assert!(wat.contains("(local $l0 i64)"));
        assert!(wat.contains("i64.add"));
    }
}
