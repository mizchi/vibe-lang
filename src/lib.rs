//! XS Language - AI-oriented programming language with S-expression syntax
//!
//! This library provides the core functionality of the XS language,
//! including parsing, type checking, and interpretation.

pub use checker::{type_check, TypeChecker};
pub use interpreter::eval;
pub use parser::parse;
pub use xs_core::{Environment, Expr, Type, Value, XsError};

/// Parse and type check a program
pub fn compile(source: &str) -> Result<(Expr, Type), XsError> {
    let expr = parse(source)?;
    let ty = type_check(&expr)?;
    Ok((expr, ty))
}

/// Parse, type check, and run a program
pub fn run(source: &str) -> Result<Value, XsError> {
    let (expr, _ty) = compile(source)?;
    eval(&expr)
}
