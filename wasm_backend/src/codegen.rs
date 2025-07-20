//! WebAssembly GC code generation implementation

use crate::{CodeGenError, WasmFunction, WasmInstr, WasmModule, WasmType};
// ordered_float is re-exported from xs_core
use std::collections::HashMap;
use xs_core::ir::IrExpr;
use xs_core::Literal;

/// Code generator for WebAssembly GC
pub struct CodeGenerator {
    /// Current function being generated
    current_function: Option<WasmFunction>,
    /// Local variable indices
    locals: HashMap<String, u32>,
    /// Next local index
    next_local: u32,
    /// Generated functions
    functions: Vec<WasmFunction>,
    // TODO: The following fields will be used when implementing WebAssembly GC features:
    // - type_allocator: TypeIndexAllocator - for managing GC type indices
    // - std_types: StandardTypes - standard GC types (structs, arrays)
    // - function_indices: HashMap<String, u32> - for function table management
}

impl Default for CodeGenerator {
    fn default() -> Self {
        Self::new()
    }
}

impl CodeGenerator {
    pub fn new() -> Self {
        Self {
            current_function: None,
            locals: HashMap::new(),
            next_local: 0,
            functions: Vec::new(),
        }
    }

    /// Generate WebAssembly module from IR
    pub fn generate(&mut self, ir: &IrExpr) -> Result<WasmModule, CodeGenError> {
        // Start with main function
        // For now, we'll return i32 as the exit code (0 for success)
        self.start_function("main", vec![], vec![WasmType::I32]);

        // Generate code for the expression
        self.generate_expr(ir)?;

        // Drop the expression result (whatever type it is)
        self.emit(WasmInstr::Drop);

        // Add return value (0 for success)
        self.emit(WasmInstr::I32Const(0));

        // Finish main function
        let main_func = self.finish_function()?;
        self.functions.push(main_func);

        Ok(WasmModule {
            functions: self.functions.clone(),
            types: vec![], // TODO: Generate type definitions
            globals: vec![],
            memory: None,
            start: None, // Don't automatically start main
        })
    }

    /// Generate code for an IR expression
    fn generate_expr(&mut self, expr: &IrExpr) -> Result<(), CodeGenError> {
        match expr {
            IrExpr::Literal(lit) => self.generate_literal(lit),
            IrExpr::Var(name) => self.generate_var(name),
            IrExpr::Let { name, value, body } => self.generate_let(name, value, body),
            IrExpr::Lambda { params, body } => self.generate_lambda(params, body),
            IrExpr::Apply { func, args } => self.generate_apply(func, args),
            IrExpr::If {
                cond,
                then_expr,
                else_expr,
            } => self.generate_if(cond, then_expr, else_expr),
            IrExpr::List(exprs) => self.generate_list(exprs),
            IrExpr::Drop(name) => self.generate_drop(name),
            IrExpr::Dup(name) => self.generate_dup(name),
            _ => Err(CodeGenError::UnsupportedExpr(format!("{expr:?}"))),
        }
    }

    /// Generate literal value
    fn generate_literal(&mut self, lit: &Literal) -> Result<(), CodeGenError> {
        match lit {
            Literal::Int(n) => {
                self.emit(WasmInstr::I64Const(*n));
                Ok(())
            }
            Literal::Bool(b) => {
                self.emit(WasmInstr::I32Const(if *b { 1 } else { 0 }));
                Ok(())
            }
            Literal::String(_s) => {
                // TODO: Implement string literal generation
                // For now, just push null
                self.emit(WasmInstr::RefNull(WasmType::ArrayRef(0)));
                Ok(())
            }
            Literal::Float(f) => {
                self.emit(WasmInstr::F64Const(f.0));
                Ok(())
            }
        }
    }

    /// Generate variable reference
    fn generate_var(&mut self, name: &str) -> Result<(), CodeGenError> {
        if let Some(&idx) = self.locals.get(name) {
            self.emit(WasmInstr::LocalGet(idx));
            Ok(())
        } else {
            Err(CodeGenError::UndefinedVariable(name.to_string()))
        }
    }

