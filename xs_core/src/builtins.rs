//! Builtin functions for XS language
//!
//! This module provides a unified interface for builtin functions that can be
//! used by both the interpreter and the WebAssembly backend.

use crate::{Type, Value, XsError};

/// Trait for builtin functions
pub trait BuiltinFunction {
    /// Get the name of this builtin function
    fn name(&self) -> &str;

    /// Get the type signature of this builtin function
    fn type_signature(&self) -> Type;

    /// Interpret this function with given arguments
    fn interpret(&self, args: &[Value]) -> Result<Value, XsError>;

    /// Generate WebAssembly instructions for this function
    /// Returns a sequence of instructions that compute the result
    fn compile_to_wasm(&self) -> WasmBuiltin;
}

/// WebAssembly builtin representation
#[derive(Debug, Clone)]
pub enum WasmBuiltin {
    /// Simple instruction sequence
    Instructions(Vec<WasmInstrPattern>),
    /// Complex builtin requiring special handling
    Complex(String),
}

/// Pattern for WebAssembly instructions
#[derive(Debug, Clone)]
pub enum WasmInstrPattern {
    /// Pop arguments and push result
    Binary(BinaryOp),
    /// Unary operation
    Unary(UnaryOp),
    /// Custom instruction sequence
    Custom(Vec<String>),
}

#[derive(Debug, Clone)]
pub enum BinaryOp {
    I64Add,
    I64Sub,
    I64Mul,
    I64DivS,
    I64RemS,
    I64LtS,
    I64GtS,
    I64LeS,
    I64GeS,
    I64Eq,
    F64Add,
    F64Sub,
    F64Mul,
    F64Div,
}

#[derive(Debug, Clone)]
pub enum UnaryOp {
    I64Neg,
    F64Neg,
}

// Integer arithmetic

pub struct AddInt;
impl BuiltinFunction for AddInt {
    fn name(&self) -> &str {
        "+"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Int(a + b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "+ requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64Add)])
    }
}

pub struct SubInt;
impl BuiltinFunction for SubInt {
    fn name(&self) -> &str {
        "-"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Int(a - b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "- requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64Sub)])
    }
}

pub struct MulInt;
impl BuiltinFunction for MulInt {
    fn name(&self) -> &str {
        "*"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Int(a * b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "* requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64Mul)])
    }
}

pub struct DivInt;
impl BuiltinFunction for DivInt {
    fn name(&self) -> &str {
        "/"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => {
                if *b == 0 {
                    Err(XsError::RuntimeError(
                        crate::Span::new(0, 0),
                        "Division by zero".to_string(),
                    ))
                } else {
                    Ok(Value::Int(a / b))
                }
            }
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "/ requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64DivS)])
    }
}

pub struct ModInt;
impl BuiltinFunction for ModInt {
    fn name(&self) -> &str {
        "%"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Int))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => {
                if *b == 0 {
                    Err(XsError::RuntimeError(
                        crate::Span::new(0, 0),
                        "Modulo by zero".to_string(),
                    ))
                } else {
                    Ok(Value::Int(a % b))
                }
            }
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "% requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64RemS)])
    }
}

// Comparison operators

pub struct LessThan;
impl BuiltinFunction for LessThan {
    fn name(&self) -> &str {
        "<"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Bool(a < b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "< requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64LtS)])
    }
}

pub struct GreaterThan;
impl BuiltinFunction for GreaterThan {
    fn name(&self) -> &str {
        ">"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Bool(a > b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "> requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64GtS)])
    }
}

pub struct LessEqual;
impl BuiltinFunction for LessEqual {
    fn name(&self) -> &str {
        "<="
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Bool(a <= b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "<= requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64LeS)])
    }
}

pub struct GreaterEqual;
impl BuiltinFunction for GreaterEqual {
    fn name(&self) -> &str {
        ">="
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Bool(a >= b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                ">= requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64GeS)])
    }
}

pub struct Equal;
impl BuiltinFunction for Equal {
    fn name(&self) -> &str {
        "="
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Int),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::Bool))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(a), Value::Int(b)] => Ok(Value::Bool(a == b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "= requires two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::I64Eq)])
    }
}

// List operations

pub struct Cons;
impl BuiltinFunction for Cons {
    fn name(&self) -> &str {
        "cons"
    }

    fn type_signature(&self) -> Type {
        // cons : a -> List a -> List a
        Type::Function(
            Box::new(Type::Var("a".to_string())),
            Box::new(Type::Function(
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
                Box::new(Type::List(Box::new(Type::Var("a".to_string())))),
            )),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [head, Value::List(tail)] => {
                let mut result = vec![head.clone()];
                result.extend(tail.clone());
                Ok(Value::List(result))
            }
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "cons requires an element and a list".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        // Cons requires GC support for lists
        WasmBuiltin::Complex("cons".to_string())
    }
}

// String operations

pub struct Concat;
impl BuiltinFunction for Concat {
    fn name(&self) -> &str {
        "concat"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(
                Box::new(Type::String),
                Box::new(Type::String),
            )),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::String(a), Value::String(b)] => Ok(Value::String(format!("{a}{b}"))),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "concat requires two string arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("concat".to_string())
    }
}

// Floating point operations

pub struct AddFloat;
impl BuiltinFunction for AddFloat {
    fn name(&self) -> &str {
        "+."
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::Float),
            Box::new(Type::Function(Box::new(Type::Float), Box::new(Type::Float))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Float(a), Value::Float(b)] => Ok(Value::Float(a + b)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "+. requires two float arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![WasmInstrPattern::Binary(BinaryOp::F64Add)])
    }
}

/// Registry of all builtin functions
pub struct BuiltinRegistry {
    functions: Vec<Box<dyn BuiltinFunction>>,
}

impl BuiltinRegistry {
    pub fn new() -> Self {
        let functions: Vec<Box<dyn BuiltinFunction>> = vec![
            // Integer arithmetic
            Box::new(AddInt),
            Box::new(SubInt),
            Box::new(MulInt),
            Box::new(DivInt),
            Box::new(ModInt),
            // Comparisons
            Box::new(LessThan),
            Box::new(GreaterThan),
            Box::new(LessEqual),
            Box::new(GreaterEqual),
            Box::new(Equal),
            // List operations
            Box::new(Cons),
            // String operations
            Box::new(Concat),
            // Float operations
            Box::new(AddFloat),
        ];

        Self { functions }
    }

