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

// I/O operations

pub struct Print;
impl BuiltinFunction for Print {
    fn name(&self) -> &str {
        "print"
    }

    fn type_signature(&self) -> Type {
        // print : a -> a
        // Returns the input value for chaining
        Type::Function(
            Box::new(Type::Var("a".to_string())),
            Box::new(Type::Var("a".to_string())),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [value] => {
                println!("{value}");
                Ok(value.clone())
            }
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "print requires exactly one argument".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        // Print requires WASI support for stdout
        WasmBuiltin::Complex("print".to_string())
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

pub struct StrConcat;
impl BuiltinFunction for StrConcat {
    fn name(&self) -> &str {
        "str-concat"
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
                "str-concat requires two string arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("str-concat".to_string())
    }
}

pub struct IntToString;
impl BuiltinFunction for IntToString {
    fn name(&self) -> &str {
        "int-to-string"
    }

    fn type_signature(&self) -> Type {
        Type::Function(Box::new(Type::Int), Box::new(Type::String))
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(n)] => Ok(Value::String(n.to_string())),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "int-to-string requires one integer argument".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("int-to-string".to_string())
    }
}

pub struct StringToInt;
impl BuiltinFunction for StringToInt {
    fn name(&self) -> &str {
        "string-to-int"
    }

    fn type_signature(&self) -> Type {
        Type::Function(Box::new(Type::String), Box::new(Type::Int))
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::String(s)] => match s.parse::<i64>() {
                Ok(n) => Ok(Value::Int(n)),
                Err(_) => Err(XsError::RuntimeError(
                    crate::Span::new(0, 0),
                    format!("Cannot parse '{s}' as integer"),
                )),
            },
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "string-to-int requires one string argument".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("string-to-int".to_string())
    }
}

pub struct StringLength;
impl BuiltinFunction for StringLength {
    fn name(&self) -> &str {
        "string-length"
    }

    fn type_signature(&self) -> Type {
        Type::Function(Box::new(Type::String), Box::new(Type::Int))
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::String(s)] => Ok(Value::Int(s.len() as i64)),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "string-length requires one string argument".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("string-length".to_string())
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

pub struct StrEq;
impl BuiltinFunction for StrEq {
    fn name(&self) -> &str {
        "str-eq"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(Box::new(Type::String), Box::new(Type::Bool))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::String(s1)] => Ok(Value::BuiltinFunction {
                name: "str-eq".to_string(),
                arity: 2,
                applied_args: vec![Value::String(s1.clone())],
            }),
            [Value::String(s1), Value::String(s2)] => Ok(Value::Bool(s1 == s2)),
            [arg] => Err(XsError::TypeError(
                crate::Span::new(0, 0),
                format!("str-eq expects string argument, got {arg:?}"),
            )),
            args => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                format!("str-eq expects 2 arguments, got {}", args.len()),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![]) // String comparison is not yet supported in WASM
    }
}

pub struct StringAt;
impl BuiltinFunction for StringAt {
    fn name(&self) -> &str {
        "stringAt"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::String))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::String(s), Value::Int(idx)] => {
                let idx = *idx as usize;
                if idx >= s.len() {
                    Err(XsError::RuntimeError(
                        crate::Span::new(0, 0),
                        format!(
                            "String index {idx} out of bounds for string of length {}",
                            s.len()
                        ),
                    ))
                } else {
                    // Get the character at the given index
                    let char = s.chars().nth(idx).unwrap();
                    Ok(Value::String(char.to_string()))
                }
            }
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "stringAt requires a string and an integer argument".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("stringAt".to_string())
    }
}

pub struct CharCode;
impl BuiltinFunction for CharCode {
    fn name(&self) -> &str {
        "charCode"
    }

    fn type_signature(&self) -> Type {
        Type::Function(Box::new(Type::String), Box::new(Type::Int))
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::String(s)] => {
                if s.is_empty() {
                    Err(XsError::RuntimeError(
                        crate::Span::new(0, 0),
                        "charCode requires a non-empty string".to_string(),
                    ))
                } else {
                    let char = s.chars().next().unwrap();
                    Ok(Value::Int(char as u32 as i64))
                }
            }
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "charCode requires one string argument".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("charCode".to_string())
    }
}

pub struct CodeChar;
impl BuiltinFunction for CodeChar {
    fn name(&self) -> &str {
        "codeChar"
    }

    fn type_signature(&self) -> Type {
        Type::Function(Box::new(Type::Int), Box::new(Type::String))
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::Int(code)] => {
                if *code < 0 || *code > 0x10FFFF {
                    Err(XsError::RuntimeError(
                        crate::Span::new(0, 0),
                        format!("Invalid character code: {code}"),
                    ))
                } else {
                    match char::from_u32(*code as u32) {
                        Some(ch) => Ok(Value::String(ch.to_string())),
                        None => Err(XsError::RuntimeError(
                            crate::Span::new(0, 0),
                            format!("Invalid character code: {code}"),
                        )),
                    }
                }
            }
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "codeChar requires one integer argument".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("codeChar".to_string())
    }
}

pub struct StringSlice;
impl BuiltinFunction for StringSlice {
    fn name(&self) -> &str {
        "stringSlice"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(
                Box::new(Type::Int),
                Box::new(Type::Function(Box::new(Type::Int), Box::new(Type::String))),
            )),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [Value::String(s), Value::Int(start), Value::Int(end)] => {
                let start = *start as usize;
                let end = *end as usize;
                let chars: Vec<char> = s.chars().collect();

                if start > chars.len() || end > chars.len() || start > end {
                    Err(XsError::RuntimeError(
                        crate::Span::new(0, 0),
                        format!(
                            "Invalid slice bounds: start={start}, end={end}, length={}",
                            chars.len()
                        ),
                    ))
                } else {
                    let slice: String = chars[start..end].iter().collect();
                    Ok(Value::String(slice))
                }
            }
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "stringSlice requires a string and two integer arguments".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("stringSlice".to_string())
    }
}