    /// Generate let binding
    fn generate_let(
        &mut self,
        name: &str,
        value: &IrExpr,
        body: &IrExpr,
    ) -> Result<(), CodeGenError> {
        // Generate value
        self.generate_expr(value)?;

        // Allocate local
        let local_idx = self.allocate_local(name);
        self.emit(WasmInstr::LocalSet(local_idx));

        // Generate body
        self.generate_expr(body)?;

        // Clean up local
        self.locals.remove(name);

        Ok(())
    }

    /// Generate lambda
    fn generate_lambda(&mut self, _params: &[String], _body: &IrExpr) -> Result<(), CodeGenError> {
        // TODO: Implement closure creation
        // For now, just push null
        self.emit(WasmInstr::RefNull(WasmType::StructRef(0)));
        Ok(())
    }

    /// Generate function application
    fn generate_apply(&mut self, func: &IrExpr, args: &[IrExpr]) -> Result<(), CodeGenError> {
        // Check if this is a builtin function
        if let IrExpr::Var(name) = func {
            if let Some(()) = self.try_generate_builtin(name, args)? {
                return Ok(());
            }
        }

        // Generate function
        self.generate_expr(func)?;

        // Generate arguments
        for arg in args {
            self.generate_expr(arg)?;
        }

        // TODO: Implement proper function call
        // For now, just drop all values and push 0
        for _ in 0..=args.len() {
            self.emit(WasmInstr::Drop);
        }
        self.emit(WasmInstr::I64Const(0));

        Ok(())
    }

    /// Generate if expression
    fn generate_if(
        &mut self,
        cond: &IrExpr,
        then_expr: &IrExpr,
        else_expr: &IrExpr,
    ) -> Result<(), CodeGenError> {
        // Generate condition
        self.generate_expr(cond)?;

        // Generate if instruction
        let mut then_instrs = vec![];
        let mut else_instrs = vec![];

        // Save current instructions
        let saved_instrs = self.current_function.as_ref().map(|f| f.body.clone());

        // Generate then branch
        if let Some(ref mut func) = self.current_function {
            func.body.clear();
        }
        self.generate_expr(then_expr)?;
        if let Some(ref func) = self.current_function {
            then_instrs = func.body.clone();
        }

        // Generate else branch
        if let Some(ref mut func) = self.current_function {
            func.body.clear();
        }
        self.generate_expr(else_expr)?;
        if let Some(ref func) = self.current_function {
            else_instrs = func.body.clone();
        }

        // Restore instructions and add if
        if let Some(ref mut func) = self.current_function {
            func.body = saved_instrs.unwrap_or_default();
            func.body.push(WasmInstr::If {
                result_type: None, // TODO: Determine result type
                then_instrs,
                else_instrs,
            });
        }

        Ok(())
    }

    /// Generate list
    fn generate_list(&mut self, _exprs: &[IrExpr]) -> Result<(), CodeGenError> {
        // TODO: Implement list creation
        // For now, just push null
        self.emit(WasmInstr::RefNull(WasmType::ArrayRef(0)));
        Ok(())
    }

    /// Generate drop instruction
    fn generate_drop(&mut self, name: &str) -> Result<(), CodeGenError> {
        self.generate_var(name)?;
        self.emit(WasmInstr::Drop);
        Ok(())
    }

    /// Generate dup instruction
    fn generate_dup(&mut self, name: &str) -> Result<(), CodeGenError> {
        self.generate_var(name)?;
        self.emit(WasmInstr::Dup);
        Ok(())
    }

    /// Start a new function
    fn start_function(&mut self, name: &str, params: Vec<WasmType>, results: Vec<WasmType>) {
        self.current_function = Some(WasmFunction {
            name: name.to_string(),
            params,
            results,
            locals: vec![],
            body: vec![],
        });
        self.locals.clear();
        self.next_local = 0;
    }

