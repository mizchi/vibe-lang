//! XS Language - AI-oriented programming language with S-expression syntax
//! 
//! This library provides the core functionality of the XS language,
//! including parsing, type checking, and interpretation.

pub use xs_core::{Expr, Type, Value, Environment, XsError};
pub use parser::parse;
pub use checker::{TypeChecker, type_check};
pub use interpreter::eval;

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