pub struct ToString;
impl BuiltinFunction for ToString {
    fn name(&self) -> &str {
        "toString"
    }

    fn type_signature(&self) -> Type {
        // toString : a -> String
        Type::Function(Box::new(Type::Var("a".to_string())), Box::new(Type::String))
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        match args {
            [value] => Ok(Value::String(format!("{value}"))),
            _ => Err(XsError::RuntimeError(
                crate::Span::new(0, 0),
                "toString requires exactly one argument".to_string(),
            )),
        }
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("toString".to_string())
    }
}

// Aliases for lowerCamelCase naming
pub struct StringConcat;
impl BuiltinFunction for StringConcat {
    fn name(&self) -> &str {
        "stringConcat"
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
        StrConcat.interpret(args)
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Complex("stringConcat".to_string())
    }
}

pub struct StringEq;
impl BuiltinFunction for StringEq {
    fn name(&self) -> &str {
        "stringEq"
    }

    fn type_signature(&self) -> Type {
        Type::Function(
            Box::new(Type::String),
            Box::new(Type::Function(Box::new(Type::String), Box::new(Type::Bool))),
        )
    }

    fn interpret(&self, args: &[Value]) -> Result<Value, XsError> {
        StrEq.interpret(args)
    }

    fn compile_to_wasm(&self) -> WasmBuiltin {
        WasmBuiltin::Instructions(vec![])
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
            // I/O operations
            Box::new(Print),
            // String operations
            Box::new(Concat),
            Box::new(StrConcat),
            Box::new(IntToString),
            Box::new(StringToInt),
            Box::new(StringLength),
            Box::new(StrEq),
            Box::new(StringAt),
            Box::new(CharCode),
            Box::new(CodeChar),
            Box::new(StringSlice),
            Box::new(ToString),
            Box::new(StringConcat), // lowerCamelCase alias
            Box::new(StringEq),     // lowerCamelCase alias
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
        assert!(registry.get("stringAt").is_some());
        assert!(registry.get("charCode").is_some());
        assert!(registry.get("codeChar").is_some());
        assert!(registry.get("stringSlice").is_some());
        assert!(registry.get("toString").is_some());
        assert!(registry.get("stringConcat").is_some());
        assert!(registry.get("stringEq").is_some());
        assert!(registry.get("unknown").is_none());

        // Test all() method
        assert!(!registry.all().is_empty());
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

    #[test]
    fn test_string_at() {
        let string_at = StringAt;
        assert_eq!(string_at.name(), "stringAt");

        // Test successful access
        let result = string_at
            .interpret(&[Value::String("hello".to_string()), Value::Int(1)])
            .unwrap();
        assert_eq!(result, Value::String("e".to_string()));

        // Test out of bounds
        let result = string_at.interpret(&[Value::String("hi".to_string()), Value::Int(5)]);
        assert!(result.is_err());
    }

    #[test]
    fn test_char_code() {
        let char_code = CharCode;
        assert_eq!(char_code.name(), "charCode");

        // Test ASCII character
        let result = char_code
            .interpret(&[Value::String("A".to_string())])
            .unwrap();
        assert_eq!(result, Value::Int(65));

        // Test empty string
        let result = char_code.interpret(&[Value::String("".to_string())]);
        assert!(result.is_err());
    }

    #[test]
    fn test_code_char() {
        let code_char = CodeChar;
        assert_eq!(code_char.name(), "codeChar");

        // Test valid code
        let result = code_char.interpret(&[Value::Int(65)]).unwrap();
        assert_eq!(result, Value::String("A".to_string()));

        // Test invalid code (negative)
        let result = code_char.interpret(&[Value::Int(-1)]);
        assert!(result.is_err());

        // Test invalid code (too large)
        let result = code_char.interpret(&[Value::Int(0x110000)]);
        assert!(result.is_err());
    }

    #[test]
    fn test_string_slice() {
        let string_slice = StringSlice;
        assert_eq!(string_slice.name(), "stringSlice");

        // Test normal slice
        let result = string_slice
            .interpret(&[
                Value::String("hello world".to_string()),
                Value::Int(0),
                Value::Int(5),
            ])
            .unwrap();
        assert_eq!(result, Value::String("hello".to_string()));

        // Test slice in middle
        let result = string_slice
            .interpret(&[
                Value::String("hello world".to_string()),
                Value::Int(6),
                Value::Int(11),
            ])
            .unwrap();
        assert_eq!(result, Value::String("world".to_string()));

        // Test invalid bounds
        let result = string_slice.interpret(&[
            Value::String("hi".to_string()),
            Value::Int(0),
            Value::Int(10),
        ]);
        assert!(result.is_err());
    }

    #[test]
    fn test_to_string() {
        let to_string = ToString;
        assert_eq!(to_string.name(), "toString");

        // Test with integer
        let result = to_string.interpret(&[Value::Int(42)]).unwrap();
        assert_eq!(result, Value::String("42".to_string()));

        // Test with boolean
        let result = to_string.interpret(&[Value::Bool(true)]).unwrap();
        assert_eq!(result, Value::String("true".to_string()));

        // Test with string (should return the same)
        let result = to_string
            .interpret(&[Value::String("hello".to_string())])
            .unwrap();
        assert_eq!(result, Value::String("\"hello\"".to_string()));
    }
}