    /// Finish current function
    fn finish_function(&mut self) -> Result<WasmFunction, CodeGenError> {
        self.current_function
            .take()
            .ok_or_else(|| CodeGenError::UnsupportedExpr("No function to finish".to_string()))
    }

    /// Emit instruction
    fn emit(&mut self, instr: WasmInstr) {
        if let Some(ref mut func) = self.current_function {
            func.body.push(instr);
        }
    }

    /// Allocate a local variable
    fn allocate_local(&mut self, name: &str) -> u32 {
        let idx = self.next_local;
        self.next_local += 1;
        self.locals.insert(name.to_string(), idx);

        // Add to function locals
        if let Some(ref mut func) = self.current_function {
            func.locals.push(WasmType::I64); // Default to i64 for now
        }

        idx
    }

    /// Try to generate builtin function call
    fn try_generate_builtin(&mut self, name: &str, args: &[IrExpr]) -> Result<Option<()>, CodeGenError> {
        // Check if this is a builtin function
        let is_builtin = match name {
            "+" | "-" | "*" | "/" | "%" | "<" | ">" | "=" | "<=" | ">=" | "cons" | "concat" => true,
            _ => false,
        };

        if !is_builtin {
            return Ok(None);
        }

        // Generate arguments first
        for arg in args {
            self.generate_expr(arg)?;
        }

        // Generate builtin operation
        match name {
            "+" => self.emit(WasmInstr::I64Add),
            "-" => self.emit(WasmInstr::I64Sub),
            "*" => self.emit(WasmInstr::I64Mul),
            "/" => self.emit(WasmInstr::I64DivS),
            "%" => self.emit(WasmInstr::I64RemS),
            "<" => {
                self.emit(WasmInstr::I64LtS);
                // Convert i32 to i64 for consistency
                self.emit(WasmInstr::I64ExtendI32S);
            }
            ">" => {
                self.emit(WasmInstr::I64GtS);
                // Convert i32 to i64 for consistency
                self.emit(WasmInstr::I64ExtendI32S);
            }
            "=" => {
                self.emit(WasmInstr::I64Eq);
                // Convert i32 to i64 for consistency
                self.emit(WasmInstr::I64ExtendI32S);
            }
            "<=" => {
                self.emit(WasmInstr::I64LeS);
                // Convert i32 to i64 for consistency
                self.emit(WasmInstr::I64ExtendI32S);
            }
            ">=" => {
                self.emit(WasmInstr::I64GeS);
                // Convert i32 to i64 for consistency
                self.emit(WasmInstr::I64ExtendI32S);
            }
            "cons" | "concat" => {
                // TODO: Implement list/string operations
                // For now, just drop arguments and push dummy value
                for _ in 0..args.len() {
                    self.emit(WasmInstr::Drop);
                }
                self.emit(WasmInstr::I64Const(0));
            }
            _ => unreachable!("Already checked that this is a builtin"),
        }

        Ok(Some(()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_literal_generation() {
        let mut gen = CodeGenerator::new();
        gen.start_function("test", vec![], vec![]);

        let lit = IrExpr::Literal(Literal::Int(42));
        gen.generate_expr(&lit).unwrap();

        let func = gen.finish_function().unwrap();
        assert_eq!(func.body.len(), 1);
        match &func.body[0] {
            WasmInstr::I64Const(n) => assert_eq!(*n, 42),
            _ => panic!("Expected I64Const"),
        }
    }

    #[test]
    fn test_let_generation() {
        let mut gen = CodeGenerator::new();
        gen.start_function("test", vec![], vec![]);

        let expr = IrExpr::Let {
            name: "x".to_string(),
            value: Box::new(IrExpr::Literal(Literal::Int(10))),
            body: Box::new(IrExpr::Var("x".to_string())),
        };

        gen.generate_expr(&expr).unwrap();
        let func = gen.finish_function().unwrap();

        // Should have: i64.const 10, local.set 0, local.get 0
        assert!(func.body.len() >= 3);
    }
}