    pub fn get(&self, name: &str) -> Option<&dyn BuiltinFunction> {
        self.functions
            .iter()
            .find(|f| f.name() == name)
            .map(|f| f.as_ref())
    }

    pub fn all(&self) -> &[Box<dyn BuiltinFunction>] {
        &self.functions
    }
}

impl Default for BuiltinRegistry {
    fn default() -> Self {
        Self::new()
    }
}

// Re-export for convenience
pub use crate::ir::{TypedIrExpr, TypedPattern};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add_int() {
        let add = AddInt;
        assert_eq!(add.name(), "+");

        // Test successful addition
        let result = add.interpret(&[Value::Int(2), Value::Int(3)]).unwrap();
        assert_eq!(result, Value::Int(5));

        // Test error case
        let result = add.interpret(&[Value::Bool(true), Value::Int(3)]);
        assert!(result.is_err());
    }

    #[test]
    fn test_division_by_zero() {
        let div = DivInt;

        // Test normal division
        let result = div.interpret(&[Value::Int(10), Value::Int(2)]).unwrap();
        assert_eq!(result, Value::Int(5));

        // Test division by zero
        let result = div.interpret(&[Value::Int(10), Value::Int(0)]);
        assert!(result.is_err());
    }

    #[test]
    fn test_comparisons() {
        let lt = LessThan;
        assert_eq!(
            lt.interpret(&[Value::Int(1), Value::Int(2)]).unwrap(),
            Value::Bool(true)
        );
        assert_eq!(
            lt.interpret(&[Value::Int(2), Value::Int(1)]).unwrap(),
            Value::Bool(false)
        );

        let eq = Equal;
        assert_eq!(
            eq.interpret(&[Value::Int(2), Value::Int(2)]).unwrap(),
            Value::Bool(true)
        );
        assert_eq!(
            eq.interpret(&[Value::Int(2), Value::Int(3)]).unwrap(),
            Value::Bool(false)
        );
    }

    #[test]
    fn test_cons() {
        let cons = Cons;
        let result = cons
            .interpret(&[
                Value::Int(1),
                Value::List(vec![Value::Int(2), Value::Int(3)]),
            ])
            .unwrap();

        match result {
            Value::List(elems) => {
                assert_eq!(elems.len(), 3);
                assert_eq!(elems[0], Value::Int(1));
                assert_eq!(elems[1], Value::Int(2));
                assert_eq!(elems[2], Value::Int(3));
            }
            _ => panic!("Expected list"),
        }
    }

    #[test]
    fn test_float_addition() {
        let add_float = AddFloat;
        let result = add_float
            .interpret(&[Value::Float(1.5), Value::Float(2.5)])
            .unwrap();
        assert_eq!(result, Value::Float(4.0));
    }

    #[test]
    fn test_builtin_registry() {
        let registry = BuiltinRegistry::new();

        // Test finding builtins
        assert!(registry.get("+").is_some());
        assert!(registry.get("-").is_some());
        assert!(registry.get("*").is_some());
        assert!(registry.get("/").is_some());
        assert!(registry.get("<").is_some());
        assert!(registry.get("cons").is_some());
        assert!(registry.get("+.").is_some());
        assert!(registry.get("unknown").is_none());

        // Test all() method
        assert!(registry.all().len() > 0);
    }

    #[test]
    fn test_type_signatures() {
        let add = AddInt;
        match add.type_signature() {
            Type::Function(from, to) => {
                assert_eq!(*from, Type::Int);
                match to.as_ref() {
                    Type::Function(from2, to2) => {
                        assert_eq!(**from2, Type::Int);
                        assert_eq!(**to2, Type::Int);
                    }
                    _ => panic!("Expected curried function"),
                }
            }
            _ => panic!("Expected function type"),
        }
    }

    #[test]
    fn test_wasm_compilation() {
        let add = AddInt;
        match add.compile_to_wasm() {
            WasmBuiltin::Instructions(instrs) => {
                assert_eq!(instrs.len(), 1);
                match &instrs[0] {
                    WasmInstrPattern::Binary(BinaryOp::I64Add) => {}
                    _ => panic!("Expected I64Add"),
                }
            }
            _ => panic!("Expected Instructions"),
        }

        let cons = Cons;
        match cons.compile_to_wasm() {
            WasmBuiltin::Complex(name) => assert_eq!(name, "cons"),
            _ => panic!("Expected Complex"),
        }
    }
}
